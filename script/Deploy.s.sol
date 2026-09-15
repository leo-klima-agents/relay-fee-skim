// SPDX-FileCopyrightText: 2026 Klima Protocol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {RelayFeeSkim} from "../src/RelayFeeSkim.sol";

/// @notice CREATE2 deployment of RelayFeeSkim through forge's default deployer:
///         `forge script script/Deploy.s.sol --rpc-url $RPC --broadcast`
contract Deploy is Script {
    /// @notice Canonical deployment: 5% to Klima's Safe on Base.
    uint256 public constant FEE_BPS = 500;
    address public constant FEE_SINK = 0xf624f9Fe1D3165c5Ca32c7Fbdbf82f4a5b1D2d0e;

    /// @notice Bump the version suffix to deploy a new generation.
    string public constant SALT_PREIMAGE = "klimaprotocol.com/RelayFeeSkim/v1";
    bytes32 public constant SALT = keccak256(bytes(SALT_PREIMAGE));

    function initCode(uint256 feeBps, address feeSink) public pure returns (bytes memory) {
        // forge-lint: disable-next-line(encode-packed-collision)
        return abi.encodePacked(type(RelayFeeSkim).creationCode, abi.encode(feeBps, feeSink));
    }

    /// @notice Depends on the exact creation bytecode, metadata hash included, as well as the arguments.
    function predict(uint256 feeBps, address feeSink) public pure returns (address) {
        return computeCreate2Address(SALT, keccak256(initCode(feeBps, feeSink)), CREATE2_FACTORY);
    }

    function run() external returns (address) {
        return deploy(FEE_BPS, FEE_SINK);
    }

    /// @notice No-op when the predicted address already has code. Code at that address proves the
    ///         bytecode and arguments, so nothing is read back; bad arguments revert in the constructor.
    function deploy(uint256 feeBps, address feeSink) public returns (address deployed) {
        deployed = predict(feeBps, feeSink);
        console.log("RelayFeeSkim", deployed);
        if (deployed.code.length != 0) {
            console.log("already deployed");
            return deployed;
        }
        vm.startBroadcast();
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(SALT, initCode(feeBps, feeSink)));
        vm.stopBroadcast();
        require(ok && deployed.code.length != 0, "CREATE2 deploy failed");
        console.log("deployed");
    }
}
