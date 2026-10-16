#!/bin/bash
# Print TX packets per second on each spine-facing port of the given leaves.
#   scripts/uplink-watch.sh p1-leaf1 [p1-leaf4 ...]     # Ctrl-C to stop
# Columns: time, then <leaf>:<pkts to spine1>/<spine2>/... for each leaf.
set -eu
LAB=${LAB:-metaroce}
spines=$(docker ps --format '{{.Names}}' | grep -cE "^clab-$LAB-p1-spine[0-9]+$")
read_tx() {  # $1 = leaf -> space-separated tx_packets of eth1..eth$spines
  docker exec "clab-$LAB-$1" sh -c "for s in \$(seq 1 $spines); do cat /sys/class/net/eth\$s/statistics/tx_packets; done" | tr '\n' ' '
}
declare -A prev
for l in "$@"; do prev[$l]=$(read_tx "$l"); done
while sleep 1; do
  line=$(date +%T)
  for l in "$@"; do
    cur=$(read_tx "$l")
    line+=" $l:$(paste -d' ' <(tr ' ' '\n' <<<"${prev[$l]}") <(tr ' ' '\n' <<<"$cur") |
      awk 'NF==2 {printf "%s%d", (NR>1?"/":""), $2-$1}')"
    prev[$l]=$cur
  done
  echo "$line"
done
