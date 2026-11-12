# AURU 轻量级 DHT 节点（backend）

Candy广场 已从中心化信令 hub 改为去中心化 DHT 网络。本目录是**轻量级节点**：任何人都可以多跑几台，节点之间用 libp2p Kademlia 组成 DHT，iOS 和网页端都通过它入网。

| 层 | 实现 |
|---|---|
| 表现层 | iOS SwiftUI（`AURU MUSIC/`）、Vue 3 + Vite（`web/`） |
| P2P 传输 | WebRTC DataChannel `auru-file/1`：64 KiB 分片，按 1 MiB 块边收边校验 |
| 发现 / 路由 | Kademlia DHT `/auru/kad/1.0.0`（go-libp2p-kad-dht 服务端 / js-libp2p 客户端），CID 内容寻址；GossipSub 广场频道 `auru/plaza/1` |
| 入网 | 引导节点 `GET /api/bootstrap` 提供初始节点列表；STUN（可选 TURN）辅助打洞 |

## 为什么 iOS 走节点网关

浏览器和手机都在 NAT 后面，别人拨不进来。libp2p 规定这类节点只能当 **DHT client**，路由表由可被拨入的服务端节点承载。两类终端接入方式如下：

- **网页端**跑完整的 js-libp2p：通过 WebSocket 连上节点，自己发起 `PROVIDE` / `GET_PROVIDERS`，在节点上预约 circuit-relay 槽位，这样它的 provider 记录里会带一个指向所在节点的地址。
- **iOS** 目前没有可用于生产的 Swift libp2p，所以通过节点的 `/ws` 网关接入，由节点代为执行 Kademlia 操作。iOS 仍然持有**自己的 Ed25519 libp2p 身份**（peer ID 与 js/go 算法一致），自己签名广场公告，文件也是点对点直传，节点只转发 SDP。

Kademlia 只接受“自己宣告自己”的 provider 记录（`handleAddProvider` 会忽略替别人发的记录），所以节点替 iOS **以自己的名义** `PROVIDE` 该 CID，再通过 `/auru/resolve/1.0.0` 告诉查询者当前挂在本节点、持有该 CID 的终端。查询方拿到的是“终端 peer ID + 它所在的节点”，SDP 就经由那个节点送达。

## 业务流程

1. **入网**：客户端请求 `GET /api/bootstrap`，得到节点列表（本节点加上路由表里的其他 DHT 服务端）。网页端用 wss 拨号，iOS 连接节点的 `gateway` 地址。列表会缓存在本地，节点不可达时轮换下一个。
2. **发布**：文件先算 SHA-256，CID = CIDv1(raw, sha2-256)，即 `bafkrei…`。网页端自己 `PROVIDE`；iOS 由节点代为 `PROVIDE`。同时在 GossipSub 上广播签名公告（正在听什么、分享了哪些文件、经由哪个节点可达）。
3. **发现**：`GET_PROVIDERS(CID)`。provider 是节点时调用 resolve 展开成终端；带 `/p2p-circuit` 地址的 provider 是浏览器，其 relay 节点就是信令中转。
4. **连接**：下载方生成完整的 SDP offer（非 trickle，候选收集完再发），经节点送到提供方；提供方回 answer 后建立 DataChannel 直连。
5. **传输**：`get(offset)` → `meta`（包含每 1 MiB 块的哈希）→ 二进制分片 → `end` → `done`。接收方每满一块就校验，最后再用 CID 里的整文件 SHA-256 校验。断线后从最后一个已校验块续传。

## 部署（服务器）

仓库根目录的 `deploy.sh` 负责编译、安装和服务管理（需要 root，默认安装目录 `/www/wwwroot/webtrc`）：

```bash
sudo ./deploy.sh install     # 编译节点和网页，安装二进制、web/dist、systemd 服务（运行中则自动重启）
sudo ./deploy.sh start|stop|restart
./deploy.sh status           # 服务状态和监听端口
./deploy.sh logs             # 跟踪日志
./deploy.sh check            # 自检 /api/bootstrap、/api/ice、GeoIP 文件
```

域名说明：`music.webtrc.eu.cc` 走 Cloudflare 代理，承载网页、API、iOS 网关和浏览器的 libp2p wss（nginx 模板 `deploy/nginx.conf`）；默认是单节点，只有这一个域名，不对外开放其他端口。以后增加节点时才需要 `p2p.webtrc.eu.cc`（仅 DNS 记录，tcp/udp 4001），见 [deploy/p2p-domain.md](deploy/p2p-domain.md)。

## 构建与运行（本地）

```powershell
Set-Location 'C:\phpwork\music\backend'
go test ./... -count=1
go build -o server.exe .
.\server.exe -http 127.0.0.1:8003 -key .\state\node.key `
  -listen '/ip4/127.0.0.1/tcp/4002/ws' `
  -announce '/dns4/music.webtrc.eu.cc/tcp/443/wss' `
  -gateway-url 'wss://music.webtrc.eu.cc/ws' -web-dir ..\web\dist -geoip-db .\GeoLite2-City2.mmdb
```

| 参数 / 环境变量 | 说明 |
|---|---|
| `-key` | 节点身份。首次启动时生成，之后保持不变，peer ID 由它决定。请备份并限制权限。 |
| `-listen` | libp2p 监听地址。`…/4002/ws` 只绑定本机，由 nginx 443 端口上路径 `/` 的 WebSocket 请求转发进来。多节点时再加 `/ip4/0.0.0.0/tcp/4001,/ip4/0.0.0.0/udp/4001/quic-v1`（不传该参数时的默认值包含它们）。 |
| `-announce` / `NODE_ANNOUNCE` | 对外公布的地址。浏览器只能使用 wss，节点之间互联使用源站公网 IP 的 tcp/quic（Cloudflare 不代理原始 TCP/UDP）。 |
| `-bootstrap` / `NODE_BOOTSTRAP` | 其他节点的 `/…/p2p/<peerId>` 地址，多个用逗号分隔。只有一台节点时留空。 |
| `-gateway-url` / `NODE_GATEWAY_URL` | 本节点 iOS 网关的公开 wss 地址，会出现在 `/api/bootstrap` 结果里。 |
| `-web-dir` | 可选：直接托管 `web/dist`。 |
| `STUN_URLS`、`TURN_URLS`、`TURN_REST_SECRET` | ICE 配置。TURN 采用 coturn REST 凭据，有效期 1 小时，见 `deploy/compose.yaml`。 |
| `-geoip-db`、`-trusted-proxies` | 本地 MMDB 地区查询（不调用外部服务）。回环地址默认视为可信代理。 |

需要放行的端口：单节点只需 443/tcp（建议只放行 Cloudflare IP 段）；多节点时再放行 4001/tcp、4001/udp。nginx 模板见 `deploy/nginx.conf`，systemd 模板见 `webtrc.service`。

### 增加一台节点

先按 [deploy/p2p-domain.md](deploy/p2p-domain.md) 让第一台监听并公布 4001，再在另一台服务器上用同样的方式启动，并设置 `NODE_BOOTSTRAP=/dns4/p2p.webtrc.eu.cc/tcp/4001/p2p/<第一台peerId>`（peer ID 可从启动日志或 `/api/bootstrap` 获取，详见 [deploy/p2p-domain.md](deploy/p2p-domain.md)）。两台节点会互相进入对方的路由表，GossipSub 会跨节点同步广场，任意节点上的 `GET_PROVIDERS` 都能查到另一台节点上的终端。客户端从 `/api/bootstrap` 自动获知新节点。

## HTTP 接口

| 路径 | 用途 |
|---|---|
| `GET /api/bootstrap` | `{"nodes":[{"peerId","addrs":[…/p2p/…],"gateway"}],"dht":"/auru/kad/1.0.0","topic":"auru/plaza/1"}`，即初始节点列表 |
| `GET /api/ice` | 给浏览器使用的 `{"iceServers":[…]}` |
| `GET /api/whoami` | `{"region":"广东省"}`，浏览器写进自己的公告 |
| `GET /api/plaza` | 当前广场快照（调试用） |
| `GET /ws` | iOS 网关 WebSocket（见下文） |

## libp2p 协议

| 协议 | 帧格式 | 内容 |
|---|---|---|
| `/auru/kad/1.0.0` | 标准 Kademlia | PROVIDE / GET_PROVIDERS / FIND_NODE |
| `auru/plaza/1` | GossipSub | 签名公告 `Envelope`（见下文） |
| `/auru/plaza/1.0.0` | uvarint 长度前缀 JSON | 节点返回 `[{"envelope","offline"}]`，作为新加入者的初始快照 |
| `/auru/resolve/1.0.0` | 同上 | `{"cid"}` → `{"peers":[peerId…]}`：本节点上持有该 CID 的在线终端 |
| `/auru/signal/1.0.0` | 同上 | 一条 `Signal`，回复 `{"ok":true}` 或 `{"error":"unreachable"}` |

`Signal = {from,to,node,nodeAddrs,fromNode,fromNodeAddrs,session,kind:"offer|answer|bye",sdp,hop}`。如果 `to` 挂在本节点（网关会话或直连的浏览器），节点直接投递；否则按 `node` 转发一跳。终端发出的信令，`from` 一律由节点根据已认证的连接改写，只有节点之间转发（`hop=1`）时才沿用原值。

### 广场公告

```json
{"body":"<JSON 原文>","sig":"base64 Ed25519(\"auru-plaza:\"+body)","pub":"base64 libp2p 公钥 protobuf"}
```

`body = {"v":1,"peerId","name","avatar?","region?","client":"ios|web","via":["/…/p2p/<node>"],"listening?":{"title","artist","isPlaying"},"files":[{"cid","name","size","sha256","kind":"listening|upload","mime?"}],"seq":<unix ms>,"bye?":true}`

签名覆盖 body 的原始文本，所以三种语言都不需要规范化 JSON。节点校验以下几点：签名正确；`peerId` 与公钥对应；`seq` 单调递增（防重放）且时间误差在 −5 分钟到 +1 分钟之内；每个 `cid` 确实是对应 `sha256` 的 CID；字段长度不超限。客户端每 30 秒重发一次公告；超过 90 秒没有收到新公告视为离线，再过 60 秒从广场移除。签名的 `bye` 会立即移除。iOS 网关断开时，节点会把对应条目立即标为离线。

## iOS 网关 WebSocket `/ws`

```text
S→C {"type":"challenge","nonce","node":{peerId,addrs,gateway}}
C→S {"type":"hello","publicKey":"base64 原始 Ed25519 公钥","signature":"base64 sign(\"auru-node-auth:\"+nonce+\":\"+nodePeerId)"}
S→C {"type":"welcome","peerId","region","node","routing":[DHT 路由表],"iceServers","entries":[广场]}
C→S {"type":"announce","id","envelope"}       → {"type":"announced"} | {"type":"error"}
C→S {"type":"find","id","cid"}                → {"type":"providers","id","providers":[{peerId,node,nodeAddrs}]}
C→S {"type":"signal","signal":{…}}            ← {"type":"signal","signal":{…}} | {"type":"signal-error"}
C→S {"type":"ice"} / {"type":"ping"}
S→C {"type":"plaza-update","entry"} / {"type":"plaza-remove","peerId"} / {"type":"plaza","entries"}
```

同一个 peer ID 再次登录会顶替旧会话。每个会话限速约 20 条/秒（突发 60 条）；客户端处理不过来时会被断开，重连后从完整快照恢复。

## 测试

- `go test ./...`：公告签名与防篡改、CID/peer ID 固定向量；两节点场景下 iOS 终端公告 → 跨节点 gossip → 跨节点 GET_PROVIDERS → 跨节点 offer/answer → 断线后的离线标记与 unreachable；浏览器式 DHT 客户端通过 circuit 地址 PROVIDE 后可被查到；`/api/bootstrap`。
- `web/`：`npm test`。其中 transfer 测试覆盖分片、块校验、整文件校验、断点续传和坏块拒绝；interop 测试会编译并启动真实的节点二进制，在 Node 里运行真实的 js-libp2p 网页端，再模拟一个 iOS 终端，把发布、发现、信令完整走一遍。
- iOS：`node scripts/verify-candy-connection.cjs`（Windows 下可运行的源码一致性检查；加 `--live` 会检查线上网关握手）；在 macOS 上运行 `node scripts/verify-candy-disk.cjs`（编译生产代码，验证编解码向量、签名互通和磁盘断点）和 `node scripts/verify-candy-ios.cjs`。

以上测试都不能代替真机：WebRTC 打洞、Wi-Fi 与蜂窝网络切换、对称 NAT 下的 TURN 回退，都需要两台手机加一个浏览器实测。

## TURN（可选）

`deploy/compose.yaml` 和 `deploy/coturn.conf` 用于单独部署 coturn（Linux，host 网络）。coturn 和节点要配置同一个**不提交到仓库**的 `TURN_REST_SECRET`，节点另外设置 `TURN_URLS`。凭据用户名为 `<过期时间>:<peerId|web>`，密码为 base64(HMAC-SHA1(secret, 用户名))，有效期 1 小时。需要放行 3478/udp+tcp、5349/tcp，以及 49160–49259/udp。

## 本地 IP 地区

`-geoip-db` 或 `GEOIP_DB_PATH` 指向 GeoLite2-City 等 MMDB 文件。国内 IP 显示省份（如 `广东省`、`香港`），国外 IP 显示 `国家-城市`，查不到时显示 `地区未知`。不会把 IP 发给外部服务，广场里只出现大致地区。
