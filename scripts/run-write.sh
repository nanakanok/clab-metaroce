#!/bin/bash
# Run an rdma_gen RDMA WRITE test between lab hosts over libsoftmetaroce.
#   scripts/run-write.sh <server> <client>[,<client>...] [options]
# Options (env):
#   PLANES=1|2|1,2   planes to use (multi-port when more than one)   default 1
#   FLOWS=8          MetaRoCE tx flows per QP (--libsoftmetaroce_txflows) default 8
#   CC=baseline_rcn  congestion control (--libsoftmetaroce_cc_algorithm) default: library default
#   MSGS=300         messages per client                              default 300
#   SIZE=1048576     message size in bytes                            default 1MiB
#   NIC_GBPS=10      NIC rate for the receiver-driven CC (RCN) hint    default 10 (library default)
#                    Integer Gbit/s. The receiver advertises ceil(NIC_GBPS / active receiving QPs)
#                    per QP, so the smallest hint is 1 Gbit/s; it cannot cap below that.
#   EXTRA="..."      extra rdma_gen flags for both sides
# Note: rdma_gen's --tx_path_count is not used by libsoftmetaroce; flows come from --libsoftmetaroce_txflows.
# Example: PLANES=1,2 FLOWS=4 scripts/run-write.sh h8 h1,h2,h3   (incast to h8)
set -eu
LAB=${LAB:-metaroce}
SRV=$1; CLIS=$2
PLANES=${PLANES:-1}; FLOWS=${FLOWS:-8}; CC=${CC:-}; MSGS=${MSGS:-300}; SIZE=${SIZE:-1048576}
NIC_GBPS=${NIC_GBPS:-10}; EXTRA=${EXTRA:-}
OUT=${OUT:-results}; mkdir -p "$OUT"
ts=$(date +%Y%m%d-%H%M%S)

# host addresses: fd00:<plane>:<leaf>:<idx>::10 (see gen.py)
addrs() {  # $1 = host name -> comma-separated GIDs for $PLANES
  local exp l i hp out=""
  hp=$(docker exec "clab-$LAB-$1" ip -6 -o addr show dev eth1 | awk '/fd00:/{print $4}' | head -1)
  l=$(echo "$hp" | cut -d: -f3); i=$(echo "$hp" | cut -d: -f4)
  for p in ${PLANES//,/ }; do out+="${out:+,}fd00:$p:$l:$i::10"; done
  echo "$out"
}
common="--verbs_mode=libsoftmetaroce --ib_dev= --mtu=IBV_MTU_4096 --op_type=write \
 --message_size=$SIZE --libsoftmetaroce_txflows=$FLOWS ${CC:+--libsoftmetaroce_cc_algorithm=$CC} \
 --libsoftmetaroce_nic_rate_gbps=$NIC_GBPS $EXTRA"

NCLI=$(echo "${CLIS//,/ }" | wc -w)
srv_gids=$(addrs "$SRV")
docker exec "clab-$LAB-$SRV" pkill -x rdma_gen || true
docker exec -d "clab-$LAB-$SRV" sh -c "rdma_gen $common --gid_addresses=$srv_gids --qp_cap=$NCLI --num_clients_to_complete=$NCLI --duration_secs=0 > /tmp/rdma_gen-server.log 2>&1"
sleep 2

pids=()
for c in ${CLIS//,/ }; do
  docker exec "clab-$LAB-$c" sh -c "timeout 120 rdma_gen $common --gid_addresses=$(addrs "$c") \
    --rc_servers=${srv_gids%%,*} --num_messages=$MSGS --duration_secs=60 \
    --json_path=/tmp/rdma_gen-$ts.json > /tmp/rdma_gen-client.log 2>&1" &
  pids+=($!)
done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
docker exec "clab-$LAB-$SRV" pkill -x rdma_gen || true

for c in ${CLIS//,/ }; do
  docker cp -q "clab-$LAB-$c:/tmp/rdma_gen-$ts.json" "$OUT/$ts-$c.json" 2>/dev/null || { echo "$c: no result"; rc=1; continue; }
  # rdma_gen counts failed work completions as messages, so report them separately.
  failed=$(docker exec "clab-$LAB-$c" grep -c 'failed with ibv_wc_status' /tmp/rdma_gen-client.log || true)
  python3 - "$OUT/$ts-$c.json" "$c" "${failed:-0}" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = (d[-1] if isinstance(d, list) else d)["results"]
failed = int(sys.argv[3])
note = f"  FAILED: {failed} work completions with error status" if failed else ""
print(f"{sys.argv[2]}: {sum(r['total_messages'])} msgs  {r['Gbps']:.3f} Gbps{note}")
EOF
  [ "${failed:-0}" -eq 0 ] || rc=1
done
exit $rc
