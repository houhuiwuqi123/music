# Candy 广场 · Web (Vue 3 + js-libp2p)

The browser is a full js-libp2p peer on the AURU DHT. It does not use any central API for plaza data.

- **Joins the network:** fetches `/api/bootstrap` (cached in `localStorage`, falling back to `VITE_BOOTSTRAP`) and dials the nodes over WebSocket (noise + yamux). It runs Kademlia `/auru/kad/1.0.0` as a DHT client and reserves a circuit-relay slot so its provider records point at its node.
- **Plaza:** subscribes to the GossipSub topic `auru/plaza/1`, verifies every Ed25519-signed announcement, and lists what iOS users are listening to. It loads an initial snapshot over `/auru/plaza/1.0.0`.
- **Sharing (manual upload):** hashes the file (whole-file SHA-256 → CID, plus a hash per 1 MiB block), PROVIDEs the CID in the DHT, and announces it. It then appears and downloads exactly like a song an iOS user is playing. Files are served only while the tab is open.
- **Download / find by hash:** runs GET_PROVIDERS, sends the SDP offer over `/auru/signal/1.0.0` through the provider's node, and receives over a WebRTC DataChannel `auru-file/1`. Each block is verified as it arrives and the whole file is checked against the CID. If the connection drops, or the network goes offline and comes back, the download resumes from the last verified block.

```bash
npm install
npm run dev                         # proxies /api to NODE_HTTP (default http://127.0.0.1:8003)
npm run build                       # → dist/, served by nginx or `server -web-dir ../web/dist`
node --test test/transfer.test.ts   # protocol tests
node --test test/interop.test.ts    # builds and starts the Go node; needs Go
```

`VITE_NODE_URL` points the page at a node's HTTP API when it is hosted on a different origin. In development, start a local node with `-listen /ip4/127.0.0.1/tcp/4002/ws` so the browser can dial `ws://127.0.0.1:4002`.

Received files are held in memory until saved. Resume works within a session (network switches, reconnects), not across page reloads.
