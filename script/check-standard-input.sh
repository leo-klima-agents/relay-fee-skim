#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Klima Protocol
# SPDX-License-Identifier: MIT
# The committed standard JSON input must match the current sources and bytecode-relevant settings. Only
# those parts are compared, so any forge release can run this.
set -euo pipefail
cd "$(dirname "$0")/.."

RECORD=verification/RelayFeeSkim.standard-input.json
PROJECTION='{
  language,
  sources,
  settings: {
    optimizer: .settings.optimizer,
    evmVersion: .settings.evmVersion,
    viaIR: (.settings.viaIR // false),
    metadata: .settings.metadata,
    remappings: (.settings.remappings // [])
  }
}'

current=$(forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 \
  src/RelayFeeSkim.sol:RelayFeeSkim | jq -S "$PROJECTION")
recorded=$(jq -S "$PROJECTION" "$RECORD")

if [ "$current" != "$recorded" ]; then
  echo "::error::$RECORD is stale; regenerate it (see README, Verify)" >&2
  diff <(echo "$recorded") <(echo "$current") || true
  exit 1
fi
echo "$RECORD matches current sources and settings"
