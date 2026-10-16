---
type: Network Lab
title: clab-metaroce
description: Multi-plane FRR leaf-spine containerlab for observing MetaRoCE (libsoftmetaroce) multipath, ECN and incast behavior
tags:
  - metaroce
  - rdma
  - containerlab
  - frr
  - multipath
timestamp: "2026-10-16"
---

# clab-metaroce

A containerlab environment for observing how [MetaRoCE](https://github.com/facebookincubator/metaroce) behaves on a multi-plane leaf-spine.

- The switches are FRR containers.
- The hosts run `libsoftmetaroce`, the software MetaRoCE transport over UDP, and drive it with `rdma_gen`.

It is meant for checking how the protocol mechanisms behave:

- ECMP spreading by source port
- multi-plane operation
- SACK retransmission
- ECN response

It is not for measuring line-rate performance.

## Topology (default)

```
 plane 1                                   plane 2
 p1-spine1..4   (AS 65001)                 p2-spine1..4   (AS 65002)
   | full mesh, eBGP unnumbered (IPv6 LL)    |
 p1-leaf1..4    (AS 65101..65104)          p2-leaf1..4    (AS 65201..65204)
   |                                         |
   +---- eth1 ---- h1..h8 ---- eth2 ---------+
```

| Item | Value |
|---|---|
| Nodes | 24: 8 spines, 8 leaves, 8 hosts |
| Links | 48 |
| Per plane | 4 spines × 4 leaves, so each leaf has 4-way ECMP |
| Hosts | 2 per leaf. Each host has one NIC per plane: `eth1` connects to plane 1, `eth2` to plane 2 |
| Addressing (IPv6 only) | host *i* on leaf *l*, plane *p* = `fd00:p:l:i::10/64`, gateway `::1`. Host h1 = `fd00:1:1:1::10` / `fd00:2:1:1::10` |
| Plane isolation | Planes do not route to each other (`fd00:1::/32` is plane 1 only, `fd00:2::/32` is plane 2 only) |
| ECMP hashing | `net.ipv6.fib_multipath_hash_policy=1` (L4 5-tuple). MetaRoCE carries its entropy in the UDP source port, so different flows can take different spines |
| MTU | 9000 |

You can change the scale with `./gen.py --planes 2 --spines 4 --leaves 4 --hosts-per-leaf 2`. It regenerates `metaroce.clab.yml` and `configs/`.

## Usage

```bash
# 1. host image (first build pulls and compiles folly/fbthrift via getdeps; takes long)
docker build -t metaroce-host:6c5a3a4 docker

# 2. generate & deploy
./gen.py
containerlab deploy -t metaroce.clab.yml

# 3. make congestion observable: shape every fabric port and mark ECN (RED)
scripts/fabric-qos.sh on 300mbit        # off / show
scripts/ecmp-stats.sh snap              # baseline; run again later for per-uplink deltas

# 4. RDMA WRITE over libsoftmetaroce
scripts/run-write.sh h8 h1                       # 1:1, plane 1
MSGS=100 scripts/run-write.sh h8 h1,h3,h5        # 3:1 incast
PLANES=1,2 MSGS=100 scripts/run-write.sh h8 h1,h3,h5   # incast over both planes (multi-port QP)
scripts/fabric-qos.sh show                       # ECN marks / drops per port

# 5. link failure, while a transfer is running (see "Link failure")
scripts/uplink-watch.sh p1-leaf1 p1-leaf4        # packets/s on each uplink
scripts/fail-link.sh down p1-leaf1 eth2          # link down; undo with 'up'
scripts/fail-link.sh blackhole p1-spine2 eth4    # drop UDP 2766 silently; undo with 'clear'

# teardown
containerlab destroy -t metaroce.clab.yml --cleanup
```

### Deploy from the GitHub URL

containerlab can clone this repository and deploy it in one step. The host image is not published to any registry, so build it locally first; the tag must match the topology (`metaroce-host:6c5a3a4`).

```bash
docker build -t metaroce-host:6c5a3a4 https://github.com/nanakanok/clab-metaroce.git#main:docker
containerlab deploy -t https://github.com/nanakanok/clab-metaroce
```

The repository is cloned into the current directory, and the helper scripts are run from that clone (`cd clab-metaroce`).

## Files

| Path | Contents |
|---|---|
| `docker/Dockerfile` | Host image with `rdma_gen` and `libsoftmetaroce`, built with getdeps and pinned to metaroce `6c5a3a4`. The build stage takes about an hour on 6 cores. The runtime image is about 240 MB |
| `gen.py` | Topology and FRR config generator |
| `metaroce.clab.yml`, `configs/` | Generated output, committed for the default size |
| `scripts/fabric-qos.sh` | Uses HTB shaping plus RED with ECN marking on all leaf and spine ports |
| `scripts/ecmp-stats.sh` | Shows TX deltas on each leaf uplink, so you can see how traffic spreads over the spines |
| `scripts/run-write.sh` | Starts an `rdma_gen` server and one or more clients, then prints each client's throughput and any failed work completions. Result JSON goes to `results/` |
| `scripts/fail-link.sh` | Takes a fabric link down, or silently drops MetaRoCE packets (UDP 2766) on a port while the link and BGP stay up |
| `scripts/uplink-watch.sh` | Prints packets per second on each spine-facing port of the given leaves |

## Example results

Conditions: default topology, 1 MiB WRITE messages, 8 MetaRoCE flows per QP, `NIC_GBPS=10` (the `run-write.sh` default). Each value is the median of 3 runs. The fabric was either shaped to 300 Mbit/s with RED ECN (`min=60KB`, `max=180KB`) or left unshaped.

| Scenario (sum over clients) | 300 Mbit/s | Unshaped |
|---|---|---|
| 1:1 (h1→h8) | 0.29 Gbit/s | 1.29 Gbit/s |
| 3:1 incast (h1,h3,h5→h8), plane 1 | 0.30 Gbit/s | 1.64 Gbit/s |
| 3:1 incast, planes 1+2 | 0.59 Gbit/s | 1.77 Gbit/s |

- At 300 Mbit/s the link is the bottleneck. The three incast senders share the downlink to h8 about equally, and the leaf downlink to h8 marked about 25k packets with ECN while dropping only a few. One multi-port QP stripes across both planes, so the sum doubles.
- Unshaped, the software transport is the bottleneck: about 1.3 Gbit/s for 1:1, and using both planes barely raises the sum.

### Receiver-driven rate limiting (RCN)

The receiver advertises `ceil(NIC_GBPS / active receiving QPs)` per QP, in whole Gbit/s, so the hint is never below 1 Gbit/s and does not bind on a 300 Mbit/s fabric. There, fair sharing comes from ECN-driven AIMD. With the fabric shaped to 3 Gbit/s (3:1 incast, median of 3 runs):

| `NIC_GBPS` | Hint per QP | Sum of throughput | ECN marks on the downlink to h8 |
|---|---|---|---|
| 3 | 1 Gbit/s (equal to the fair share) | 1.45 Gbit/s | 0 / 0 / 0 |
| 10 | 4 Gbit/s (does not bind) | 1.60 Gbit/s | 207 / 257 / 413 |

When RCN binds, the window is capped before the queue reaches the RED threshold, so no packets were marked. A small `NIC_GBPS` silently caps each QP, which is why `run-write.sh` uses the library default of 10.

### Multipath

Having 8 flows per QP does not mean all 4 spines carry data. The spec adds flows as the rate, and so the window, grows (§7.4.2), and moves window from congested flows to uncongested ones (§6.1.2). With the short RTTs in this lab, a few packets of window are enough, so one flow carries the traffic on an idle fabric. The traffic spread only when a path became congested.

- 1:1 unshaped and 3:1 incast: each sender used almost only one spine. The bottleneck is the software or the downlink to h8, so extra paths do not help.
- h1→h7 and h2→h8 at the same time, both from leaf1: when both senders hashed onto a shared uplink, the traffic from leaf1 spread over three spines and the congested uplink marked ECN. In 2 of 3 runs the two senders happened to take different spines and each stayed on one.

This matches the spec. §7.4.2 recommends activating another flow when `average_window × (active_flow_count + 1) < QWND`. §6.1.2 reduces only the congested flow's `FWND`, and requires that a flow with higher-than-usual RTT can skip a window increase so that another flow claims it. libsoftmetaroce sends a fast-start burst on each flow, then grows the window only on flows whose RTT is at or below the smoothed QP RTT and shrinks it on flows that see ECN marks.

A capture on h1 showed 6 data source ports, most traffic on 2 of them. They step by 2 because each flow gets a data socket and an ACK socket. The ACKs used other source ports at a constant offset, but the offset is not computed from the data port: the receiver sends the ACKs for each flow ID from its own fixed socket. When the sender repaths a flow after repeated RTOs, the ACK path stays the same, which differs from the recommendation in spec §7.1.1 (metaroce `6c5a3a4`). The link failure tests below show the effect.

### Link failure

A 1:1 transfer (h1→h8, 2000 × 1 MiB, unshaped) runs while one path fails 4 s after the start. `uplink-watch.sh` shows packets per second on the uplinks of leaf1 (data) and leaf4 (ACKs). Three failure types, 3 runs each:

| Failure | How | Result |
|---|---|---|
| Link down | `fail-link.sh down p1-leaf1 ethN` on the uplink carrying data | Completed 3/3 (1.24–1.48 Gbit/s). The kernel removes the nexthop at once and traffic moves to the other spines within 1 s |
| Silent drop, forward path | `fail-link.sh blackhole p1-spineN eth4` on the spine carrying data. The link and BGP stay up | Completed 3/3 (1.27–1.46 Gbit/s). Data moved to another spine within about 1 s; 16–54 packets were dropped |
| Silent drop, return path | `fail-link.sh blackhole p1-spineN eth1` on the spine carrying ACKs | Failed 3/3. The sender retransmits on other spines, but the ACKs keep taking the dropping spine. After 8.6 s without ACK progress the watchdog fails the QP |

Return-path drop, second run (columns are packets per second to spine1/2/3/4):

```text
22:53:08 p1-leaf1:2/2/3/38873 p1-leaf4:1/2/2/27011   <- data and ACKs on spine4
22:53:09 p1-leaf1:33/62/151/16183 p1-leaf4:3/3/3/9025 <- ACKs dropped on spine4 -> leaf1
22:53:10 p1-leaf1:32/3/1/3 p1-leaf4:1/2/2/24          <- retransmits on spine1, ACKs still to spine4
22:53:11 p1-leaf1:2/32/2/2 p1-leaf4:1/2/2/3           <- retransmits on spine2
22:53:13 p1-leaf1:3/4/31/4 p1-leaf4:1/3/2/3           <- retransmits on spine3
```

```text
E... Qp.cpp:1365] Watchdog expired for qp: 2. No progress (ACKs) for 8590ms
E... RdmaGenRequester.cpp:280] ... failed with ibv_wc_status code: 12 [transport retry counter exceeded]
```

The data side repaths as specified: after `--libsoftmetaroce_rtos_before_repath` (default 2) RTOs it moves the flow to another source port. The receiver, however, sends the ACKs for each flow ID from a fixed socket, so the ACK path never changes and the failure on the return path cannot be avoided. Spec §7.1.1 asks for the ACK source port to change when the data source port changes, exactly so that a repath also escapes a fault on the return path. In the third run, one flow's ACKs took a different spine and kept the transfer going for a few seconds before it also stalled, and the client crashed with SIGSEGV in `Qp::processWatchdogExpiryAsync`.

`rdma_gen` counts failed work completions as messages and still prints a throughput. `run-write.sh` therefore also counts `failed with ibv_wc_status` lines in the client log, prints them as `FAILED: N work completions`, and exits with status 1.

## Notes

- In libsoftmetaroce mode, `rdma_gen --tx_path_count` has no effect.
  The flow count per QP comes from `--libsoftmetaroce_txflows`, default 8. `run-write.sh` exposes it as `FLOWS=`.
- The server must be told how many clients to wait for (`--qp_cap` and `--num_clients_to_complete`). `run-write.sh` sets both.
  Otherwise the first client to finish terminates the server. The remaining clients then crashed with SIGSEGV in `Qp::processWatchdogExpiry` (metaroce `6c5a3a4`).
- `net.core.rmem_max` and `wmem_max` are not per network namespace. libsoftmetaroce asks for 16 MB socket buffers and logs a warning when the host limit is lower.
  For high rates, raise the limit on the container host: `sysctl -w net.core.rmem_max=67108864 net.core.wmem_max=67108864`.
- The switches are Linux kernel forwarding in FRR containers. They do no PFC, trimming or AR. MetaRoCE needs only ECN and ECMP from the fabric, so this is enough to watch the transport.
- The MetaRoCE default UDP destination port is 2766, which IANA lists as `compaq-scp`. tcpdump may label it that way.
  To decode the packets, use the Lua dissector in the metaroce repository at `wireshark/`.

## License

[MIT](LICENSE).

The image built by `docker/Dockerfile` contains third-party software fetched at build time: MetaRoCE, folly, fbthrift and others. Each of these keeps its own license, mostly Apache-2.0. FRR, used for the switch nodes, is GPL-2.0.
If you redistribute a built image, include their LICENSE and NOTICE files.

<details>
<summary>日本語</summary>

# clab-metaroce

マルチプレーンの leaf-spine 上で [MetaRoCE](https://github.com/facebookincubator/metaroce) の振る舞いを観察するための containerlab 環境です。

- スイッチには FRR コンテナを使っています。
- ホストでは、UDP 上で動くソフトウェア実装の MetaRoCE（`libsoftmetaroce`）を `rdma_gen` で動かします。

次のようなプロトコルの仕組みが、どう振る舞うかを確かめることを目的にしています。

- 送信元ポートによる ECMP 分散
- マルチプレーンでの動作
- SACK による再送
- ECN への反応

ラインレートの性能測定には向きません。

## トポロジ（既定）

```
 plane 1                                   plane 2
 p1-spine1..4   (AS 65001)                 p2-spine1..4   (AS 65002)
   | フルメッシュ、eBGP unnumbered (IPv6 LL)  |
 p1-leaf1..4    (AS 65101..65104)          p2-leaf1..4    (AS 65201..65204)
   |                                         |
   +---- eth1 ---- h1..h8 ---- eth2 ---------+
```

| 項目 | 値 |
|---|---|
| ノード | 24（スパイン 8、リーフ 8、ホスト 8） |
| リンク | 48 |
| プレーンあたり | スパイン 4 × リーフ 4。各リーフは 4-way ECMP |
| ホスト | リーフあたり 2 台。各ホストはプレーンごとに NIC を 1 つ持つ（`eth1` がプレーン 1、`eth2` がプレーン 2） |
| アドレス（IPv6 のみ） | プレーン *p*・リーフ *l* の *i* 番目のホスト = `fd00:p:l:i::10/64`、ゲートウェイは `::1`。h1 は `fd00:1:1:1::10` / `fd00:2:1:1::10` |
| プレーンの分離 | プレーン間はルーティングしない（`fd00:1::/32` はプレーン 1 だけ、`fd00:2::/32` はプレーン 2 だけ） |
| ECMP ハッシュ | `net.ipv6.fib_multipath_hash_policy=1`（L4 の 5-tuple）。MetaRoCE はエントロピーを UDP 送信元ポートに入れるので、フローごとに別のスパインを通りうる |
| MTU | 9000 |

規模は `./gen.py --planes 2 --spines 4 --leaves 4 --hosts-per-leaf 2` で変えられます。`metaroce.clab.yml` と `configs/` を作り直します。

## 使い方

```bash
# 1. ホストイメージ（初回は getdeps で folly/fbthrift を取得してビルドするので時間がかかる）
docker build -t metaroce-host:6c5a3a4 docker

# 2. 生成して起動
./gen.py
containerlab deploy -t metaroce.clab.yml

# 3. 輻輳を観察できるようにする: ファブリックの全ポートを帯域制限し、RED で ECN マーク
scripts/fabric-qos.sh on 300mbit        # off / show
scripts/ecmp-stats.sh snap              # 基準値を保存。あとで再実行すると上りポートごとの差分を表示

# 4. libsoftmetaroce で RDMA WRITE
scripts/run-write.sh h8 h1                       # 1 対 1、プレーン 1
MSGS=100 scripts/run-write.sh h8 h1,h3,h5        # 3 対 1 の incast
PLANES=1,2 MSGS=100 scripts/run-write.sh h8 h1,h3,h5   # 両プレーンを使う incast（マルチポート QP）
scripts/fabric-qos.sh show                       # ポートごとの ECN マーク数と廃棄数

# 5. リンク断（転送中に実行する。「リンク断」の節を参照）
scripts/uplink-watch.sh p1-leaf1 p1-leaf4        # 上りポートごとの毎秒のパケット数
scripts/fail-link.sh down p1-leaf1 eth2          # リンクダウン。戻すときは up
scripts/fail-link.sh blackhole p1-spine2 eth4    # UDP 2766 を黙って捨てる。戻すときは clear

# 片付け
containerlab destroy -t metaroce.clab.yml --cleanup
```

### GitHub の URL から起動する

containerlab はこのリポジトリを clone して、そのまま起動できます。ホストイメージはどのレジストリにも公開していないので、先に手元でビルドしてください。タグはトポロジと同じ `metaroce-host:6c5a3a4` にする必要があります。

```bash
docker build -t metaroce-host:6c5a3a4 https://github.com/nanakanok/clab-metaroce.git#main:docker
containerlab deploy -t https://github.com/nanakanok/clab-metaroce
```

リポジトリはカレントディレクトリに clone されます。補助スクリプトは、その clone の中で実行してください（`cd clab-metaroce`）。

## ファイル

| パス | 内容 |
|---|---|
| `docker/Dockerfile` | `rdma_gen` と `libsoftmetaroce` を入れたホストイメージ。getdeps でビルドし、metaroce `6c5a3a4` に固定。ビルド段階は 6 コアで約 1 時間。実行用イメージは約 240 MB |
| `gen.py` | トポロジと FRR 設定の生成スクリプト |
| `metaroce.clab.yml`, `configs/` | 生成物。既定の規模の分を commit している |
| `scripts/fabric-qos.sh` | リーフとスパインの全ポートに、HTB による帯域制限と RED による ECN マークをかける |
| `scripts/ecmp-stats.sh` | 各リーフの上りポートの送信差分を表示し、スパインへの分散具合を見る |
| `scripts/run-write.sh` | `rdma_gen` のサーバと 1 台以上のクライアントを起動し、クライアントごとのスループットと、エラーになった完了の数を表示する。結果の JSON は `results/` に保存 |
| `scripts/fail-link.sh` | ファブリックのリンクを落とす。または、リンクと BGP は up のまま、ポートで MetaRoCE のパケット（UDP 2766）を黙って捨てる |
| `scripts/uplink-watch.sh` | 指定したリーフの、スパイン向けポートごとの毎秒のパケット数を表示する |

## 測定例

条件: 既定のトポロジ、1 MiB の WRITE、QP あたり 8 フロー、`NIC_GBPS=10`（`run-write.sh` の既定値）。値は 3 回の中央値です。ファブリックは、300 Mbit/s に制限して RED の ECN を有効にした場合（`min=60KB`、`max=180KB`）と、制限なしの場合で測りました。

| シナリオ（全クライアントの合計） | 300 Mbit/s | 制限なし |
|---|---|---|
| 1 対 1（h1→h8） | 0.29 Gbit/s | 1.29 Gbit/s |
| 3 対 1 の incast（h1,h3,h5→h8）、プレーン 1 | 0.30 Gbit/s | 1.64 Gbit/s |
| 3 対 1 の incast、プレーン 1+2 | 0.59 Gbit/s | 1.77 Gbit/s |

- 300 Mbit/s では、ボトルネックはリンクです。incast の 3 台は h8 への下りをほぼ均等に分け合い、その下りポートでは約 2.5 万パケットに ECN マークが付いた一方、廃棄はわずかでした。1 つのマルチポート QP が両プレーンに振り分けて送るので、合計は 2 倍になります。
- 制限なしでは、ボトルネックはソフト実装です。1 対 1 は約 1.3 Gbit/s で、両プレーンを使っても合計はほとんど増えません。

### 受信側主導のレート制御（RCN）

受信側は QP ごとに `ceil(NIC_GBPS ÷ 受信中の QP 数)` のレートを整数の Gbit/s で知らせます。そのため目標レートは 1 Gbit/s を下回らず、300 Mbit/s のファブリックでは上限として働きません。そこでの公平な分け合いは、ECN による AIMD の働きです。ファブリックを 3 Gbit/s に制限した場合の結果です（3 対 1 の incast、3 回の中央値）。

| `NIC_GBPS` | QP あたりの目標レート | 合計スループット | h8 への下りの ECN マーク |
|---|---|---|---|
| 3 | 1 Gbit/s（公平な取り分と同じ） | 1.45 Gbit/s | 0 / 0 / 0 |
| 10 | 4 Gbit/s（上限として働かない） | 1.60 Gbit/s | 207 / 257 / 413 |

RCN が効くと、キューが RED の閾値に達する前に窓が抑えられるので、ECN マークは一度も付きませんでした。`NIC_GBPS` を小さくすると知らないうちに QP ごとの上限がかかるので、`run-write.sh` はライブラリの既定値 10 を使います。

### マルチパス

QP あたり 8 本のフローがあっても、4 台のスパインすべてにデータが流れるわけではありません。仕様では、フローはレートが上がって窓が大きくなるにつれて増やし（§7.4.2）、混んだフローの窓は減らして空いているフローに回します（§6.1.2）。RTT の短いこのラボでは窓が数パケットで足りるので、空いているときは 1 フローで十分です。トラフィックが広がったのは、経路が混んだときだけでした。

- 1 対 1（制限なし）と 3 対 1 の incast: 各送信者は、ほぼ 1 台のスパインしか使いませんでした。ボトルネックがソフト実装や h8 への下りにあるので、経路を増やしても速くなりません。
- h1→h7 と h2→h8 を同時に流した場合（どちらも leaf1 から送信）: 2 台の送信が同じ上りに乗ると、leaf1 からのトラフィックは 3 台のスパインに分かれ、混んだ上りで ECN マークが付きました。3 回のうち 2 回は、2 台がたまたま別のスパインを通り、それぞれ 1 台のままでした。

これは仕様どおりの動作です。§7.4.2 は、`average_window × (active_flow_count + 1) < QWND` のときにフローを 1 本増やすことを推奨しています。§6.1.2 は、混んだフローの `FWND` だけを減らし、RTT がふだんより大きいフローは窓の増分を見送って別のフローに回せることを必須としています。libsoftmetaroce は、まず fast start で各フローに少しずつ送り、その後は RTT が QP の平滑化 RTT 以下のフローだけ窓を増やし、ECN マークを受けたフローの窓を減らします。

h1 でパケットを取ると、データの送信元ポートは 6 種類あり、大半は 2 種類に集中していました。ポートが 2 ずつずれるのは、フローごとにデータ用と ACK 用のソケットを対で作るためです。ACK は一定の差がある別のポートを使っていましたが、この差はデータのポートから計算した値ではありません。受信側はフロー番号ごとに自分の固定のソケットから ACK を返しています。そのため、送信側が RTO を繰り返して経路を変えても、ACK の経路は変わりません。これは仕様 §7.1.1 の推奨と異なります（metaroce `6c5a3a4`）。その影響は、次のリンク断の試験で確かめました。

### リンク断

1 対 1 の転送（h1→h8、1 MiB を 2000 回、帯域制限なし）を流し、開始 4 秒後に経路を 1 本壊します。`uplink-watch.sh` で、leaf1（データ）と leaf4（ACK）の上りポートの毎秒のパケット数を見ます。障害は 3 種類で、それぞれ 3 回試しました。

| 障害 | 方法 | 結果 |
|---|---|---|
| リンクダウン | データが通る上りポートで `fail-link.sh down p1-leaf1 ethN` | 3 回とも完了（1.24〜1.48 Gbit/s）。カーネルがすぐにネクストホップを消し、1 秒以内に残りのスパインへ移った |
| 往路のサイレント破棄 | データが通るスパインで `fail-link.sh blackhole p1-spineN eth4`。リンクと BGP は up のまま | 3 回とも完了（1.27〜1.46 Gbit/s）。約 1 秒で別のスパインに移り、捨てられたのは 16〜54 パケット |
| 復路のサイレント破棄 | ACK が通るスパインで `fail-link.sh blackhole p1-spineN eth1` | 3 回とも失敗。送信側は別のスパインで再送するが、ACK は破棄するスパインを通り続ける。ACK が 8.6 秒進まず、watchdog が QP をエラーにした |

復路のサイレント破棄の 2 回目（列はスパイン 1/2/3/4 への毎秒のパケット数）:

```text
22:53:08 p1-leaf1:2/2/3/38873 p1-leaf4:1/2/2/27011   <- データも ACK も spine4
22:53:09 p1-leaf1:33/62/151/16183 p1-leaf4:3/3/3/9025 <- spine4 -> leaf1 で ACK を破棄
22:53:10 p1-leaf1:32/3/1/3 p1-leaf4:1/2/2/24          <- spine1 で再送。ACK は spine4 のまま
22:53:11 p1-leaf1:2/32/2/2 p1-leaf4:1/2/2/3           <- spine2 で再送
22:53:13 p1-leaf1:3/4/31/4 p1-leaf4:1/3/2/3           <- spine3 で再送
```

```text
E... Qp.cpp:1365] Watchdog expired for qp: 2. No progress (ACKs) for 8590ms
E... RdmaGenRequester.cpp:280] ... failed with ibv_wc_status code: 12 [transport retry counter exceeded]
```

データ側は仕様どおりに経路を変えています。RTO が `--libsoftmetaroce_rtos_before_repath`（既定 2）回続くと、そのフローを別の送信元ポートに移します。しかし受信側は、フロー番号ごとに固定のソケットから ACK を返すので、ACK の経路は変わらず、復路の障害を避けられません。仕様 §7.1.1 が「データの送信元ポートが変わったら ACK の送信元ポートも変える」ことを求めているのは、まさに経路の切り替えで復路の障害も避けるためです。3 回目は、1 つのフローの ACK が別のスパインを通っていたので数秒は転送が続きましたが、やがて止まり、クライアントは `Qp::processWatchdogExpiryAsync` で SIGSEGV を起こしました。

`rdma_gen` はエラーになった完了も 1 メッセージとして数え、スループットも表示します。そこで `run-write.sh` は、クライアントのログにある `failed with ibv_wc_status` の行数を数えて `FAILED: N work completions` と表示し、終了コード 1 で終わるようにしました。

## 注意点

- libsoftmetaroce モードでは、`rdma_gen --tx_path_count` は効きません。
  QP あたりのフロー数は `--libsoftmetaroce_txflows`（既定 8）で決まります。`run-write.sh` では `FLOWS=` で指定します。
- サーバには、待つクライアントの数を指定する必要があります（`--qp_cap` と `--num_clients_to_complete`）。`run-write.sh` は両方を設定します。
  指定しないと、最初に終わったクライアントがサーバを止めてしまいます。その後、残りのクライアントが `Qp::processWatchdogExpiry` で SIGSEGV を起こして落ちました（metaroce `6c5a3a4`）。
- `net.core.rmem_max` と `wmem_max` は network namespace ごとの設定ではありません。libsoftmetaroce は 16 MB のソケットバッファを要求し、ホストの上限が低いと警告を出します。
  高いレートで使うときは、コンテナを動かすホストで上限を上げてください: `sysctl -w net.core.rmem_max=67108864 net.core.wmem_max=67108864`
- スイッチは FRR コンテナ内の Linux カーネル転送で、PFC・trimming・AR はありません。MetaRoCE がファブリックに求めるのは ECN と ECMP だけなので、トランスポートの観察にはこれで足ります。
- MetaRoCE の既定の UDP 宛先ポートは 2766 で、IANA では `compaq-scp` として登録されています。tcpdump ではその名前で表示されることがあります。
  パケットを解析するには、metaroce リポジトリの `wireshark/` にある Lua dissector を使ってください。

## ライセンス

[MIT](LICENSE)。

`docker/Dockerfile` でビルドしたイメージには、ビルド時に取得したサードパーティのソフトウェアが含まれます（MetaRoCE、folly、fbthrift など）。それぞれのライセンス（主に Apache-2.0）に従います。スイッチに使う FRR は GPL-2.0 です。
ビルド済みイメージを再配布する場合は、それらの LICENSE と NOTICE を同梱してください。

</details>
