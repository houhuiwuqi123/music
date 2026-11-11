// Protocol tests for the DataChannel file transfer, using an in-memory channel pair.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { manifestOf, cidFromSha256, BLOCK_SIZE } from '../src/lib/content.ts'
import { Assembly, receiveChannel, serveChannel, type FileChannel, type SourceFile } from '../src/lib/transfer.ts'

class FakeChannel extends EventTarget implements FileChannel {
  readyState = 'open'
  bufferedAmount = 0
  bufferedAmountLowThreshold = 0
  binaryType = 'arraybuffer'
  peer?: FakeChannel
  sent = 0
  breakAfter = Infinity // bytes of binary data before the "network" drops
  corruptAt = -1
  send(data: string | ArrayBuffer | ArrayBufferView<ArrayBuffer>) {
    if (this.readyState !== 'open') throw new Error('closed')
    let payload: unknown = data
    if (typeof data !== 'string') {
      const bytes = new Uint8Array(ArrayBuffer.isView(data) ? data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) : data)
      if (this.sent <= this.corruptAt && this.corruptAt < this.sent + bytes.length) bytes[this.corruptAt - this.sent] ^= 0xff
      this.sent += bytes.length
      payload = bytes.buffer
      if (this.sent > this.breakAfter) {
        queueMicrotask(() => { this.close() })
        return
      }
    }
    const target = this.peer!
    queueMicrotask(() => target.dispatchEvent(Object.assign(new Event('message'), { data: payload })))
  }
  close() {
    for (const ch of [this, this.peer!]) {
      if (ch.readyState === 'closed') continue
      ch.readyState = 'closed'
      queueMicrotask(() => ch.dispatchEvent(new Event('close')))
    }
  }
}

function pair(): [FakeChannel, FakeChannel] {
  const a = new FakeChannel()
  const b = new FakeChannel()
  a.peer = b
  b.peer = a
  return [a, b]
}

async function source(size: number): Promise<SourceFile> {
  const bytes = new Uint8Array(size)
  for (let i = 0; i < size; i++) bytes[i] = (i * 7 + (i >> 11)) & 0xff
  const blob = new Blob([bytes])
  return { blob, manifest: await manifestOf(blob), name: 'song.flac', mime: 'audio/flac' }
}

test('CID matches the Go and Swift vector', () => {
  const hex = createHash('sha256').update('hello').digest('hex')
  assert.equal(cidFromSha256(hex), 'bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq')
})

for (const size of [0, 1, BLOCK_SIZE, 3 * BLOCK_SIZE + 12345]) {
  test(`transfers ${size} bytes with block and whole-file verification`, async () => {
    const file = await source(size)
    const [s, r] = pair()
    const served = serveChannel(s, (cid) => (cid === file.manifest.cid ? file : undefined))
    const blob = await receiveChannel(r, new Assembly(file.manifest.cid))
    await served
    assert.equal(blob.size, size)
    assert.equal(createHash('sha256').update(new Uint8Array(await blob.arrayBuffer())).digest('hex'), file.manifest.sha256)
  })
}

test('resumes from the last verified block after the link drops (network switch)', async () => {
  const file = await source(5 * BLOCK_SIZE + 999)
  const assembly = new Assembly(file.manifest.cid)
  const [s1, r1] = pair()
  s1.breakAfter = 2 * BLOCK_SIZE + 300_000
  const lookup = (cid: string) => (cid === file.manifest.cid ? file : undefined)
  const first = serveChannel(s1, lookup).catch(() => 'broken')
  await assert.rejects(receiveChannel(r1, assembly))
  assert.equal(await first, 'broken')
  assert.equal(assembly.verified, 2 * BLOCK_SIZE)
  const [s2, r2] = pair()
  let requested = -1
  r2.send = ((orig) => function (this: FakeChannel, data: Parameters<FakeChannel['send']>[0]) {
    if (typeof data === 'string' && JSON.parse(data).t === 'get') requested = JSON.parse(data).offset
    orig.call(this, data)
  })(r2.send)
  const second = serveChannel(s2, lookup)
  const blob = await receiveChannel(r2, assembly)
  await second
  assert.equal(requested, 2 * BLOCK_SIZE)
  assert.equal(createHash('sha256').update(new Uint8Array(await blob.arrayBuffer())).digest('hex'), file.manifest.sha256)
})

test('rejects a corrupted block before accepting more data', async () => {
  const file = await source(3 * BLOCK_SIZE)
  const [s, r] = pair()
  s.corruptAt = BLOCK_SIZE + 5
  const assembly = new Assembly(file.manifest.cid)
  void serveChannel(s, () => file).catch(() => undefined)
  await assert.rejects(receiveChannel(r, assembly), /第 2 块校验失败/)
  assert.equal(assembly.verified, BLOCK_SIZE)
})

test('unknown CID is refused', async () => {
  const file = await source(10)
  const [s, r] = pair()
  void serveChannel(s, () => undefined)
  await assert.rejects(receiveChannel(r, new Assembly(file.manifest.cid)), /not-found/)
})

test('Ed25519 seed 0x00..0x1f peer ID matches the Go and Swift vector', async () => {
  const { generateKeyPairFromSeed } = await import('@libp2p/crypto/keys')
  const { peerIdFromPrivateKey } = await import('@libp2p/peer-id')
  const key = await generateKeyPairFromSeed('Ed25519', Uint8Array.from({ length: 32 }, (_, i) => i))
  assert.equal(peerIdFromPrivateKey(key).toString(), '12D3KooWA4Xop1JaT3MHxwYMkCepYsv4iPVopMXwCz5iHYdBfeSB')
})
