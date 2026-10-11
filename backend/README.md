# Music signaling and temporary online-transfer gateway

Implemented here; no production service is modified automatically. The independent stdlib HTTP gateway binds **127.0.0.1**, separate from the WebSocket port. It is a temporary, verified-byte fan-out cache, not an offline music library. Source online authorization is necessary even after the entire file is cached.

## Build, configure, run

```powershell
Set-Location 'C:\phpwork\music\backend'
go test ./... -count=1
go vet ./...
go build -o music-signaling.exe .
.\music-signaling.exe -port 8080 -gateway-port 8081 `
  -gateway-public-url 'https://music.webtrc.eu.cc/gateway' `
  -gateway-cache-dir '.\state\relay-cache' `
  -identity-store '.\state\identities.json'
```

`-gateway-port 0` (default) disables reliable grants; configure both gateway flags to enable them. `GATEWAY_PUBLIC_URL` supplies the public URL default. HTTPS is mandatory for advertised URLs; terminate TLS at the reverse proxy, not on the localhost gateway. URLs must have no userinfo/query/fragment. A path prefix is supported if the reverse proxy strips it. Never expose the HTTP port directly.

`-identity-store` holds SHA-256 identity-secret digests, persisted by synchronized file write and atomic replacement **before** accepting a new identity. Keep this file, restrict it and its parent to the service account, and back it up. Identity-store failure fails authentication/startup rather than silently resetting identity. No identity secret is included in snapshots or application logs. TOFU is possession of the first registered secret, not an account, and cannot prevent initial ID squatting. Limit unauthenticated upgrade traffic at the proxy. Each process requires an exclusive identity store and cache directory; this implementation is single-instance, not a distributed deployment.

Only cache artifacts named exactly `relay-<canonical UUID>.part` in the configured exclusive directory are deleted on restart. Unrelated files are left alone; matching directories/symlinks cause startup failure. Grants are memory-only: restart loses all grants and resumable prefixes, but **not** persisted identities. The directory and parent must not be attacker-writable. Cache quota reserves the entire declared size before admitting a new physical relay object.

## WebSocket API (protocol version 2)

Connect to `wss://signaling.example.com/ws?id=<persisted-client-id>&secret=<persisted-random-UUID>`. Swift's preference key is `client_secret`. Keep the same secret across reconnects; use a fresh random ID+secret for a new identity. A mismatched/missing secret on an already-pinned ID is rejected **before upgrade** with HTTP 403. Legacy IDs without any pinned secret can connect without one and publish/listen to metadata, but cannot create reliable grants or send grant-bound signals.

The server sends:

```json
{"type":"config","protocolVersion":2,"gatewayEnabled":true,"iceServers":[{"urls":["stun:stun.l.google.com:19302"]}]}
```

TURN credentials are added when configured. Request another config with `{"type":"config"}` before credentials expire. A registered active socket alone can mutate state, request/cancel grants, or relay signals. Replacing a socket closes the previous one and revokes its grants; its late cleanup cannot affect its replacement.

### Current publication and online lease

```json
{"type":"listening","listening":{"ownerName":"Visitor","title":"Song","artist":"Artist","isPlaying":true,"file":{"id":"PUBLICATION-UUID","name":"song.mp3","size":12345,"sha256":"64-lowercase-hex-digits","protocolVersion":2}}}
```

`FileMeta.sha256` and `protocolVersion` remain optional for metadata compatibility. Reliable requests require version 2, a positive bounded size, a UUID publication ID, and a SHA-256 hash manifest. Compute the hash **before** publishing. UUID identifies the publication; SHA-256 identifies stable content/checkpoints. Reusing a publication UUID with different size/hash is rejected. The server supplies `ownerId`, `ownerName`, `clientId`, region, and clears client-supplied `offlineAt`.

Refresh listening every 30 seconds. The lease expires at 90 seconds, independently checked during transfer I/O. Pause with a nonnil file retains sharing. A new nonnil file withdraws the previous publication for **new** requests while keeping old authorized grant manifests/transfers valid. Send `{"type":"listening"}` to opt out completely; retaining listening metadata with `file` absent/null is also a sharing opt-out and revokes **all** owner transfers (including older songs).

Detected disconnect revokes immediately; expiry/opt-out revokes all associated bearer leases and aborts active streams. Reconnect with the same secret does **not** resurrect grants revoked by disconnection. Republish the current share and obtain a new grant. Other recipients do not retain offline access to verified cache bytes. Listener metadata remains offline for 60 seconds after disconnect/expiry; graceful opt-out removes it immediately.

Optional `avatar` is plain base64 JPEG/PNG, <=32 KiB, dimensions 1–256 pixels. Name/title/artist validation and local region lookup remain unchanged. `plaza`/`listeners` snapshots never include secrets or transfer tokens. Legacy `publish`/`unpublish` are ownership-checked metadata operations, not reliable transfer authorization for arbitrary files. Legacy unscoped signal forwarding is no longer allowed.

### Grant request, response, ready notification, release

```json
{"type":"transfer-request","requestId":"UUID","fileId":"PUBLICATION-UUID","to":"OWNER-ID"}
{"type":"transfer","requestId":"UUID","transfer":{"id":"GRANT-UUID","file":{"id":"PUBLICATION-UUID","name":"song.mp3","size":12345,"ownerId":"OWNER-ID","ownerName":"Visitor","sha256":"HASH","protocolVersion":2},"mode":"relay","token":"RECIPIENT-BEARER","downloadURL":"https://gateway.example.com/v2/transfers/GRANT-UUID/download","expiresAt":1234567890,"status":"waiting","generation":1}}
```

First two **active** grants per owner use `mode:"p2p"`; subsequent grants use `mode:"relay"`. P2P grants have `status:"ready"` for negotiation but their gateway URL returns 409 `p2p-only`; use WebRTC. Relay grants share one physical object per **owner + SHA-256 + size**. Cache verified once, serve many recipients. Client filenames never form filesystem paths.

Resume an existing still-valid grant by including `transferId:"GRANT-UUID"` in the request with matching owner/file. A new resume request ID increments P2P `generation`; retrying any known request ID is idempotent. At most 64 distinct request IDs per grant; further resumes return `resume-limit`. Never resume a disconnected/revoked grant. Cancellation/completion:

```json
{"type":"transfer-cancel","transferId":"GRANT-UUID"}
{"type":"transfer-complete","transferId":"GRANT-UUID"}
```

Only its recipient may release a grant. Repeated WS releases are harmless. HTTP completion also works below. Cache remains while any other grant references it, then becomes idle. On verified relay completion the server sends `{"type":"transfer","transfer":{...same grant, status:"ready"}}` **without** `requestId`. Polling download HEAD is allowed.

Failure: `{"type":"transfer-error","requestId":"UUID","transferId":"UUID-if-supplied","error":"CODE"}`. Codes include `identity-required`, `gateway-disabled`, `invalid-request-id`, `not-available`, `manifest-required`, `file-too-large`, `full`, `cache-full`, `busy`, `request-id-conflict`, `invalid-or-revoked-transfer`, `resume-limit`, `rate-limited`, `not-your-transfer`, `invalid-signal`, and asynchronous `hash-mismatch`. Do not silently retry permanent/revoked errors.

### Deduplicated owner upload

Only the scheduled uploader receives:

```json
{"type":"upload-request","transfer":{"id":"CONTENT-UPLOAD-UUID","file":{"id":"PUBLICATION-UUID","name":"song.mp3","size":12345,"ownerId":"OWNER-ID","ownerName":"Visitor","sha256":"HASH","protocolVersion":2},"mode":"relay","token":"OWNER-UPLOAD-BEARER","uploadURL":"https://gateway.example.com/v2/uploads/CONTENT-UPLOAD-UUID","expiresAt":1234567890}}
```

Here `transfer.id` identifies the deduplicated **content upload**, not a recipient grant. Owner and recipient tokens are different random 256-bit opaque bearers. One relay upload is scheduled per owner; other contents wait in a bounded queue. Retain old source file versions while grants are authorized, even after changing songs. The owner should HEAD to obtain the durable prefix, not assume an ambiguous PUT response failed.

### Grant-bound signaling

```json
{"type":"signal","to":"PEER-ID","transferId":"GRANT-UUID","generation":1,"data":"{\"transferId\":\"GRANT-UUID\",\"fileId\":\"PUBLICATION-UUID\",\"generation\":1,\"kind\":\"offer\",\"sdp\":\"...\"}"}
```

Envelope ID/generation and inner JSON string ID/file/generation must agree with the active P2P grant. Sender/target must be its owner/recipient pair. Relay grants, stale sockets, wrong generations, objects instead of inner strings, and unauthorized peers are rejected. Valid inner JSON is forwarded unchanged, with `from`, `transferId`, `generation`. WebRTC payload/checkpoint handling is the client responsibility; gateway byte/hash tests do not validate WebRTC device performance.

Before the recipient response or offer, the owner is sent `{"type":"transfer-authorized","from":"RECIPIENT-ID","transfer":{"id":"GRANT-UUID","file":{...},"mode":"p2p","token":"","expiresAt":1234567890,"generation":1}}`. This authorizes the retained file snapshot and `file-v2:<transferId>` channel without exposing the receiver bearer. The authorization is resent on valid grant resumes/retries with current generation. The recipient uses `transfer.file.ownerId` as its signaling target.

Optional request `mode:"relay"` forces relay admission or atomically upgrades the existing `transferId` from P2P after failed ICE. It preserves grant ID, recipient bearer, manifest, and expiry, releases the P2P slot, and deduplicates relay upload. Capacity failure leaves the original P2P grant valid. Upgrading sends the **owner only** `{"type":"transfer-revoked","transferId":"GRANT-UUID","error":"relay-upgrade"}` to stop its direct channel; the recipient receives the requested relay transfer response and handles fallback rather than a terminal cancellation. Relay cannot be downgraded back to P2P. Invalid mode returns `invalid-mode`.

Connected peers receive terminal `{"type":"transfer-revoked","transferId":"GRANT-UUID","error":"revoked"}` on opt-out/disconnect/replacement, `"expired-or-revoked"` on lease cleanup, or `"released"` when a recipient releases. Clients **must close that grant's PeerConnection/DataChannel** on these notices. A server cannot unilaterally recall bytes on an already-established direct P2P connection; both authorized clients enforce cancellation locally.

## HTTP gateway API

Every request requires `Authorization: Bearer <role-specific token>`; never put bearer tokens in URLs. No download is served until whole-file SHA-256 verification succeeds. Authorization is checked at admission, before writes, and every **100 ms** by a lease timer; cancellation also sets socket read/write deadlines to interrupt stalled I/O. Already-transmitted/in-flight network bytes cannot be recalled.

| Method and route | Success | Other behavior |
| --- | --- | --- |
| `HEAD /v2/uploads/{contentId}` | 200; `Upload-Offset`, `Upload-Length`, `Upload-Status: waiting/ready` | 403 wrong/revoked bearer, unqueued upload or no active grant |
| `PUT /v2/uploads/{contentId}` | 204; durable `Upload-Offset`; final `Upload-Status: ready` | `Content-Range: bytes start-end/total`, max 1 MiB body. 400 invalid/oversized range/body; 409 gap, overlap or different duplicate bytes; 422 full hash mismatch; 507 cache write/sync failure |
| `HEAD /v2/transfers/{grantId}/download` | 200 or 206; same headers as GET, no body | 425 waiting (`Retry-After: 1`); 409 p2p-only; 403 wrong/revoked/expired bearer |
| `GET /v2/transfers/{grantId}/download` | 200 full or 206 range; `Accept-Ranges: bytes`, `Content-Length`, `ETag: "sha256"` | Single `bytes=start-end`, `start-`, and `-suffix` supported. 416 invalid/unsatisfiable/multipart, `Content-Range: bytes */size`. If-Range mismatch requests the full file |
| `POST /v2/transfers/{grantId}/complete` | 204, idempotent with same bearer until expiry/revocation | Immediately cancels this recipient grant; bounded tombstone retained for retries. Other grants/cache remain intact |

Offsets advance only after file Sync. Retrying an entirely acknowledged chunk compares the stored bytes and does not advance twice. Partial overlaps are rejected; use HEAD and start at the returned prefix. Truncated/overlong HTTP bodies are rejected before writes. Final hash is recomputed by streaming the entire disk file; mismatch revokes dependent grants and deletes the failed object on cleanup. Ready files are immutable.

403 intentionally conflates unknown/revoked/wrong token. 404 unknown route/encoded path traversal. 405 unsupported method. 429 per-grant/content request limit; 503 bounded handler capacity or unavailable cache; `Retry-After: 1` accompanies busy/rate-limited responses. Errors are plain text. No filename Content-Disposition is trusted.

### Default limits

| Resource | Default |
| --- | --- |
| Active P2P grants per owner | 2 |
| Scheduled relay source uploads per owner | 1 |
| Total grants (including HTTP completion tombstones) | 2,048 |
| Active grants per owner / recipient | 256 / 4 |
| Cached objects / queued unfinished objects per owner | 64 / 50 |
| Maximum file / reserved owner cache / total reserved cache | 512 MiB / 1 GiB / 4 GiB |
| HTTP concurrent handlers / chunk size | 128 / 1 MiB |
| Aggregate gateway byte pacing (uploads + downloads) | 64 MiB/sec |
| Incoming WS messages per socket | 30/sec |
| HTTP requests per grant or upload token | 120/sec |
| WS outgoing queue | 128; overflow closes that socket |
| Grant lifetime / idle cache TTL | 30 min / 10 min |
| Source listening TTL / transfer lease check / cleanup tick | 90 sec / 100 ms / 1 sec |
| Identity records / manual publications total / per owner | 100,000 / 4,096 / 64 |

Main exposes `-gateway-max-file-bytes`, `-gateway-max-cache-bytes`, `-gateway-max-owner-bytes`, and `-gateway-bytes-per-second`. Other limits are centralized in `DefaultTransferConfig`; smaller configured quotas must remain >= the maximum file. Global handler slots, bounded request bodies, 64 KiB download/hash buffers, content upload serialization, token rate limits, and byte pacing bound server work. No unlimited slow-writer broadcast locks: a dedicated WS writer consumes each bounded queue. Grant/queue/cache full errors are explicit. This does not rate-limit iOS P2P byte uploads: implement client backpressure and concurrency limits.

## TURN and deployment (not applied automatically)

`deploy\nginx.conf` is a TLS reverse-proxy template with same-origin `https://music.webtrc.eu.cc/gateway/v2/...` routes (stripping `/gateway` to the localhost gateway), plus an optional separate gateway hostname. Query strings and authorization headers are excluded from access logs. Gateway response buffering/cache and request buffering are disabled so revoked streams/chunk prefixes are not hidden by proxy storage. Configure your own certificates/domains, and confirm no upstream CDN buffers/caches requests or ignores cancellation.

`deploy\compose.yaml` and `deploy\coturn.conf` provide a separate coturn deployment on a Linux host with host networking. Supply a strong, **uncommitted** `TURN_REST_SECRET` environment value to both coturn and backend, and set backend `TURN_URLS`, e.g.:

```powershell
$env:TURN_URLS = 'turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp,turns:turn.example.com:5349?transport=tcp'
# Obtain TURN_REST_SECRET through your service secret manager; do not paste it into source or shell history.
```

REST username is `<unix-expiry>:<clientId>` and credential is base64(HMAC-SHA1(secret, username)), expiring in **10 minutes**. The server never embeds the shared secret or sends it to clients. Request a fresh config before expiry; renew/restart ICE as required by the device implementation. Do not issue public static TURN usernames/passwords. Host process/environment and Docker administrator access are trusted; the compose wrapper passes the shared secret to coturn's startup argument. Use protected service secrets and restrict operator access.

Provision coturn TLS files and external public IP/NAT mapping, then open UDP/TCP 3478, TCP 5349, and UDP 49160–49259. Enable UDP 5349 if deploying DTLS URLs. The template denies loopback/private/link-local/multicast peer targets, limits allocations/bandwidth, disables CLI, and has no anonymous authentication. Set actual listening/relay/external IPs in coturn config when NAT requires it. TLS endpoint and UDP reachability must be tested from devices; TURN is a transport fallback, not an offline source or upload deduplication solution.

## Local IP-region lookup

Use `-geoip-db 'C:\GeoIP\GeoLite2-City.mmdb'` or `GEOIP_DB_PATH`; provision a licensed compatible MMDB yourself. Do not use the MaxMind test fixture in production. `-trusted-proxies '127.0.0.1/32,::1/128'` or `TRUSTED_PROXY_CIDRS` should include only actual reverse proxies. No proxy headers are trusted by default; never trust `0.0.0.0/0`. The template overwrites `X-Forwarded-For`; additional upstream proxies require carefully verified real-IP configuration.

No IP is sent to an external lookup service. Only approximate region names are broadcast. Missing DB displays “地区未知”; unreadable configured DB fails startup. Private/unmatched addresses and lookup failures display unknown.

## Verified tests versus proposed device SLOs

`go test ./... -count=1` exercises persisted identities, ownership, stale clients, P2P generations, cut-song grants, opt-out/offline/TTL revocation, hash mismatch, chunk/range/resume, quotas, path traversal, exact restart cleanup, idle cleanup, queue scheduling, and midstream cancellation/lease timer. The real-process integration test starts only its own backend subprocess on isolated loopback ports, drives actual WS config/grants/signals/ready notifications plus HTTP uploads/range downloads, reconnects, and kills only that process. Test artifacts live in UUID-scoped project directories and are cleaned up.

The measured in-process fan-out test admits **100 simultaneous relay recipients plus two P2P reservations**, uploads one physical 180,000-byte source object, concurrently verifies all 100 complete bodies and SHA-256 values, and checks only one cache artifact. It is a correctness/concurrency test, **not** a large-file throughput, WAN speed, 100-device, TURN, Swift backgrounding, packet-loss, or energy benchmark. Existing `verify-listening.cjs` exercises the legacy metadata protocol; its old unrestricted-signal check is no longer a v2 guarantee. The new Go integration test is authoritative for authorized transfers.

Validated in the Windows development environment: `go test ./... -count=1` and `go vet ./...` pass; real-process integration was additionally repeated three times, and fan-out/slow-writer/stream-cancellation regressions five times. `go test -race ./...` was attempted but cannot run here: CGO is disabled and no GCC/Clang is installed. It needs CGO and a working C compiler on a suitable CI runner. TURN/nginx templates have not been deployed or exercised here. `GEOIP_TEST_DB` enables the existing MaxMind fixture-specific lookup test; without it that optional test is skipped.

Proposed **unmeasured** device SLOs: active source, valid retained file, working network and sufficient cache capacity should allow resumable verified downloads; revoke detection should interrupt server output within a timer tick plus scheduling/network delay. Test real iPhones under loss, NAT/TURN, foreground/background, heat, reconnects, and 100-recipient load before claiming device success percentages or latency/throughput targets. A source suspended/offline beyond its lease cannot guarantee completion.
