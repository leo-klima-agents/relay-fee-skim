#!/usr/bin/env bash
# Compare the current build's RelayFeeSkim artifact against verification/bytecode-hashes.json:
# the runtime template (immutable slots zeroed), the creation code, and the recorded compiler settings.
# Exits 0 when everything matches or when no record exists yet; a record with missing keys is a failure.
set -euo pipefail
cd "$(dirname "$0")/.."

ARTIFACT=out/RelayFeeSkim.sol/RelayFeeSkim.json
RECORD=verification/bytecode-hashes.json

[ -f "$ARTIFACT" ] || { echo "missing $ARTIFACT; run forge build first" >&2; exit 1; }

runtime_hash=$(cast keccak "$(jq -r '.deployedBytecode.object' "$ARTIFACT")")
creation_hash=$(cast keccak "$(jq -r '.bytecode.object' "$ARTIFACT")")
echo "creationCodeKeccak    (built)    $creation_hash"
echo "runtimeTemplateKeccak (built)    $runtime_hash"

if [ ! -f "$RECORD" ]; then
  echo "no $RECORD yet; nothing to compare"
  exit 0
fi

status=0
# expect <jq path into RECORD> <built value> <label>
expect() {
  local recorded
  # `// empty` would drop a legitimate `false`, so test for null explicitly.
  recorded=$(jq -r "$1 | if . == null then \"\" else tostring end" "$RECORD")
  if [ -z "$recorded" ]; then
    echo "::error::$RECORD is missing $1" >&2; status=1
  elif [ "$recorded" != "$2" ]; then
    echo "::error::$3 drifted: recorded $recorded, built $2" >&2; status=1
  else
    echo "$3 ok ($2)"
  fi
}

expect '.runtimeTemplateKeccak' "$runtime_hash" "runtimeTemplateKeccak"
expect '.creationCodeKeccak' "$creation_hash" "creationCodeKeccak"
expect '.compiler.solc' "$(jq -r '.metadata.compiler.version' "$ARTIFACT")" "compiler.solc"
expect '.compiler.evmVersion' "$(jq -r '.metadata.settings.evmVersion' "$ARTIFACT")" "compiler.evmVersion"
expect '.compiler.optimizer' "$(jq -r '.metadata.settings.optimizer.enabled' "$ARTIFACT")" "compiler.optimizer"
expect '.compiler.optimizerRuns' "$(jq -r '.metadata.settings.optimizer.runs' "$ARTIFACT")" "compiler.optimizerRuns"
expect '.compiler.viaIr' "$(jq -r '.metadata.settings.viaIR // false' "$ARTIFACT")" "compiler.viaIr"
expect '.compiler.bytecodeHash' "$(jq -r '.metadata.settings.metadata.bytecodeHash' "$ARTIFACT")" "compiler.bytecodeHash"

[ $status -eq 0 ] && echo "artifact matches $RECORD"
exit $status
