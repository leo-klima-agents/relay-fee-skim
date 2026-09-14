// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title  IRelayEntrypoint
/// @notice The slice of a Metadex Relay that RelayFeeSkim drives. Re-declared here so `src/` has no
///         dependency on the upstream tree; every member below is byte-for-byte selector-compatible
///         with dromos-labs/metadex-public at the commit pinned in test/upstream/UPSTREAM.md.
/// @dev Structs mirror `ILeafVoter.FeeClaim` / `ILeafVoter.IncentiveClaim`; `claimRewards` mirrors
///      `IRelay.claimRewards`; the rest mirrors `IRelayEntrypoint`. test/Selectors.t.sol pins all five.
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

    /// @notice Balance of `token` already notified to holders and not yet claimed. Selector 0xa7838c8a.
    function accountedBalance(address token) external view returns (uint256);

    /// @notice The KEEPER role bit. Selector 0x862a179e.
    function KEEPER() external view returns (uint256);

    /// @notice Whether `account` holds any of the `roles` bits on the Relay. Selector 0x514e62fc.
    function hasAnyRole(address account, uint256 roles) external view returns (bool);

    /// @notice Permissionless pass-through to the Voter. A root-chain claim (`chainId == block.chainid`)
    ///         must carry zero value and always pays the Relay itself. Selector 0xfa6a8ba9.
    function claimRewards(
        uint256 chainId,
        uint256 gasLimit,
        FeeClaim[] calldata feeClaims,
        IncentiveClaim[] calldata incentiveClaims
    ) external payable;
}
