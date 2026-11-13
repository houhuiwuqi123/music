// AURU file protocol over one ordered, reliable RTCDataChannel ("auru-file/1").
// Shared byte-for-byte with CandyReliableTransfer.swift:
//   R→S  {"t":"get","cid":C,"offset":N}            N is a multiple of BLOCK_SIZE
//   S→R  {"t":"meta","cid","size","name","mime","blockSize","blocks":[hex…]}
//        | {"t":"error","error":"not-found"|"busy"|"bad-request"}
//   S→R  binary chunks (≤ CHUNK_SIZE) covering [N, size) in order
//   S→R  {"t":"end"}
//   R→S  {"t":"done"} | {"t":"error","error":…}
// The receiver verifies each block against `blocks`, then the whole file
// against the SHA-256 inside the CID it asked for, before accepting it.
import { sha256 } from '@noble/hashes/sha2.js'
import { BLOCK_SIZE, CHUNK_SIZE, sha256FromCID, toHex, type Manifest } from './content.ts'

export const CHANNEL_LABEL = 'auru-file/1'
const HIGH_WATER = 8 * 1024 * 1024
const LOW_WATER = 1024 * 1024

/** The subset of RTCDataChannel the protocol needs (so tests can fake it). */
export interface FileChannel extends EventTarget {
  readonly readyState: string
  readonly bufferedAmount: number
  bufferedAmountLowThreshold: number
  binaryType: string
  send(data: string | ArrayBuffer | ArrayBufferView<ArrayBuffer>): void
  close(): void
}

export interface SourceFile {
  blob: Blob
  manifest: Manifest
  name: string
  mime: string
}

interface Meta {
  t: 'meta'
  cid: string
  size: number
  name: string
  mime: string
  blockSize: number
  blocks: string[]
}

class Inbox {
  private queue: unknown[] = []
  private waiter?: (v: unknown) => void
  private failure?: Error
  constructor(ch: FileChannel) {
    ch.addEventListener('message', (ev) => this.push((ev as MessageEvent).data))
    ch.addEventListener('close', () => this.fail(new Error('文件通道已关闭')))
  }
  push(value: unknown) {
    if (this.waiter) {
      const w = this.waiter
      this.waiter = undefined
      w(value)
    } else this.queue.push(value)
  }
  fail(error: Error) {
    this.failure ??= error
    this.push(undefined)
  }
  async next(timeoutMs = 30_000): Promise<unknown> {
    if (this.queue.length) return this.queue.shift()
    if (this.failure) throw this.failure
    const value = await new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiter = undefined
        reject(new Error('对方长时间无响应'))
      }, timeoutMs)
      this.waiter = (v) => {
        clearTimeout(timer)
        resolve(v)
      }
    })
    if (value === undefined && this.failure) throw this.failure
    return value
  }
}

function text(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== 'string') return undefined
  try {
    const parsed = JSON.parse(value)
    return typeof parsed === 'object' && parsed ? parsed : undefined
  } catch {
    return undefined
  }
}

function drained(ch: FileChannel): Promise<void> {
  if (ch.bufferedAmount <= HIGH_WATER) return Promise.resolve()
  return new Promise((resolve, reject) => {
    const low = () => {
      cleanup()
      resolve()
    }
    const closed = () => {
      cleanup()
      reject(new Error('文件通道已关闭'))
    }
    const cleanup = () => {
      ch.removeEventListener('bufferedamountlow', low)
      ch.removeEventListener('close', closed)
    }
    ch.addEventListener('bufferedamountlow', low)
    ch.addEventListener('close', closed)
  })
}

/** Sender side: answers one "get" on the channel. */
export async function serveChannel(ch: FileChannel, lookup: (cid: string) => SourceFile | undefined,
  onProgress?: (sent: number, total: number) => void): Promise<void> {
  ch.binaryType = 'arraybuffer'
  ch.bufferedAmountLowThreshold = LOW_WATER
  const inbox = new Inbox(ch)
  const request = text(await inbox.next())
  if (request?.t !== 'get' || typeof request.cid !== 'string' || typeof request.offset !== 'number') {
    ch.send(JSON.stringify({ t: 'error', error: 'bad-request' }))
    return
  }
  const source = lookup(request.cid)
  const offset = request.offset
  if (!source) {
    ch.send(JSON.stringify({ t: 'error', error: 'not-found' }))
    return
  }
  const { manifest } = source
  if (offset < 0 || offset > manifest.size || offset % BLOCK_SIZE !== 0) {
    ch.send(JSON.stringify({ t: 'error', error: 'bad-request' }))
    return
  }
  const meta: Meta = { t: 'meta', cid: manifest.cid, size: manifest.size, name: source.name, mime: source.mime,
    blockSize: BLOCK_SIZE, blocks: manifest.blocks }
  ch.send(JSON.stringify(meta))
  for (let position = offset; position < manifest.size; position += BLOCK_SIZE) {
    const block = new Uint8Array(await source.blob.slice(position, Math.min(manifest.size, position + BLOCK_SIZE)).arrayBuffer())
    for (let i = 0; i < block.length; i += CHUNK_SIZE) {
      await drained(ch)
      if (ch.readyState !== 'open') throw new Error('文件通道已关闭')
      ch.send(block.slice(i, i + CHUNK_SIZE))
    }
    onProgress?.(Math.min(manifest.size, position + BLOCK_SIZE), manifest.size)
  }
  ch.send(JSON.stringify({ t: 'end' }))
  const reply = text(await inbox.next(120_000))
  if (reply?.t !== 'done') throw new Error(`接收方未确认：${String(reply?.error ?? 'unknown')}`)
}

/** Verified data that survives reconnects; a retry resumes at `verified`. */
export class Assembly {
  parts: Blob[] = []
  verified = 0
  meta?: Meta
  /** Called after each verified block is appended (used by 听听看 to stream). */
  onBlock?: () => void
  private whole = sha256.create()
  readonly cid: string
  constructor(cid: string) { this.cid = cid }

  reset() {
    this.parts = []
    this.verified = 0
    this.meta = undefined
    this.whole = sha256.create()
  }

  accept(meta: Meta) {
    const expectedBlocks = Math.ceil(meta.size / BLOCK_SIZE)
    if (meta.cid !== this.cid || meta.blockSize !== BLOCK_SIZE || !Array.isArray(meta.blocks) ||
        meta.blocks.length !== expectedBlocks || !(meta.size >= 0) || meta.size > 4 * 1024 ** 3) {
      throw new Error('对方返回的文件描述无效')
    }
    if (this.meta && (this.meta.size !== meta.size || this.meta.blocks.join() !== meta.blocks.join())) this.reset()
    this.meta = meta
  }

  /** Appends one complete block after checking its hash. */
  addBlock(index: number, block: Uint8Array) {
    if (!this.meta || index !== this.verified / BLOCK_SIZE) throw new Error('数据块顺序错误')
    if (toHex(sha256(block)) !== this.meta.blocks[index]) throw new Error(`第 ${index + 1} 块校验失败`)
    this.whole.update(block)
    this.parts.push(new Blob([block as Uint8Array<ArrayBuffer>]))
    this.verified += block.length
    this.onBlock?.()
  }

  finish(): Blob {
    if (!this.meta || this.verified !== this.meta.size) throw new Error('文件不完整')
    if (toHex(this.whole.clone().digest()) !== sha256FromCID(this.cid)) throw new Error('整文件 SHA-256 与 CID 不符')
    return new Blob(this.parts, { type: this.meta.mime || 'application/octet-stream' })
  }
}

/** Receiver side: requests from `assembly.verified` and streams until verified end. */
export async function receiveChannel(ch: FileChannel, assembly: Assembly,
  onProgress?: (received: number, total: number) => void): Promise<Blob> {
  try {
    return await receive(ch, assembly, onProgress)
  } catch (error) {
    // Tell the sender to stop instead of leaving it waiting for "done".
    if (ch.readyState === 'open') {
      try { ch.send(JSON.stringify({ t: 'error', error: 'aborted' })) } catch { /* closing anyway */ }
      ch.close()
    }
    throw error
  }
}

async function receive(ch: FileChannel, assembly: Assembly,
  onProgress?: (received: number, total: number) => void): Promise<Blob> {
  ch.binaryType = 'arraybuffer'
  const inbox = new Inbox(ch)
  ch.send(JSON.stringify({ t: 'get', cid: assembly.cid, offset: assembly.verified }))
  const first = text(await inbox.next())
  if (first?.t === 'error') throw new Error(`对方拒绝：${String(first.error)}`)
  if (first?.t !== 'meta') throw new Error('对方协议不兼容')
  assembly.accept(first as unknown as Meta)
  const size = assembly.meta!.size
  let block = new Uint8Array(Math.min(BLOCK_SIZE, size - assembly.verified))
  let filled = 0
  onProgress?.(assembly.verified, size)
  while (true) {
    const message = await inbox.next()
    if (typeof message === 'string') {
      const control = text(message)
      if (control?.t === 'end') break
      throw new Error(`传输被中止：${String(control?.error ?? 'unknown')}`)
    }
    const bytes = new Uint8Array(message as ArrayBuffer)
    if (assembly.verified + filled + bytes.length > size || bytes.length > CHUNK_SIZE * 4) throw new Error('收到越界数据')
    let consumed = 0
    while (consumed < bytes.length) {
      const take = Math.min(block.length - filled, bytes.length - consumed)
      block.set(bytes.subarray(consumed, consumed + take), filled)
      filled += take
      consumed += take
      if (filled === block.length) {
        assembly.addBlock(assembly.verified / BLOCK_SIZE, block)
        filled = 0
        block = new Uint8Array(Math.min(BLOCK_SIZE, size - assembly.verified))
        onProgress?.(assembly.verified, size)
      }
    }
  }
  try {
    const blob = assembly.finish()
    ch.send(JSON.stringify({ t: 'done' }))
    return blob
  } catch (error) {
    assembly.reset()
    throw error
  }
}
