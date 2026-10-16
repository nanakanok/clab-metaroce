#!/bin/bash
# Shape every fabric port (leaf/spine ethN) and mark ECN with RED, so the
# software transport sees congestion. veth is otherwise "infinitely" fast.
#   scripts/fabric-qos.sh on  [rate=1gbit] [min=60000] [max=180000]   (bytes)
#   scripts/fabric-qos.sh off
#   scripts/fabric-qos.sh show
# Runs from the containerlab host with docker exec.
set -eu
LAB=${LAB:-metaroce}
MODE=${1:-show}; RATE=${2:-1gbit}; MIN=${3:-60000}; MAX=${4:-180000}
nodes=$(docker ps --format '{{.Names}}' | grep -E "^clab-$LAB-p[0-9]+-(leaf|spine)[0-9]+$" | sort -V)

for n in $nodes; do
  ifs=$(docker exec "$n" sh -c "ls /sys/class/net | grep -E '^eth[1-9][0-9]*$'")
  for i in $ifs; do
    case $MODE in
      on)
        docker exec "$n" sh -c "
          tc qdisc del dev $i root 2>/dev/null || true
          tc qdisc add dev $i root handle 1: htb default 1 r2q 1000
          tc class add dev $i parent 1: classid 1:1 htb rate $RATE ceil $RATE
          tc qdisc add dev $i parent 1:1 handle 10: red limit $((MAX * 8)) min $MIN max $MAX \
             avpkt 4200 burst $(( (2 * MIN + MAX) / (3 * 4200) + 1 )) bandwidth $RATE probability 1 ecn"
        ;;
      off) docker exec "$n" tc qdisc del dev "$i" root 2>/dev/null || true ;;
      show)
        docker exec "$n" tc -s qdisc show dev "$i" | awk -v n="${n#clab-$LAB-}" -v i="$i" '
          /^qdisc red/ {red=1} red && /Sent/ {sent=$2; drop=$7}
          red && /marked/ {print n, i, "sent=" sent, "dropped=" drop, $0; red=0}' | tr -s ' ' ;;
    esac
  done
done
[ "$MODE" = on ] && echo "fabric shaped to $RATE, RED ECN min=$MIN max=$MAX bytes"
true
