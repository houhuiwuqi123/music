# p2p.webtrc.eu.cc 域名配置

`p2p.webtrc.eu.cc` 只用于**节点之间的直连**：libp2p 的 TCP / QUIC 4001 端口。网页、API、iOS 网关和浏览器的 libp2p 都走 `music.webtrc.eu.cc`（经 Cloudflare 代理），和这个域名无关。

| 域名 | Cloudflare 代理 | 端口 | 用途 | 由谁处理 |
|---|---|---|---|---|
| `music.webtrc.eu.cc` | 开启（橙云） | 443 | 网页、`/api/`、iOS 网关 `/ws` | nginx → 127.0.0.1:8080 |
| `music.webtrc.eu.cc` | 开启（橙云） | 8443 | 浏览器的 libp2p wss | nginx → 127.0.0.1:4002 |
| `p2p.webtrc.eu.cc` | **关闭（灰云，仅 DNS）** | 4001/tcp、4001/udp | 节点之间的 Kademlia / GossipSub / 信令转发 | Go 进程直接监听 |

## 先了解：域名并不能隐藏 IP

Cloudflare 的普通代理只转发 HTTP/HTTPS/WebSocket，不转发原始 TCP/UDP，所以 `p2p.webtrc.eu.cc` 必须设为"仅 DNS"。任何人解析这个域名都能拿到源站 IP；节点公布的地址也会通过 DHT 传给其他节点。

用域名代替 IP 的好处：

- 仓库和 systemd 文件里不出现 IP；
- 服务器换 IP 时只需改 DNS，其他节点的 `NODE_BOOTSTRAP` 不用动；
- `music.webtrc.eu.cc` 仍然在 Cloudflare 后面，普通访客（网页、iOS）看不到源站 IP。

如果不希望 `music.webtrc.eu.cc` 的源站 IP 被关联出来，可以选择：

1. **给 p2p 单独用一台机器或一个 IP**（推荐）。节点之间互联用另一台小服务器或另一个公网 IP，`music` 主站的源站 IP 不出现在任何 DNS 记录里。这台节点通过 `NODE_BOOTSTRAP` 和主站节点互联，主站节点不需要公布 4001。
2. **单节点时不公布 4001**。只有一台节点时，节点间互联用不到，可以把 `NODE_ANNOUNCE` 里两条 `p2p.webtrc.eu.cc` 删掉，也不创建这个 DNS 记录。浏览器和 iOS 不受影响，它们只用 `music.webtrc.eu.cc`。
3. **使用 Cloudflare Spectrum**（付费）代理 TCP/UDP，可以保持橙云，但要另外配置。

主站源站本身也应只允许 Cloudflare 的 IP 段访问 443 和 8443（宝塔防火墙或云厂商安全组）。这样即使 IP 泄露，也无法绕过 Cloudflare 直接访问网站。

## 1. 添加 DNS 记录（Cloudflare 控制台）

DNS → 记录 → 添加记录：

| 类型 | 名称 | 内容 | 代理状态 | TTL |
|---|---|---|---|---|
| A | `p2p` | 节点服务器的公网 IPv4 | **仅 DNS（灰云）** | 自动 |
| AAAA（可选） | `p2p` | 公网 IPv6 | **仅 DNS（灰云）** | 自动 |

如果配置了 AAAA 记录，`NODE_ANNOUNCE` 里的 `/dns4/` 可以改成 `/dns/`（同时解析 v4 和 v6），并在 `-listen` 中加入 `/ip6/::/tcp/4001,/ip6/::/udp/4001/quic-v1`。

确认解析结果（应返回源站 IP，而不是 Cloudflare 的 104.x 或 172.x 段）：

```bash
dig +short p2p.webtrc.eu.cc
```

## 2. 放行端口

需要在**云厂商安全组**和**宝塔面板 → 安全**两处都放行：

| 端口 | 协议 | 来源 | 说明 |
|---|---|---|---|
| 4001 | TCP | 0.0.0.0/0 | 节点互联（libp2p TCP） |
| 4001 | UDP | 0.0.0.0/0 | 节点互联（QUIC） |
| 8443 | TCP | Cloudflare IP 段 | 浏览器的 libp2p wss（经 Cloudflare） |
| 443 | TCP | Cloudflare IP 段 | 网站 |

8080 和 4002 只监听在 127.0.0.1，**不要**对外开放。

## 3. 节点配置

`backend/webtrc.service` 中已经配好：

```ini
Environment=NODE_ANNOUNCE=/dns4/music.webtrc.eu.cc/tcp/8443/wss,/dns4/p2p.webtrc.eu.cc/tcp/4001,/dns4/p2p.webtrc.eu.cc/udp/4001/quic-v1
```

改完后执行 `./deploy.sh install && ./deploy.sh restart`。

## 4. 验证

在服务器上：

```bash
./deploy.sh check        # 本机 API 与 /api/bootstrap
./deploy.sh logs         # 启动日志里有 "peer 12D3KooW… listening on [...]"
```

在另一台机器上检查 4001 是否可达：

```bash
nc -vz p2p.webtrc.eu.cc 4001          # TCP
curl -s https://music.webtrc.eu.cc/api/bootstrap   # nodes[0].addrs 应包含 /dns4/p2p.webtrc.eu.cc/…
```

## 5. 增加第二台节点

假设第二台节点使用域名 `p2p2.webtrc.eu.cc`（同样是灰云 A 记录）：

1. 第二台的 `NODE_ANNOUNCE` 改为 `/dns4/p2p2.webtrc.eu.cc/tcp/4001,/dns4/p2p2.webtrc.eu.cc/udp/4001/quic-v1`。如果它也要服务浏览器，再加上它自己的 wss 域名。
2. 第二台的 `NODE_BOOTSTRAP` 填第一台的地址：
   ```ini
   Environment=NODE_BOOTSTRAP=/dns4/p2p.webtrc.eu.cc/tcp/4001/p2p/<第一台的 peerId>
   ```
   peerId 可以从第一台的 `./deploy.sh logs` 或 `/api/bootstrap` 里找到。它由 `state/node.key` 决定，**这个文件要备份**，丢失后 peerId 会变，其他节点的 bootstrap 配置都要跟着改。
3. 启动后，两台节点的 `/api/bootstrap` 应该互相列出对方。客户端下次获取节点列表时就会知道新节点。
