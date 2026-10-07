#!/usr/bin/env bash
#
# The anvil lab: a local chain holding one fleet whose first two keys are
# yours, and the site on http://localhost:4097 sending its wallet buttons to
# that chain. docs/anvil-lab.md says what to try.
#
#   direnv exec /Users/sean/Documents/regent/repos/keyfleet/platform scripts/anvil-lab.sh 0xYourWallet
#
# Run it from this platform directory. The chain is kept in tmp/anvil-lab, so
# stopping and starting again keeps the fleet and everything done with it.
# Ctrl-C stops the site and the chain together.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/anvil-lab.sh <your wallet address>" >&2
  exit 64
fi

holder="$1"
chain_port=8546
state_dir="tmp/anvil-lab"

export KEYFLEET_LAB="http://127.0.0.1:${chain_port}"
export PORT=4097

mkdir -p "$state_dir"

anvil --port "$chain_port" --block-time 2 --prune-history \
  --state "${state_dir}/chain.json" --silent &
anvil_pid=$!
trap 'kill -INT "$anvil_pid" 2>/dev/null; wait "$anvil_pid" 2>/dev/null || true' EXIT

for _try in $(seq 1 50); do
  if cast chain-id --rpc-url "$KEYFLEET_LAB" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
cast chain-id --rpc-url "$KEYFLEET_LAB" >/dev/null

mix ecto.create
mix keyfleet.setup_local_auth
mix keyfleet.anvil_lab "$holder"
mix phx.server
