#!/bin/sh
# Checks the code store's files restored onto the drill volume.
#
# Runs inside the code store's drill machine, whose image carries git:
#
#   sh /restore-drill/check_code.sh /drill
#
# Prints whether the node's identity key came back (never the key itself), then
# one line per fleet repository, `<repository> <fsck result> <refs>`, and exits 1
# when the key is missing or any repository fails its check. The copies belong
# to the drill machine's root user and the store's to its own, so git is told
# to trust them.
set -eu

root="$1"
status=0

if [ -s "$root/keys/identity.pem" ]; then
  echo "identity key: present"
else
  echo "identity key: missing"
  status=1
fi

# Each bare repository is a folder holding HEAD and objects/. The loop reads
# from a file, not a pipe, so its counts and status survive it.
find "$root/repos" -name HEAD -type f -not -path '*/refs/*' -not -path '*/logs/*' >/tmp/drill-heads
found=0
while read -r head; do
  repo="$(dirname "$head")"
  [ -d "$repo/objects" ] || continue
  found=$((found + 1))
  name="${repo#"$root/repos/"}"
  refs="$(git -c safe.directory='*' --git-dir="$repo" for-each-ref | wc -l | tr -d ' ')"
  if git -c safe.directory='*' --git-dir="$repo" fsck --no-progress --connectivity-only >/dev/null 2>&1; then
    echo "$name ok $refs"
  else
    echo "$name failed $refs"
    status=1
  fi
done </tmp/drill-heads

echo "repositories: $found"
exit "$status"
