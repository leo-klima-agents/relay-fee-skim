// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IRelayEntrypoint} from "./interfaces/IRelayEntrypoint.sol";

/// @title  RelayFeeSkim
/// @notice Takes a fixed basis-point fee from a Metadex (Aero v3) Relay's rewards and forwards it to a
///         fixed sink. Sits in the Relay's `converter` slot so it may call `pull`; never calls
///         `notifyReward`, never swaps, holds no storage, has no owner.
/// @dev Two paths:
///      - `claimAndSkim` (permissionless): claims rewards on the Relay's behalf and taxes exactly the
///        balance delta the claim produced.
///      - `skim` (KEEPER-gated): taxes whatever un-notified balance is idle on the Relay. Gated because
///        repeated calls compound the fee on the same base (see README).
///      Every unit this contract moves is bounded by the Relay's own `pull` check, so rewards already
///      notified to holders (`accountedBalance`) are unreachable.
contract RelayFeeSkim {
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Hard cap on the fee rate: 10%.
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Fee rate in basis points, fixed at deploy.
    uint256 public immutable FEE_BPS;

    /// @notice Recipient of every skimmed unit, fixed at deploy.
    address public immutable FEE_SINK;

    /// @dev Reentrancy lock. Transient, so it costs no persistent storage and resets each transaction.
    bool transient _locked;

    /// @notice Emitted once per token per successful skim.
    /// @param relay Relay the fee was pulled from.
    /// @param token Token skimmed.
    /// @param base Amount the fee was computed on (claim delta or idle balance).
    /// @param fee Amount pulled from the Relay.
    event Skimmed(address indexed relay, address indexed token, uint256 base, uint256 fee);

    error FeeOutOfRange();
    error ZeroAddress();
    error TokensNotSorted();
    error NoFee();
    error NotKeeper();
    error TransferFailed();
    error Reentrancy();

    /// @param feeBps Fee rate in basis points, in (0, MAX_FEE_BPS].
    /// @param feeSink Recipient of skimmed tokens.
    constructor(uint256 feeBps, address feeSink) {
        if (feeBps == 0 || feeBps > MAX_FEE_BPS) revert FeeOutOfRange();
        if (feeSink == address(0)) revert ZeroAddress();
        FEE_BPS = feeBps;
        FEE_SINK = feeSink;
    }

    /// @dev Kept inline on purpose: six lines, no library, no internal helpers to audit.
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @notice Claim the Relay's root-chain rewards, then take the fee on exactly what the claim brought in.
    /// @param relay Relay to claim for and pull from.
    /// @param feeClaims Fee claim requests forwarded to the Voter.
    /// @param incentiveClaims Incentive claim requests forwarded to the Voter.
    /// @param tokens Tokens to measure and tax; strictly ascending, no duplicates.
    /// @return fees Fee taken per token, aligned with `tokens`.
    /// @dev No `accountedBalance` subtraction: a claim delta is un-accounted by construction, and the
    ///      Relay's `pull` still enforces its bound. Sorting is required so a token cannot be listed
    ///      twice and have its delta taxed twice.
    function claimAndSkim(
        address relay,
        IRelayEntrypoint.FeeClaim[] calldata feeClaims,
        IRelayEntrypoint.IncentiveClaim[] calldata incentiveClaims,
        address[] calldata tokens
    ) external nonReentrant returns (uint256[] memory fees) {
        uint256 n = tokens.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (i != 0 && tokens[i] <= tokens[i - 1]) revert TokensNotSorted();
            before[i] = IERC20Minimal(tokens[i]).balanceOf(relay);
        }

        IRelayEntrypoint(relay).claimRewards(block.chainid, 0, feeClaims, incentiveClaims);

        fees = new uint256[](n);
        bool any;
        for (uint256 i; i < n; ++i) {
            uint256 balance = IERC20Minimal(tokens[i]).balanceOf(relay);
            // Saturating: a token whose balance somehow fell during the claim yields no fee rather
            // than reverting the whole batch.
            uint256 delta = balance > before[i] ? balance - before[i] : 0;
            fees[i] = _take(relay, tokens[i], delta);
            if (fees[i] != 0) any = true;
        }
        if (!any) revert NoFee();
    }

    /// @notice Take the fee on the Relay's idle (un-notified) balance of `token`.
    /// @param relay Relay to pull from; its KEEPER set gates the caller.
    /// @param token Token to skim.
    /// @return fee Fee taken.
    /// @dev Gated on the Relay's KEEPER role, checked before any other read. Idle is
    ///      `balanceOf - accountedBalance`, the same bound `pull` enforces.
    function skim(address relay, address token) external nonReentrant returns (uint256 fee) {
        IRelayEntrypoint r = IRelayEntrypoint(relay);
        if (!r.hasAnyRole(msg.sender, r.KEEPER())) revert NotKeeper();

        uint256 balance = IERC20Minimal(token).balanceOf(relay);
        uint256 accounted = r.accountedBalance(token);
        uint256 idle = balance > accounted ? balance - accounted : 0;

        fee = _take(relay, token, idle);
        if (fee == 0) revert NoFee();
    }

    /// @dev Compute the fee on `base`, pull it, forward everything held to the sink. Forwards the whole
    ///      balance rather than `fee` so stray tokens and fee-on-transfer shortfalls never strand here.
    function _take(address relay, address token, uint256 base) internal returns (uint256 fee) {
        fee = (base * FEE_BPS) / BPS;
        if (fee == 0) return 0;

        IRelayEntrypoint(relay).pull(token, fee);
        _safeTransfer(token, FEE_SINK, IERC20Minimal(token).balanceOf(address(this)));

        emit Skimmed(relay, token, base, fee);
    }

    /// @dev Raw `transfer`: succeeds on no return data (USDT style) or `true`; reverts otherwise.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || !(data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))))) revert TransferFailed();
    }
}
