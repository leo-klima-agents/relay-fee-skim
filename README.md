<!--
SPDX-FileCopyrightText: 2026 Klima Protocol
SPDX-License-Identifier: MIT
-->

# RelayFeeSkim

A 90-line immutable contract that Klima Protocol places in the `converter` slot of its Metadex Maxi
Relay, deployed on Base at [`0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb`](https://basescan.org/address/0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb#code).
It claims the Relay's rewards on anyone's behalf and pulls a fixed 5% of what the claim brought in to a
fixed sink. It never swaps, never calls `notifyReward` or `compound`, holds no storage and has
no owner. Aero's official Compounder occupies the `compounder` slot and processes the other 95%.

The whole mechanism is the single external function `claimAndSkim` in
[`src/RelayFeeSkim.sol`](src/RelayFeeSkim.sol): record the Relay's balance of each listed token, call
the Relay's own `claimRewards`, and for each token pull the fee share of the balance increase and forward
it to the sink.

## What it can do to a Relay

It calls exactly two Relay functions.

- `claimRewards(chainId, gasLimit, feeClaims, incentiveClaims)`, always for the root chain with zero
  value. This is permissionless on the Relay and pays the Relay itself, so the call changes nothing an
  arbitrary caller could not already change.
- `pull(token, amount)`, authorized by the CONVERTER role the `converter` slot grants. The Relay bounds
  every pull to `balanceOf(relay) - accountedBalance(token)`, so notified rewards are unreachable
  regardless of what this contract asks for.

The amount it asks for is `FEE_BPS / 10_000` of the balance increase its own `claimRewards` call
produced, per token, in the same transaction. It never reads or pulls against the idle balance, so
rewards that were already on the Relay before the call, whether accounted or not, are never touched.
`FEE_BPS` is an immutable checked against `MAX_FEE_BPS = 1_000` in the constructor.

## What it cannot do

- **Take more than the fee share of its own claim.** The base is a measured delta, the rate is fixed,
  and `pull` enforces the Relay's own bound on top. Fuzz-tested over balance, delta and rate.
- **Move funds anywhere but the sink.** `FEE_SINK` is an immutable. After every pull the contract
  forwards its entire balance of that token, so it holds nothing between transactions.
- **Change the Relay's accounting.** It never calls `notifyReward`, `compound`, `addRewardToken` or any
  role function. `accountedBalance` and the reward index are untouched by it.
- **Be administered or upgraded.** No owner, no setters, no proxy, no `receive`, no `fallback`. The
  only mutable state is a `bool transient` reentrancy lock that resets every transaction.
- **Be reentered.** `claimAndSkim` is guarded. A hostile reward token reentering from `transfer`,
  including one that sets up a second claim source for another token and reenters for that token,
  is reverted by the lock; both cases are tests.
- **Be pointed at anything dangerous.** `relay` and `tokens` are caller-supplied. A fake Relay or a
  hostile token can make the contract forward whatever it already holds to the fixed sink, and nothing
  else. A hostile token can also make it emit a `Skimmed` event with false numbers; no value moves.

## Interaction with the Compounder

Both entrypoints hold `pull`. The skimmer draws only on the delta of its own claim, in the same
transaction as that claim, so the Compounder never sees a balance the skimmer has partially processed
and then re-taxes it, and the skimmer never taxes a balance the Compounder is about to process. Rewards
claimed by any other caller reach the Relay untaxed and go to the Compounder whole; the skimmer has no
idle-balance path. That is a revenue gap for Klima, not a risk to the Relay.

## Relay wiring

The Relay is created with `RelayFactory.createMaxiRelay`. On a Maxi Relay the entrypoint slots are
immutable, so the CONVERTER grant to this contract is made once, at creation.

| `CreateParams` field | Value |
|---|---|
| `converter` | this contract (address below) |
| `compounder` | Aero's official Compounder |
| `rewardToken` | none (`address(0)`) |
| `admin` | Klima's multisig |
| `keeper` | a keeper Klima controls, so that `claimAndSkim` runs before compounding |

## Deployment

| | |
|---|---|
| Network | Base |
| Address | [`0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb`](https://basescan.org/address/0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb#code) |
| Verified source | [Basescan](https://basescan.org/address/0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb#code), [Sourcify](https://sourcify.dev/#/lookup/0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb) (exact runtime match) |
| Runtime code hash | `0x26ca5d6df3f33e0e45e32900630a6bf99fad4540df3fbbd5d8209027475279cc` |
| `FEE_BPS` | 500 (5%) |
| `FEE_SINK` | `0xf624f9Fe1D3165c5Ca32c7Fbdbf82f4a5b1D2d0e`, a 2-of-3 Safe |
| Method | CREATE2 through the default deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Salt | `keccak256("klimaprotocol.com/RelayFeeSkim/v1")` |

The on-chain runtime bytecode hashes to the `deployment.runtimeKeccak` recorded in
`verification/bytecode-hashes.json`; `verification/RelayFeeSkim.standard-input.json` is the compiler input
both explorers verified against.

## Upstream pin

Built against https://github.com/dromos-labs/metadex-public at `b032bb7f55eff31e081196754e0fdbc217f978d2`
(`1.0.0-provisional.3`). `src/interfaces/IRelayEntrypoint.sol` re-declares the two members it calls and
the two claim structs; it imports nothing from upstream. The three MIT interface files are vendored
byte-for-byte under `test/upstream/`, and `test/Selectors.t.sol` asserts both selectors against
literals, against `keccak256` of the signatures, and against those files.

If a later Relay release changes either selector or struct, refreshing the vendored files fails the
tests, and a corrected contract is deployed under a new salt.

## Reviewing

- The deployed code is this repository's code:
  `cast keccak $(cast code 0xa9bE0D3279eC1E0fF5e62be19793A06F47ba88Fb --rpc-url https://mainnet.base.org)`
  returns the runtime code hash above.
- `src/RelayFeeSkim.sol` and `src/interfaces/` are the whole surface; the rest is tests, tooling and
  records.
- `forge test` runs 41 tests, including fuzzing and both reentrancy scenarios, against `test/mocks/MockRelay.sol`,
  which mirrors the Relay's role gate, `pull` bound and the Voter's claim validation.
- `forge build --sizes` gives a 3,558-byte runtime. Two clean builds are byte-identical, and
  `verification/` holds the standard JSON input and the bytecode hashes CI checks on every commit.
- Compiler: solc 0.8.36 to match the Relay, `prague`, optimizer at 1,000,000 runs, ipfs metadata.

## Known limitations

- Rewards claimed by anyone other than this contract are not taxed.
- The sink is immutable; a token that blacklists it cannot be skimmed and must be left out of `tokens`.
- `Skimmed` events are only as trustworthy as the token that emitted the balance.
- A delta above `2²⁵⁶ / FEE_BPS` reverts the batch with a panic instead of saturating.

## License

MIT, REUSE compliant. The vendored upstream files are MIT, reproduced unmodified, with their copyright
holder recorded in `REUSE.toml`.
