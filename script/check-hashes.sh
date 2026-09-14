#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Klima Protocol
# SPDX-License-Identifier: MIT
# Compare the current build's RelayFeeSkim artifact against verification/bytecode-hashes.json: bytecode
# hashes, compiler settings and the recorded deployment. Exits 0 with no record; a record with missing keys fails.
set -euo pipefail
cd "$(dirname "$0")/.."

ARTIFACT=out/RelayFeeSkim.sol/RelayFeeSkim.json
RECORD=verification/bytecode-hashes.json

[ -f "$ARTIFACT" ] || { echo "missing $ARTIFACT; run forge build first" >&2; exit 1; }

creation=$(jq -r '.bytecode.object' "$ARTIFACT")
runtime_hash=$(cast keccak "$(jq -r '.deployedBytecode.object' "$ARTIFACT")")
creation_hash=$(cast keccak "$creation")
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

fee_bps=$(jq -r '.deployment.feeBps // empty' "$RECORD")
fee_sink=$(jq -r '.deployment.feeSink // empty' "$RECORD")
deployer=$(jq -r '.create2Deployer // empty' "$RECORD")
salt=$(jq -r '.salt // empty' "$RECORD")
if [ -z "$fee_bps" ] || [ -z "$fee_sink" ] || [ -z "$deployer" ] || [ -z "$salt" ]; then
  echo "::error::$RECORD is missing deployment.feeBps, deployment.feeSink, create2Deployer or salt" >&2; status=1
else
  args=$(cast abi-encode 'constructor(uint256,address)' "$fee_bps" "$fee_sink")
  init_code_hash=$(cast keccak "${creation}${args#0x}")
  address=$(cast to-check-sum-address "0x$(cast keccak "0xff${deployer#0x}${salt#0x}${init_code_hash#0x}" | tail -c 41)")
  expect '.deployment.constructorArgs' "$args" "deployment.constructorArgs"
  expect '.deployment.initCodeHash' "$init_code_hash" "deployment.initCodeHash"
  expect '.deployment.address' "$address" "deployment.address"
fi

[ $status -eq 0 ] && echo "artifact matches $RECORD"
exit $status
