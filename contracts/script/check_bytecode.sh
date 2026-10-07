#!/usr/bin/env bash
# Refuses a build in which the collection, the factory and its deployers, the REGENT buyer, the
# shard record or any of a fleet's four contracts can reach DELEGATECALL, CALLCODE or SELFDESTRUCT. Each contract's deployed code is disassembled with `cast disassemble`, which steps
# over push data, and walked from its entry point: straight on until an instruction that ends the
# path, and into every JUMPDEST whose offset reachable code pushes as a constant, which is how
# Solidity names every jump target. Bytes nothing jumps to, such as the Classic price table at the
# end of the manager's code, are data and are not judged. A deployer's runtime code is checked as
# deployed; the code it places is checked under its own contract's name.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for contract in KeyfleetKeys KeyfleetFactory KeyfleetManagerDeployer KeyfleetVotesDeployer \
  KeyfleetTreasuryDeployer KeyfleetRewardsDeployer KeyfleetRegentBuyer KeyfleetShards KeyfleetManager \
  KeyfleetVotes KeyfleetTreasury KeyfleetRewards; do
  code=$(forge inspect "$contract" deployedBytecode)
  found=$(cast disassemble "$code" | awk '
    function hex(s,    i, n, c) {
      s = tolower(s); sub(/^0x/, "", s); n = 0
      for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; n = n * 16 + c }
      return n
    }
    {
      off = $1; sub(/:$/, "", off)
      count++; at[count] = hex(off); op[count] = $2; arg[count] = $3; index_of[hex(off)] = count
    }
    END {
      ends["STOP"] = ends["RETURN"] = ends["REVERT"] = ends["INVALID"] = ends["SELFDESTRUCT"] = ends["JUMP"] = 1
      todo[1] = 1; queued[1] = 1; head = 1; tail = 1
      while (head <= tail) {
        i = todo[head++]
        for (; i <= count; i++) {
          if (seen[i]) break
          seen[i] = 1
          name = op[i]
          if (name == "DELEGATECALL" || name == "CALLCODE" || name == "SELFDESTRUCT") {
            printf "%s at 0x%x\n", name, at[i]
          }
          if (name ~ /^PUSH[1-4]$/) {
            j = index_of[hex(arg[i])]
            if (j && op[j] == "JUMPDEST" && !queued[j]) { queued[j] = 1; todo[++tail] = j }
          }
          if ((name in ends) || name !~ /^[A-Z0-9]+$/) break
        }
      }
    }')
  if [ -n "$found" ]; then
    echo "$contract can reach:" >&2
    echo "$found" >&2
    status=1
  else
    echo "$contract: no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT"
  fi
done
exit "$status"
