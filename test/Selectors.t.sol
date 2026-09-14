// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {IRelayEntrypoint} from "../src/interfaces/IRelayEntrypoint.sol";
import {IRelayEntrypoint as UpstreamIRelayEntrypoint} from "./upstream/IRelayEntrypoint.sol";

/// @notice Pins the five upstream selectors RelayFeeSkim depends on three ways: against literals,
///         against keccak256 of the signature strings, and against the vendored upstream files.
/// @dev The vendored IRelayEntrypoint.sol compiles standalone and is compared by `.selector`. The
///      vendored IRelay.sol and ILeafVoter.sol import the rest of the metadex tree, so they are
///      excluded from compilation (foundry.toml `skip`) and checked as text: the exact declarations
///      that produce `claimRewards`' selector must still be present, byte for byte.
contract SelectorsTest is Test {
    bytes4 internal constant PULL = 0xf2d5d56b;
    bytes4 internal constant ACCOUNTED_BALANCE = 0xa7838c8a;
    bytes4 internal constant KEEPER = 0x862a179e;
    bytes4 internal constant HAS_ANY_ROLE = 0x514e62fc;
    bytes4 internal constant CLAIM_REWARDS = 0xfa6a8ba9;

    function test_selectors_literals() public pure {
        assertEq(IRelayEntrypoint.pull.selector, PULL);
        assertEq(IRelayEntrypoint.accountedBalance.selector, ACCOUNTED_BALANCE);
        assertEq(IRelayEntrypoint.KEEPER.selector, KEEPER);
        assertEq(IRelayEntrypoint.hasAnyRole.selector, HAS_ANY_ROLE);
        assertEq(IRelayEntrypoint.claimRewards.selector, CLAIM_REWARDS);
    }

    function test_selectors_keccak() public pure {
        assertEq(IRelayEntrypoint.pull.selector, bytes4(keccak256("pull(address,uint256)")));
        assertEq(IRelayEntrypoint.accountedBalance.selector, bytes4(keccak256("accountedBalance(address)")));
        assertEq(IRelayEntrypoint.KEEPER.selector, bytes4(keccak256("KEEPER()")));
        assertEq(IRelayEntrypoint.hasAnyRole.selector, bytes4(keccak256("hasAnyRole(address,uint256)")));
        assertEq(
            IRelayEntrypoint.claimRewards.selector,
            bytes4(keccak256("claimRewards(uint256,uint256,(address,uint256)[],(address,uint256,uint256)[])"))
        );
    }

    function test_selectors_upstreamCompiled() public pure {
        assertEq(IRelayEntrypoint.pull.selector, UpstreamIRelayEntrypoint.pull.selector);
        assertEq(IRelayEntrypoint.accountedBalance.selector, UpstreamIRelayEntrypoint.accountedBalance.selector);
        assertEq(IRelayEntrypoint.KEEPER.selector, UpstreamIRelayEntrypoint.KEEPER.selector);
        assertEq(IRelayEntrypoint.hasAnyRole.selector, UpstreamIRelayEntrypoint.hasAnyRole.selector);
    }

    /// @dev The human-readable table in UPSTREAM.md must agree with the compiled selectors.
    function test_selectors_upstreamMdTable() public view {
        string memory md = vm.readFile("test/upstream/UPSTREAM.md");
        _assertRow(md, "pull(address,uint256)", IRelayEntrypoint.pull.selector);
        _assertRow(md, "accountedBalance(address)", IRelayEntrypoint.accountedBalance.selector);
        _assertRow(md, "KEEPER()", IRelayEntrypoint.KEEPER.selector);
        _assertRow(md, "hasAnyRole(address,uint256)", IRelayEntrypoint.hasAnyRole.selector);
        _assertRow(
            md,
            "claimRewards(uint256,uint256,(address,uint256)[],(address,uint256,uint256)[])",
            IRelayEntrypoint.claimRewards.selector
        );
    }

    function _assertRow(string memory md, string memory signature, bytes4 selector) internal pure {
        // vm.toString(bytes4) pads to 32 bytes; go through `bytes` for the 4-byte hex form.
        string memory row = string.concat("| `", signature, "` | `", vm.toString(abi.encodePacked(selector)), "` |");
        assertTrue(vm.contains(md, row), string.concat("UPSTREAM.md row missing or stale: ", row));
    }

    function test_selectors_upstreamText() public view {
        string memory entrypoint = vm.readFile("test/upstream/IRelayEntrypoint.sol");
        assertTrue(vm.contains(entrypoint, "function pull(address _token, uint256 _amount) external;"));
        assertTrue(
            vm.contains(
                entrypoint, "function accountedBalance(address _token) external view returns (uint256 _accounted);"
            )
        );
        assertTrue(vm.contains(entrypoint, "function KEEPER() external view returns (uint256 _role);"));
        assertTrue(
            vm.contains(
                entrypoint, "function hasAnyRole(address _account, uint256 _roles) external view returns (bool _has);"
            )
        );

        string memory relay = vm.readFile("test/upstream/IRelay.sol");
        assertTrue(
            vm.contains(
                relay,
                "function claimRewards(\n" "    uint256 _chainId,\n" "    uint256 _gasLimit,\n"
                "    ILeafVoter.FeeClaim[] calldata _feeClaims,\n"
                "    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims\n" "  ) external payable;"
            )
        );

        string memory voter = vm.readFile("test/upstream/ILeafVoter.sol");
        assertTrue(
            vm.contains(
                voter, "struct FeeClaim {\n" "    address votingRewardsManager;\n" "    uint256 maxCheckpoints;\n" "  }"
            )
        );
        assertTrue(
            vm.contains(
                voter,
                "struct IncentiveClaim {\n" "    address votingRewardsManager;\n" "    uint256 programId;\n"
                "    uint256 maxCheckpoints;\n" "  }"
            )
        );
    }
}
