// SPDX-FileCopyrightText: 2026 Klima Protocol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title  IRelayEntrypoint
/// @notice The two Relay members RelayFeeSkim calls, and the structs they take, re-declared so `src/` has
///         no upstream dependency. Selector-compatible with dromos-labs/metadex-public at the commit
///         pinned in test/upstream/UPSTREAM.md; test/Selectors.t.sol proves it.
/// @dev Upstream sources: `IRelayEntrypoint.pull`, `IRelay.claimRewards`, `ILeafVoter.FeeClaim` and
///      `ILeafVoter.IncentiveClaim`.
interface IRelayEntrypoint {
    /// @notice Fee claim request forwarded through the Voter.
    struct FeeClaim {
        address votingRewardsManager;
        uint256 maxCheckpoints;
    }

    /// @notice Incentive claim request forwarded through the Voter.
    struct IncentiveClaim {
        address votingRewardsManager;
        uint256 programId;
        uint256 maxCheckpoints;
    }

    /// @notice Pull `amount` of `token` from the Relay to the caller. Gated on COMPOUNDER | CONVERTER
    ///         and bounded by `balanceOf(relay) - accountedBalance(token)`. Selector 0xf2d5d56b.
    function pull(address token, uint256 amount) external;

    /// @notice Permissionless pass-through to the Voter. A root-chain claim (`chainId == block.chainid`)
    ///         must carry zero value and always pays the Relay itself. Selector 0xfa6a8ba9.
    function claimRewards(
        uint256 chainId,
        uint256 gasLimit,
        FeeClaim[] calldata feeClaims,
        IncentiveClaim[] calldata incentiveClaims
    ) external payable;
}
