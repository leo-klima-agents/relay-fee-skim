#!/usr/bin/env bash
# Compare the current build's RelayFeeSkim runtime template (immutable slots zeroed) against the hash
# recorded in verification/bytecode-hashes.json. Exits 0 when they match or when no hash is recorded yet.
set -euo pipefail
cd "$(dirname "$0")/.."

ARTIFACT=out/RelayFeeSkim.sol/RelayFeeSkim.json
RECORD=verification/bytecode-hashes.json

[ -f "$ARTIFACT" ] || { echo "missing $ARTIFACT; run forge build first" >&2; exit 1; }

runtime=$(jq -r '.deployedBytecode.object' "$ARTIFACT")
creation=$(jq -r '.bytecode.object' "$ARTIFACT")
runtime_hash=$(cast keccak "$runtime")
creation_hash=$(cast keccak "$creation")

echo "creationCodeKeccak    (built)    $creation_hash"
echo "runtimeTemplateKeccak (built)    $runtime_hash"

if [ ! -f "$RECORD" ]; then
  echo "no $RECORD yet; nothing to compare"
  exit 0
fi

recorded_runtime=$(jq -r '.runtimeTemplateKeccak // empty' "$RECORD")
recorded_creation=$(jq -r '.creationCodeKeccak // empty' "$RECORD")
echo "creationCodeKeccak    (recorded) ${recorded_creation:-<none>}"
echo "runtimeTemplateKeccak (recorded) ${recorded_runtime:-<none>}"

status=0
if [ -n "$recorded_runtime" ] && [ "$recorded_runtime" != "$runtime_hash" ]; then
  echo "::error::runtime bytecode drifted from $RECORD" >&2; status=1
fi
if [ -n "$recorded_creation" ] && [ "$recorded_creation" != "$creation_hash" ]; then
  echo "::error::creation bytecode drifted from $RECORD" >&2; status=1
fi
[ $status -eq 0 ] && echo "bytecode matches recorded hashes"
exit $status
