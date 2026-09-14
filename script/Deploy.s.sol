// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";

/// @notice Deterministic CREATE2 deployment of RelayFeeSkim through forge's default deployer.
/// @dev Usage:
///        FEE_BPS=<1..1000> FEE_SINK=<address> forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
///      Address preview without a key:
///        forge script script/Deploy.s.sol --sig "predict(uint256,address)" $FEE_BPS $FEE_SINK
contract Deploy is Script {
    /// @notice Arachnid's deterministic deployment proxy, forge-std's `CREATE2_FACTORY`, exposed as a getter.
    address public constant CREATE2_DEPLOYER = CREATE2_FACTORY;

    /// @notice Mirror of RelayFeeSkim.MAX_FEE_BPS, checked here for a readable error before any broadcast.
    ///         Solidity cannot read a constant through a contract type, so test/Deploy.t.sol pins the two equal.
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Salt preimage. Bump the version suffix to redeploy (e.g. after an upstream pin change).
    string public constant SALT_PREIMAGE = "leo-klima-agents/relay-fee-skim/RelayFeeSkim/v1";
    bytes32 public constant SALT = keccak256(bytes(SALT_PREIMAGE));

    /// @notice Constructor-args-appended init code for the given parameters.
    function initCode(uint256 feeBps, address feeSink) public pure returns (bytes memory) {
        // Raw concatenation is exactly what CREATE2 init code is; no hashing of ambiguous fields happens here.
        // forge-lint: disable-next-line(encode-packed-collision)
        return abi.encodePacked(type(RelayFeeSkim).creationCode, abi.encode(feeBps, feeSink));
    }

    /// @notice Address RelayFeeSkim(feeBps, feeSink) lands on when deployed via `run`.
    /// @dev Depends on the exact creation bytecode (including the metadata hash) as well as the arguments.
    function predict(uint256 feeBps, address feeSink) public pure returns (address) {
        return computeCreate2Address(SALT, keccak256(initCode(feeBps, feeSink)), CREATE2_FACTORY);
    }

    function run() external returns (address deployed) {
        uint256 feeBps = vm.envUint("FEE_BPS");
        address feeSink = vm.envAddress("FEE_SINK");
        deployed = deploy(feeBps, feeSink);
    }

    function deploy(uint256 feeBps, address feeSink) public returns (address deployed) {
        require(feeBps != 0 && feeBps <= MAX_FEE_BPS, "FEE_BPS out of range: 1..MAX_FEE_BPS");
        require(feeSink != address(0), "FEE_SINK must not be zero");
        require(CREATE2_FACTORY.code.length != 0, "CREATE2 deployer not present on this chain");

        deployed = predict(feeBps, feeSink);
        console.log("RelayFeeSkim  salt      :", vm.toString(SALT));
        console.log("RelayFeeSkim  FEE_BPS   :", feeBps);
        console.log("RelayFeeSkim  FEE_SINK  :", feeSink);
        console.log("RelayFeeSkim  predicted :", deployed);

        if (deployed.code.length != 0) {
            console.log("RelayFeeSkim  already deployed; nothing to do");
        } else {
            vm.startBroadcast();
            (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(SALT, initCode(feeBps, feeSink)));
            vm.stopBroadcast();
            require(ok && ret.length == 20, "CREATE2 deploy failed");
            // forge-lint: disable-next-line(unsafe-typecast)
            require(address(bytes20(ret)) == deployed, "deployed address != predicted"); // ret.length == 20 checked above
            console.log("RelayFeeSkim  deployed  :", deployed);
        }

        RelayFeeSkim skim = RelayFeeSkim(deployed);
        require(skim.FEE_BPS() == feeBps, "FEE_BPS mismatch on chain");
        require(skim.FEE_SINK() == feeSink, "FEE_SINK mismatch on chain");
    }
}
