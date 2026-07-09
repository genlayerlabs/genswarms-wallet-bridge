#!/usr/bin/env bash
# Run every verification layer locally — the same gates as CI.
# Requires: elixir/mix, node >= 22, foundry (forge + anvil).
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s ==\n' "$1"; }

step "version stamps"
./scripts/check-version.sh

step "keeper hermetic tests (mix test)"
mix test

step "webapp tests (node --test)"
node --test webapp/tools/

step "vectors are the committed generator output (byte-identical)"
node webapp/tools/gen-vectors.mjs
git diff --exit-code vectors/

step "contracts (forge test)"
(cd contracts && forge test)

step "real-EVM e2e (anvil permit lane)"
(cd contracts && forge build)
anvil --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 1
mix run test/e2e/anvil_permit_lane.exs

printf '\nAll layers green.\n'
