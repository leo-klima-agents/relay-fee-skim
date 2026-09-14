# RelayFeeSkim

A single immutable contract that takes a fixed fee from a Metadex (Aero v3) Relay's rewards and
forwards it to a fixed sink. It sits in the Relay's `converter` slot. No owner, no storage, no swaps,
no `notifyReward`. MIT, Foundry, zero runtime dependencies.

```
claimAndSkim(relay, feeClaims, incentiveClaims, tokens):   # anyone; at least one claim, maxCheckpoints > 0
    before = relay.balanceOf(tokens)                       # tokens strictly ascending
    relay.claimRewards(chainid, 0, feeClaims, incentiveClaims)
    for t in tokens: fee = (relay.balanceOf(t) - before[t]) * FEE_BPS / 10_000
                     relay.pull(t, fee); t.transfer(FEE_SINK, everything this contract holds)
```

## Guarantees

| Property | Where it is enforced |
|---|---|
| Fee rate is at most 10% and fixed for the life of the contract | `MAX_FEE_BPS = 1_000` in source; `FEE_BPS` is an immutable checked in the constructor |
| One call moves at most `FEE_BPS / 10_000` of the rewards it claimed | `_take` computes `fee = delta * FEE_BPS / BPS` and pulls exactly `fee`; fuzz-tested in `test/RelayFeeSkim.t.sol` |
| Balances already on the Relay are never touched | Only the balance delta produced by this call's own `claimRewards` is taxed; the Relay's `pull` additionally reverts above `balanceOf(relay) - accountedBalance(token)`, so notified rewards are unreachable |
| Nothing ever strands on this contract | After every pull the entire held balance of that token, not just `fee`, is forwarded to `FEE_SINK` |
| No admin surface | No owner, no setters, no storage, no `receive`, no `fallback`, no `notifyReward`, no swaps. The only mutable state is a transient reentrancy lock |
| Untrusted inputs cannot extract value | `relay` and `tokens` are caller-supplied. A fake relay or hostile token can only cause the contract to forward whatever it already holds to the fixed sink. The lock blocks a hostile token from reentering to tax another token twice |

## How it collects

`claimAndSkim` is permissionless. It reads the Relay's balance of each listed token, calls the Relay's own
`claimRewards` for the root chain (no value), and taxes only the balance delta the claim produced. A repeat
call finds no delta and reverts with `NoFee`. Anyone can run it, so fees can be collected as soon as rewards
are claimable; whoever calls it pays the claim gas. Tokens must be passed strictly ascending so a token
cannot be listed twice and have its delta taxed twice. The claim arrays are forwarded to the Voter
unchanged, and the Voter rejects a request with no claims at all (`EmptyClaimRewardsParams`) and any claim
whose `maxCheckpoints` is zero (`ZeroCheckpoints`), so a real call always carries at least one sized claim.
The tests mirror both rejections in `MockRelay`.

## Known limitations

These follow from the design (one permissionless claim path, no storage, fixed sink) and are stated here so
nobody relies on a guarantee the contract does not make.

- **Rewards claimed by someone else are not taxed.** The Relay's `claimRewards` is itself permissionless.
  Anything claimed directly, by Aero's keeper flow, or by front-running a pending `claimAndSkim`, lands on
  the Relay untaxed and stays that way: this contract has no path that taxes an idle balance. Fee revenue
  therefore depends on `claimAndSkim` being the call that claims.
- **The sink is immutable.** If a token blacklists `FEE_SINK` (USDC/USDT style) or otherwise refuses the
  transfer, every skim of that token reverts `TransferFailed` for the life of the contract and there is no
  admin path to change the sink. Callers must omit that token.
- **`Skimmed` events are only as trustworthy as the token.** `tokens` is caller-supplied, so a hostile token
  that lies about `balanceOf(relay)` can make the skimmer emit a `Skimmed(realRelay, hostileToken, …)` event
  with arbitrary numbers. No value moves. Indexers should count only tokens the Relay registers as reward
  tokens.
- **Absurd balances revert instead of saturating.** `delta × FEE_BPS` uses checked arithmetic, so a token
  reporting a delta above `2²⁵⁶ / FEE_BPS` reverts the whole batch with a panic rather than yielding a zero
  fee. No real token reaches that range.

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
`b032bb7f55eff31e081196754e0fdbc217f978d2` (`1.0.0-provisional.3`, **undeployed**). The three MIT interface files are vendored
byte-for-byte under [`test/upstream/`](test/upstream/UPSTREAM.md) and pinned by sha256 in CI.
`test/Selectors.t.sol` asserts the two selectors this contract depends on, `pull` and `claimRewards`,
against literals, against `keccak256` of the signature strings, and against the vendored files.

**Do not deploy before Aero's final Relay code lands.** When it does, refresh the pin as described in
`test/upstream/UPSTREAM.md` and rerun the selector tests. If they fail, fix `src/interfaces/IRelayEntrypoint.sol`
and redeploy under a bumped salt (`.../RelayFeeSkim/v2` in `script/Deploy.s.sol`).

## Before deploying

Open items, in order. Nothing below is automated; each step is a human decision or a manual run.

1. **Wait for Aero's final Relay code.** The pin is `1.0.0-provisional.3`, which is undeployed. Refresh
   `test/upstream/` to the final commit (see `UPSTREAM.md`) and run `forge test --match-path test/Selectors.t.sol`.
   If anything fails, fix `src/interfaces/IRelayEntrypoint.sol`, regenerate `verification/`, and bump the salt.
2. **Choose `FEE_BPS` and `FEE_SINK`.** Neither is chosen yet. `FEE_BPS` is 1 to 1000; `FEE_SINK` should be
   an address that no reward token can blacklist (see Known limitations).
3. **Record the deployment hashes.** `FEE_BPS=… FEE_SINK=… forge script script/Hashes.s.sol` fills the
   `deployment` key in `verification/bytecode-hashes.json` (constructor args, init-code hash, predicted
   address, runtime keccak). Commit it before deploying so the record predates the deployment.
4. **Deploy and verify** (sections below), then confirm the on-chain address equals the recorded one.
5. **Hand off.** Pass the address as `converter` in `RelayFactory.createMaxiRelay` (table above). The slot is
   set once at creation, so check the address twice.

## Build and test

```
git clone --recurse-submodules https://github.com/leo-klima-agents/relay-fee-skim
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test        # 10_000 fuzz runs, what CI runs
forge lint --deny warnings           # what CI runs; needs the pinned forge, see below
```

`foundry.toml` pins `solc 0.8.36` to match the Relay's own compiler (move only when Aero's final code does),
`evm_version = "prague"`, optimizer on at 1,000,000 runs, `bytecode_hash = "ipfs"`, `cbor_metadata = true`.
Bytecode depends on solc and those settings, not on the forge release. `forge-std` is a submodule used by
tests and scripts only.

CI pins Foundry `v1.8.1` exactly (never `stable`). Two things in the repo assume that release: the
`[lint]` block in `foundry.toml` names 1.8.x lint ids, so `forge lint` on an older forge errors with
"Unknown lint ID" (`forge build` and `forge test` are unaffected), and `verification/RelayFeeSkim.standard-input.json`
is shaped by the forge that generated it (see Verify).

## Deploy

CREATE2 through forge's default deterministic deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with
salt `keccak256("leo-klima-agents/relay-fee-skim/RelayFeeSkim/v1")`. The address depends on the constructor
arguments **and on the exact creation bytecode**, which includes the ipfs metadata hash of the sources: a
comment edit in `src/` or a compiler-setting change moves it. Run `script/check-hashes.sh` before
re-running the script against a chain that already has a deployment.

```
export FEE_BPS=500                      # 1..1000
export FEE_SINK=0x...                   # non-zero

# preview the address
forge script script/Deploy.s.sol --sig "predict(uint256,address)" $FEE_BPS $FEE_SINK

# deploy (no-op if the predicted address already has code)
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
```

The script range-checks both inputs, asserts the deployed address equals the prediction, and reads
`FEE_BPS` and `FEE_SINK` back from the chain. The Base broadcast log, `broadcast/Deploy.s.sol/8453/run-latest.json`,
is the one broadcast artifact kept under version control; commit it with the deployment.

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

- `RelayFeeSkim.standard-input.json`: the solc standard JSON input, for manual verification. Regenerate
  with the pinned forge:
  `forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 src/RelayFeeSkim.sol:RelayFeeSkim > verification/RelayFeeSkim.standard-input.json`.
  `script/check-standard-input.sh` compares only the sources and the bytecode-relevant settings, so it
  passes on any forge release; the rest of the file is whatever forge emitted.
- `bytecode-hashes.json`: salt, CREATE2 deployer, keccak of the creation code and of the runtime template
  (immutable slots zeroed), and the compiler settings read back from the build artifact's metadata. With
  `FEE_BPS` and `FEE_SINK` set, `forge script script/Hashes.s.sol` also records the constructor args,
  init-code hash, predicted address and the keccak of the runtime bytecode with immutables filled in;
  without them the `deployment` key is absent. `script/check-hashes.sh` compares a fresh build against
  every recorded value and fails if any key is missing.

CI runs `forge fmt --check`, `forge build --sizes`, `forge lint --deny warnings`, `forge test` at the high
fuzz profile, the sha256 check of the vendored upstream files, and a reproducible-build job that builds
twice from clean, compares the bytecode, and fails on any drift from the recorded hashes or the committed
standard JSON input.

## Layout

```
src/RelayFeeSkim.sol                 the contract
src/interfaces/IRelayEntrypoint.sol  the two Relay members it calls, plus the two claim structs
src/interfaces/IERC20Minimal.sol     balanceOf, transfer
script/Deploy.s.sol                  CREATE2 deploy + predict
script/Hashes.s.sol                  writes verification/bytecode-hashes.json
script/check-hashes.sh               CI drift check (hashes + compiler settings)
script/check-standard-input.sh       CI check that the committed standard JSON input is current
test/RelayFeeSkim.t.sol              behaviour, fuzz, token edge cases, reentrancy (same-token and cross-token)
test/Selectors.t.sol                 upstream selector pin
test/Deploy.t.sol                    deploy script against forge's pre-deployed CREATE2 deployer
test/mocks/                          MockRelay (upstream semantics), MockERC20 variants
test/upstream/                       vendored MIT interfaces + UPSTREAM.md + SHA256SUMS
verification/                        standard JSON input, bytecode hashes
```

## License

MIT. The vendored files under `test/upstream/` are MIT-licensed upstream code, reproduced unmodified.
