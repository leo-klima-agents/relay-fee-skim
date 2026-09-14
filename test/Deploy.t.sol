// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";

/// @notice Exercises the deploy script against a locally etched copy of the deterministic deployer.
contract DeployTest is Test {
    /// @dev Runtime bytecode of Arachnid's deterministic-deployment-proxy (the code behind forge's default
    ///      CREATE2 deployer at 0x4e59b44847b379578588920cA78FbF26c0B4956C on every supported chain).
    bytes internal constant PROXY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    Deploy internal d;
    address internal constant SINK = address(0xFEE);

    function setUp() public {
        d = new Deploy();
        vm.etch(d.CREATE2_DEPLOYER(), PROXY_RUNTIME);
    }

    function test_salt() public view {
        assertEq(d.SALT(), keccak256("leo-klima-agents/relay-fee-skim/RelayFeeSkim/v1"));
    }

    function test_predict_matchesCheatcode() public view {
        bytes32 initCodeHash = keccak256(d.initCode(500, SINK));
        assertEq(d.predict(500, SINK), vm.computeCreate2Address(d.SALT(), initCodeHash, d.CREATE2_DEPLOYER()));
    }

    function test_predict_dependsOnArgs() public view {
        assertTrue(d.predict(500, SINK) != d.predict(501, SINK));
        assertTrue(d.predict(500, SINK) != d.predict(500, address(0xBEEF)));
    }

    function test_deploy_landsOnPredictedAddress() public {
        address predicted = d.predict(500, SINK);
        assertEq(predicted.code.length, 0);

        address deployed = d.deploy(500, SINK);

        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
        assertEq(RelayFeeSkim(deployed).FEE_BPS(), 500);
        assertEq(RelayFeeSkim(deployed).FEE_SINK(), SINK);
    }

    function test_deploy_isIdempotent() public {
        address first = d.deploy(500, SINK);
        bytes32 codehash = first.codehash;

        address second = d.deploy(500, SINK);

        assertEq(second, first);
        assertEq(first.codehash, codehash);
    }

    function test_run_readsEnv() public {
        vm.setEnv("FEE_BPS", "250");
        vm.setEnv("FEE_SINK", vm.toString(SINK));

        address deployed = d.run();

        assertEq(deployed, d.predict(250, SINK));
        assertEq(RelayFeeSkim(deployed).FEE_BPS(), 250);
    }

    function test_deploy_rejectsBadInputs() public {
        vm.expectRevert(bytes("FEE_BPS must be in 1..1000"));
        d.deploy(0, SINK);
        vm.expectRevert(bytes("FEE_BPS must be in 1..1000"));
        d.deploy(1001, SINK);
        vm.expectRevert(bytes("FEE_SINK must not be zero"));
        d.deploy(500, address(0));
    }

    function test_deploy_requiresDeployerOnChain() public {
        vm.etch(d.CREATE2_DEPLOYER(), "");
        vm.expectRevert(bytes("CREATE2 deployer not present on this chain"));
        d.deploy(500, SINK);
    }
}
