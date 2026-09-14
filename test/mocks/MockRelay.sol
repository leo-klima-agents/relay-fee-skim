// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IRelayEntrypoint} from "../../src/interfaces/IRelayEntrypoint.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Mirrors the Relay semantics RelayFeeSkim depends on (RelayRoles, RelayBase.pull,
///         RelayRewardsLib.pull / claimRewards) with the minimum machinery to drive them in tests.
contract MockRelay {
    uint256 public constant KEEPER = 1 << 0;
    uint256 public constant VOTER_ROLE = 1 << 1;
    uint256 public constant COMPOUNDER = 1 << 2;
    uint256 public constant CONVERTER = 1 << 3;

    error NotAuthorized();
    error RewardExceedsBalance();
    error NoValueOnRootClaim();
    error RecipientNotSet();
    error TransferFailed();

    mapping(address account => uint256 roles) public rolesOf;
    mapping(address token => uint256 accounted) public accountedBalance;
    mapping(address token => uint256 amount) public claimable;
    address[] internal _claimTokens;

    uint256 public claimCalls;

    // ---- role admin (upstream: OwnableRoles, owner-managed) ----

    function grantRoles(address account, uint256 roles) external {
        rolesOf[account] |= roles;
    }

    function revokeRoles(address account, uint256 roles) external {
        rolesOf[account] &= ~roles;
    }

    function hasAnyRole(address account, uint256 roles) public view returns (bool) {
        return rolesOf[account] & roles != 0;
    }

    // ---- test knobs ----

    function setAccountedBalance(address token, uint256 amount) external {
        accountedBalance[token] = amount;
    }

    /// @notice Configure how much of `token` the next `claimRewards` mints to this Relay.
    function setClaimable(address token, uint256 amount) external {
        if (claimable[token] == 0 && amount != 0) _claimTokens.push(token);
        claimable[token] = amount;
    }

    // ---- IRelayEntrypoint surface ----

    /// @dev RelayBase.pull: COMPOUNDER | CONVERTER gate; RelayRewardsLib.pull: bound by un-accounted balance.
    function pull(address token, uint256 amount) external {
        if (!hasAnyRole(msg.sender, COMPOUNDER | CONVERTER)) revert NotAuthorized();
        if (amount > _balance(token) - accountedBalance[token]) revert RewardExceedsBalance();
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount));
        if (!ok || !(data.length == 0 || abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev RelayRewardsLib.claimRewards: a root claim (`chainId == block.chainid`) pays the Relay itself
    ///      and must carry zero value; a leaf claim needs a configured recipient, which this mock never has.
    function claimRewards(
        uint256 chainId,
        uint256,
        IRelayEntrypoint.FeeClaim[] calldata,
        IRelayEntrypoint.IncentiveClaim[] calldata
    ) external payable {
        if (chainId != block.chainid) revert RecipientNotSet();
        if (msg.value != 0) revert NoValueOnRootClaim();
        claimCalls++;
        for (uint256 i; i < _claimTokens.length; ++i) {
            address token = _claimTokens[i];
            uint256 amount = claimable[token];
            if (amount == 0) continue;
            claimable[token] = 0;
            IMintable(token).mint(address(this), amount);
        }
    }

    function _balance(address token) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        require(ok && data.length >= 32, "balanceOf failed");
        return abi.decode(data, (uint256));
    }
}

/// @notice Relay stub whose `pull` is a no-op and whose gates always pass, so the skimmer's own
///         forward-to-sink transfer is the only thing under test.
contract NoopPullRelay {
    uint256 public constant KEEPER = 1 << 0;

    function hasAnyRole(address, uint256) external pure returns (bool) {
        return true;
    }

    function accountedBalance(address) external pure returns (uint256) {
        return 0;
    }

    function pull(address, uint256) external {}

    function claimRewards(
        uint256,
        uint256,
        IRelayEntrypoint.FeeClaim[] calldata,
        IRelayEntrypoint.IncentiveClaim[] calldata
    ) external payable {}
}
