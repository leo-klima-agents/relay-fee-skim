// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {RelayFeeSkim} from "../../src/RelayFeeSkim.sol";
import {IRelayEntrypoint} from "../../src/interfaces/IRelayEntrypoint.sol";

/// @notice Shared ledger for every test token; each variant declares only its own `transfer`.
abstract contract MockLedger {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    error InsufficientBalance();

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Minimal standard ERC-20: returns `true`, reverts on insufficient balance.
contract MockERC20 is MockLedger {
    string public name;

    constructor(string memory name_) {
        name = name_;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }
}

/// @notice USDT style: `transfer` moves tokens but returns no data at all.
contract NoReturnERC20 is MockLedger {
    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }
}

/// @notice Returns `false` from `transfer` without moving anything.
contract ReturnsFalseERC20 is MockLedger {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Reenters the skimmer from `transfer` whenever the skimmer itself is the sender, i.e. during
///         the forward-to-sink step. With `record` off the reentrant call's revert bubbles; with it on,
///         the revert data is captured in `lastRevert` and the transfer completes.
contract ReentrantERC20 is MockERC20 {
    enum Mode {
        ClaimAndSkim,
        Skim
    }

    RelayFeeSkim public immutable SKIMMER;
    address public immutable RELAY;
    Mode public mode;
    bool public record;
    bytes public lastRevert;
    bool public reentered;

    constructor(RelayFeeSkim skimmer, address relay) MockERC20("REENTRANT") {
        SKIMMER = skimmer;
        RELAY = relay;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setRecord(bool record_) external {
        record = record_;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (msg.sender == address(SKIMMER) && !reentered) {
            reentered = true;
            _reenter();
        }
        _move(msg.sender, to, amount);
        return true;
    }

    function _reenter() internal {
        bytes memory call;
        if (mode == Mode.ClaimAndSkim) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(this);
            IRelayEntrypoint.FeeClaim[] memory feeClaims = new IRelayEntrypoint.FeeClaim[](1);
            feeClaims[0] = IRelayEntrypoint.FeeClaim({votingRewardsManager: address(0xB0B), maxCheckpoints: 1});
            call = abi.encodeCall(
                RelayFeeSkim.claimAndSkim, (RELAY, feeClaims, new IRelayEntrypoint.IncentiveClaim[](0), tokens)
            );
        } else {
            call = abi.encodeCall(RelayFeeSkim.skim, (RELAY, address(this)));
        }
        (bool ok, bytes memory data) = address(SKIMMER).call(call);
        if (!record) {
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(data, 0x20), mload(data))
                }
            }
            return;
        }
        lastRevert = data;
        require(!ok, "reentrant call unexpectedly succeeded");
    }
}
