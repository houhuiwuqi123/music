# Candy广场 → Swift (iOS/macOS) 移植提示词文档

> 本文档描述现有 Web 版「Candy广场」文件共享广场的完整产品效果、交互细节与通信协议，供移植到 Swift (iOS/macOS) 原生客户端时作为需求/提示词使用。**后端（Go + GoFrame 信令服务）无需任何改动**，Swift 客户端作为该信令协议的另一种实现接入，理论上可以和现有网页版用户在同一个广场里互相发布/接收文件。

---

## 1. 产品定位

一个「全球公开文件共享广场」：打开 App 即进入一个暗色星空主题的广场，可以看到其他在线用户正在分享的文件（以星星形式呈现），点击即可通过 WebRTC P2P 直连下载；也可以发布本机文件供他人下载。文件本体不经过服务器、不落盘存储，只在发布者保持在线期间有效。

品牌识别：Logo 为 🍬（糖果 emoji），标题「Candy广场」，糖果色系（粉色 `#ff5fa2`、紫色 `#8a5cff`、金色 `#ffd166`）点缀在深蓝紫到黑的渐变背景上。

---

## 2. 通信协议（必须严格对齐，才能与现有后端/网页端互通）

### 2.1 连接

```
ws://<host>/ws?id=<clientId>
```

- `clientId`：客户端自己生成的 UUID v4，每次启动/刷新都重新生成（不需要持久化）。
- 生产环境地址：`ws://music.webtrc.eu.cc/ws?id=...`（nginx 反代到 Go 后端 8080 端口）。
- 连接建立后，服务器立即推送一条当前广场快照（见下）。

### 2.2 消息包络（JSON，Swift 用 `Codable` 对应即可）

```jsonc
{
  "type": "publish" | "unpublish" | "signal" | "plaza",
  "file": { "id": "...", "name": "...", "size": 1234, "ownerId": "...", "ownerName": "..." }, // publish 时客户端发送（ownerId 由服务端覆盖填充，客户端不用传）
  "fileId": "...",      // unpublish 时客户端发送
  "files": [ /* FileMeta[] */ ],  // plaza 广播时服务端发送
  "to": "...",           // signal 时客户端发送，目标 clientId
  "from": "...",         // signal 时服务端填充，发起方 clientId
  "data": "..."          // signal 消息体，是一个【JSON 字符串】（二次编码！见 2.4）
}
```

`FileMeta` 字段：`id, name, size(字节,Int64), ownerId, ownerName`。

### 2.3 客户端 → 服务器

| 场景 | 消息 |
|---|---|
| 发布文件 | `{"type":"publish","file":{"id":"<uuid>","name":"demo.zip","size":123456,"ownerName":"访客1234"}}` |
| 撤回文件 | `{"type":"unpublish","fileId":"<uuid>"}` |
| 转发信令 | `{"type":"signal","to":"<对方clientId>","data":"<JSON字符串，见2.4>"}` |

### 2.4 服务器 → 客户端

| 场景 | 消息 |
|---|---|
| 广场快照（连接时 / 任何 publish/unpublish/断线后广播全量） | `{"type":"plaza","files":[FileMeta,...]}` |
| 转发信令 | `{"type":"signal","from":"<对方clientId>","data":"<JSON字符串>"}` |

**`data` 字段是「字符串」类型，里面装的是再次 JSON 编码后的信令对象**（Web 端实现是 `JSON.stringify` 了两层，服务器只做无脑转发，不解析 `data` 内容）。Swift 端收发时要对应做两层编解码：外层 `WSMessage.data` 是 `String`，内层再 `JSONDecoder` 解析成下面的信令结构：

```jsonc
// kind = offer | answer
{ "kind": "offer", "sdp": { "type": "offer", "sdp": "<SDP文本>" } }
{ "kind": "answer", "sdp": { "type": "answer", "sdp": "<SDP文本>" } }
// kind = candidate
{ "kind": "candidate", "candidate": { "candidate": "...", "sdpMid": "...", "sdpMLineIndex": 0 } }
```

### 2.5 WebRTC 建连与文件传输时序

1. **接收方**（想下载文件的人）：创建 `RTCPeerConnection`（ICE server 见下），创建 `RTCDataChannel`，**label 必须是 `"file:<fileId>"`**（发布方靠这个 label 识别要传哪个文件）；创建 offer → `setLocalDescription` → 通过 `signal{kind:"offer", sdp:...}` 发给文件的 `ownerId`。
2. **发布方**收到 `signal` 且 `kind=="offer"`：新建一个 `RTCPeerConnection`，`setRemoteDescription`，监听 `ondatachannel`（取 `channel.label` 里的 fileId 找到本地持有的文件），创建 answer → `setLocalDescription` → `signal{kind:"answer", sdp:...}` 回给请求方。
3. 双方各自在 `onicecandidate` 回调里，把产生的 candidate 通过 `signal{kind:"candidate", candidate:...}` 发给对方（谁的连接谁转发给谁）。
4. DataChannel 建连后（`onopen` / `didOpen`），**发布方**按以下顺序发送：
   - 一条文本帧：`{"type":"meta","name":"<文件名>","size":<字节数>}`
   - 若干二进制帧：文件内容按 **16 KB (16384 字节)** 一片，依次 `send`，不能乱序（SCTP 保证顺序，但发送端要串行等待上一片，用 `bufferedAmount` 做背压：超过 1MB 缓冲就暂停发送，等 `onbufferedamountlow`（阈值设为 512KB）再继续，防止内存暴涨）
   - 最后一条文本帧：`{"type":"eof"}`
5. **接收方**收到二进制帧就按顺序拼进缓冲区，累加字节数算百分比用于进度展示；收到 `eof` 文本帧后，把所有二进制帧拼成完整文件数据（Web 端用 `Blob`，Swift 对应用 `Data` 累加或写临时文件），触发保存/分享。

ICE 配置（STUN only，无 TURN 兜底，严格 NAT 环境可能打洞失败，这是已知限制）：

```json
{ "iceServers": [ { "urls": "stun:stun.l.google.com:19302" } ] }
```

---

## 3. 交互与视觉效果（原生实现时要还原的"感觉"，不要求像素级复刻）

### 3.1 顶栏
- 左侧：🍬 + 渐变色文字「Candy广场」。
- 右侧：连接状态小胶囊（在线/离线两种颜色），「+ 发布」糖果色渐变圆角按钮。

### 3.2 搜索栏
紧贴在顶栏下方，圆角输入框，placeholder「搜索文件名…」，**输入即时过滤**（不区分大小写、子串匹配），只影响星空区域显示哪些"别人分享的文件"星星，不影响"我的分享"。

### 3.3 星空区域（核心交互区，要有设计感）
- 背景：深蓝紫→黑的径向渐变，叠加约 90 个微小白色装饰点，各自随机延迟/周期做透明度呼吸动画（纯装饰，固定不动，与数据无关）。
- 每个**别人发布**的文件渲染为一颗发光的**五角星图标**（不是圆点），糖果色渐变 + 发光效果：
  - 尺寸按文件大小做对数映射，范围大约 16px～34px（小文件更小，大文件更大），整体偏小巧。
  - 星星本身持续"一闪一闪"：透明度 0.55↔1 配合缩放 0.82↔1.12 的呼吸动画，周期随机 1.4～2.6 秒，让每颗星星闪烁节奏不同步。
  - 星星位置由文件 id 的哈希值决定（不是纯随机），保证同一个文件每次刷新广场列表都出现在同一个位置，不会因为别人上下线而跳动错位。
  - 星星会**缓慢漂移**：以锚点为中心，16～30 秒一个周期在小范围内做位移循环（4 种预设漂移路径轮流分配，各自随机延迟起步），营造漂浮在夜空中的感觉，但不会飘出太远。
  - 星星下方常驻一个小标签（不是 hover 才显示，是一直显示），两行文字：**发布者昵称**（金色、字号较大、加粗）在上，**文件名**（浅色、字号稍小、加粗）在下——这两行文字要比星星图标本身更突出、字号更大，是用户明确要求的重点（星星要小、文字要大）。
  - 点击星星 → 弹出确认框：「是否接收来自「昵称」的文件「文件名」（大小）？」，取消/确认接收两个按钮。
  - 确认后星星进入"下载中"视觉状态：呼吸动画变快，中心叠加百分比文字；完成后短暂泛绿色光晕（约 1.5 秒）恢复正常。下载状态的视觉必须绑定在该星星稳定的视图标识上，**广场列表刷新时不能把正在下载的星星销毁重建**（否则进度会丢/闪烁）。
  - 无文件 / 搜索无结果时，星空中间显示提示文字，且要能区分「广场本来没人分享」和「搜索没有匹配结果」两种文案。

### 3.4 发布面板
点击右上角「+ 发布」以浮层形式弹出（半透明遮罩 + 居中/靠右卡片），内容从上到下：
1. 文件选择区（Web 端是拖拽区；iOS/macOS 原生对应系统文件选择器 / 分享扩展，不强求做"拖拽"）
2. 「我的分享」列表：当前仍在广场广播中的、属于自己的文件，每项一个「撤回」按钮（调用 unpublish，从服务器广场摘除）
3. 「发布记录」列表：历史发布日志（只含文件名/大小/时间，不含实时状态），**本地持久化**保存，独立的「清除记录」按钮，与"我的分享"是两份不同数据——"我的分享"是活跃状态（App 关闭/文件引用失效就没了），"发布记录"是只增不减的历史日志，除非手动清除。

### 3.5 接收记录
主界面星空区域下方常驻展示，列表每项：文件名、来源昵称、大小、时间、"已完成"徽章。**本地持久化**保存，独立的「清除记录」按钮。

### 3.6 本地持久化字段（迁移到 Swift 可用 `UserDefaults` 起步，量大了再换 CoreData/SQLite，字段语义保持一致即可）

| 用途 | 建议 key | 结构 |
|---|---|---|
| 用户昵称 | `candy_nickname` | 字符串，首次启动生成「访客」+4位随机数字后固定，不随 clientId 变化 |
| 发布记录 | `candy_publish_log` | 数组，每项 `{name, size, time}`，新记录插最前，最多保留 100 条 |
| 接收记录 | `candy_receive_log` | 数组，每项 `{name, size, fromName, time}`，同上逻辑 |

---

## 4. Swift 技术选型建议

- **WebSocket**：系统自带 `URLSessionWebSocketTask` 即可，不需要额外引入 Starscream。
- **WebRTC**：引入 Google 官方 WebRTC（社区打包的 `WebRTC-SDK` / `GoogleWebRTC` 均可，通过 SPM 或 CocoaPods），对应 API：`RTCPeerConnectionFactory`、`RTCPeerConnection`、`RTCDataChannel`、`RTCIceServer(urlStrings:["stun:stun.l.google.com:19302"])`。浏览器与原生 WebRTC 的 SDP/ICE/DTLS-SRTP/SCTP 均遵循同一套标准，天然互通，无需任何协议转换。
- **JSON 编解码**：为 `WSMessage` / `FileMeta` / 信令子结构各写一个 `Codable` struct，注意 `data` 字段要先当 `String` 解出来，再用 `JSONDecoder` 解一次内层信令对象（对应 Web 端的二次编码）。
- **UI**：SwiftUI。星空动态效果可以用一堆按坐标/动画参数定位的 `View`（`.overlay` + `withAnimation(.repeatForever)`），或者用 `Canvas`/`TimelineView` 做更精细的自绘；五角星图标可以用 SF Symbols 的 `star.fill` 或自绘 `Path`。
- **文件生命周期注意**：iOS 不能像浏览器一样安心长期持有用户选的文件引用——系统给的是安全范围 URL，建议发布时就把文件拷贝一份到 App 的 `Documents`/临时目录，保证后续按需读取分片不受原始授权失效影响。接收完成后用 `UIDocumentPickerViewController`（导出）或 `UIActivityViewController`（分享面板）让用户保存文件。

---

## 5. 已知限制（移植时按需决定是否弥补，均不是 bug，是当前 MVP 的既有取舍）

1. 只配置了公共 STUN，没有 TURN 中继兜底，严格 NAT/企业防火墙环境下 P2P 打洞可能失败。
2. 广场状态是 Go 后端单进程内存态，重启即丢失所有在线文件记录（客户端重连后重新 publish 即可恢复，不影响"发布记录"等本地持久化数据）。
3. 接收端把所有分片攒在内存里，收到 `eof` 才一次性组装成完整文件，没做流式落盘，超大文件会占用等量内存。
