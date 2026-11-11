// Content addressing shared with the Go node and the iOS app:
// CID = CIDv1(raw 0x55, sha2-256 multihash of the whole file), base32 "bafkrei…".
import { CID } from 'multiformats/cid'
import * as raw from 'multiformats/codecs/raw'
import { create as createDigest } from 'multiformats/hashes/digest'
import { sha256 } from '@noble/hashes/sha2.js'

export const BLOCK_SIZE = 1024 * 1024 // verification granularity
export const CHUNK_SIZE = 64 * 1024 // DataChannel message size

export function toHex(bytes: Uint8Array): string {
  let out = ''
  for (const b of bytes) out += b.toString(16).padStart(2, '0')
  return out
}

export function fromHex(hex: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error('sha256 must be 64 lowercase hex characters')
  const out = new Uint8Array(32)
  for (let i = 0; i < 32; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16)
  return out
}

export function cidFromSha256(hex: string): string {
  return CID.createV1(raw.code, createDigest(0x12, fromHex(hex))).toString()
}

export function parseContentCID(value: string): CID {
  const cid = CID.parse(value.trim())
  if (cid.version !== 1 || cid.code !== raw.code || cid.multihash.code !== 0x12 || cid.multihash.size !== 32) {
    throw new Error('需要 CIDv1 raw sha2-256（bafkrei 开头）')
  }
  return cid
}

export function sha256FromCID(value: string): string {
  return toHex(parseContentCID(value).multihash.digest)
}

export interface Manifest {
  sha256: string
  cid: string
  size: number
  blocks: string[] // sha256 hex per BLOCK_SIZE block
}

/** Hashes a file in one streaming pass: whole-file SHA-256 plus per-block hashes. */
export async function manifestOf(file: Blob, onProgress?: (fraction: number) => void): Promise<Manifest> {
  const whole = sha256.create()
  const blocks: string[] = []
  const step = 4 * BLOCK_SIZE
  for (let offset = 0; offset < file.size; offset += step) {
    const bytes = new Uint8Array(await file.slice(offset, Math.min(file.size, offset + step)).arrayBuffer())
    whole.update(bytes)
    for (let i = 0; i < bytes.length; i += BLOCK_SIZE) blocks.push(toHex(sha256(bytes.subarray(i, i + BLOCK_SIZE))))
    onProgress?.(Math.min(1, (offset + step) / file.size))
  }
  const hex = toHex(whole.digest())
  return { sha256: hex, cid: cidFromSha256(hex), size: file.size, blocks }
}
