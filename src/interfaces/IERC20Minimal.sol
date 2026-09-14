// SPDX-FileCopyrightText: 2026 Klima Protocol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title  IERC20Minimal
/// @notice The two ERC-20 members RelayFeeSkim needs: read a balance, move tokens it holds.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
