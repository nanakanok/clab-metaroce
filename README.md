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
| ECMP hashing | `net.ipv6.fib_multipath_hash_policy=1` (L4 5-tuple). MetaRoCE carries its entropy in the UDP source port, so each flow takes a different spine |
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
| `scripts/run-write.sh` | Starts an `rdma_gen` server and one or more clients, then prints each client's throughput. Result JSON goes to `results/` |

## Example results

These were measured with the default topology, every fabric port shaped to 300 Mbit/s and RED ECN enabled (`min=60KB`, `max=180KB`). Each client sends 1 MiB WRITE messages, with 8 MetaRoCE flows per QP.

| Scenario | Per-client throughput | What it shows |
|---|---|---|
| 3:1 incast, plane 1 | about 0.10 Gbit/s each (sum ≈ 0.3) | Fair sharing of the bottleneck link to h8. The leaf downlink marked about 28k packets with ECN and dropped fewer than 10 |
| 3:1 incast, planes 1+2 | about 0.20 Gbit/s each (sum ≈ 0.6) | One multi-port QP stripes traffic across both planes, so aggregate throughput doubles. Both planes mark ECN |
| 1:1, unshaped | about 1.1 Gbit/s | Ceiling of the software transport with a single sender thread on this kind of host |

Flows spread over the spines only when the window needs them. With an idle fabric, two flows were enough to carry the traffic and only two spines carried data. Under congestion, all four spines were used.

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
| ECMP ハッシュ | `net.ipv6.fib_multipath_hash_policy=1`（L4 の 5-tuple）。MetaRoCE はエントロピーを UDP 送信元ポートに入れるので、フローごとに別のスパインを通る |
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
| `scripts/run-write.sh` | `rdma_gen` のサーバと 1 台以上のクライアントを起動し、クライアントごとのスループットを表示する。結果の JSON は `results/` に保存 |

## 測定例

既定のトポロジで、ファブリックの全ポートを 300 Mbit/s に制限し、RED の ECN を有効にして測りました（`min=60KB`、`max=180KB`）。各クライアントは 1 MiB の WRITE を送り、QP あたりの MetaRoCE フローは 8 本です。

| シナリオ | クライアントあたりのスループット | わかること |
|---|---|---|
| 3 対 1 の incast、プレーン 1 | 各約 0.10 Gbit/s（合計 ≈ 0.3） | h8 へのボトルネックを公平に分け合う。リーフの下りポートで約 2.8 万パケットに ECN マークが付き、廃棄は 10 個未満 |
| 3 対 1 の incast、プレーン 1+2 | 各約 0.20 Gbit/s（合計 ≈ 0.6） | 1 つのマルチポート QP が両プレーンに振り分けて送るので、合計スループットが 2 倍になる。両プレーンで ECN マークが付く |
| 1 対 1、帯域制限なし | 約 1.1 Gbit/s | この種のホストで、送信スレッド 1 本のソフト実装が出せる上限 |

フローがスパインに分散するのは、窓がそれを必要とするときだけです。ファブリックが空いているときは 2 本のフローで足り、データを運んだスパインも 2 台だけでした。輻輳時は 4 台すべてを使いました。

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
