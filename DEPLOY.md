# nginx 配置：除了指向 web/dist 还需要的内容

只把 nginx 的 `root` 指到 `web/dist`，网页能打开，但广场、听听看用不了：网页要访问节点的 HTTP API 和 libp2p WebSocket，iOS 要连网关，这些请求都要由 nginx 转给本机的节点进程（`webtrc` 服务）。

完整模板见 `backend/deploy/nginx.conf`，下面逐项说明。

## 端口一览

| 对外路径（443） | 转发到 | 用途 |
|---|---|---|
| `/api/` | `127.0.0.1:8003` | 节点 HTTP API：`/api/bootstrap`、`/api/ice`、地区、`/api/announce` |
| `/ws`（WebSocket） | `127.0.0.1:8003` | iOS 网关 |
| `/`，带 `Upgrade: websocket` | `127.0.0.1:4002` | 浏览器的 libp2p wss（js-libp2p 拨 `wss://<域名>/`） |
| `/`，普通请求 | `web/dist` | Vue 网页 |

8003 和 4002 只监听在 127.0.0.1，**不要**在防火墙或安全组里对外开放。

## 1. http 上下文（全局，只写一次）

放进主配置的 `http {}` 里（宝塔：`/www/server/nginx/conf/nginx.conf`）。这三行不能写在 `server {}` 里，也不能重复定义：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
log_format music_safe '$remote_addr $request_method $uri $status $body_bytes_sent';
limit_req_zone $binary_remote_addr zone=music_ws:10m rate=10r/s;
```

- `map`：WebSocket 转发要用的 `Connection` 头。
- `log_format music_safe`：只记录路径（`$uri`），不记录查询参数。
- `limit_req_zone`：给 API 和 WebSocket 限速。

## 2. server 块

把 `music.webtrc.eu.cc` 换成你的域名，证书路径换成实际路径。dist 路径在 `location = /` 和 `location /` **两处**都要改成你的目录。

```nginx
server {
    listen 443 ssl;
    server_name music.webtrc.eu.cc;
    ssl_certificate     /www/server/panel/vhost/cert/music.webtrc.eu.cc/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/music.webtrc.eu.cc/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    access_log /www/wwwlogs/music.webtrc.eu.cc.log music_safe;
    error_log  /www/wwwlogs/music.webtrc.eu.cc.error.log;

    # iOS 网关 WebSocket
    location = /ws {
        limit_req zone=music_ws burst=50 nodelay;
        proxy_pass http://127.0.0.1:8003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_read_timeout 120s;
        proxy_send_timeout 30s;
        proxy_buffering off;
    }

    # 节点 HTTP API
    location /api/ {
        limit_req zone=music_ws burst=50 nodelay;
        proxy_pass http://127.0.0.1:8003;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
    }

    # 根路径：带 Upgrade: websocket 的请求交给节点的 libp2p（4002），普通请求返回网页。
    # go-libp2p 的 websocket 监听不检查路径，所以和网页共用 "/"，不需要单独端口。
    location = / {
        error_page 418 = @libp2p;
        if ($http_upgrade ~* "^websocket$") { return 418; }
        root /www/wwwroot/webtrc/web/dist;
        try_files /index.html =404;
    }
    location @libp2p {
        limit_req zone=music_ws burst=50 nodelay;
        proxy_pass http://127.0.0.1:4002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }

    # Vue 网页；找不到的路径回退到 index.html，刷新子路由也能打开
    location / {
        root /www/wwwroot/webtrc/web/dist;
        try_files $uri $uri/ /index.html;
    }
}
```

宝塔面板：把 `server {}` 的内容填进站点「配置文件」，或保存为 `/www/server/panel/vhost/nginx/<域名>.conf`。

## 3. Cloudflare 真实 IP（开了橙云时）

开橙云后 `$remote_addr` 是 Cloudflare 边缘节点的 IP，日志、限速和转给节点的 `X-Forwarded-For` 都会是 CF 的地址，网页上的地区也会显示成 CF 机房。在服务器上执行一次：

```bash
sudo ./extension/cloudflare-realip.sh install        # 加 cron 子命令可每周自动更新 CF IP 段
```

脚本会把 `set_real_ip_from <CF 段>` 和 `real_ip_header CF-Connecting-IP` 写进本站点的扩展目录 `/www/server/panel/vhost/nginx/extension/<域名>/`，由站点配置里的 `include` 引入。只对本站点生效。**不要**再在 server 块里手写 `real_ip_header`，否则会报 `duplicate`。

Cloudflare 控制台另外要确认：

- SSL/TLS 模式选 **Full (strict)**（源站 443 用自己的证书）。
- Network → WebSockets 保持开启（默认开启）。

## 4. 与节点服务保持一致

nginx 里的域名要和 `backend/webtrc.service` 里的这两项一致，改了域名要一起改，然后执行 `sudo ./deploy.sh install`：

```ini
Environment=NODE_ANNOUNCE=/dns4/<你的域名>/tcp/443/wss
Environment=NODE_GATEWAY_URL=wss://<你的域名>/ws
```

## 5. 生效与验证

```bash
nginx -t && nginx -s reload
./deploy.sh check                                   # 本机 API、wss 公布地址、GeoIP、CF 真实 IP
curl -s https://<你的域名>/api/bootstrap             # nodes[].addrs 应包含 /tcp/443/wss
```

常见问题：

| 现象 | 原因 |
|---|---|
| 网页能开，`/api/...` 返回 404 或 index.html | 缺少 `location /api/`，或 `webtrc` 服务没运行 |
| 浏览器连不上节点，广场里看不到自己 | 缺少 `location = /` 的 Upgrade 分流，或 http 上下文里没有 `map $http_upgrade` |
| iOS 连不上 | 缺少 `location = /ws` |
| `nginx -t` 报 `limit_req_zone` / `map` 重复 | 这几行在 http 上下文里定义了多次 |
| 地区都显示成同一个 CF 机房 | 没执行 `cloudflare-realip.sh install` |
