#!/usr/bin/env bash
# The Base-fork lab: the Keyfleet system on a local fork of Base with Classic #1 selling, against
# Base's own USDC, swap route, REGENT staking and Autolaunch factory, for the site on
# http://localhost:4097. Every step refuses a chain whose id is not 31337, so nothing here reaches
# Base itself. No part of a release.
#
# Start the fork first, in its own terminal:
#
#   anvil --fork-url https://base.drpc.org --chain-id 31337 --port 8546
#
# Then, from contracts/, with KEYFLEET_LAB naming that chain (the site's lab reads the same):
#
#   export KEYFLEET_LAB=http://127.0.0.1:8546
#   script/base-fork-lab.sh deploy 0xBuyer [0xBuyer ...]  deploy, write deployments/base-fork-lab.json, fund each buyer
#   script/base-fork-lab.sh fund 0xBuyer [0xBuyer ...]    give each buyer 100 ETH and exactly 1,000 USDC
#   script/base-fork-lab.sh fulfil                        answer every card draw still waiting
#
# The Safe is anvil's first default account and the keeper its second; anvil unlocks both.
set -euo pipefail
cd "$(dirname "$0")/.."

rpc="${KEYFLEET_LAB:?Set KEYFLEET_LAB to the lab chain, such as http://127.0.0.1:8546.}"
safe=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
keeper=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
usdc=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
# Base USDC keeps each balance in slot 9's mapping (balanceAndBlacklistStates).
usdc_balance_slot=9
eth_each=0x56BC75E2D63100000
usdc_each=1000000000

usage() {
  echo "Usage: script/base-fork-lab.sh deploy|fund <buyer address>... | fulfil" >&2
  exit 64
}

require_lab_chain() {
  local chain
  chain=$(cast chain-id --rpc-url "$rpc")
  if [[ "$chain" != 31337 ]]; then
    echo "Refused: the chain at $rpc has id $chain, not the lab's 31337." >&2
    exit 1
  fi
}

fund() {
  local buyer slot held
  for buyer in "$@"; do
    cast rpc anvil_setBalance "$buyer" "$eth_each" --rpc-url "$rpc" >/dev/null
    slot=$(cast index address "$buyer" "$usdc_balance_slot")
    cast rpc anvil_setStorageAt "$usdc" "$slot" "$(cast to-uint256 "$usdc_each")" --rpc-url "$rpc" >/dev/null
    held=$(cast call "$usdc" "balanceOf(address)(uint256)" "$buyer" --rpc-url "$rpc" | awk '{print $1}')
    if [[ "$held" != "$usdc_each" ]]; then
      echo "Funding $buyer failed: it holds $held atomic USDC." >&2
      exit 1
    fi
    echo "Funded $buyer: 100 ETH and 1,000 USDC."
  done
}

[[ $# -ge 1 ]] || usage
step="$1"
shift

case "$step" in
  deploy)
    [[ $# -ge 1 ]] || usage
    require_lab_chain
    forge script script/BaseForkLab.s.sol:BaseForkLab --sig "deploy(address)" "$keeper" \
      --rpc-url "$rpc" --broadcast --unlocked --sender "$safe"
    forge script script/BaseForkLab.s.sol:BaseForkLab --sig "record()" --rpc-url "$rpc"
    fund "$@"
    echo "Wrote $(pwd)/deployments/base-fork-lab.json"
    ;;
  fund)
    [[ $# -ge 1 ]] || usage
    require_lab_chain
    fund "$@"
    ;;
  fulfil)
    [[ $# -eq 0 ]] || usage
    require_lab_chain
    # The coordinator, like Chainlink's, refuses an answer that cannot give the callback its full
    # gas, which Forge's estimate from the simulated run does not allow for; doubling it does.
    forge script script/BaseForkLab.s.sol:BaseForkLab --sig "fulfil()" \
      --rpc-url "$rpc" --broadcast --unlocked --sender "$safe" --gas-estimate-multiplier 200
    ;;
  *)
    usage
    ;;
esac
