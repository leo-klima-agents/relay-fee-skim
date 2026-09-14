# Vendored upstream fixtures

Byte-identical copies of the three MIT-licensed interface files RelayFeeSkim is built against.
They are **test fixtures only**: `src/` never imports them. `test/Selectors.t.sol` compiles
`IRelayEntrypoint.sol` and compares selectors directly; `IRelay.sol` and `ILeafVoter.sol` import
the rest of the metadex tree, so they are excluded from compilation (`skip` in `foundry.toml`) and
checked as text for the exact declarations that produce the `claimRewards` selector and the two
claim structs.

| Local file | Upstream path | License |
|---|---|---|
| `IRelayEntrypoint.sol` | `V3/src/interfaces/relay/IRelayEntrypoint.sol` | MIT |
| `IRelay.sol` | `V3/src/interfaces/relay/IRelay.sol` | MIT |
| `ILeafVoter.sol` | `V3/src/interfaces/voter/ILeafVoter.sol` | MIT |

- Repository: https://github.com/dromos-labs/metadex-public
- Commit: `b032bb7f55eff31e081196754e0fdbc217f978d2` (`1.0.0-provisional.3`, undeployed)
- Hashes: see `SHA256SUMS` (verified in CI with `sha256sum -c`)

```
d10e57499d9c91795eac315333e39998fcfb9e609b8f52831c49cdc25aeb841c  IRelayEntrypoint.sol
0735a94ecef3d5208f710652e1891fddd40e32c312c0246e7298cfb7258226bb  IRelay.sol
06ec6ce350e142624e7df76a803006e4dd4ed8c65e0249de765b4f82d5147dac  ILeafVoter.sol
```

## Selectors pinned from these files

| Member | Selector | Source |
|---|---|---|
| `pull(address,uint256)` | `0xf2d5d56b` | `IRelayEntrypoint` |
| `accountedBalance(address)` | `0xa7838c8a` | `IRelayEntrypoint` |
| `KEEPER()` | `0x862a179e` | `IRelayEntrypoint` |
| `hasAnyRole(address,uint256)` | `0x514e62fc` | `IRelayEntrypoint` |
| `claimRewards(uint256,uint256,(address,uint256)[],(address,uint256,uint256)[])` | `0xfa6a8ba9` | `IRelay` + `ILeafVoter` structs |

## Refreshing the pin

```
C=<new commit>
for f in relay/IRelayEntrypoint relay/IRelay voter/ILeafVoter; do
  curl -sSL -o test/upstream/$(basename $f).sol \
    https://raw.githubusercontent.com/dromos-labs/metadex-public/$C/V3/src/interfaces/$f.sol
done
(cd test/upstream && sha256sum IRelayEntrypoint.sol IRelay.sol ILeafVoter.sol > SHA256SUMS)
forge test --match-path test/Selectors.t.sol
```

If any selector test fails after a refresh, the deployed contract no longer matches the Relay it
targets: fix `src/interfaces/IRelayEntrypoint.sol`, then redeploy under a bumped salt.
