<!--
SPDX-FileCopyrightText: 2026 Klima Protocol
SPDX-License-Identifier: MIT
-->

# RelayFeeSkim

One immutable contract that takes a fixed fee from a Metadex (Aero v3) Relay's rewards and forwards it to a
fixed sink. It sits in the Relay's `converter` slot. No owner, no storage, no swaps, no `notifyReward`.
MIT, Foundry, zero runtime dependencies.

```
claimAndSkim(relay, feeClaims, incentiveClaims, tokens):   # anyone; at least one claim, maxCheckpoints > 0
    before = relay.balanceOf(tokens)                       # tokens strictly ascending
    relay.claimRewards(chainid, 0, feeClaims, incentiveClaims)
    for t in tokens: fee = (relay.balanceOf(t) - before[t]) * FEE_BPS / 10_000
                     relay.pull(t, fee); t.transfer(FEE_SINK, everything this contract holds)
```

## Guarantees

| Property | Enforced by |
|---|---|
| Fee rate at most 10%, fixed for life | `MAX_FEE_BPS = 1_000`; `FEE_BPS` is an immutable checked in the constructor |
| One call moves at most `FEE_BPS / 10_000` of what it claimed | `_take` pulls exactly `delta * FEE_BPS / BPS`; fuzz-tested |
| Balances already on the Relay are never touched | Only this call's own claim delta is taxed, and the Relay's `pull` reverts above `balanceOf - accountedBalance` |
| Nothing strands on this contract | The whole held balance, not just `fee`, is forwarded after every pull |
| No admin surface | No owner, setters, storage, `receive` or `fallback`; the only mutable state is a transient reentrancy lock |
| Untrusted inputs cannot extract value | `relay` and `tokens` are caller-supplied; a fake relay or hostile token can only forward what the contract already holds to the fixed sink, and the lock blocks a reentrant second tax |

## How it collects

`claimAndSkim` is permissionless. It reads the Relay's balance of each token, calls the Relay's own root-chain
`claimRewards`, and taxes the balance delta. A repeat call finds no delta and reverts `NoFee`. Whoever calls
pays the claim gas. Tokens must be strictly ascending so none is taxed twice. The claim arrays go to the
Voter unchanged; it rejects an empty request and any claim with zero `maxCheckpoints`, and `MockRelay`
mirrors both rejections.

## Known limitations

- **Rewards claimed by someone else are not taxed.** The Relay's `claimRewards` is itself permissionless.
  Anything claimed directly, by Aero's keeper, or by front-running a pending `claimAndSkim` lands untaxed and
  stays so; there is no path that taxes an idle balance.
- **The sink is immutable.** A token that blacklists `FEE_SINK` reverts every skim of that token for the life
  of the contract. Callers must omit it.
- **`Skimmed` events are only as trustworthy as the token.** A hostile token can lie about `balanceOf(relay)`
  and make the contract emit arbitrary numbers. No value moves. Indexers should count only tokens the Relay
  registers as reward tokens.
- **Absurd balances revert instead of saturating.** A delta above `2²⁵⁶ / FEE_BPS` panics the whole batch.
  No real token reaches that range.

## Relay hand-off

`RelayFactory.createMaxiRelay(CreateParams)`:

| `CreateParams` field | Value |
|---|---|
| `admin` | your multisig |
| `converter` | this contract's address (grants it `CONVERTER`, which authorizes `pull`) |
| `compounder` | Aero's official Compounder entrypoint |
| `rewardToken` | `address(0)` |

`initialize` grants `CONVERTER` at creation and the public role paths refuse that bit afterwards, so the
slot is set once.

## Upstream pin

Built against https://github.com/dromos-labs/metadex-public at `b032bb7f55eff31e081196754e0fdbc217f978d2`
(`1.0.0-provisional.3`, **undeployed**). The three MIT interface files are vendored byte-for-byte under
[`test/upstream/`](test/upstream/UPSTREAM.md) and pinned by sha256 in CI. `test/Selectors.t.sol` asserts the
two selectors this contract uses, `pull` and `claimRewards`, against literals, `keccak256` of the signatures,
and the vendored files.

**Do not deploy before Aero's final Relay code lands.** Then refresh the pin per `test/upstream/UPSTREAM.md`
and rerun the selector tests. If they fail, fix `src/interfaces/IRelayEntrypoint.sol`, regenerate
`verification/`, and bump the salt to `v2`.

## Before deploying

1. **Wait for Aero's final Relay code** and refresh the pin as above.
2. **Deploy and verify** (below), then confirm the on-chain address equals `deployment.address` in
   `verification/bytecode-hashes.json`.
3. **Hand off** the address as `converter` in `createMaxiRelay`. The slot is set once; check the address twice.

## Build and test

```
git clone --recurse-submodules https://github.com/ldeso/relay-fee-skim
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test        # 10_000 fuzz runs, what CI runs
forge lint --deny warnings           # what CI runs; needs the pinned forge
```

`foundry.toml` pins solc 0.8.36 to match the Relay's compiler, `prague`, optimizer at 1,000,000 runs and
ipfs metadata. Bytecode depends on those, not on the forge release. CI pins Foundry `v1.8.1` exactly because
the `[lint]` ids and the committed standard JSON input are shaped by that release; `forge build` and
`forge test` work on any recent forge.

## Deploy

CREATE2 through forge's default deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with salt
`keccak256("klimaprotocol.com/RelayFeeSkim/v1")`. `FEE_BPS` (500) and `FEE_SINK`
(`0xf624f9Fe1D3165c5Ca32c7Fbdbf82f4a5b1D2d0e`, a Safe on Base) are constants of `script/Deploy.s.sol`. The
address depends on those arguments and on the exact bytecode, metadata hash included, so a comment edit in
`src/` moves it; the predicted address is recorded under `deployment` in `verification/bytecode-hashes.json`.

```
forge script script/Deploy.s.sol --sig "predict(uint256,address)" 500 0xf624f9Fe1D3165c5Ca32c7Fbdbf82f4a5b1D2d0e
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

The script is a no-op if the address already has code. Commit `broadcast/Deploy.s.sol/8453/run-latest.json`
with the deployment; it is the one broadcast artifact not ignored.

## Verify

```
ARGS=$(cast abi-encode 'constructor(uint256,address)' 500 0xf624f9Fe1D3165c5Ca32c7Fbdbf82f4a5b1D2d0e)
forge verify-contract --chain base --verifier etherscan --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $ARGS $ADDRESS src/RelayFeeSkim.sol:RelayFeeSkim
forge verify-contract --chain base --verifier sourcify \
  --constructor-args $ARGS $ADDRESS src/RelayFeeSkim.sol:RelayFeeSkim
```

`verification/` holds the solc standard JSON input (regenerate with
`forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 src/RelayFeeSkim.sol:RelayFeeSkim`)
and `bytecode-hashes.json`, written by `forge script script/Hashes.s.sol`: salt, deployer, creation and
runtime-template keccaks, compiler settings from the artifact, and the deployment's constructor args,
init-code hash, address and runtime keccak. `script/check-hashes.sh` and `script/check-standard-input.sh`
compare a fresh build against both files; CI runs them after two clean builds that must be byte-identical.

## Layout

```
src/RelayFeeSkim.sol                 the contract
src/interfaces/IRelayEntrypoint.sol  the two Relay members it calls, plus the two claim structs
src/interfaces/IERC20Minimal.sol     balanceOf, transfer
script/Deploy.s.sol                  CREATE2 deploy + predict
script/Hashes.s.sol                  writes verification/bytecode-hashes.json
script/check-hashes.sh               CI drift check against bytecode-hashes.json
script/check-standard-input.sh       CI drift check against the standard JSON input
test/RelayFeeSkim.t.sol              behaviour, fuzz, token edge cases, reentrancy
test/Selectors.t.sol                 upstream selector pin
test/Deploy.t.sol                    deploy script
test/mocks/                          MockRelay (upstream semantics), MockERC20 variants
test/upstream/                       vendored MIT interfaces + UPSTREAM.md + SHA256SUMS
verification/                        standard JSON input, bytecode hashes
LICENSES/, REUSE.toml                license texts and REUSE annotations
```

## License

MIT, [REUSE](https://reuse.software) compliant. Every file carries SPDX tags except the checksum list and the
generated `verification/` files, which `REUSE.toml` covers. The vendored upstream files are MIT code
reproduced unmodified with their copyright holder recorded in `REUSE.toml`. The root `LICENSE` duplicates
`LICENSES/MIT.txt` for GitHub's benefit.
