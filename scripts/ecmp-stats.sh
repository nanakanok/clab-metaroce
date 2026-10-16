#!/bin/bash
# Show how traffic spread over the spines: TX packets of each leaf uplink.
#   scripts/ecmp-stats.sh snap   # save a baseline
#   scripts/ecmp-stats.sh        # print delta since the baseline
set -eu
LAB=${LAB:-metaroce}
STATE=${TMPDIR:-/tmp}/ecmp-stats-$LAB
spines=$(docker ps --format '{{.Names}}' | grep -cE "^clab-$LAB-p1-spine[0-9]+$")
now() {
  for n in $(docker ps --format '{{.Names}}' | grep -E "^clab-$LAB-p[0-9]+-leaf[0-9]+$" | sort -V); do
    for s in $(seq 1 "$spines"); do
      echo "${n#clab-$LAB-} eth$s $(docker exec "$n" cat /sys/class/net/eth$s/statistics/tx_packets)"
    done
  done
}
if [ "${1:-}" = snap ]; then now > "$STATE"; echo "baseline saved"; exit; fi
[ -f "$STATE" ] || { echo "run '$0 snap' first"; exit 1; }
join -j1 <(awk '{print $1"/"$2, $3}' "$STATE" | sort) <(now | awk '{print $1"/"$2, $3}' | sort) |
  awk '{split($1,a,"/"); d=$3-$2; if (d>0) row[a[1]]=row[a[1]] sprintf(" %s(->spine%s)=%d", a[2], substr(a[2],4), d)}
       END {for (r in row) print r ":" row[r]}' | sort -V
