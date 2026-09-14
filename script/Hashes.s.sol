// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";

import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";
import {Deploy} from "./Deploy.s.sol";

/// @notice Writes verification/bytecode-hashes.json from the current build.
/// @dev Always records the argument-independent hashes (creation code, runtime template with immutable
///      slots zeroed) and the compiler settings read from the build artifact's metadata. With FEE_BPS and
///      FEE_SINK in the environment it also records the deployment-specific values: constructor args,
///      init-code hash, CREATE2 address and the keccak of the runtime bytecode with immutables filled in.
///      Without them the `deployment` key is omitted.
///        forge script script/Hashes.s.sol
///        FEE_BPS=500 FEE_SINK=0x... forge script script/Hashes.s.sol
contract Hashes is Script {
    string internal constant ARTIFACT = "out/RelayFeeSkim.sol/RelayFeeSkim.json";
    string internal constant OUT = "verification/bytecode-hashes.json";

    function run() external {
        Deploy d = new Deploy();
        bytes memory creation = type(RelayFeeSkim).creationCode;
        bytes memory runtimeTemplate = vm.getDeployedCode("RelayFeeSkim.sol:RelayFeeSkim");
        string memory artifact = vm.readFile(ARTIFACT);

        string memory compiler = "compiler";
        vm.serializeString(compiler, "solc", vm.parseJsonString(artifact, ".metadata.compiler.version"));
        vm.serializeString(compiler, "evmVersion", vm.parseJsonString(artifact, ".metadata.settings.evmVersion"));
        vm.serializeBool(compiler, "optimizer", vm.parseJsonBool(artifact, ".metadata.settings.optimizer.enabled"));
        vm.serializeUint(compiler, "optimizerRuns", vm.parseJsonUint(artifact, ".metadata.settings.optimizer.runs"));
        // solc omits `viaIR` from metadata unless it is enabled.
        bool viaIr = vm.keyExistsJson(artifact, ".metadata.settings.viaIR")
            && vm.parseJsonBool(artifact, ".metadata.settings.viaIR");
        vm.serializeBool(compiler, "viaIr", viaIr);
        string memory compilerJson = vm.serializeString(
            compiler, "bytecodeHash", vm.parseJsonString(artifact, ".metadata.settings.metadata.bytecodeHash")
        );

        string memory root = "hashes";
        vm.serializeString(root, "contract", "src/RelayFeeSkim.sol:RelayFeeSkim");
        vm.serializeString(root, "compiler", compilerJson);
        vm.serializeAddress(root, "create2Deployer", d.CREATE2_DEPLOYER());
        vm.serializeString(root, "saltPreimage", d.SALT_PREIMAGE());
        vm.serializeBytes32(root, "salt", d.SALT());
        vm.serializeBytes32(root, "creationCodeKeccak", keccak256(creation));
        string memory json = vm.serializeBytes32(root, "runtimeTemplateKeccak", keccak256(runtimeTemplate));

        uint256 feeBps = vm.envOr("FEE_BPS", uint256(0));
        address feeSink = vm.envOr("FEE_SINK", address(0));
        if (feeBps != 0 && feeSink != address(0)) {
            RelayFeeSkim local = new RelayFeeSkim(feeBps, feeSink);

            string memory dep = "deployment";
            vm.serializeUint(dep, "feeBps", feeBps);
            vm.serializeAddress(dep, "feeSink", feeSink);
            vm.serializeBytes(dep, "constructorArgs", abi.encode(feeBps, feeSink));
            vm.serializeBytes32(dep, "initCodeHash", keccak256(d.initCode(feeBps, feeSink)));
            vm.serializeAddress(dep, "address", d.predict(feeBps, feeSink));
            string memory depJson = vm.serializeBytes32(dep, "runtimeKeccak", keccak256(address(local).code));
            json = vm.serializeString(root, "deployment", depJson);
        }
        vm.writeJson(json, OUT);
    }
}
