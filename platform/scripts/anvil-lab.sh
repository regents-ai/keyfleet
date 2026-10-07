#!/usr/bin/env bash
#
# The anvil lab: a local fork of Base, run as chain 31337, with the Keyfleet
# contracts deployed and Classic #1 selling, and the site on
# http://localhost:4097 sending its wallet buttons to that chain. Each wallet
# named gets 100 ETH and 1,000 USDC on the lab chain and no Keys.
# docs/anvil-lab.md says what to try.
#
#   direnv exec /Users/sean/Documents/regent/repos/keyfleet/platform scripts/anvil-lab.sh 0xYourWallet [0xAnother ...]
#
# Run it from this platform directory. Every start is a fresh fork of Base and
# a fresh lab database (keyfleet_lab_dev). Ctrl-C stops the site and the chain
# together.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: scripts/anvil-lab.sh <your wallet address> [more wallet addresses]" >&2
  exit 64
fi

chain_port=8546
contracts="$(cd ../contracts && pwd)"
log_dir="tmp/anvil-lab"

export KEYFLEET_LAB="http://127.0.0.1:${chain_port}"
export PORT=4097
export KEYFLEET_APP_SURFACES=on

if cast chain-id --rpc-url "$KEYFLEET_LAB" >/dev/null 2>&1; then
  echo "Something already answers on port ${chain_port}. Stop it, then start the lab again." >&2
  exit 1
fi

mkdir -p "$log_dir"

anvil --fork-url https://mainnet.base.org --chain-id 31337 --port "$chain_port" \
  --block-time 2 --prune-history 300 --silent &
anvil_pid=$!
draws_pid=""
trap 'kill -INT "$anvil_pid" ${draws_pid:+"$draws_pid"} 2>/dev/null; wait "$anvil_pid" 2>/dev/null || true' EXIT

for _try in $(seq 1 100); do
  if cast chain-id --rpc-url "$KEYFLEET_LAB" >/dev/null 2>&1; then
    break
  fi
  sleep 0.3
done
cast chain-id --rpc-url "$KEYFLEET_LAB" >/dev/null

# On Base every one of anvil's default accounts has delegated code (EIP-7702)
# that passes on any NFT it receives. The lab's Safe, keeper and test buyers
# are those accounts, so the fork forgets that code.
for account in \
  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 \
  0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc \
  0x976EA74026E726554dB657fA54763abd0C3a0aa9 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955 \
  0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720; do
  cast rpc anvil_setCode "$account" 0x --rpc-url "$KEYFLEET_LAB" >/dev/null
done

(cd "$contracts" && script/base-fork-lab.sh deploy "$@")

# A Key's card is drawn by the lab's stand-in for Chainlink VRF, which answers
# only when asked: every 20 seconds, the lab asks it to answer every draw
# still waiting.
(
  while sleep 20; do
    (cd "$contracts" && script/base-fork-lab.sh fulfil) >>"${log_dir}/draws.log" 2>&1 || true
  done
) &
draws_pid=$!

mix ecto.drop
mix ecto.create
mix keyfleet.setup_local_auth
mix keyfleet.seed_deployment "${contracts}/deployments/base-fork-lab.json"
mix phx.server
