// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";

/// @notice Exercises the deploy script against the deterministic deployer forge pre-deploys in every test.
contract DeployTest is Test {
    Deploy internal d;
    address internal constant SINK = address(0xFEE);

    function setUp() public {
        d = new Deploy();
        assertEq(d.CREATE2_DEPLOYER(), CREATE2_FACTORY);
        assertGt(CREATE2_FACTORY.code.length, 0, "forge did not pre-deploy the CREATE2 deployer");
    }

    function test_maxFeeBpsMirrorsContract() public {
        assertEq(d.MAX_FEE_BPS(), new RelayFeeSkim(1, SINK).MAX_FEE_BPS());
    }

    function test_salt() public view {
        assertEq(d.SALT(), keccak256("leo-klima-agents/relay-fee-skim/RelayFeeSkim/v1"));
    }

    function test_predict_matchesCheatcode() public view {
        bytes32 initCodeHash = keccak256(d.initCode(500, SINK));
        assertEq(d.predict(500, SINK), vm.computeCreate2Address(d.SALT(), initCodeHash, CREATE2_FACTORY));
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
        vm.expectRevert(bytes("FEE_BPS out of range: 1..MAX_FEE_BPS"));
        d.deploy(0, SINK);
        uint256 aboveCap = d.MAX_FEE_BPS() + 1; // read first: an external call would consume expectRevert
        vm.expectRevert(bytes("FEE_BPS out of range: 1..MAX_FEE_BPS"));
        d.deploy(aboveCap, SINK);
        vm.expectRevert(bytes("FEE_SINK must not be zero"));
        d.deploy(500, address(0));
    }

    function test_deploy_acceptsCap() public {
        address deployed = d.deploy(d.MAX_FEE_BPS(), SINK);
        assertEq(RelayFeeSkim(deployed).FEE_BPS(), 1000);
    }

    function test_deploy_requiresDeployerOnChain() public {
        vm.etch(CREATE2_FACTORY, "");
        vm.expectRevert(bytes("CREATE2 deployer not present on this chain"));
        d.deploy(500, SINK);
    }
}
