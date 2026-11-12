// Signed plaza announcements. The body is signed as exact JSON text, so the
// Go node, Swift and JS verify bytes rather than re-serialising objects.
import { publicKeyFromProtobuf, publicKeyToProtobuf } from '@libp2p/crypto/keys'
import { peerIdFromPublicKey } from '@libp2p/peer-id'
import type { PrivateKey } from '@libp2p/interface'

export const SIGNATURE_PREFIX = 'auru-plaza:'

export interface PlazaFile {
  cid: string
  name: string
  size: number
  sha256: string
  kind: 'listening' | 'upload'
  mime?: string
}

export interface PlazaBody {
  v: 1
  peerId: string
  name: string
  avatar?: string
  region?: string
  /** coarse [lat, lon] from the node's GeoIP (0.1°), shown on the iOS globe */
  geo?: [number, number]
  client?: 'ios' | 'web'
  via: string[]
  listening?: { title: string; artist: string; isPlaying: boolean }
  files: PlazaFile[]
  seq: number
  bye?: boolean
}

export interface Envelope {
  body: string
  sig: string
  pub: string
}

const encoder = new TextEncoder()

export function b64(bytes: Uint8Array): string {
  let text = ''
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(text)
}

export function unb64(text: string): Uint8Array {
  const bin = atob(text)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

export async function signEnvelope(key: PrivateKey, body: PlazaBody): Promise<Envelope> {
  const text = JSON.stringify(body)
  const sig = await key.sign(encoder.encode(SIGNATURE_PREFIX + text))
  return { body: text, sig: b64(sig), pub: b64(publicKeyToProtobuf(key.publicKey)) }
}

/** Verifies signature and key binding; returns the body or throws. */
export async function verifyEnvelope(env: Envelope): Promise<PlazaBody> {
  const pub = publicKeyFromProtobuf(unb64(env.pub))
  if (pub.type !== 'Ed25519') throw new Error('only Ed25519')
  const ok = await pub.verify(encoder.encode(SIGNATURE_PREFIX + env.body), unb64(env.sig))
  if (!ok) throw new Error('bad signature')
  const body = JSON.parse(env.body) as PlazaBody
  if (body.v !== 1 || peerIdFromPublicKey(pub).toString() !== body.peerId) throw new Error('peerId mismatch')
  if (!Array.isArray(body.files) || !Array.isArray(body.via)) throw new Error('malformed body')
  return body
}
