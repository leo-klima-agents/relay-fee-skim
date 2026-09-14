# RelayFeeSkim

A single immutable contract that takes a fixed fee from a Metadex (Aero v3) Relay's rewards and
forwards it to a fixed sink. It sits in the Relay's `converter` slot. No owner, no storage, no swaps,
no `notifyReward`. MIT, Foundry, zero runtime dependencies.

```
claimAndSkim(relay, feeClaims, incentiveClaims, tokens):   # anyone
    before = relay.balanceOf(tokens); relay.claimRewards(chainid, 0, feeClaims, incentiveClaims)
    for t in tokens: fee = (balanceOf(t) - before[t]) * FEE_BPS / 10_000; relay.pull(t, fee); t.transfer(FEE_SINK, all held)
skim(relay, token):                                         # relay's KEEPER only
    fee = (balanceOf(token) - accountedBalance(token)) * FEE_BPS / 10_000; relay.pull(token, fee); token.transfer(FEE_SINK, all held)
```

## Guarantees

| Property | Where it is enforced |
|---|---|
| Fee rate is at most 10% and fixed for the life of the contract | `MAX_FEE_BPS = 1_000` in source; `FEE_BPS` is an immutable checked in the constructor |
| One call moves at most `FEE_BPS / 10_000` of its base | `_take` computes `fee = base * FEE_BPS / BPS` and pulls exactly `fee`; fuzz-tested in `test/RelayFeeSkim.t.sol` |
| Rewards already notified to holders are unreachable | The Relay's own `pull` reverts above `balanceOf(relay) - accountedBalance(token)`; `skim` also subtracts `accountedBalance` before computing the fee |
| Nothing ever strands on this contract | After every pull the entire held balance of that token, not just `fee`, is forwarded to `FEE_SINK` |
| No admin surface | No owner, no setters, no storage, no `receive`, no `fallback`, no `notifyReward`, no swaps. The only mutable state is a transient reentrancy lock |
| Untrusted inputs cannot extract value | `relay` and `tokens` are caller-supplied. A fake relay or hostile token can only cause the contract to forward whatever it already holds to the fixed sink. Both entry points are `nonReentrant` |

## The two paths

**`claimAndSkim` is permissionless.** It reads the Relay's balance of each listed token, calls the Relay's
own `claimRewards` for the root chain (no value), and taxes only the balance delta the claim produced. A
repeat call finds no delta and reverts with `NoFee`. Anyone can run it, so fees are collected as soon as
rewards are claimable; whoever calls it pays the claim gas. Tokens must be passed strictly ascending so a
token cannot be listed twice and have its delta taxed twice.

**`skim` is gated on the Relay's KEEPER role.** It taxes whatever balance is idle on the Relay, meaning
`balanceOf - accountedBalance`. It exists for the case `claimAndSkim` cannot see: rewards that reached the
Relay through some other route. It is gated because the base is not refreshed between calls, so two calls
in a row take `1 - 0.95^2 = 9.75%` of the original idle balance at a 5% rate rather than 5%. The Relay's
keeper is expected to call it once per inflow, before the compounder converts the balance.

**The one uncovered case.** If someone else claims a batch and compounds it in one transaction, the
rewards never sit idle on the Relay and neither path can tax them. Against Aero's official keeper flow this
is a matter of ordering: run `claimAndSkim` first, or have the keeper `skim` before compounding.

## Relay hand-off

`RelayFactory.createMaxiRelay(CreateParams)`:

| `CreateParams` field | Value |
|---|---|
| `admin` | your multisig |
| `converter` | this contract's address (grants it `CONVERTER`, which is what authorizes `pull`) |
| `compounder` | Aero's official Compounder entrypoint |
| `rewardToken` | `address(0)` |

`initialize` grants `CONVERTER` to `converter` at creation; the public role paths refuse that bit
afterwards, so the slot is set once.

## Upstream pin

Built against https://github.com/dromos-labs/metadex-public at commit
`b032bb7f55eff31e081196754e0fdbc217f978d2` (`1.0.0-provisional.3`, **undeployed**). The three MIT
interface files are vendored byte-for-byte under [`test/upstream/`](test/upstream/UPSTREAM.md) and pinned
by sha256 in CI. `test/Selectors.t.sol` asserts the five selectors this contract depends on against
literals, against `keccak256` of the signature strings, and against the vendored files.

**Do not deploy before Aero's final Relay code lands.** When it does, refresh the pin as described in
`test/upstream/UPSTREAM.md` and rerun the selector tests. If they fail, fix `src/interfaces/IRelayEntrypoint.sol`
and redeploy under a bumped salt (`.../RelayFeeSkim/v2` in `script/Deploy.s.sol`).

## Build and test

```
git clone --recurse-submodules https://github.com/leo-klima-agents/relay-fee-skim
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test        # 10_000 fuzz runs, what CI runs
```

`foundry.toml` pins `solc 0.8.36` to match the Relay's own compiler (move only when Aero's final code does), `evm_version = "prague"`, optimizer on at 1,000,000 runs,
`bytecode_hash = "ipfs"`, `cbor_metadata = true`. `forge-std` is a submodule used by tests and scripts only. CI pins Foundry `v1.8.1` exactly (never `stable`); the hashes under `verification/` were produced with it.

## Deploy

CREATE2 through forge's default deterministic deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with
salt `keccak256("leo-klima-agents/relay-fee-skim/RelayFeeSkim/v1")`, so the address depends only on the
constructor arguments.

```
export FEE_BPS=500                      # 1..1000
export FEE_SINK=0x...                   # non-zero

# preview the address
forge script script/Deploy.s.sol --sig "predict(uint256,address)" $FEE_BPS $FEE_SINK

# deploy (no-op if the predicted address already has code)
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

The script range-checks both inputs, asserts the deployed address equals the prediction, and reads
`FEE_BPS` and `FEE_SINK` back from the chain.

## Verify

Constructor args:

```
ARGS=$(cast abi-encode 'constructor(uint256,address)' $FEE_BPS $FEE_SINK)
```

Basescan:

```
forge verify-contract --chain base --verifier etherscan --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $ARGS $ADDRESS src/RelayFeeSkim.sol:RelayFeeSkim
```

Sourcify:

```
forge verify-contract --chain base --verifier sourcify \
  --constructor-args $ARGS $ADDRESS src/RelayFeeSkim.sol:RelayFeeSkim
```

Committed under `verification/`:

- `RelayFeeSkim.standard-input.json`: the exact solc standard JSON input, for manual verification.
  Regenerate with
  `forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 src/RelayFeeSkim.sol:RelayFeeSkim > verification/RelayFeeSkim.standard-input.json`.
- `bytecode-hashes.json`: salt, CREATE2 deployer, keccak of the creation code and of the runtime
  template (immutable slots zeroed). With `FEE_BPS` and `FEE_SINK` set, `forge script script/Hashes.s.sol`
  also records the constructor args, init-code hash, predicted address and the keccak of the runtime
  bytecode with immutables filled in. `script/check-hashes.sh` compares a fresh build against the record.

CI runs `forge fmt --check`, `forge build --sizes`, `forge test` at the high fuzz profile, the sha256 check
of the vendored upstream files, and a reproducible-build job that builds twice from clean, compares the
bytecode, and fails on any drift from the recorded hashes.

## Layout

```
src/RelayFeeSkim.sol                 the contract
src/interfaces/IRelayEntrypoint.sol  the five Relay members it calls, plus the two claim structs
src/interfaces/IERC20Minimal.sol     balanceOf, transfer
script/Deploy.s.sol                  CREATE2 deploy + predict
script/Hashes.s.sol                  writes verification/bytecode-hashes.json
script/check-hashes.sh               CI drift check
test/RelayFeeSkim.t.sol              behaviour, fuzz, token edge cases, reentrancy
test/Selectors.t.sol                 upstream selector pin
test/Deploy.t.sol                    deploy script against a locally etched CREATE2 proxy
test/mocks/                          MockRelay (upstream semantics), MockERC20 variants
test/upstream/                       vendored MIT interfaces + UPSTREAM.md + SHA256SUMS
verification/                        standard JSON input, bytecode hashes
```

## License

MIT. The vendored files under `test/upstream/` are MIT-licensed upstream code, reproduced unmodified.
