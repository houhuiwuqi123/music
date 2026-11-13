// "听听看": plays a plaza song while it downloads. MP3 / AAC stream through
// MediaSource as verified blocks arrive; other audio formats play once the
// download has finished (and its SHA-256 has been checked).
import { reactive, watch } from 'vue'
import type { PlazaNetwork, DownloadTask } from './network.ts'
import type { PlazaFile } from './plaza.ts'

export type PreviewPhase = 'idle' | 'buffering' | 'playing' | 'paused' | 'failed'

/** Same audio extensions the iOS app treats as songs. */
const AUDIO_EXTENSIONS = new Set([
  'aac', 'ac3', 'aif', 'aifc', 'aiff', 'amr', 'au', 'caf', 'eac3', 'flac',
  'm4a', 'm4b', 'm4p', 'mp1', 'mp2', 'mp3', 'mpa', 'ogg', 'oga', 'opus',
  'snd', 'wav', 'wave', 'wma',
])

/** Formats MediaSource can take as a plain byte stream. */
const STREAM_MIME: Record<string, string> = { mp3: 'audio/mpeg', mpa: 'audio/mpeg', aac: 'audio/aac' }

const extension = (name: string) => name.split('.').pop()?.toLowerCase() ?? ''

export function isSong(name: string): boolean {
  return AUDIO_EXTENSIONS.has(extension(name))
}

export class WebPreview {
  state = reactive({ cid: '', phase: 'idle' as PreviewPhase, error: '' })

  private audio?: HTMLAudioElement
  private objectURL?: string
  private cleanup: (() => void)[] = []
  private readonly net: PlazaNetwork

  constructor(net: PlazaNetwork) { this.net = net }

  /** Starts the song, or pauses / resumes it if it is the current one. */
  listen(file: PlazaFile, from: string) {
    if (this.state.cid === file.cid && this.state.phase !== 'failed') {
      this.toggle()
      return
    }
    this.stop()
    this.state.cid = file.cid
    this.state.phase = 'buffering'
    this.state.error = ''
    const audio = new Audio()
    this.audio = audio
    this.wire(audio)

    const done = this.task(file.cid, 'complete')
    if (done?.url) {
      this.start(done.url)
      return
    }
    void this.net.download(file.cid, { name: file.name, size: file.size, from }) // no-op if already running
    const mime = STREAM_MIME[extension(file.name)]
    if (mime && typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported(mime)) this.stream(file.cid, mime)
    else this.whenComplete(file.cid)
  }

  toggle() {
    const audio = this.audio
    if (!audio) return
    if (audio.paused) void audio.play().catch((error: Error) => this.fail(error.message))
    else audio.pause()
  }

  stop() {
    for (const fn of this.cleanup) fn()
    this.cleanup = []
    if (this.audio) {
      this.audio.pause()
      this.audio.removeAttribute('src')
      this.audio.load()
    }
    if (this.objectURL) URL.revokeObjectURL(this.objectURL)
    this.audio = undefined
    this.objectURL = undefined
    this.state.cid = ''
    this.state.phase = 'idle'
  }

  private task(cid: string, state?: DownloadTask['state']) {
    return this.net.state.downloads.find((d) => d.cid === cid && (!state || d.state === state))
  }

  private wire(audio: HTMLAudioElement) {
    const mine = () => this.audio === audio
    audio.addEventListener('playing', () => { if (mine()) this.state.phase = 'playing' })
    audio.addEventListener('pause', () => { if (mine() && this.state.phase !== 'failed') this.state.phase = 'paused' })
    audio.addEventListener('waiting', () => { if (mine() && !audio.paused) this.state.phase = 'buffering' })
    audio.addEventListener('error', () => { if (mine()) this.fail('浏览器无法播放该格式，可下载后用本地播放器打开') })
  }

  private start(url: string) {
    const audio = this.audio
    if (!audio) return
    audio.src = url
    void audio.play().catch((error: Error) => {
      if (error.name !== 'AbortError') this.fail(error.name === 'NotAllowedError' ? '浏览器阻止了自动播放，请再点一次' : error.message)
    })
  }

  private fail(message: string) {
    this.state.phase = 'failed'
    this.state.error = message
    for (const fn of this.cleanup) fn()
    this.cleanup = []
  }

  /** Non-streamable formats: wait for the verified download, then play the blob. */
  private whenComplete(cid: string) {
    const stop = watch(() => this.task(cid)?.state, (state) => {
      const task = this.task(cid)
      if (state === 'complete' && task?.url) {
        stop()
        this.start(task.url)
      } else if (state === 'failed' || state === 'canceled') {
        stop()
        this.fail(task?.status ?? '下载失败')
      }
    }, { immediate: true })
    this.cleanup.push(stop)
  }

  /** MP3 / AAC: feed each verified block to a SourceBuffer as it arrives. */
  private stream(cid: string, mime: string) {
    const audio = this.audio!
    const source = new MediaSource()
    this.objectURL = URL.createObjectURL(source)
    this.start(this.objectURL)
    source.addEventListener('sourceopen', () => {
      if (this.audio !== audio) return
      let buffer: SourceBuffer
      try {
        buffer = source.addSourceBuffer(mime)
        buffer.mode = 'sequence'
      } catch {
        this.fail('浏览器不支持边下边播该格式')
        return
      }
      let next = 0
      let reading = false
      const pump = async () => {
        if (this.audio !== audio || reading || buffer.updating || source.readyState !== 'open') return
        const parts = this.net.assemblyFor(cid)?.parts ?? []
        if (next < parts.length) {
          reading = true
          const data = await parts[next].arrayBuffer()
          reading = false
          if (this.audio !== audio || source.readyState !== 'open') return
          try {
            buffer.appendBuffer(data)
            next++
          } catch (error) {
            if ((error as Error).name !== 'QuotaExceededError') return this.fail((error as Error).message)
            // The browser caps buffered audio; drop what has already been played and retry.
            if (audio.currentTime > 20) buffer.remove(0, audio.currentTime - 10)
            else setTimeout(() => void pump(), 1000)
          }
        } else if (this.task(cid)?.state === 'complete') {
          source.endOfStream()
        }
      }
      buffer.addEventListener('updateend', () => void pump())
      this.cleanup.push(this.net.watchBlocks(cid, () => void pump()))
      const stop = watch(() => this.task(cid)?.state, (state) => {
        if (state === 'complete') void pump()
        else if (state === 'failed' || state === 'canceled') this.fail(this.task(cid)?.status ?? '下载失败')
      })
      this.cleanup.push(stop)
      void pump()
    }, { once: true })
  }
}
