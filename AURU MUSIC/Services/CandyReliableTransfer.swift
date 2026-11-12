import CryptoKit
import Foundation
import WebRTC

// AURU file protocol over one ordered, reliable RTCDataChannel ("auru-file/1").
// Identical to web/src/lib/transfer.ts:
//   R→S  {"t":"get","cid":C,"offset":N}            N is a multiple of 1 MiB
//   S→R  {"t":"meta","cid","size","name","mime","blockSize","blocks":[hex…]} | {"t":"error","error":…}
//   S→R  binary chunks (≤ 64 KiB) covering [N, size) in order, then {"t":"end"}
//   R→S  {"t":"done"} | {"t":"error","error":…}
// Every 1 MiB block is checked against `blocks` while receiving, and the whole
// file against the SHA-256 inside the CID before it is saved as complete.

let candyBlockSize = 1_048_576
let candyChunkSize = 65_536
let candyChannelLabel = "auru-file/1"

struct CandySignal: Codable, Sendable {
    var from: String? = nil
    var to: String
    var node: String? = nil
    var nodeAddrs: [String]? = nil
    var fromNode: String? = nil
    var fromNodeAddrs: [String]? = nil
    var session: String
    var kind: String
    var sdp: String? = nil
    var hop: Int? = nil
}

struct CandyCandidate: Codable, Sendable {
    var peerId: String
    var node: String
    var nodeAddrs: [String]? = nil
}

struct CandyICEServer: Codable, Sendable {
    var urls: [String]
    var username: String? = nil
    var credential: String? = nil
}

struct CandyWireMessage: Codable {
    var t: String
    var cid: String? = nil
    var offset: Int64? = nil
    var size: Int64? = nil
    var name: String? = nil
    var mime: String? = nil
    var blockSize: Int? = nil
    var blocks: [String]? = nil
    var error: String? = nil
}

enum CandyTransferFailure: LocalizedError {
    case invalid(String)
    case network(String)
    case source(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .network(let message), .source(let message): return message
        }
    }
}

// MARK: - Disk

actor CandyTransferDisk {
    struct Manifest: Sendable {
        var size: Int64
        var sha256: String
        var blocks: [String]
    }
    private struct Checkpoint: Codable {
        var hash: String
        var size: Int64
        var offset: Int64
        var prefixHash: String
        var updated: Date
        var completedURL: URL?
    }

    private let file: CandyPlazaFile
    private let folder: URL
    private let part: URL
    private let record: URL
    private var handle: FileHandle?
    private var offset: Int64 = 0
    private var hasher = SHA256()
    private var checkpointOffset: Int64 = 0
    private var completedURL: URL?

    init(file: CandyPlazaFile, folder: URL) {
        self.file = file
        self.folder = folder
        part = Self.partialURL(file: file, folder: folder)
        record = part.deletingPathExtension().appendingPathExtension("json")
    }

    /// Content-addressed: any provider of the same SHA-256 continues the same partial.
    /// The preview player reads verified bytes from this file while it is being written.
    nonisolated static func partialURL(file: CandyPlazaFile, folder: URL) -> URL {
        let namespace = SHA256.hash(data: Data("auru-dht".utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "\(namespace)-\(file.sha256 ?? file.id)"
        return folder.appendingPathComponent(".partial", isDirectory: true)
            .appendingPathComponent(key).appendingPathExtension("part")
    }

    /// Whole-file SHA-256 plus per-block hashes, in one streaming pass.
    nonisolated static func manifest(_ url: URL) async throws -> Manifest {
        try await Task.detached(priority: .utility) {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size >= 0 else {
                throw CandyTransferFailure.source("分享文件不可读取。")
            }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var whole = SHA256()
            var block = SHA256()
            var inBlock = 0
            var blocks: [String] = []
            var count: Int64 = 0
            while let data = try input.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation()
                whole.update(data: data)
                var cursor = data.startIndex
                while cursor < data.endIndex {
                    let take = min(candyBlockSize - inBlock, data.endIndex - cursor)
                    block.update(data: data[cursor..<(cursor + take)])
                    inBlock += take
                    cursor += take
                    if inBlock == candyBlockSize {
                        blocks.append(block.finalize().map { String(format: "%02x", $0) }.joined())
                        block = SHA256()
                        inBlock = 0
                    }
                }
                count += Int64(data.count)
            }
            if inBlock > 0 { blocks.append(block.finalize().map { String(format: "%02x", $0) }.joined()) }
            let final = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard count == Int64(size), final.fileSize == size,
                  final.contentModificationDate == attributes.contentModificationDate else {
                throw CandyTransferFailure.source("分享文件在读取过程中发生变化。")
            }
            return Manifest(size: count, sha256: whole.finalize().map { String(format: "%02x", $0) }.joined(), blocks: blocks)
        }.value
    }

    nonisolated static func cleanExpiredPartials(in folder: URL) async throws {
        try await Task.detached(priority: .utility) {
            let staging = folder.appendingPathComponent(".partial", isDirectory: true)
            guard FileManager.default.fileExists(atPath: staging.path) else { return }
            let records = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            for record in records where record.lastPathComponent.range(of: "^[0-9a-f]{64}-[0-9a-f]{64}\\.json$", options: .regularExpression) != nil {
                let saved = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: record))
                guard saved.completedURL == nil, Date().timeIntervalSince(saved.updated) >= 86_400 else { continue }
                let partial = record.deletingPathExtension().appendingPathExtension("part")
                if FileManager.default.fileExists(atPath: partial.path) { try FileManager.default.removeItem(at: partial) }
                try FileManager.default.removeItem(at: record)
            }
        }.value
    }

    var isCompleted: Bool { completedURL != nil }

    func prepare() async throws -> Int64 {
        if handle != nil { try close() }
        guard let hash = file.sha256, hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              file.size >= 0, file.size <= 2_147_483_648 else {
            throw CandyTransferFailure.invalid("歌曲缺少有效的校验信息，或超出 2 GB 限制。")
        }
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: record.path) {
            let saved = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: record))
            guard saved.hash == hash, saved.size == file.size, saved.offset >= 0, saved.offset <= file.size else {
                throw CandyTransferFailure.invalid("下载断点与当前歌曲不一致，请清除断点后重试。")
            }
            if let destination = saved.completedURL, FileManager.default.fileExists(atPath: destination.path) {
                guard destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
                    throw CandyTransferFailure.invalid("下载完成记录的保存位置无效。")
                }
                let manifest = try await Self.manifest(destination)
                guard manifest.size == file.size, manifest.sha256 == file.sha256 else {
                    throw CandyTransferFailure.invalid("已下载歌曲发生变化，请清除断点后重新下载。")
                }
                completedURL = destination
                offset = file.size
                return offset
            }
            if Date().timeIntervalSince(saved.updated) < 86_400, FileManager.default.fileExists(atPath: part.path) {
                try rehash(upTo: saved.offset)
                guard digest() == saved.prefixHash else {
                    throw CandyTransferFailure.invalid("下载断点校验失败，请清除断点后重试。")
                }
                offset = saved.offset
            } else {
                try FileManager.default.removeItem(at: record)
                if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
                offset = 0
                hasher = SHA256()
            }
        }
        if !FileManager.default.fileExists(atPath: part.path) {
            let entries = try FileManager.default.contentsOfDirectory(at: part.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])
            var partialBytes: Int64 = 0
            for entry in entries where entry.pathExtension == "part" {
                partialBytes += Int64(try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard partialBytes + file.size <= 4_294_967_296 else {
                throw CandyTransferFailure.invalid("下载断点空间已达 4 GB，请清除旧断点。")
            }
            if let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
               Int64(available) < file.size + 16_777_216 {
                throw CandyTransferFailure.invalid("设备存储空间不足，请释放空间后重试。")
            }
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forUpdating: part)
        try handle?.truncate(atOffset: UInt64(offset))
        try handle?.seek(toOffset: UInt64(offset))
        checkpointOffset = offset
        return offset
    }

    /// Drops everything after `target` (a block boundary for resume, or the start
    /// of a block that failed verification) and re-derives the prefix hash.
    func rewind(to target: Int64) throws {
        guard completedURL == nil, let handle, target >= 0, target <= offset else { return }
        try handle.truncate(atOffset: UInt64(target))
        try rehash(upTo: target)
        offset = target
        try handle.seek(toOffset: UInt64(target))
        try checkpoint()
    }

    func append(_ data: Data, at expected: Int64) throws {
        guard completedURL == nil, let handle, expected == offset, !data.isEmpty, data.count <= 1_048_576,
              Int64(data.count) <= file.size - offset else {
            throw CandyTransferFailure.invalid("收到越界或顺序错误的歌曲数据。")
        }
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        offset += Int64(data.count)
        if offset - checkpointOffset >= 262_144 || offset == file.size { try checkpoint() }
    }

    func durableOffset() throws -> Int64 {
        if completedURL != nil { return offset }
        try checkpoint()
        return offset
    }

    func finish() throws -> URL {
        if let completedURL { return completedURL }
        guard offset == file.size, digest() == file.sha256 else {
            throw CandyTransferFailure.invalid("歌曲 SHA-256 校验失败，文件未保存为已完成。")
        }
        try checkpoint()
        try handle?.close()
        handle = nil
        let safeName = URL(fileURLWithPath: file.name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            throw CandyTransferFailure.invalid("歌曲名称无效。")
        }
        let source = URL(fileURLWithPath: safeName)
        var destination = folder.appendingPathComponent(safeName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = "\(source.deletingPathExtension().lastPathComponent) \(suffix)"
            destination = folder.appendingPathComponent(name)
            if !source.pathExtension.isEmpty { destination.appendPathExtension(source.pathExtension) }
            suffix += 1
        }
        completedURL = destination
        try saveRecord()
        do { try FileManager.default.moveItem(at: part, to: destination) }
        catch {
            completedURL = nil
            throw error
        }
        return destination
    }

    func close() throws {
        if handle != nil {
            try checkpoint()
            try handle?.close()
            handle = nil
        }
    }

    func clear() throws {
        try handle?.close()
        handle = nil
        for url in [part, record] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        offset = 0
        checkpointOffset = 0
        completedURL = nil
        hasher = SHA256()
    }

    private func rehash(upTo target: Int64) throws {
        let input = try FileHandle(forReadingFrom: part)
        defer { try? input.close() }
        var remaining = target
        hasher = SHA256()
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: Int(min(remaining, 262_144))), !chunk.isEmpty else {
                throw CandyTransferFailure.invalid("下载断点文件不完整，请清除断点后重试。")
            }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private func digest() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func checkpoint() throws {
        try handle?.synchronize()
        try saveRecord()
        checkpointOffset = offset
    }

    private func saveRecord() throws {
        let saved = Checkpoint(hash: file.sha256 ?? "", size: file.size, offset: offset,
            prefixHash: digest(), updated: Date(), completedURL: completedURL)
        try JSONEncoder().encode(saved).write(to: record, options: .atomic)
    }
}

private actor CandyTransferSource {
    private let handle: FileHandle
    private let url: URL
    private let size: Int?
    private let modified: Date?
    init(url: URL) throws {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard attributes.isRegularFile == true else { throw CandyTransferFailure.source("源歌曲已被删除。") }
        self.url = url
        size = attributes.fileSize
        modified = attributes.contentModificationDate
        handle = try FileHandle(forReadingFrom: url)
    }
    func read(offset: Int64, count: Int) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard attributes.fileSize == size, attributes.contentModificationDate == modified else {
            throw CandyTransferFailure.source("源歌曲已变更，传输停止。")
        }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
    func close() throws { try handle.close() }
}

// MARK: - Engine

@MainActor
final class CandyReliableTransfer {
    /// GET_PROVIDERS through the node gateway.
    var findProviders: ((String) async throws -> [CandyCandidate])?
    var sendSignal: ((CandySignal) -> Void)?
    var iceServers: () -> [CandyICEServer] = { [] }
    var isOnline: () -> Bool = { false }
    var changed: ((CandyPlazaFile, Double, String) -> Void)?
    /// Bytes from the start of the partial file that passed per-block SHA-256 checks
    /// (block-aligned, or the full size). Drives listen-while-downloading.
    var verified: ((CandyPlazaFile, Int64) -> Void)?
    var completed: ((CandyPlazaFile, URL) -> Void)?
    var failed: ((CandyPlazaFile?, String) -> Void)?
    var publicationUnavailable: ((String) -> Void)?

    private final class Job {
        let file: CandyPlazaFile
        let disk: CandyTransferDisk
        var task: Task<Void, Never>?
        var peer: CandyRTCPeer?
        var lastUIUpdate = Date.distantPast
        var verifiedBytes: Int64 = 0
        init(file: CandyPlazaFile, folder: URL) {
            self.file = file
            disk = CandyTransferDisk(file: file, folder: folder)
        }
    }
    private struct Publication {
        var file: CandyPlazaFile
        var url: URL
        var manifest: CandyTransferDisk.Manifest
        var mime: String
    }

    private let folder: URL
    private let factory: RTCPeerConnectionFactory
    private var jobs: [String: Job] = [:]
    private var publications: [String: Publication] = [:]
    private var uploads: [String: CandyRTCPeer] = [:]
    private var pendingAnswers: [String: CheckedContinuation<CandySignal, Error>] = [:]
    private var wakeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let maxUploads = 2

    init(folder: URL) {
        self.folder = folder
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
        Task { [weak self] in
            do { try await CandyTransferDisk.cleanExpiredPartials(in: folder) }
            catch { self?.failed?(nil, "下载断点清理失败：\(error.localizedDescription)") }
        }
    }

    // MARK: Publishing

    func publish(_ file: CandyPlazaFile, url: URL, manifest: CandyTransferDisk.Manifest) {
        // Switching songs: new requests go to the new file; running uploads keep their open source.
        publications = [file.id: Publication(file: file, url: url, manifest: manifest, mime: Self.mime(for: url))]
    }

    /// Privacy withdrawal: stop serving and drop running uploads.
    func withdraw() {
        publications.removeAll()
        for session in Array(uploads.keys) { closeUpload(session) }
    }

    // MARK: Network state

    /// Wi-Fi ↔ cellular switches invalidate ICE paths: drop live peers now so
    /// downloads resume from the last verified block instead of waiting for timeouts.
    func networkChanged() {
        for job in jobs.values { job.peer?.shutdown(CandyTransferFailure.network("网络已切换，正在重新连接")) }
        for session in Array(uploads.keys) { closeUpload(session) }
        wake()
    }

    func wake() {
        let waiters = wakeWaiters
        wakeWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private func pause(_ seconds: Double) async {
        let id = UUID()
        // The continuation body is not main-actor isolated: register through a main-actor hop.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in self.registerWake(id, continuation, seconds: seconds) }
        }
    }

    private func registerWake(_ id: UUID, _ continuation: CheckedContinuation<Void, Never>, seconds: Double) {
        wakeWaiters[id] = continuation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.wakeWaiters.removeValue(forKey: id)?.resume()
        }
    }

    // MARK: Signalling

    func handle(_ signal: CandySignal) {
        switch signal.kind {
        case "offer": serve(signal)
        case "answer": pendingAnswers.removeValue(forKey: signal.session)?.resume(returning: signal)
        case "bye": closeUpload(signal.session)
        default: break
        }
    }

    func signalFailed(session: String, error: String) {
        let message = error == "unreachable" ? "对方已离线" : "信令失败：\(error)"
        pendingAnswers.removeValue(forKey: session)?.resume(throwing: CandyTransferFailure.network(message))
    }

    private func makePeer(session: String, remote: String) -> CandyRTCPeer {
        let servers = iceServers()
        let peer = CandyRTCPeer(session: session, remote: remote,
            expectsRelay: servers.contains { $0.urls.contains { $0.hasPrefix("turn") } })
        let configuration = RTCConfiguration()
        configuration.iceServers = servers.map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: server.urls)
        }
        configuration.sdpSemantics = .unifiedPlan
        peer.connection = factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: peer)
        return peer
    }

    // MARK: Serving (sender side)

    private func serve(_ offer: CandySignal) {
        guard let remote = offer.from, let sdp = offer.sdp, uploads[offer.session] == nil, uploads.count < maxUploads,
              !publications.isEmpty else { return }
        let peer = makePeer(session: offer.session, remote: remote)
        guard let connection = peer.connection else { return }
        uploads[offer.session] = peer
        peer.onChannel = { [weak self, weak peer] channel in
            guard let self, let peer else { return }
            guard channel.label == candyChannelLabel, peer.attach(channel) else { channel.close(); return }
            Task { @MainActor in await self.runUpload(peer) }
        }
        Task { @MainActor [weak self] in
            do {
                try await connection.candyApplyRemote(RTCSessionDescription(type: .offer, sdp: sdp))
                let answer = try await connection.candyAnswer()
                try await connection.candyApplyLocal(answer)
                await peer.gathering.wait(seconds: 5)
                guard let self, self.uploads[offer.session] === peer, let local = connection.localDescription?.sdp else { return }
                self.sendSignal?(CandySignal(to: remote, node: offer.fromNode, nodeAddrs: offer.fromNodeAddrs,
                    session: offer.session, kind: "answer", sdp: local))
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !peer.channelOpen.isSucceeded { self.closeUpload(offer.session) }
            } catch {
                self?.closeUpload(offer.session)
            }
        }
    }

    private func runUpload(_ peer: CandyRTCPeer) async {
        var source: CandyTransferSource?
        var servedID: String?
        do {
            try await peer.channelOpen.wait(seconds: 20, failure: CandyTransferFailure.network("文件通道未打开。"))
            guard case .text(let text) = try await peer.inbox.next(timeout: 30),
                  let request = try? JSONDecoder().decode(CandyWireMessage.self, from: Data(text.utf8)),
                  request.t == "get", let cid = request.cid, let offset = request.offset else {
                try peer.sendControl(CandyWireMessage(t: "error", error: "bad-request"))
                throw CandyTransferFailure.invalid("下载请求无效。")
            }
            guard let publication = publications[cid] else {
                try peer.sendControl(CandyWireMessage(t: "error", error: "not-found"))
                throw CandyTransferFailure.invalid("请求的文件已停止分享。")
            }
            servedID = cid
            let size = publication.manifest.size
            guard offset >= 0, offset <= size, offset % Int64(candyBlockSize) == 0 else {
                try peer.sendControl(CandyWireMessage(t: "error", error: "bad-request"))
                throw CandyTransferFailure.invalid("续传位置无效。")
            }
            let input = try CandyTransferSource(url: publication.url)
            source = input
            try peer.sendControl(CandyWireMessage(t: "meta", cid: cid, size: size, name: publication.file.name,
                mime: publication.mime, blockSize: candyBlockSize, blocks: publication.manifest.blocks))
            var position = offset
            while position < size {
                let expected = Int(min(Int64(candyBlockSize), size - position))
                let block = try await input.read(offset: position, count: expected)
                guard block.count == expected else { throw CandyTransferFailure.source("源歌曲被删除或截断。") }
                var index = 0
                while index < block.count {
                    while (peer.channel?.bufferedAmount ?? 0) > 8_388_608 {
                        guard peer.channel?.readyState == .open else { throw CandyTransferFailure.network("发送连接已关闭。") }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let end = min(index + candyChunkSize, block.count)
                    guard peer.channel?.readyState == .open,
                          peer.channel?.sendData(RTCDataBuffer(data: block.subdata(in: index..<end), isBinary: true)) == true else {
                        throw CandyTransferFailure.network("文件分片发送失败。")
                    }
                    index = end
                }
                position += Int64(block.count)
            }
            try peer.sendControl(CandyWireMessage(t: "end"))
            guard case .text(let reply) = try await peer.inbox.next(timeout: 120),
                  (try? JSONDecoder().decode(CandyWireMessage.self, from: Data(reply.utf8)))?.t == "done" else {
                throw CandyTransferFailure.network("接收方未确认完成。")
            }
        } catch {
            if case CandyTransferFailure.source = error, let servedID { publicationUnavailable?(servedID) }
        }
        if let source { try? await source.close() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        closeUpload(peer.session)
    }

    private func closeUpload(_ session: String) {
        guard let peer = uploads.removeValue(forKey: session) else { return }
        peer.shutdown(CandyTransferFailure.network("上传已结束。"))
    }

    // MARK: Downloading (receiver side)

    func download(_ file: CandyPlazaFile) {
        guard jobs[file.id] == nil else { return }
        let job = Job(file: file, folder: folder)
        jobs[file.id] = job
        changed?(file, 0, "DHT 查询提供者…")
        job.task = Task { @MainActor [weak self] in await self?.run(job) }
    }

    func isDownloading(_ fileID: String) -> Bool { jobs[fileID] != nil }

    /// Verified prefix of a running download, or nil when it is not running.
    func verifiedBytes(_ fileID: String) -> Int64? { jobs[fileID]?.verifiedBytes }

    func partialURL(for file: CandyPlazaFile) -> URL { CandyTransferDisk.partialURL(file: file, folder: folder) }

    private func reportVerified(_ job: Job, _ bytes: Int64) {
        guard jobs[job.file.id] === job else { return }
        job.verifiedBytes = bytes
        verified?(job.file, bytes)
    }

    func cancel(_ fileID: String) {
        guard let job = jobs.removeValue(forKey: fileID) else { return }
        job.task?.cancel()
        job.peer?.shutdown(CancellationError())
        wake()
        failed?(job.file, "已取消，可重试或清除断点。")
    }

    func clearPartial(_ file: CandyPlazaFile) {
        let job = jobs.removeValue(forKey: file.id)
        job?.task?.cancel()
        job?.peer?.shutdown(CancellationError())
        let disk = job?.disk ?? CandyTransferDisk(file: file, folder: folder)
        Task { @MainActor [weak self] in
            do { try await disk.clear() }
            catch { self?.failed?(file, "无法清除断点：\(error.localizedDescription)") }
        }
    }

    private func report(_ job: Job, _ offset: Int64, _ status: String, force: Bool = true) {
        guard jobs[job.file.id] === job else { return }
        guard force || Date().timeIntervalSince(job.lastUIUpdate) >= 0.25 else { return }
        job.lastUIUpdate = Date()
        changed?(job.file, job.file.size > 0 ? Double(offset) / Double(job.file.size) : 0, status)
    }

    private func run(_ job: Job) async {
        let deadline = Date().addingTimeInterval(600)
        var delay = 1.0
        do {
            var offset = try await job.disk.prepare()
            if await job.disk.isCompleted {
                let url = try await job.disk.finish()
                complete(job, url)
                return
            }
            reportVerified(job, offset - offset % Int64(candyBlockSize))
            while Date() < deadline {
                try Task.checkCancellation()
                guard isOnline() else {
                    report(job, offset, "网络断开，等待重连…")
                    await pause(2)
                    continue
                }
                report(job, offset, "DHT 查询提供者（GET_PROVIDERS）…")
                // The listener the user tapped is online and playing this song: try them first.
                let owner = job.file.ownerId
                let candidates = ((try? await findProviders?(job.file.id)) ?? [])
                    .sorted { $0.peerId == owner && $1.peerId != owner }
                try Task.checkCancellation()
                if candidates.isEmpty { report(job, offset, "暂无在线提供者，稍后重试…") }
                for candidate in candidates {
                    try Task.checkCancellation()
                    do {
                        let url = try await attempt(job, candidate)
                        complete(job, url)
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        offset = try await job.disk.durableOffset()
                        let resumed = offset - offset % Int64(candyBlockSize)
                        report(job, offset, "\(error.localizedDescription)，将从 \(resumed / 1_048_576) MB 处续传")
                    }
                }
                await pause(delay * Double.random(in: 0.75...1.25))
                delay = min(30, delay * 2)
            }
            try Task.checkCancellation()
            try await job.disk.close()
            fail(job, "提供者长时间不可达，断点已保留，可稍后重试。")
        } catch is CancellationError {
            try? await job.disk.close()
        } catch {
            try? await job.disk.close()
            fail(job, error.localizedDescription)
        }
    }

    private func complete(_ job: Job, _ url: URL) {
        guard jobs[job.file.id] === job else { return }
        jobs.removeValue(forKey: job.file.id)
        completed?(job.file, url)
    }

    private func fail(_ job: Job, _ message: String) {
        guard jobs[job.file.id] === job else { return }
        jobs.removeValue(forKey: job.file.id)
        failed?(job.file, message)
    }

    /// One provider: offer → answer via the nodes, then the file protocol on a direct DataChannel.
    private func attempt(_ job: Job, _ candidate: CandyCandidate) async throws -> URL {
        let session = UUID().uuidString.lowercased()
        let peer = makePeer(session: session, remote: candidate.peerId)
        job.peer = peer
        defer {
            peer.shutdown(CandyTransferFailure.network("连接已结束。"))
            if job.peer === peer { job.peer = nil }
        }
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let connection = peer.connection,
              let channel = connection.dataChannel(forLabel: candyChannelLabel, configuration: config), peer.attach(channel) else {
            throw CandyTransferFailure.network("无法创建文件通道。")
        }
        let startOffset = try await job.disk.durableOffset()
        report(job, startOffset, "连接 …\(candidate.peerId.suffix(8))")
        let offer = try await connection.candyOffer()
        try await connection.candyApplyLocal(offer)
        await peer.gathering.wait(seconds: 5)
        guard let local = connection.localDescription?.sdp else { throw CandyTransferFailure.network("无法生成连接描述。") }
        let offerSignal = CandySignal(to: candidate.peerId, node: candidate.node, nodeAddrs: candidate.nodeAddrs,
            session: session, kind: "offer", sdp: local)
        let answer: CandySignal = try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in self.awaitAnswer(offerSignal, continuation) }
        }
        guard answer.from == candidate.peerId, let remoteSDP = answer.sdp else { throw CandyTransferFailure.network("应答来源不符。") }
        try await connection.candyApplyRemote(RTCSessionDescription(type: .answer, sdp: remoteSDP))
        try await peer.channelOpen.wait(seconds: 20, failure: CandyTransferFailure.network("点对点连接超时（可能需要 TURN）"))

        // Resume only at verified block boundaries.
        var position = try await job.disk.durableOffset()
        let aligned = position - position % Int64(candyBlockSize)
        if aligned != position {
            try await job.disk.rewind(to: aligned)
            position = aligned
        }
        try peer.sendControl(CandyWireMessage(t: "get", cid: job.file.id, offset: position))
        guard case .text(let first) = try await peer.inbox.next(timeout: 30),
              let meta = try? JSONDecoder().decode(CandyWireMessage.self, from: Data(first.utf8)) else {
            throw CandyTransferFailure.network("对方协议不兼容。")
        }
        if meta.t == "error" { throw CandyTransferFailure.network("对方拒绝：\(meta.error ?? "unknown")") }
        let size = job.file.size
        let expectedBlocks = Int((size + Int64(candyBlockSize) - 1) / Int64(candyBlockSize))
        guard meta.t == "meta", meta.cid == job.file.id, meta.size == size, meta.blockSize == candyBlockSize,
              let blocks = meta.blocks, blocks.count == expectedBlocks else {
            throw CandyTransferFailure.invalid("对方返回的文件描述与广场信息不一致。")
        }
        report(job, position, "点对点传输中")
        var blockIndex = Int(position / Int64(candyBlockSize))
        var blockHasher = SHA256()
        var inBlock = 0
        receiving: while true {
            switch try await peer.inbox.next(timeout: 30) {
            case .text(let text):
                let control = try? JSONDecoder().decode(CandyWireMessage.self, from: Data(text.utf8))
                if control?.t == "end" { break receiving }
                throw CandyTransferFailure.network("传输被中止：\(control?.error ?? "unknown")")
            case .binary(let data):
                guard data.count <= candyChunkSize * 4, position + Int64(data.count) <= size else {
                    throw CandyTransferFailure.invalid("收到越界数据。")
                }
                var cursor = data.startIndex
                while cursor < data.endIndex {
                    let blockLength = Int(min(Int64(candyBlockSize), size - Int64(blockIndex) * Int64(candyBlockSize)))
                    let take = min(blockLength - inBlock, data.endIndex - cursor)
                    let piece = Data(data[cursor..<(cursor + take)])
                    blockHasher.update(data: piece)
                    try await job.disk.append(piece, at: position)
                    position += Int64(take)
                    inBlock += take
                    cursor += take
                    if inBlock == blockLength {
                        let digest = blockHasher.finalize().map { String(format: "%02x", $0) }.joined()
                        guard digest == blocks[blockIndex] else {
                            try await job.disk.rewind(to: Int64(blockIndex) * Int64(candyBlockSize))
                            throw CandyTransferFailure.invalid("第 \(blockIndex + 1) 块校验失败，换源重试")
                        }
                        blockIndex += 1
                        inBlock = 0
                        blockHasher = SHA256()
                        reportVerified(job, min(size, Int64(blockIndex) * Int64(candyBlockSize)))
                    }
                }
                report(job, position, "点对点传输中", force: false)
            }
        }
        guard position == size else { throw CandyTransferFailure.network("文件不完整。") }
        let url: URL
        do { url = try await job.disk.finish() }
        catch {
            reportVerified(job, 0)
            try? await job.disk.clear()
            _ = try? await job.disk.prepare()
            try? peer.sendControl(CandyWireMessage(t: "error", error: "hash-mismatch"))
            throw error
        }
        try? peer.sendControl(CandyWireMessage(t: "done"))
        return url
    }

    private func awaitAnswer(_ offer: CandySignal, _ continuation: CheckedContinuation<CandySignal, Error>) {
        let session = offer.session
        pendingAnswers[session] = continuation
        sendSignal?(offer)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.pendingAnswers.removeValue(forKey: session)?.resume(throwing: CandyTransferFailure.network("对方未应答"))
        }
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg", "oga", "opus": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - WebRTC helpers

private extension RTCPeerConnection {
    func candyOffer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CandyTransferFailure.network("创建连接失败。")) }
            }
        }
    }

    func candyAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CandyTransferFailure.network("应答连接失败。")) }
            }
        }
    }

    func candyApplyLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func candyApplyRemote(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// One-shot main-actor event that tasks can await with a timeout.
@MainActor
final class CandyLatch {
    private var finished = false
    private var failure: Error?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var isSucceeded: Bool { finished && failure == nil }

    nonisolated init() {}

    func succeed() { finish(nil) }
    func fail(_ error: Error) { finish(error) }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        failure = error
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    /// Waits for the event; on timeout throws `failure`, or returns normally when `failure` is nil.
    func wait(seconds: Double, failure timeoutError: Error? = nil) async throws {
        if finished {
            if let failure { throw failure }
            return
        }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in self.register(id, continuation, seconds: seconds, timeoutError: timeoutError) }
        }
    }

    private func register(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>, seconds: Double, timeoutError: Error?) {
        if finished {
            if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
            return
        }
        waiters[id] = continuation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let continuation = self.waiters.removeValue(forKey: id) else { return }
            if let timeoutError { continuation.resume(throwing: timeoutError) } else { continuation.resume() }
        }
    }

    /// Non-throwing wait (used for ICE gathering, which proceeds on timeout).
    func wait(seconds: Double) async {
        try? await wait(seconds: seconds, failure: nil)
    }
}

/// Thread-safe queue fed by WebRTC delegate callbacks.
final class CandyInbox: @unchecked Sendable {
    enum Item { case text(String), binary(Data) }
    private let lock = NSLock()
    private var queue: [Item] = []
    private var head = 0
    private var bytes = 0
    private var failure: Error?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Item, Error>)?

    func push(_ item: Item) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: item)
            return
        }
        queue.append(item)
        if case .binary(let data) = item { bytes += data.count }
        let overflow = bytes > 33_554_432
        lock.unlock()
        if overflow { fail(CandyTransferFailure.network("接收缓冲已满，正在恢复。")) }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.continuation.resume(throwing: error)
    }

    func next(timeout: TimeInterval) async throws -> Item {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if head < queue.count {
                let item = queue[head]
                head += 1
                if case .binary(let data) = item { bytes -= data.count }
                if head > 256 {
                    queue.removeFirst(head)
                    head = 0
                }
                lock.unlock()
                continuation.resume(returning: item)
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                waiter = (id, continuation)
                lock.unlock()
            }
        }
    }

    private func expire(_ id: UUID) {
        lock.lock()
        guard let pending = waiter, pending.id == id else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        pending.continuation.resume(throwing: CandyTransferFailure.network("对方长时间无响应"))
    }
}

final class CandyRTCPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let session: String
    let remote: String
    var connection: RTCPeerConnection?
    private(set) var channel: RTCDataChannel?
    let inbox = CandyInbox()
    let gathering = CandyLatch()
    let channelOpen = CandyLatch()
    @MainActor var onChannel: (@MainActor (RTCDataChannel) -> Void)?
    @MainActor private var iceState: RTCIceConnectionState = .new
    @MainActor private var closed = false
    @MainActor private var earlyGathering = false
    /// With TURN configured, wait for a relay candidate; otherwise a server-reflexive one is enough.
    private let expectsRelay: Bool

    init(session: String, remote: String, expectsRelay: Bool = false) {
        self.session = session
        self.remote = remote
        self.expectsRelay = expectsRelay
    }

    @MainActor func attach(_ channel: RTCDataChannel) -> Bool {
        guard self.channel == nil, !closed else { return false }
        self.channel = channel
        channel.delegate = self
        if channel.readyState == .open { channelOpen.succeed() }
        return true
    }

    @MainActor func sendControl(_ message: CandyWireMessage) throws {
        let bytes = try JSONEncoder().encode(message)
        guard channel?.readyState == .open, channel?.sendData(RTCDataBuffer(data: bytes, isBinary: false)) == true else {
            throw CandyTransferFailure.network("控制消息发送失败。")
        }
    }

    @MainActor func shutdown(_ error: Error) {
        guard !closed else { return }
        closed = true
        inbox.fail(error)
        channelOpen.fail(error)
        gathering.succeed()
        channel?.close()
        connection?.close()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in onChannel?(dataChannel) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { Task { @MainActor in gathering.succeed() } }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            iceState = newState
            switch newState {
            case .failed, .closed:
                inbox.fail(CandyTransferFailure.network("点对点连接中断"))
                channelOpen.fail(CandyTransferFailure.network("点对点连接失败"))
            case .disconnected:
                // Brief disconnects can heal; a network switch does not.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if iceState == .disconnected { inbox.fail(CandyTransferFailure.network("点对点连接中断")) }
            default: break
            }
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor in
            if state == .open { channelOpen.succeed() }
            else if state == .closed {
                inbox.fail(CandyTransferFailure.network("文件通道已关闭"))
                channelOpen.fail(CandyTransferFailure.network("文件通道已关闭"))
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if buffer.isBinary { inbox.push(.binary(buffer.data)) }
        else { inbox.push(.text(String(decoding: buffer.data, as: UTF8.self))) }
    }

    /// Non-trickle SDP waits for gathering, which can idle for seconds on dead interfaces.
    /// Once a candidate that works across NATs exists, give siblings a moment and send.
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp
        let usable = sdp.contains(" typ relay") || (!expectsRelay && sdp.contains(" typ srflx"))
        guard usable else { return }
        Task { @MainActor in
            guard !earlyGathering else { return }
            earlyGathering = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            gathering.succeed()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
