// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";

import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";
import {Deploy} from "./Deploy.s.sol";

/// @notice Writes verification/bytecode-hashes.json from the current build.
/// @dev Always records the argument-independent hashes (creation code, runtime template with immutable
///      slots zeroed). With FEE_BPS and FEE_SINK in the environment it also records the deployment-
///      specific values: constructor args, init-code hash, CREATE2 address and the keccak of the runtime
///      bytecode with immutables filled in.
///        forge script script/Hashes.s.sol
///        FEE_BPS=500 FEE_SINK=0x... forge script script/Hashes.s.sol
contract Hashes is Script {
    string internal constant OUT = "verification/bytecode-hashes.json";

    function run() external {
        Deploy d = new Deploy();
        bytes memory creation = type(RelayFeeSkim).creationCode;
        bytes memory runtimeTemplate = vm.getDeployedCode("RelayFeeSkim.sol:RelayFeeSkim");

        string memory compiler = "compiler";
        vm.serializeString(compiler, "solc", "0.8.36");
        vm.serializeString(compiler, "evmVersion", "prague");
        vm.serializeBool(compiler, "optimizer", true);
        vm.serializeUint(compiler, "optimizerRuns", 1_000_000);
        vm.serializeBool(compiler, "viaIr", false);
        string memory compilerJson = vm.serializeString(compiler, "bytecodeHash", "ipfs");

        string memory root = "hashes";
        vm.serializeString(root, "contract", "src/RelayFeeSkim.sol:RelayFeeSkim");
        vm.serializeString(root, "compiler", compilerJson);
        vm.serializeAddress(root, "create2Deployer", d.CREATE2_DEPLOYER());
        vm.serializeString(root, "saltPreimage", d.SALT_PREIMAGE());
        vm.serializeBytes32(root, "salt", d.SALT());
        vm.serializeBytes32(root, "creationCodeKeccak", keccak256(creation));
        vm.serializeBytes32(root, "runtimeTemplateKeccak", keccak256(runtimeTemplate));

        uint256 feeBps = vm.envOr("FEE_BPS", uint256(0));
        address feeSink = vm.envOr("FEE_SINK", address(0));
        string memory json;
        if (feeBps != 0 && feeSink != address(0)) {
            bytes memory args = abi.encode(feeBps, feeSink);
            RelayFeeSkim local = new RelayFeeSkim(feeBps, feeSink);

            string memory dep = "deployment";
            vm.serializeUint(dep, "feeBps", feeBps);
            vm.serializeAddress(dep, "feeSink", feeSink);
            vm.serializeBytes(dep, "constructorArgs", args);
            vm.serializeBytes32(dep, "initCodeHash", keccak256(d.initCode(feeBps, feeSink)));
            vm.serializeAddress(dep, "address", d.predict(feeBps, feeSink));
            string memory depJson = vm.serializeBytes32(dep, "runtimeKeccak", keccak256(address(local).code));
            json = vm.serializeString(root, "deployment", depJson);
        } else {
            json = vm.serializeString(root, "deployment", "unset: rerun with FEE_BPS and FEE_SINK");
        }
        vm.writeJson(json, OUT);
    }
}
