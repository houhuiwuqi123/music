// Browser terminal of the AURU DHT network.
// - joins the "/auru/kad/1.0.0" Kademlia DHT as a client through bootstrap nodes
// - publishes / receives signed plaza announcements on GossipSub
// - provides uploaded files in the DHT and finds providers with GET_PROVIDERS
// - exchanges WebRTC SDP via "/auru/signal/1.0.0" and transfers over DataChannels
import { createLibp2p, type Libp2p } from 'libp2p'
import { webSockets } from '@libp2p/websockets'
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { identify } from '@libp2p/identify'
import { ping } from '@libp2p/ping'
import { kadDHT, type KadDHT } from '@libp2p/kad-dht'
import { gossipsub, type GossipSub, type Message } from '@libp2p/gossipsub'
import { circuitRelayTransport } from '@libp2p/circuit-relay-v2'
import { generateKeyPair, privateKeyFromProtobuf, privateKeyToProtobuf } from '@libp2p/crypto/keys'
import { peerIdFromString } from '@libp2p/peer-id'
import { lpStream } from '@libp2p/utils'
import { multiaddr, type Multiaddr } from '@multiformats/multiaddr'
import type { PrivateKey, Stream } from '@libp2p/interface'
import { reactive } from 'vue'
import { parseContentCID, manifestOf, sha256FromCID } from './content.ts'
import { b64, unb64, signEnvelope, verifyEnvelope, type Envelope, type PlazaBody, type PlazaFile } from './plaza.ts'
import { Assembly, CHANNEL_LABEL, receiveChannel, serveChannel, type SourceFile } from './transfer.ts'

export const DHT_PROTOCOL = '/auru/kad/1.0.0'
export const SIGNAL_PROTO = '/auru/signal/1.0.0'
export const RESOLVE_PROTO = '/auru/resolve/1.0.0'
export const SNAPSHOT_PROTO = '/auru/plaza/1.0.0'
export const PLAZA_TOPIC = 'auru/plaza/1'
const ENTRY_TTL = 90_000
const OFFLINE_RETENTION = 60_000
const ANNOUNCE_EVERY = 30_000
const MAX_UPLOADS = 3

export interface NodeInfo { peerId: string; addrs: string[]; gateway?: string }
export interface Signal {
  from?: string; to: string; node?: string; nodeAddrs?: string[]
  fromNode?: string; fromNodeAddrs?: string[]
  session: string; kind: 'offer' | 'answer' | 'bye'; sdp?: string
}
export interface Candidate { peerId: string; node: string; nodeAddrs: string[] }
export interface PlazaEntry { body: PlazaBody; offline: boolean; lastSeen: number }
export interface DownloadTask {
  id: string; cid: string; name: string; size: number; from?: string
  progress: number; status: string; state: 'running' | 'complete' | 'failed' | 'canceled'
  url?: string
}
export interface UploadEntry { cid: string; name: string; size: number; serving: number; hashing?: number }

type Services = { dht: KadDHT; pubsub: GossipSub; identify: unknown; ping: unknown }

const defaultNodeURL = (import.meta.env?.VITE_NODE_URL as string | undefined) ?? ''
const encoder = new TextEncoder()
const decoder = new TextDecoder()

function readKey(): Promise<PrivateKey> {
  try {
    const saved = localStorage.getItem('auru-key')
    if (saved) return Promise.resolve(privateKeyFromProtobuf(unb64(saved)))
  } catch { /* storage unavailable: use an ephemeral identity */ }
  return generateKeyPair('Ed25519').then((key) => {
    try { localStorage.setItem('auru-key', b64(privateKeyToProtobuf(key))) } catch { /* ephemeral */ }
    return key
  })
}

function wsAddrs(addrs: string[]): Multiaddr[] {
  return addrs.filter((a) => /\/wss?(\/|$)/.test(a) || a.includes('/tls/ws')).map((a) => multiaddr(a))
}

async function request<T>(stream: Stream, value: unknown, timeoutMs = 10_000): Promise<T> {
  const signal = AbortSignal.timeout(timeoutMs)
  const lp = lpStream(stream)
  await lp.write(encoder.encode(JSON.stringify(value)), { signal })
  const reply = await lp.read({ signal })
  await stream.close().catch(() => undefined)
  return JSON.parse(decoder.decode(reply.subarray())) as T
}

function gathered(pc: RTCPeerConnection, ms = 5000): Promise<void> {
  if (pc.iceGatheringState === 'complete') return Promise.resolve()
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer)
      pc.removeEventListener('icegatheringstatechange', check)
      resolve()
    }
    const check = () => { if (pc.iceGatheringState === 'complete') done() }
    const timer = setTimeout(done, ms)
    pc.addEventListener('icegatheringstatechange', check)
  })
}

const sleep = (ms: number, wake?: { promise: Promise<void> }) =>
  Promise.race([new Promise<void>((r) => setTimeout(r, ms)), wake?.promise ?? new Promise<void>(() => undefined)])

export class PlazaNetwork {
  state = reactive({
    status: 'offline' as 'connecting' | 'online' | 'offline',
    peerId: '',
    region: '',
    nodes: [] as string[],
    entries: {} as Record<string, PlazaEntry>,
    uploads: [] as UploadEntry[],
    downloads: [] as DownloadTask[],
    name: '',
    error: '',
  })

  private libp2p?: Libp2p<Services>
  private key?: PrivateKey
  private bootstrap: NodeInfo[] = []
  private connectedNodes = new Map<string, NodeInfo>()
  private sources = new Map<string, SourceFile>()
  private pendingAnswers = new Map<string, (sig: Signal) => void>()
  private ice: RTCIceServer[] = [{ urls: ['stun:stun.l.google.com:19302'] }]
  private serving = 0
  private reconnectDelay = 1000
  private reconnectTimer?: ReturnType<typeof setTimeout>
  private timers: ReturnType<typeof setInterval>[] = []
  private provided = new Set<string>()
  private online = { promise: Promise.resolve(), wake: () => {} }
  private canceled = new Set<string>()

  private nodeURL: string

  constructor(options: { nodeURL?: string } = {}) {
    this.nodeURL = options.nodeURL ?? defaultNodeURL
    this.state.name = (() => {
      try { return localStorage.getItem('auru-name') ?? '' } catch { return '' }
    })() || `网页访客${Math.floor(1000 + Math.random() * 9000)}`
    this.resetWake()
  }

  private resetWake() {
    let wake = () => {}
    const promise = new Promise<void>((r) => { wake = r })
    this.online = { promise, wake }
  }

  async start() {
    this.key = await readKey()
    const libp2p = await createLibp2p({
      privateKey: this.key,
      // Browsers are not dialable: reserve a circuit slot on the node so DHT
      // provider records carry "/…/p2p/<node>/p2p-circuit" — the signalling hop.
      addresses: { listen: ['/p2p-circuit'] },
      transports: [webSockets(), circuitRelayTransport()],
      connectionEncrypters: [noise()],
      streamMuxers: [yamux()],
      connectionGater: { denyDialMultiaddr: () => false },
      services: {
        identify: identify(),
        ping: ping(),
        dht: kadDHT({ protocol: DHT_PROTOCOL, clientMode: true, peerInfoMapper: (p) => p }),
        pubsub: gossipsub({ allowPublishToZeroTopicPeers: true, emitSelf: false }),
      },
    })
    this.libp2p = libp2p as unknown as Libp2p<Services>
    this.state.peerId = libp2p.peerId.toString()
    await libp2p.handle(SIGNAL_PROTO, (stream, connection) => this.onSignalStream(stream, connection.remotePeer.toString()))
    const pubsub = this.libp2p.services.pubsub
    pubsub.subscribe(PLAZA_TOPIC)
    pubsub.addEventListener('message', (evt: CustomEvent<Message>) => {
      if (evt.detail.topic !== PLAZA_TOPIC) return
      try { void this.applyEnvelope(JSON.parse(decoder.decode(evt.detail.data)) as Envelope) } catch { /* ignore */ }
    })
    libp2p.addEventListener('peer:disconnect', (evt) => {
      const id = evt.detail.toString()
      if (this.connectedNodes.delete(id)) {
        this.state.nodes = [...this.connectedNodes.keys()]
        if (this.connectedNodes.size === 0) {
          this.state.status = 'offline'
          this.scheduleReconnect()
        }
      }
    })
    libp2p.addEventListener('self:peer:update', () => {
      if (libp2p.getMultiaddrs().some((a) => a.toString().includes('/p2p-circuit'))) void this.provideAll()
    })
    if (typeof window !== 'undefined') {
      // Mobile network switches surface as offline → online; reconnect immediately.
      window.addEventListener('online', () => { this.online.wake(); this.resetWake(); void this.connect() })
      window.addEventListener('offline', () => { this.state.status = 'offline' })
      window.addEventListener('pagehide', () => { void this.announce(true) })
    }
    this.timers.push(setInterval(() => void this.announce(), ANNOUNCE_EVERY))
    this.timers.push(setInterval(() => this.sweep(), 1000))
    this.timers.push(setInterval(() => { this.provided.clear(); void this.provideAll() }, 3_600_000))
    await this.connect()
  }

  async stop() {
    for (const timer of this.timers) clearInterval(timer)
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = undefined
    const libp2p = this.libp2p
    this.libp2p = undefined
    this.connectedNodes.clear()
    await libp2p?.stop()
  }

  setName(name: string) {
    const trimmed = name.trim().slice(0, 40)
    if (!trimmed) return
    this.state.name = trimmed
    try { localStorage.setItem('auru-name', trimmed) } catch { /* ignore */ }
    void this.announce()
  }

  // ---- node connectivity & reconnection ----

  private async loadBootstrap(): Promise<NodeInfo[]> {
    try {
      const res = await fetch(`${this.nodeURL}/api/bootstrap`, { signal: AbortSignal.timeout(8000) })
      const list = (await res.json()) as { nodes: NodeInfo[] }
      if (list.nodes?.length) {
        try { localStorage.setItem('auru-bootstrap', JSON.stringify(list.nodes)) } catch { /* ignore */ }
        return list.nodes
      }
    } catch { /* fall back to the cached / configured list */ }
    try {
      const cached = JSON.parse(localStorage.getItem('auru-bootstrap') ?? '[]') as NodeInfo[]
      if (cached.length) return cached
    } catch { /* ignore */ }
    const configured = (import.meta.env?.VITE_BOOTSTRAP as string | undefined ?? '').split(',').map((s) => s.trim()).filter(Boolean)
    return configured.map((addr) => ({ peerId: addr.split('/p2p/').pop() ?? '', addrs: [addr] }))
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return
    const delay = this.reconnectDelay * (0.75 + Math.random() * 0.5)
    this.reconnectDelay = Math.min(30_000, this.reconnectDelay * 2)
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined
      void this.connect()
    }, delay)
  }

  async connect() {
    const libp2p = this.libp2p
    if (!libp2p) return
    if (this.connectedNodes.size === 0) this.state.status = 'connecting'
    this.bootstrap = await this.loadBootstrap()
    await Promise.all(this.bootstrap.map(async (info) => {
      if (this.connectedNodes.has(info.peerId)) return
      const addrs = wsAddrs(info.addrs)
      if (!addrs.length) return
      try {
        await libp2p.dial(addrs, { signal: AbortSignal.timeout(10_000) })
        this.connectedNodes.set(info.peerId, info)
      } catch (error) {
        console.warn('node dial failed', info.peerId, error)
      }
    }))
    this.state.nodes = [...this.connectedNodes.keys()]
    if (this.connectedNodes.size === 0) {
      this.state.status = 'offline'
      this.scheduleReconnect()
      return
    }
    this.reconnectDelay = 1000
    this.state.status = 'online'
    await Promise.all([this.loadSnapshot(), this.loadMeta()])
    this.provided.clear()
    await this.announce()
    void this.provideAll()
  }

  private async loadMeta() {
    try {
      const [ice, who] = await Promise.all([
        fetch(`${this.nodeURL}/api/ice`).then((r) => r.json()) as Promise<{ iceServers: RTCIceServer[] }>,
        fetch(`${this.nodeURL}/api/whoami`).then((r) => r.json()) as Promise<{ region: string }>,
      ])
      if (ice.iceServers?.length) this.ice = ice.iceServers
      this.state.region = who.region ?? ''
    } catch { /* keep defaults */ }
  }

  private async loadSnapshot() {
    for (const id of this.connectedNodes.keys()) {
      try {
        const stream = await this.libp2p!.dialProtocol(peerIdFromString(id), SNAPSHOT_PROTO, { signal: AbortSignal.timeout(10_000) })
        const lp = lpStream(stream, { maxDataLength: 4 * 1024 * 1024 })
        const data = await lp.read({ signal: AbortSignal.timeout(10_000) })
        const items = JSON.parse(decoder.decode(data.subarray())) as { envelope: Envelope; offline: boolean }[]
        await Promise.all(items.map((item) => this.applyEnvelope(item.envelope, item.offline)))
        return
      } catch (error) {
        console.warn('snapshot failed', error)
      }
    }
  }

  // ---- plaza ----

  private async applyEnvelope(env: Envelope, offline = false) {
    let body: PlazaBody
    try { body = await verifyEnvelope(env) } catch { return }
    if (body.peerId === this.state.peerId) return
    const current = this.state.entries[body.peerId]
    if (current && current.body.seq >= body.seq) return
    if (body.bye) {
      delete this.state.entries[body.peerId]
      return
    }
    this.state.entries[body.peerId] = { body, offline, lastSeen: offline ? Date.now() - ENTRY_TTL : Date.now() }
  }

  private sweep() {
    const now = Date.now()
    for (const [id, entry] of Object.entries(this.state.entries)) {
      const age = now - entry.lastSeen
      if (age >= ENTRY_TTL + OFFLINE_RETENTION) delete this.state.entries[id]
      else if (age >= ENTRY_TTL && !entry.offline) entry.offline = true
    }
  }

  private via(): string[] {
    const result: string[] = []
    for (const info of this.connectedNodes.values()) {
      for (const addr of info.addrs.slice(0, 4)) result.push(addr.includes('/p2p/') ? addr : `${addr}/p2p/${info.peerId}`)
    }
    return result.slice(0, 8)
  }

  async announce(bye = false) {
    if (!this.libp2p || !this.key || (this.connectedNodes.size === 0 && !bye)) return
    const files: PlazaFile[] = [...this.sources.values()].map((s) => ({
      cid: s.manifest.cid, name: s.name, size: s.manifest.size, sha256: s.manifest.sha256, kind: 'upload', mime: s.mime || undefined,
    }))
    const body: PlazaBody = { v: 1, peerId: this.state.peerId, name: this.state.name, region: this.state.region || undefined,
      client: 'web', via: this.via(), files: bye ? [] : files, seq: Date.now(), bye: bye || undefined }
    try {
      const env = await signEnvelope(this.key, body)
      await this.libp2p.services.pubsub.publish(PLAZA_TOPIC, encoder.encode(JSON.stringify(env)))
    } catch (error) {
      console.warn('announce failed', error)
    }
  }

  // ---- uploads (manual publish) ----

  async addUpload(file: File) {
    const entry: UploadEntry = reactive({ cid: '', name: file.name, size: file.size, serving: 0, hashing: 0 })
    this.state.uploads.unshift(entry)
    try {
      const manifest = await manifestOf(file, (f) => { entry.hashing = f })
      if (this.sources.has(manifest.cid)) {
        this.state.uploads.splice(this.state.uploads.indexOf(entry), 1)
        return
      }
      entry.cid = manifest.cid
      entry.hashing = undefined
      this.sources.set(manifest.cid, { blob: file, manifest, name: file.name.replace(/[/\\]/g, '_'), mime: file.type })
      await this.announce()
      void this.provideAll()
    } catch (error) {
      this.state.uploads.splice(this.state.uploads.indexOf(entry), 1)
      this.state.error = `无法分享文件：${(error as Error).message}`
    }
  }

  removeUpload(cid: string) {
    this.sources.delete(cid)
    this.provided.delete(cid)
    this.state.uploads = this.state.uploads.filter((u) => u.cid !== cid)
    void this.announce()
  }

  /** PROVIDE: announce "I have this CID" to the DHT nodes closest to its hash. */
  private async provideAll() {
    const libp2p = this.libp2p
    if (!libp2p || this.connectedNodes.size === 0) return
    if (!libp2p.getMultiaddrs().some((a) => a.toString().includes('/p2p-circuit'))) return
    for (const cid of this.sources.keys()) {
      if (this.provided.has(cid)) continue
      this.provided.add(cid)
      libp2p.contentRouting.provide(parseContentCID(cid), { signal: AbortSignal.timeout(60_000) })
        .catch((error: unknown) => {
          this.provided.delete(cid)
          console.warn('provide failed', cid, error)
        })
    }
  }

  // ---- discovery ----

  /** GET_PROVIDERS for the CID, expanding node providers into the terminals they front. */
  async findCandidates(cid: string): Promise<Candidate[]> {
    const libp2p = this.libp2p!
    const seen = new Set<string>([this.state.peerId])
    const result: Candidate[] = []
    const add = (c: Candidate) => {
      if (!seen.has(c.peerId) && c.node) { seen.add(c.peerId); result.push(c) }
    }
    for (const entry of Object.values(this.state.entries)) {
      if (!entry.offline && entry.body.files.some((f) => f.cid === cid)) {
        const node = entry.body.via[0]?.split('/p2p/').pop() ?? ''
        add({ peerId: entry.body.peerId, node, nodeAddrs: entry.body.via.filter((a) => a.endsWith(node)) })
      }
    }
    try {
      const jobs: Promise<void>[] = []
      for await (const provider of libp2p.contentRouting.findProviders(parseContentCID(cid), { signal: AbortSignal.timeout(15_000) })) {
        const addrs = provider.multiaddrs.map((a) => a.toString())
        const circuit = addrs.find((a) => a.includes('/p2p-circuit'))
        if (circuit) {
          const relayAddr = circuit.split('/p2p-circuit')[0]
          add({ peerId: provider.id.toString(), node: relayAddr.split('/p2p/').pop() ?? '', nodeAddrs: [relayAddr] })
        } else if (provider.id.toString() !== this.state.peerId) {
          jobs.push(this.resolve(provider.id.toString(), addrs, cid).then((peers) => {
            const nodeAddrs = addrs.map((a) => (a.includes('/p2p/') ? a : `${a}/p2p/${provider.id}`))
            for (const peerId of peers) add({ peerId, node: provider.id.toString(), nodeAddrs })
          }).catch(() => undefined))
        }
      }
      await Promise.all(jobs)
    } catch (error) {
      console.warn('findProviders ended', error)
    }
    return result
  }

  private async resolve(nodeId: string, addrs: string[], cid: string): Promise<string[]> {
    const target = this.connectedNodes.has(nodeId) || !wsAddrs(addrs).length ? peerIdFromString(nodeId) : wsAddrs(addrs)
    const stream = await this.libp2p!.dialProtocol(target, RESOLVE_PROTO, { signal: AbortSignal.timeout(10_000) })
    const reply = await request<{ peers: string[] }>(stream, { cid })
    return (reply.peers ?? []).slice(0, 64)
  }

  // ---- signalling ----

  private async sendSignal(sig: Signal): Promise<void> {
    const libp2p = this.libp2p!
    const home = [...this.connectedNodes.values()][0]
    sig.fromNode = home?.peerId
    sig.fromNodeAddrs = home?.addrs.slice(0, 4).map((a) => (a.includes('/p2p/') ? a : `${a}/p2p/${home.peerId}`))
    const node = sig.node ?? ''
    const target = this.connectedNodes.has(node) ? peerIdFromString(node) : wsAddrs(sig.nodeAddrs ?? [])
    if (Array.isArray(target) && !target.length) throw new Error('无法连接到对方所在节点')
    const stream = await libp2p.dialProtocol(target, SIGNAL_PROTO, { signal: AbortSignal.timeout(10_000) })
    const reply = await request<{ ok?: boolean; error?: string }>(stream, sig)
    if (reply.error) throw new Error(reply.error === 'unreachable' ? '对方已离线' : reply.error)
  }

  private async onSignalStream(stream: Stream, remote: string) {
    const lp = lpStream(stream)
    try {
      const data = await lp.read({ signal: AbortSignal.timeout(10_000) })
      const sig = JSON.parse(decoder.decode(data.subarray())) as Signal
      // Only nodes may relay signals for other peers.
      if (!this.connectedNodes.has(remote) && sig.from !== remote) sig.from = remote
      await lp.write(encoder.encode(JSON.stringify({ ok: true })))
      await stream.close()
      this.onSignal(sig)
    } catch {
      stream.abort(new Error('bad signal'))
    }
  }

  private onSignal(sig: Signal) {
    if (sig.kind === 'answer') {
      this.pendingAnswers.get(sig.session)?.(sig)
      return
    }
    if (sig.kind === 'offer' && sig.sdp && sig.from) void this.answer(sig)
  }

  private async answer(offer: Signal) {
    if (this.serving >= MAX_UPLOADS) return
    const pc = new RTCPeerConnection({ iceServers: this.ice })
    this.serving++
    let released = false
    const release = () => {
      if (released) return
      released = true
      this.serving--
      pc.close()
    }
    pc.addEventListener('connectionstatechange', () => {
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') release()
    })
    setTimeout(() => { if (pc.connectionState !== 'connected') release() }, 30_000)
    pc.addEventListener('datachannel', (evt) => {
      const ch = evt.channel
      if (ch.label !== CHANNEL_LABEL) { ch.close(); return }
      const start = () => {
        let upload: UploadEntry | undefined
        serveChannel(ch, (cid) => {
          upload = this.state.uploads.find((u) => u.cid === cid)
          if (upload) upload.serving++
          return this.sources.get(cid)
        }).catch((error: unknown) => console.warn('upload ended', error))
          .finally(() => {
            if (upload) upload.serving--
            setTimeout(release, 1000)
          })
      }
      if (ch.readyState === 'open') start()
      else ch.addEventListener('open', start, { once: true })
    })
    try {
      await pc.setRemoteDescription({ type: 'offer', sdp: offer.sdp })
      await pc.setLocalDescription(await pc.createAnswer())
      await gathered(pc)
      await this.sendSignal({ to: offer.from!, node: offer.fromNode, nodeAddrs: offer.fromNodeAddrs,
        session: offer.session, kind: 'answer', sdp: pc.localDescription!.sdp })
    } catch (error) {
      console.warn('answer failed', error)
      release()
    }
  }

  /** Offer → answer over the nodes, then open the file channel directly. */
  private async connectTo(candidate: Candidate): Promise<{ pc: RTCPeerConnection; channel: RTCDataChannel }> {
    const pc = new RTCPeerConnection({ iceServers: this.ice })
    const channel = pc.createDataChannel(CHANNEL_LABEL, { ordered: true })
    const session = crypto.randomUUID()
    try {
      await pc.setLocalDescription(await pc.createOffer())
      await gathered(pc)
      const answered = new Promise<Signal>((resolve, reject) => {
        const timer = setTimeout(() => { this.pendingAnswers.delete(session); reject(new Error('对方未应答')) }, 20_000)
        this.pendingAnswers.set(session, (sig) => {
          clearTimeout(timer)
          this.pendingAnswers.delete(session)
          resolve(sig)
        })
      })
      await this.sendSignal({ to: candidate.peerId, node: candidate.node, nodeAddrs: candidate.nodeAddrs, session,
        kind: 'offer', sdp: pc.localDescription!.sdp })
      const answer = await answered
      if (answer.from !== candidate.peerId) throw new Error('应答来源不符')
      await pc.setRemoteDescription({ type: 'answer', sdp: answer.sdp })
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('点对点连接超时（可能需要 TURN）')), 20_000)
        channel.addEventListener('open', () => { clearTimeout(timer); resolve() }, { once: true })
        pc.addEventListener('connectionstatechange', () => {
          if (pc.connectionState === 'failed') { clearTimeout(timer); reject(new Error('点对点连接失败')) }
        })
      })
      return { pc, channel }
    } catch (error) {
      pc.close()
      throw error
    }
  }

  // ---- downloads with resume across network changes ----

  async download(cid: string, hint?: { name?: string; size?: number; from?: string }) {
    try { sha256FromCID(cid) } catch (error) {
      this.state.error = (error as Error).message
      return
    }
    if (this.state.downloads.some((d) => d.cid === cid && d.state === 'running')) return
    const task: DownloadTask = reactive({ id: crypto.randomUUID(), cid, name: hint?.name ?? cid.slice(0, 16), size: hint?.size ?? 0,
      from: hint?.from, progress: 0, status: '查找提供者…', state: 'running' as const })
    this.state.downloads.unshift(task)
    const assembly = new Assembly(cid)
    const deadline = Date.now() + 10 * 60_000
    let delay = 1000
    while (task.state === 'running' && Date.now() < deadline) {
      if (this.state.status !== 'online') {
        task.status = '网络断开，等待重连…'
        await sleep(2000, this.online)
        continue
      }
      task.status = 'DHT 查询提供者（GET_PROVIDERS）…'
      const candidates = await this.findCandidates(cid)
      if (!candidates.length) task.status = '暂无在线提供者，稍后重试…'
      for (const candidate of candidates) {
        if (task.state !== 'running' || this.canceled.has(task.id)) break
        let pc: RTCPeerConnection | undefined
        try {
          task.status = `连接 ${candidate.peerId.slice(-8)}…`
          const link = await this.connectTo(candidate)
          pc = link.pc
          pc.addEventListener('connectionstatechange', () => {
            if (pc && (pc.connectionState === 'disconnected' || pc.connectionState === 'failed')) {
              // A network switch kills ICE; abort and resume from the verified block.
              setTimeout(() => { if (pc && pc.connectionState !== 'connected') link.channel.close() }, 4000)
            }
          })
          task.status = '点对点传输中'
          const blob = await receiveChannel(link.channel, assembly, (got, total) => {
            task.size = total
            task.progress = total ? got / total : 1
            if (this.canceled.has(task.id)) link.channel.close()
          })
          task.name = assembly.meta?.name || task.name
          task.url = URL.createObjectURL(blob)
          task.progress = 1
          task.state = 'complete'
          task.status = '已完成，SHA-256 校验通过'
          pc.close()
          return
        } catch (error) {
          pc?.close()
          if (this.canceled.has(task.id)) break
          task.status = `${(error as Error).message}，将从 ${(assembly.verified / 1048576).toFixed(0)} MB 处续传`
        }
      }
      if (this.canceled.has(task.id)) break
      await sleep(delay * (0.75 + Math.random() * 0.5), this.online)
      delay = Math.min(30_000, delay * 2)
    }
    if (this.canceled.has(task.id)) {
      task.state = 'canceled'
      task.status = '已取消'
    } else if (task.state === 'running') {
      task.state = 'failed'
      task.status = '下载失败：提供者长时间不可达'
    }
  }

  cancel(id: string) { this.canceled.add(id) }
}
