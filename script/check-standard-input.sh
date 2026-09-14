#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Klima Protocol
# SPDX-License-Identifier: MIT
# Check that verification/RelayFeeSkim.standard-input.json describes the current sources and the
# bytecode-relevant compiler settings. Only those parts are compared, so the check is independent of the
# forge release that shaped the rest of the file.
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
