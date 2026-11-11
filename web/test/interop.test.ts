// End-to-end interop: the real Go node binary, the real browser PlazaNetwork
// (js-libp2p, running in Node), and an emulated iOS gateway terminal.
// Covers: bootstrap list, GossipSub plaza in both directions, browser PROVIDE
// via circuit address, delegated PROVIDE for iOS, GET_PROVIDERS + resolve,
// and SDP signalling both ways. Run: node --test test/interop.test.ts
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawn, execFileSync, type ChildProcess } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { generateKeyPair } from '@libp2p/crypto/keys'
import { peerIdFromPrivateKey } from '@libp2p/peer-id'
import type { PrivateKey } from '@libp2p/interface'
import { PlazaNetwork, type Signal } from '../src/lib/network.ts'
import { signEnvelope, b64, type PlazaBody } from '../src/lib/plaza.ts'
import { cidFromSha256, manifestOf } from '../src/lib/content.ts'

const HTTP = 18000 + Math.floor(Math.random() * 1000)
const WS = HTTP + 1000
const base = `http://127.0.0.1:${HTTP}`
let node: ChildProcess

async function waitFor<T>(check: () => T | undefined | false | Promise<T | undefined | false>, what: string, ms = 30_000): Promise<T> {
  const end = Date.now() + ms
  while (Date.now() < end) {
    const value = await check()
    if (value) return value
    await new Promise((r) => setTimeout(r, 200))
  }
  throw new Error(`timeout: ${what}`)
}

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'auru-node-'))
  const exe = join(dir, process.platform === 'win32' ? 'node.exe' : 'node')
  execFileSync('go', ['build', '-o', exe, '.'], { cwd: join(import.meta.dirname, '..', '..', 'backend'), stdio: 'inherit' })
  node = spawn(exe, ['-http', `127.0.0.1:${HTTP}`, '-key', '', '-listen', `/ip4/127.0.0.1/tcp/${WS}/ws`], { stdio: 'inherit' })
  await waitFor(() => fetch(`${base}/api/bootstrap`).then((r) => r.ok).catch(() => false), 'node http')
})

after(() => { node?.kill() })

/** Minimal iOS-side gateway client, same JSON protocol as CandyDHTGateway.swift. */
class Terminal {
  ws!: WebSocket
  key!: PrivateKey
  id = ''
  via: string[] = []
  nodeId = ''
  inbox: Record<string, unknown>[] = []
  async open() {
    this.key = await generateKeyPair('Ed25519')
    this.ws = new WebSocket(`ws://127.0.0.1:${HTTP}/ws`)
    this.ws.addEventListener('message', (e) => this.inbox.push(JSON.parse(String(e.data))))
    const challenge = await this.next('challenge') as { nonce: string; node: { peerId: string } }
    const sig = await this.key.sign(new TextEncoder().encode(`auru-node-auth:${challenge.nonce}:${challenge.node.peerId}`))
    this.ws.send(JSON.stringify({ type: 'hello', publicKey: b64(this.key.publicKey.raw), signature: b64(sig) }))
    const welcome = await this.next('welcome') as { peerId: string; node: { peerId: string; addrs: string[] } }
    this.id = welcome.peerId
    this.via = welcome.node.addrs
    this.nodeId = welcome.node.peerId
    assert.equal(this.id, peerIdFromPrivateKey(this.key).toString(), 'gateway derives the libp2p peer ID')
  }
  async next(type: string, match: (m: Record<string, unknown>) => boolean = () => true) {
    return waitFor(() => {
      const index = this.inbox.findIndex((m) => m.type === type && match(m))
      return index >= 0 ? this.inbox.splice(index, 1)[0] : undefined
    }, `terminal ${type}`)
  }
  send(value: unknown) { this.ws.send(JSON.stringify(value)) }
}

test('browser ↔ node ↔ iOS terminal', { timeout: 120_000 }, async () => {
  const web = new PlazaNetwork({ nodeURL: base })
  const answers: Signal[] = []
  // Node has no RTCPeerConnection: answer offers with a placeholder SDP over the real signalling path.
  const internals = web as unknown as { answer(sig: Signal): Promise<void>; sendSignal(sig: Signal): Promise<void> }
  internals.answer = async (offer) => {
    answers.push(offer)
    await internals.sendSignal({ to: offer.from!, node: offer.fromNode, nodeAddrs: offer.fromNodeAddrs, session: offer.session,
      kind: 'answer', sdp: 'v=0 web-answer' })
  }
  await web.start()
  assert.equal(web.state.status, 'online')

  const ios = new Terminal()
  await ios.open()

  // iOS announces the song it is listening to; the browser receives it over GossipSub.
  const sha = 'a'.repeat(64)
  const fileCID = cidFromSha256(sha)
  const body: PlazaBody = { v: 1, peerId: ios.id, name: '游客1234', client: 'ios', via: ios.via,
    listening: { title: '晴天', artist: '周杰伦', isPlaying: true },
    files: [{ cid: fileCID, name: 'song.mp3', size: 4096, sha256: sha, kind: 'listening' }], seq: Date.now() }
  ios.send({ type: 'announce', id: 'a1', envelope: await signEnvelope(ios.key, body) })
  await ios.next('announced')
  const entry = await waitFor(() => web.state.entries[ios.id], 'browser sees iOS listening entry')
  assert.equal(entry.body.listening?.title, '晴天')

  // GET_PROVIDERS from the browser (DHT path only): node provides on behalf of iOS, resolve expands it.
  delete web.state.entries[ios.id]
  const candidates = await web.findCandidates(fileCID)
  assert.deepEqual(candidates.map((c) => [c.peerId, c.node]), [[ios.id, ios.nodeId]])

  // Browser manual upload: hashed, announced and PROVIDEd with its circuit address.
  const upload = new File([new TextEncoder().encode('browser shared bytes')], 'demo.txt', { type: 'text/plain' })
  const manifest = await manifestOf(upload)
  await web.addUpload(upload)
  const update = await ios.next('plaza-update', (m) => (m.entry as PlazaBody).peerId === web.state.peerId) as { entry: PlazaBody }
  assert.equal(update.entry.files[0].cid, manifest.cid)
  assert.equal(update.entry.client, 'web')
  const found = await waitFor(async () => {
    ios.send({ type: 'find', id: 'f1', cid: manifest.cid })
    const reply = await ios.next('providers', (m) => m.id === 'f1') as { providers: { peerId: string; node: string; nodeAddrs: string[] }[] }
    return reply.providers.find((p) => p.peerId === web.state.peerId)
  }, 'iOS finds the browser through GET_PROVIDERS')
  assert.equal(found.node, ios.nodeId)

  // iOS → browser offer, browser → iOS answer, both routed by the node.
  ios.send({ type: 'signal', signal: { to: found.peerId, node: found.node, nodeAddrs: found.nodeAddrs, session: 's1', kind: 'offer', sdp: 'v=0 ios-offer' } })
  await waitFor(() => answers.length > 0, 'browser receives offer')
  assert.equal(answers[0].from, ios.id)
  assert.equal(answers[0].sdp, 'v=0 ios-offer')
  const answer = await ios.next('signal') as { signal: Signal }
  assert.equal(answer.signal.from, web.state.peerId)
  assert.equal(answer.signal.sdp, 'v=0 web-answer')

  ios.ws.close()
  await web.stop()
})
