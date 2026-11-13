<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { PlazaNetwork, type PlazaEntry } from './lib/network.ts'
import type { PlazaFile } from './lib/plaza.ts'
import { WebPreview, isSong } from './lib/preview.ts'

const net = new PlazaNetwork()
const s = net.state
const preview = new WebPreview(net)
const pv = preview.state
watch(() => pv.phase, (phase) => { if (phase === 'failed') s.error = `听听看：${pv.error}` })
const query = ref('')
const cidInput = ref('')
const editingName = ref(false)
const nameDraft = ref('')
const dragging = ref(false)
const fileInput = ref<HTMLInputElement>()
const avatarInput = ref<HTMLInputElement>()

onMounted(() => {
  net.start().catch((error: Error) => { s.error = `网络启动失败：${error.message}` })
})

const statusText = computed(() => ({ online: '在线', connecting: '连线中', offline: '离线' })[s.status])

const entries = computed(() => {
  const q = query.value.trim().toLowerCase()
  return Object.values(s.entries)
    // Matches user name, song (title / artist / file name) or region.
    .filter((e: PlazaEntry) => !q || [e.body.name, e.body.region, e.body.listening?.title, e.body.listening?.artist,
      ...e.body.files.map((f) => f.name)]
      .some((v) => v?.toLowerCase().includes(q)))
    .sort((a, b) => Number(a.offline) - Number(b.offline) || b.body.seq - a.body.seq)
})

function size(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB']
  let value = bytes / 1024
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++ }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`
}

function pick(event: Event) {
  const files = (event.target as HTMLInputElement).files
  if (files) for (const f of files) void net.addUpload(f)
  ;(event.target as HTMLInputElement).value = ''
}

function drop(event: DragEvent) {
  dragging.value = false
  for (const f of event.dataTransfer?.files ?? []) void net.addUpload(f)
}

function download(entry: PlazaEntry, file: PlazaFile) {
  void net.download(file.cid, { name: file.name, size: file.size, from: entry.body.name })
}

function listen(entry: PlazaEntry, file: PlazaFile) {
  preview.listen(file, entry.body.name)
}

const downloaded = (cid: string) => s.downloads.some((d) => d.cid === cid && d.state === 'complete')

function findByCID() {
  const value = cidInput.value.trim()
  if (value) void net.download(value)
  cidInput.value = ''
}

function saveName() {
  net.setName(nameDraft.value)
  editingName.value = false
}

const AVATAR_SIDE = 96 // same size as the iOS app

/** Centre-crops the picked image to a 96×96 JPEG, small enough for the announcement limit. */
async function makeAvatar(file: File): Promise<string> {
  const bitmap = await createImageBitmap(file)
  const side = Math.min(bitmap.width, bitmap.height)
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = AVATAR_SIDE
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('浏览器不支持 canvas')
  ctx.fillStyle = '#fff' // transparent PNGs would otherwise turn black in JPEG
  ctx.fillRect(0, 0, AVATAR_SIDE, AVATAR_SIDE)
  ctx.drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, AVATAR_SIDE, AVATAR_SIDE)
  bitmap.close()
  for (const quality of [0.8, 0.65, 0.5, 0.35]) {
    const url = canvas.toDataURL('image/jpeg', quality)
    const base64 = url.slice(url.indexOf(',') + 1)
    if (base64.length <= 40_000) return base64 // node accepts up to 48 KB; iOS sends ≤ 32 KB raw
  }
  throw new Error('无法压缩到支持的大小')
}

async function pickAvatar(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  try {
    net.setAvatar(await makeAvatar(file))
  } catch (error) {
    s.error = `头像设置失败：${(error as Error).message}`
  }
}

function copy(text: string) {
  void navigator.clipboard?.writeText(text)
}

const downloading = (cid: string) => s.downloads.some((d) => d.cid === cid && d.state === 'running')
</script>

<template>
  <main class="page">
    <header class="top">
      <div class="brand"><span class="logo">🍬</span><h1>Candy 广场</h1></div>
      <div class="me">
        <button class="me-avatar" title="更换头像" @click="avatarInput?.click()">
          <img v-if="s.avatar" class="avatar" :src="`data:image/jpeg;base64,${s.avatar}`" alt="我的头像" />
          <div v-else class="avatar star">★</div>
          <span class="cam">✎</span>
        </button>
        <input ref="avatarInput" type="file" accept="image/*" hidden @change="pickAvatar" />
        <button v-if="s.avatar" class="link" title="移除头像" @click="net.setAvatar('')">移除头像</button>
        <template v-if="editingName">
          <input v-model="nameDraft" type="text" maxlength="40" @keyup.enter="saveName" />
          <button @click="saveName">保存</button>
        </template>
        <button v-else class="name" title="修改昵称" @click="nameDraft = s.name; editingName = true">{{ s.name }}</button>
        <span class="status" :class="s.status"><i />{{ statusText }}</span>
      </div>
    </header>

    <p class="sub">
      浏览器即 DHT 节点：通过引导节点加入 Kademlia 网络，经 GossipSub 接收 iOS 正在听的歌，用 WebRTC DataChannel 点对点传输。
      <span v-if="s.peerId" class="pid" :title="s.peerId">Peer ID <code>…{{ s.peerId.slice(-10) }}</code></span>
      <span v-if="s.nodes.length"> · 已连 {{ s.nodes.length }} 个节点</span>
    </p>

    <div v-if="s.error" class="error" @click="s.error = ''">{{ s.error }}</div>

    <section class="grid">
      <div class="col">
        <div class="panel">
          <div class="panel-head">
            <h2>广场</h2>
            <input v-model="query" type="text" placeholder="搜索用户名、歌曲名或地区…" />
          </div>
          <p v-if="!entries.length" class="empty">
            {{ s.status === 'online' ? '暂时没有其他在线用户。打开 iOS 端播放歌曲，或在右侧分享文件。' : '正在连接引导节点…' }}
          </p>
          <article v-for="e in entries" :key="e.body.peerId" class="peer" :class="{ offline: e.offline }">
            <img v-if="e.body.avatar" class="avatar" :src="`data:image/jpeg;base64,${e.body.avatar}`" alt="" />
            <div v-else class="avatar star">★</div>
            <div class="peer-main">
              <div class="peer-line">
                <strong>{{ e.body.name }}</strong>
                <span class="muted"> · {{ e.body.region || '地区未知' }}</span>
                <span class="badge">{{ e.body.client === 'ios' ? 'iOS' : 'Web' }}</span>
                <span v-if="e.offline" class="badge gray">离线</span>
              </div>
              <div v-if="e.body.listening" class="listening">
                {{ e.body.listening.isPlaying ? '♪ 正在听' : '⏸ 暂停' }}：{{ e.body.listening.title }}
                <span class="muted">— {{ e.body.listening.artist }}</span>
              </div>
              <div v-for="f in e.body.files" :key="f.cid" class="file">
                <span class="kind">{{ f.kind === 'listening' ? '在听' : '上传' }}</span>
                <span class="fname" :title="f.cid">{{ f.name }}</span>
                <span class="muted">{{ size(f.size) }}</span>
                <button v-if="isSong(f.name)" class="listen" :class="{ on: pv.cid === f.cid }"
                        :disabled="e.offline && !downloaded(f.cid) && pv.cid !== f.cid"
                        :title="pv.cid === f.cid && pv.phase === 'playing' ? '暂停' : '听听看'" @click="listen(e, f)">
                  <span v-if="pv.cid === f.cid && pv.phase === 'buffering'" class="spin" />
                  <template v-else-if="pv.cid === f.cid && pv.phase === 'failed'">⚠ 重试</template>
                  <span v-else-if="pv.cid === f.cid" class="eq" :class="{ paused: pv.phase !== 'playing' }"><i /><i /><i /><i /></span>
                  <template v-else>▶ 听听看</template>
                </button>
                <button v-else class="listen" disabled title="不是音乐文件">▶ 听听看</button>
                <button :disabled="e.offline || downloading(f.cid)" @click="download(e, f)">下载</button>
              </div>
            </div>
          </article>
        </div>
      </div>

      <div class="col">
        <div class="panel">
          <h2>分享文件</h2>
          <div class="drop" :class="{ on: dragging }" @dragover.prevent="dragging = true" @dragleave="dragging = false"
               @drop.prevent="drop" @click="fileInput?.click()">
            <input ref="fileInput" type="file" multiple hidden @change="pick" />
            <strong>拖入或点击选择文件</strong>
            <span class="muted">计算 SHA-256 → CID，向 DHT 发布并出现在广场，效果与 iOS 在听的歌曲相同。保持本页打开才能被下载。</span>
          </div>
          <div v-for="u in s.uploads" :key="u.cid || u.name" class="row">
            <div class="row-main">
              <div class="fname">{{ u.name }} <span class="muted">{{ size(u.size) }}</span></div>
              <div v-if="u.hashing !== undefined" class="muted">计算哈希 {{ Math.round(u.hashing * 100) }}%</div>
              <div v-else class="muted cid" @click="copy(u.cid)" title="点击复制 CID">
                <code>{{ u.cid }}</code><span v-if="u.serving"> · 正在发送 {{ u.serving }}</span>
              </div>
            </div>
            <button v-if="u.cid" @click="net.removeUpload(u.cid)">停止</button>
          </div>
        </div>

        <div class="panel">
          <h2>按哈希查找</h2>
          <div class="find">
            <input v-model="cidInput" type="text" placeholder="粘贴 CID（bafkrei…）" @keyup.enter="findByCID" />
            <button class="primary" :disabled="s.status !== 'online'" @click="findByCID">查找并下载</button>
          </div>
        </div>

        <div v-if="s.downloads.length" class="panel">
          <h2>传输任务</h2>
          <div v-for="d in s.downloads" :key="d.id" class="row task">
            <div class="row-main">
              <div class="fname">{{ d.name }} <span v-if="d.size" class="muted">{{ size(d.size) }}</span></div>
              <div class="muted">{{ d.from ? `来自 ${d.from} · ` : '' }}{{ d.status }}</div>
              <progress v-if="d.state === 'running'" :value="d.progress" max="1" />
            </div>
            <button v-if="d.state === 'running'" @click="net.cancel(d.id)">取消</button>
            <a v-else-if="d.url" class="save" :href="d.url" :download="d.name">保存</a>
            <button v-else-if="d.state !== 'complete'" @click="net.download(d.cid, { name: d.name, size: d.size, from: d.from })">重试</button>
          </div>
        </div>
      </div>
    </section>
  </main>
</template>

<style scoped>
.page { max-width: 1120px; margin: 0 auto; padding: 20px 16px 48px; }
.top { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.brand { display: flex; align-items: center; gap: 10px; }
.logo { font-size: 28px; }
h1 {
  margin: 0; font-size: 24px; font-weight: 900;
  background: linear-gradient(90deg, #ff6fb5, #a77bff, #ffb04f); -webkit-background-clip: text; background-clip: text; color: transparent;
}
h2 { margin: 0 0 12px; font-size: 16px; }
.me { display: flex; align-items: center; gap: 8px; }
.me input { width: 160px; }
.name { border-radius: 999px; }
.me-avatar { position: relative; padding: 0; border: 0; background: none; border-radius: 50%; cursor: pointer; flex: none; }
.me-avatar .avatar { width: 38px; height: 38px; }
.me-avatar .cam { position: absolute; right: -2px; bottom: -2px; width: 17px; height: 17px; border-radius: 50%;
  display: grid; place-items: center; font-size: 10px; color: #fff; background: var(--accent); border: 2px solid var(--panel); }
.me-avatar:hover .avatar { opacity: 0.8; }
.link { background: none; border: 0; padding: 4px 2px; color: var(--muted); font-size: 12px; cursor: pointer; }
.link:hover { color: var(--text); }
.status { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 700; padding: 6px 11px;
  border-radius: 999px; background: var(--panel); border: 1px solid var(--line); }
.status i { width: 7px; height: 7px; border-radius: 50%; background: var(--warn); }
.status.online i { background: var(--ok); }
.sub { color: var(--muted); font-size: 13px; margin: 10px 0 18px; }
.pid code { color: var(--text); }
.error { background: rgba(255, 90, 90, 0.12); border: 1px solid rgba(255, 90, 90, 0.35); padding: 10px 14px;
  border-radius: 12px; margin-bottom: 16px; cursor: pointer; }
.grid { display: grid; grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr); gap: 16px; }
@media (max-width: 820px) { .grid { grid-template-columns: minmax(0, 1fr); } }
.col { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 18px; padding: 16px; min-width: 0; }
.panel-head { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
.panel-head h2 { margin: 0; flex: none; }
.empty { color: var(--muted); font-size: 14px; padding: 18px 0; text-align: center; }
.peer { display: flex; gap: 12px; padding: 12px 0; border-top: 1px solid var(--line); }
.peer:first-of-type { border-top: 0; }
.peer.offline { filter: grayscale(1); opacity: 0.5; }
.avatar { width: 42px; height: 42px; border-radius: 50%; object-fit: cover; flex: none; }
.avatar.star { display: grid; place-items: center; font-size: 22px; color: #fff;
  background: linear-gradient(135deg, #ff6fb5, #a77bff, #ffd16b); }
.peer-main { min-width: 0; flex: 1; }
.peer-line strong { color: var(--gold); }
.badge { font-size: 11px; font-weight: 700; margin-left: 6px; padding: 1px 7px; border-radius: 999px;
  background: rgba(155, 124, 242, 0.18); color: var(--accent-2); }
.badge.gray { background: var(--line); color: var(--muted); }
.listening { font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.muted { color: var(--muted); font-size: 13px; }
.file { display: flex; align-items: center; gap: 8px; margin-top: 6px; }
.file button { padding: 4px 12px; margin-left: auto; flex: none; }
.file .listen { margin-left: auto; min-width: 76px; border: 0; color: var(--accent-2);
  background: rgba(155, 124, 242, 0.16); display: inline-flex; align-items: center; justify-content: center; }
.file .listen.on { background: rgba(155, 124, 242, 0.26); }
.file .listen:disabled { color: var(--muted); background: var(--line); }
.file .listen + button { margin-left: 0; }
.spin { width: 12px; height: 12px; border-radius: 50%; border: 2px solid rgba(155, 124, 242, 0.3);
  border-top-color: var(--accent-2); animation: spin 0.8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.eq { display: inline-flex; align-items: flex-end; gap: 2.5px; height: 14px; }
.eq i { width: 3px; height: 100%; border-radius: 2px; background: var(--accent-2); transform-origin: bottom;
  animation: eq 0.9s ease-in-out infinite; }
.eq i:nth-child(2) { animation-delay: -0.3s; animation-duration: 0.7s; }
.eq i:nth-child(3) { animation-delay: -0.6s; animation-duration: 1.1s; }
.eq i:nth-child(4) { animation-delay: -0.15s; animation-duration: 0.8s; }
.eq.paused i { animation-play-state: paused; transform: scaleY(0.45); }
@keyframes eq { 0%, 100% { transform: scaleY(0.3); } 50% { transform: scaleY(1); } }
.kind { font-size: 11px; padding: 1px 6px; border-radius: 6px; background: var(--line); flex: none; }
.fname { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; font-weight: 600; }
.drop { border: 1.5px dashed var(--line); border-radius: 14px; padding: 22px 16px; text-align: center; cursor: pointer;
  display: flex; flex-direction: column; gap: 6px; transition: border-color 0.15s; }
.drop.on, .drop:hover { border-color: var(--accent); }
.row { display: flex; align-items: center; gap: 10px; padding: 10px 0; border-top: 1px solid var(--line); margin-top: 10px; }
.row-main { flex: 1; min-width: 0; }
.cid { cursor: pointer; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.find { display: flex; gap: 8px; }
.find button { flex: none; }
progress { width: 100%; height: 6px; margin-top: 6px; accent-color: var(--accent); }
.save { flex: none; text-decoration: none; font-weight: 700; color: #fff; padding: 7px 14px; border-radius: 10px;
  background: linear-gradient(90deg, var(--accent), var(--accent-2)); }
</style>
