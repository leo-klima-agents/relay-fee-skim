// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title  IRelayEntrypoint
/// @notice The slice of a Metadex Relay that RelayFeeSkim drives. Re-declared here so `src/` has no
///         dependency on the upstream tree; every member below is byte-for-byte selector-compatible
///         with dromos-labs/metadex-public at the commit pinned in test/upstream/UPSTREAM.md.
/// @dev Structs mirror `ILeafVoter.FeeClaim` / `ILeafVoter.IncentiveClaim`; `claimRewards` mirrors
///      `IRelay.claimRewards`; `pull` mirrors `IRelayEntrypoint.pull`. test/Selectors.t.sol pins both.
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
