#!/bin/bash
# Inject a link failure on a fabric node.
#   scripts/fail-link.sh down      <node> <if>   # link down: routing withdraws the path
#   scripts/fail-link.sh up        <node> <if>
#   scripts/fail-link.sh blackhole <node> <if>   # silent failure: link and BGP stay up,
#                                                # MetaRoCE packets (UDP dport 2766) leaving <if> are dropped
#   scripts/fail-link.sh clear     <node> <if>
#   scripts/fail-link.sh show      <node> <if>   # blackhole drop counter
# <node> is the short name (e.g. p1-spine2). Spine ethN faces leafN; leaf eth1..4 face spine1..4.
set -eu
LAB=${LAB:-metaroce}
cmd=$1; n="clab-$LAB-$2"; i=$3
case $cmd in
  down) docker exec "$n" ip link set "$i" down ;;
  up) docker exec "$n" ip link set "$i" up ;;
  blackhole)
    docker exec "$n" sh -c "tc qdisc replace dev $i clsact && \
      tc filter add dev $i egress protocol ipv6 flower ip_proto udp dst_port 2766 action drop" ;;
  clear) docker exec "$n" tc qdisc del dev "$i" clsact 2>/dev/null || true ;;
  show) docker exec "$n" tc -s filter show dev "$i" egress | awk '/Sent/ {print "'"$2 $i"'", $0}' ;;
  *) echo "usage: $0 down|up|blackhole|clear|show <node> <if>"; exit 1 ;;
esac
