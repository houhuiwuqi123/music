import CryptoKit
import Foundation
import WebRTC

struct CandyTransferGrant: Codable {
    var id: String
    var file: CandyPlazaFile
    var mode: String
    var token: String
    var downloadURL: String?
    var uploadURL: String?
    var expiresAt: Int64
    var status: String?
}

struct CandyTransferICE: Codable {
    var urls: [String]
    var username: String?
    var credential: String?
}

struct CandyTransferEnvelope: Codable {
    var type: String
    var requestId: String? = nil
    var fileId: String? = nil
    var to: String? = nil
    var from: String? = nil
    var transferId: String? = nil
    var generation: Int? = nil
    var mode: String? = nil
    var data: String? = nil
    var transfer: CandyTransferGrant? = nil
    var error: String? = nil
    var iceServers: [CandyTransferICE]? = nil
    var gatewayEnabled: Bool? = nil
    var protocolVersion: Int? = nil
}

private struct CandyTransferSignal: Codable {
    struct Description: Codable { var type: String; var sdp: String }
    struct Candidate: Codable { var candidate: String; var sdpMid: String?; var sdpMLineIndex: Int32 }
    var kind: String
    var transferId: String
    var fileId: String
    var generation: Int
    var sdp: Description? = nil
    var candidate: Candidate? = nil
}

private struct CandyTransferControl: Codable {
    var type: String
    var offset: Int64? = nil
    var size: Int64? = nil
    var sha256: String? = nil
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
    var retryable: Bool {
        if case .network = self { return true }
        return false
    }
}

actor CandyTransferDisk {
    struct Manifest: Sendable { var size: Int64; var sha256: String }
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
        let owner = SHA256.hash(data: Data((file.ownerId ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "\(owner)-\(file.sha256 ?? file.id)"
        let staging = folder.appendingPathComponent(".partial", isDirectory: true)
        part = staging.appendingPathComponent(key).appendingPathExtension("part")
        record = staging.appendingPathComponent(key).appendingPathExtension("json")
    }

    nonisolated static func manifest(_ url: URL) async throws -> Manifest {
        try await Task.detached(priority: .utility) {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size >= 0 else {
                throw CandyTransferFailure.source("分享文件不可读取。")
            }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var hasher = SHA256()
            var count: Int64 = 0
            while let data = try input.read(upToCount: 262_144), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
                count += Int64(data.count)
            }
            let final = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard count == Int64(size), final.fileSize == size,
                  final.contentModificationDate == attributes.contentModificationDate else {
                throw CandyTransferFailure.source("分享文件在读取过程中发生变化。")
            }
            return Manifest(size: count, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
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
            if Date().timeIntervalSince(saved.updated) < 86_400 {
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                var remaining = saved.offset
                hasher = SHA256()
                while remaining > 0 {
                    guard let chunk = try input.read(upToCount: Int(min(remaining, 262_144))), !chunk.isEmpty else {
                        throw CandyTransferFailure.invalid("下载断点文件不完整，请清除断点后重试。")
                    }
                    hasher.update(data: chunk)
                    remaining -= Int64(chunk.count)
                }
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

    func append(_ data: Data, at expected: Int64) throws -> Int64? {
        guard completedURL == nil, let handle, expected == offset, !data.isEmpty, data.count <= 1_048_576,
              Int64(data.count) <= file.size - offset else {
            throw CandyTransferFailure.invalid("收到越界或顺序错误的歌曲数据。")
        }
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        offset += Int64(data.count)
        if offset - checkpointOffset >= 262_144 || offset == file.size {
            try checkpoint()
            return offset
        }
        return nil
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

private actor CandyUploadBudget {
    private struct Waiter {
        var id: UUID
        var count: Int
        var continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var tokens = 1_048_576.0
    private var updated = Date()
    private var pumpTask: Task<Void, Never>?

    func acquire(_ count: Int) async throws {
        try Task.checkCancellation()
        guard count > 0, count <= 1_048_576 else { throw CandyTransferFailure.invalid("上传数据块超出速率预算。") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, count: count, continuation: continuation))
                if pumpTask == nil { pumpTask = Task { await pump() } }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func pump() async {
        while let first = waiters.first {
            let now = Date()
            tokens = min(1_048_576, tokens + max(0, now.timeIntervalSince(updated)) * 1_048_576)
            updated = now
            if tokens >= Double(first.count) {
                tokens -= Double(first.count)
                waiters.removeFirst().continuation.resume()
            } else {
                let delay = max(0.025, (Double(first.count) - tokens) / 1_048_576)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch {
                    let pending = waiters
                    waiters.removeAll()
                    pending.forEach { $0.continuation.resume(throwing: error) }
                }
            }
        }
        pumpTask = nil
    }
}

@MainActor
final class CandyReliableTransfer {
    var send: ((CandyTransferEnvelope) -> Void)?
    var changed: ((CandyPlazaFile, Double, String) -> Void)?
    var completed: ((CandyPlazaFile, URL) -> Void)?
    var failed: ((CandyPlazaFile?, String) -> Void)?
    var publicationUnavailable: ((String) -> Void)?

    private final class Job {
        let file: CandyPlazaFile
        let disk: CandyTransferDisk
        let requestID = UUID().uuidString.lowercased()
        var grant: CandyTransferGrant?
        var generation = 0
        var task: Task<Void, Never>?
        var retries = 0
        var retryStarted = Date()
        var lastProgress = Date()
        var lastRequest = Date.distantPast
        var status = "等待授权"
        var lastUIUpdate = Date.distantPast
        var forceRelay = false
        var offset: Int64 = 0
        init(file: CandyPlazaFile, folder: URL) {
            self.file = file
            disk = CandyTransferDisk(file: file, folder: folder)
        }
    }
    private struct Publication: Sendable {
        var file: CandyPlazaFile
        var url: URL
        var time: Date
        var modified: Date?
    }
    private let folder: URL
    private var jobs: [String: Job] = [:]
    private var diskClosures: [String: Task<Void, Never>] = [:]
    private var diskClosureVersions: [String: UUID] = [:]
    private var publications: [String: Publication] = [:]
    private var currentFileID: String?
    private var authorized: [String: CandyTransferGrant] = [:]
    private var recipients: [String: String] = [:]
    private var peers: [String: CandyTransferPeer] = [:]
    private var earlyCandidates: [String: [CandyTransferSignal.Candidate]] = [:]
    private var uploads: [String: Task<Void, Never>] = [:]
    private var uploadFiles: [String: String] = [:]
    private var cancelledUploads: Set<String> = []
    private var iceServers: [CandyTransferICE] = []
    private var gatewayEnabled = false
    private var configured = false
    private var connected = false
    private var monitor: Task<Void, Never>?
    private var lastSourceCheck = Date.distantPast
    private let factory: RTCPeerConnectionFactory
    private let uploadBudget = CandyUploadBudget()
    private let http = CandyTransferHTTP()

    init(folder: URL) {
        self.folder = folder
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
        Task { [weak self] in
            do { try await CandyTransferDisk.cleanExpiredPartials(in: folder) }
            catch { self?.failed?(nil, "下载断点清理失败：\(error.localizedDescription)") }
        }
    }

    func publish(_ file: CandyPlazaFile, url: URL) throws {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard Int64(attributes.fileSize ?? -1) == file.size else {
            throw CandyTransferFailure.invalid("源歌曲在准备分享时发生变化。")
        }
        currentFileID = file.id
        publications[file.id] = Publication(file: file, url: url, time: Date(), modified: attributes.contentModificationDate)
        let held = Set(authorized.values.map { $0.file.id })
        publications = publications.filter { $0.key == file.id || held.contains($0.key) || Date().timeIntervalSince($0.value.time) < 600 }
        if publications.count > 64 {
            let idle = publications.values.filter { $0.file.id != file.id && !held.contains($0.file.id) }
                .sorted { $0.time < $1.time }
            for item in idle.prefix(publications.count - 64) { publications.removeValue(forKey: item.file.id) }
        }
    }

    func withdraw() {
        currentFileID = nil
        publications.removeAll()
        for id in Array(authorized.keys) { closePeer(id) }
        authorized.removeAll()
        recipients.removeAll()
        uploads.values.forEach { $0.cancel() }
        uploads.removeAll()
        uploadFiles.removeAll()
        cancelledUploads.removeAll()
    }

    func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        if !value {
            configured = false
            monitor?.cancel()
            monitor = nil
            for id in Array(peers.keys) { closePeer(id) }
            earlyCandidates.removeAll()
            authorized.removeAll()
            recipients.removeAll()
            uploads.values.forEach { $0.cancel() }
            uploads.removeAll()
            uploadFiles.removeAll()
            for job in jobs.values {
                job.task?.cancel()
                job.task = nil
                parkDisk(job)
                job.grant = nil
                job.status = "等待重新连接"
                changed?(job.file, progress(job), job.status)
            }
        } else {
            monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastSourceCheck) >= 10 {
                        self.lastSourceCheck = Date()
                        let snapshots = Array(self.publications.values)
                        let invalid = await Task.detached(priority: .utility) {
                            snapshots.compactMap { item -> String? in
                                do {
                                    let values = try item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                                    return Int64(values.fileSize ?? -1) == item.file.size && values.contentModificationDate == item.modified ? nil : item.file.id
                                } catch {
                                    return item.file.id
                                }
                            }
                        }.value
                        for id in invalid where self.publications[id] != nil { self.sourceUnavailable(id) }
                    }
                    for peer in Array(self.peers.values) where peer.channel?.readyState != .open {
                        if Date().timeIntervalSince(peer.created) > 20 { peer.onFailure?("下载建连超过 20 秒，正在恢复。") }
                    }
                    for job in Array(self.jobs.values) {
                        if let grant = job.grant, grant.expiresAt - Int64(Date().timeIntervalSince1970) < 60,
                           Date().timeIntervalSince(job.lastRequest) > 15 {
                            self.request(job)
                        }
                        if Date().timeIntervalSince(job.lastProgress) > 30, job.task == nil {
                            self.retry(job, message: "下载连接无进展。")
                        }
                    }
                    for (id, grant) in self.authorized where grant.expiresAt <= Int64(Date().timeIntervalSince1970) {
                        self.closePeer(id)
                        self.authorized.removeValue(forKey: id)
                        self.recipients.removeValue(forKey: id)
                    }
                }
            }
            if configured { resumeRequests() }
        }
    }

    func download(_ file: CandyPlazaFile) {
        guard configured else {
            failed?(file, "服务器尚未启用可靠下载，请先部署新版信令和网关。")
            return
        }
        guard file.protocolVersion == 2, file.sha256?.count == 64, file.ownerId != nil else {
            failed?(file, "发布者尚未准备好可靠分享，请更新双方 App 后重试。")
            return
        }
        guard jobs[file.id] == nil else { return }
        guard !jobs.values.contains(where: { $0.file.ownerId == file.ownerId && $0.file.sha256 == file.sha256 }) else {
            failed?(file, "同一首歌曲正在下载，请等待原任务完成。")
            return
        }
        guard jobs.count < 2 else {
            failed?(file, "最多同时下载两首歌曲，请完成或取消后再试。")
            return
        }
        let job = Job(file: file, folder: folder)
        jobs[file.id] = job
        changed?(file, 0, job.status)
        request(job)
    }

    func cancel(_ fileID: String, clearPartial: Bool = false) {
        guard let job = jobs.removeValue(forKey: fileID) else { return }
        job.task?.cancel()
        if let grant = job.grant {
            closePeer(grant.id)
        }
        send?(CandyTransferEnvelope(type: "transfer-cancel", requestId: job.requestID, transferId: job.grant?.id))
        parkDisk(job, clearPartial: clearPartial)
        failed?(job.file, "下载已取消，断点保留 24 小时。")
    }

    func clearPartial(_ file: CandyPlazaFile) {
        guard jobs[file.id] == nil else {
            failed?(file, "请先取消下载再清除断点。")
            return
        }
        parkDisk(Job(file: file, folder: folder), clearPartial: true) { [weak self] in
            self?.failed?(file, "断点已清除，请重试下载。")
        }
    }

    func handle(_ message: CandyTransferEnvelope) {
        switch message.type {
        case "config":
            guard message.protocolVersion == 2 else { return }
            iceServers = message.iceServers ?? []
            gatewayEnabled = message.gatewayEnabled == true
            configured = true
            if connected { resumeRequests() }
        case "transfer":
            guard let grant = message.transfer,
                  let job = jobs.values.first(where: { $0.requestID == message.requestId || $0.grant?.id == grant.id }),
                  grant.file.sha256 == job.file.sha256, grant.file.size == job.file.size,
                  grant.file.ownerId == job.file.ownerId else { return }
            let alreadyRunning = job.grant?.id == grant.id && (job.task != nil || peers[grant.id] != nil)
            job.grant = grant
            if !alreadyRunning {
                if grant.mode == "relay" { receiveRelay(job) }
                else if grant.mode == "p2p" { startPeer(job) }
                else { fail(job, "服务器返回不支持的下载方式。") }
            }
        case "transfer-authorized":
            guard let grant = message.transfer, let recipient = message.from,
                  let publication = publications[grant.file.id],
                  publication.file.sha256 == grant.file.sha256 else { return }
            authorized[grant.id] = grant
            recipients[grant.id] = recipient
        case "upload-request":
            guard let grant = message.transfer else { return }
            upload(grant)
        case "transfer-completed":
            guard let id = message.transferId else { return }
            closePeer(id)
            authorized.removeValue(forKey: id)
            recipients.removeValue(forKey: id)
        case "transfer-error":
            guard let job = jobs.values.first(where: { $0.requestID == message.requestId || $0.grant?.id == message.transferId }) else {
                failed?(nil, message.error ?? "服务器拒绝传输请求。")
                return
            }
            fail(job, message.error ?? "服务器拒绝传输请求。")
        case "transfer-revoked":
            guard let id = message.transferId else { return }
            closePeer(id)
            authorized.removeValue(forKey: id)
            recipients.removeValue(forKey: id)
            uploads.removeValue(forKey: id)?.cancel()
            cancelledUploads.insert(id)
            if let job = jobs.values.first(where: { $0.grant?.id == id }) {
                fail(job, message.error ?? "发布者已撤销下载授权。")
            }
        case "signal":
            do {
                guard let data = message.data?.data(using: .utf8) else { throw CandyTransferFailure.invalid("连接信令缺少数据。") }
                let signal = try JSONDecoder().decode(CandyTransferSignal.self, from: data)
                guard signal.transferId == message.transferId, signal.generation == message.generation,
                      let remote = message.from else { throw CandyTransferFailure.invalid("连接信令的任务身份不一致。") }
                handleSignal(signal, remote: remote)
            } catch { failed?(nil, "无法处理下载信令：\(error.localizedDescription)") }
        default: break
        }
    }

    private func resumeRequests() {
        for job in jobs.values where job.task == nil && job.grant == nil { request(job) }
    }

    private func request(_ job: Job) {
        guard connected, configured else { return }
        job.lastRequest = Date()
        if job.grant == nil { job.lastProgress = Date() }
        job.status = "等待下载授权"
        changed?(job.file, progress(job), job.status)
        send?(CandyTransferEnvelope(type: "transfer-request", requestId: job.requestID, fileId: job.file.id,
            to: job.file.ownerId, transferId: job.grant?.id, mode: job.forceRelay ? "relay" : nil))
    }

    private func progress(_ job: Job) -> Double {
        job.file.size == 0 ? 0 : min(1, Double(job.offset) / Double(job.file.size))
    }

    private func fail(_ job: Job, _ message: String) {
        guard jobs[job.file.id] === job else { return }
        jobs.removeValue(forKey: job.file.id)
        job.task?.cancel()
        if let grant = job.grant {
            closePeer(grant.id)
        }
        send?(CandyTransferEnvelope(type: "transfer-cancel", requestId: job.requestID, transferId: job.grant?.id))
        parkDisk(job)
        failed?(job.file, message)
    }

    private func retry(_ job: Job, message: String) {
        guard jobs[job.file.id] === job else { return }
        if let id = job.grant?.id { closePeer(id) }
        job.task?.cancel()
        job.task = nil
        guard Date().timeIntervalSince(job.retryStarted) < 300 else {
            fail(job, "\(message) 自动恢复超过 5 分钟，断点已保留，请手动重试。")
            return
        }
        if gatewayEnabled { job.forceRelay = true }
        job.retries += 1
        job.status = "网络中断，正在恢复（\(job.retries)）"
        changed?(job.file, progress(job), job.status)
        job.task = Task { @MainActor [weak self] in
            do {
                try await job.disk.close()
                let delay = min(30, pow(2, Double(min(job.retries - 1, 5)))) + Double.random(in: 0...0.5)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
                guard let self, self.jobs[job.file.id] === job else { return }
                job.task = nil
                self.request(job)
            } catch is CancellationError { return }
            catch {
                guard let self, self.jobs[job.file.id] === job else { return }
                self.fail(job, "下载断点无法恢复：\(error.localizedDescription)")
            }
        }
    }

    private func contentKey(_ file: CandyPlazaFile) -> String { "\(file.ownerId ?? ""):\(file.sha256 ?? file.id)" }

    private func parkDisk(_ job: Job, clearPartial: Bool = false, completion: (() -> Void)? = nil) {
        let key = contentKey(job.file)
        let previous = diskClosures[key]
        let version = UUID()
        diskClosureVersions[key] = version
        diskClosures[key] = Task { @MainActor in
            defer {
                if diskClosureVersions[key] == version {
                    diskClosures.removeValue(forKey: key)
                    diskClosureVersions.removeValue(forKey: key)
                }
            }
            do {
                if let previous { await previous.value }
                if clearPartial { try await job.disk.clear() }
                else { try await job.disk.close() }
                completion?()
            } catch { failed?(job.file, "保存下载断点失败：\(error.localizedDescription)") }
        }
    }

    private func prepareDisk(_ job: Job) async throws -> Int64 {
        if let closing = diskClosures[contentKey(job.file)] { await closing.value }
        try Task.checkCancellation()
        return try await job.disk.prepare()
    }

    private func finish(_ job: Job) async throws {
        let destination = try await job.disk.finish()
        guard jobs[job.file.id] === job, !Task.isCancelled else { return }
        jobs.removeValue(forKey: job.file.id)
        completed?(job.file, destination)
        if let grant = job.grant {
            if let peer = peers[grant.id] {
                do { try peer.control(CandyTransferControl(type: "complete", offset: job.file.size, sha256: job.file.sha256)) }
                catch { failed?(nil, "歌曲已校验保存，但点对点完成确认失败；正在通过信令确认：\(error.localizedDescription)") }
            }
            send?(CandyTransferEnvelope(type: "transfer-complete", transferId: grant.id))
            closePeer(grant.id)
        }
    }

    private func checkedURL(_ value: String?) throws -> URL {
        guard let value, let url = URL(string: value), url.scheme == "https",
              url.host == "music.webtrc.eu.cc", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            throw CandyTransferFailure.invalid("下载网关必须使用 music.webtrc.eu.cc 的 HTTPS 地址。")
        }
        return url
    }

    private func httpRequest(_ url: URL, token: String, method: String = "HEAD") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func response(_ request: URLRequest, body: Data? = nil, limit: Int = 1_048_576) async throws -> (Data, HTTPURLResponse) {
        try await http.response(request, body: body, limit: limit)
    }

    private func requireAuthorized(_ response: HTTPURLResponse) throws {
        if [401, 403, 404, 410].contains(response.statusCode) {
            throw CandyTransferFailure.invalid("下载授权已失效或发布者已离线。")
        }
        if response.statusCode >= 500 || response.statusCode == 429 {
            throw CandyTransferFailure.network("下载网关繁忙，正在重试。")
        }
    }

    private func receiveRelay(_ job: Job) {
        guard let grant = job.grant else { return }
        job.task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try self.checkedURL(grant.downloadURL)
                job.offset = try await self.prepareDisk(job)
                while true {
                    try Task.checkCancellation()
                    let (_, head) = try await self.response(self.httpRequest(url, token: grant.token))
                    try self.requireAuthorized(head)
                    if head.statusCode == 200 { break }
                    guard head.statusCode == 409 || head.statusCode == 425 || head.statusCode == 202 else {
                        throw CandyTransferFailure.invalid("网关尚未准备好歌曲，HTTP \(head.statusCode)。")
                    }
                    guard Date().timeIntervalSince(job.retryStarted) < 300 else {
                        throw CandyTransferFailure.invalid("发布者上传等待超过 5 分钟，请稍后重试。")
                    }
                    job.status = "等待发布者上传至临时中转"
                    self.changed?(job.file, self.progress(job), job.status)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
                while job.offset < job.file.size {
                    try Task.checkCancellation()
                    let end = min(job.file.size - 1, job.offset + 1_048_576 - 1)
                    var request = self.httpRequest(url, token: grant.token, method: "GET")
                    request.setValue("bytes=\(job.offset)-\(end)", forHTTPHeaderField: "Range")
                    request.setValue("\"\(job.file.sha256 ?? "")\"", forHTTPHeaderField: "If-Match")
                    let (data, result) = try await self.response(request)
                    try self.requireAuthorized(result)
                    guard result.statusCode == 206,
                          result.value(forHTTPHeaderField: "Content-Range") == "bytes \(job.offset)-\(end)/\(job.file.size)",
                          result.value(forHTTPHeaderField: "ETag") == "\"\(job.file.sha256 ?? "")\"",
                          data.count == Int(end - job.offset + 1) else {
                        throw CandyTransferFailure.invalid("网关断点或文件版本校验失败。")
                    }
                    _ = try await job.disk.append(data, at: job.offset)
                    job.offset = try await job.disk.durableOffset()
                    job.lastProgress = Date()
                    job.retries = 0
                    job.retryStarted = Date()
                    self.changed?(job.file, self.progress(job), "中转下载中")
                }
                self.changed?(job.file, self.progress(job), "正在校验歌曲")
                try await self.finish(job)
            } catch is CancellationError { return }
            catch {
                guard self.jobs[job.file.id] === job else { return }
                job.task = nil
                if self.retryable(error) { self.retry(job, message: error.localizedDescription) }
                else { self.fail(job, error.localizedDescription) }
            }
        }
    }

    private func retryable(_ error: Error) -> Bool {
        if let failure = error as? CandyTransferFailure { return failure.retryable }
        return error is URLError
    }

    private func upload(_ grant: CandyTransferGrant) {
        guard !cancelledUploads.contains(grant.id), uploads[grant.id] == nil else { return }
        guard let publication = publications[grant.file.id],
              publication.file.sha256 == grant.file.sha256, publication.file.size == grant.file.size else {
            send?(CandyTransferEnvelope(type: "upload-error", transferId: grant.id, error: "Source snapshot is unavailable."))
            failed?(nil, "中转请求的源歌曲已不可用。")
            return
        }
        guard uploads.count < 1 else {
            send?(CandyTransferEnvelope(type: "upload-error", transferId: grant.id, error: "Publisher upload is busy."))
            failed?(nil, "中转上传已满，请稍后重试。")
            return
        }
        uploadFiles[grant.id] = grant.file.id
        uploads[grant.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.uploads.removeValue(forKey: grant.id)
                self.uploadFiles.removeValue(forKey: grant.id)
            }
            var source: CandyTransferSource?
            do {
                let url = try self.checkedURL(grant.uploadURL)
                let manifest = try await CandyTransferDisk.manifest(publication.url)
                guard manifest.sha256 == grant.file.sha256, manifest.size == grant.file.size else {
                    throw CandyTransferFailure.source("源歌曲已变更，无法继续中转上传。")
                }
                let input = try CandyTransferSource(url: publication.url)
                source = input
                var retries = 0
                let deadline = Date().addingTimeInterval(300)
                while true {
                    try Task.checkCancellation()
                    do {
                        let (_, head) = try await self.response(self.httpRequest(url, token: grant.token))
                        try self.requireAuthorized(head)
                        guard head.statusCode == 200 || head.statusCode == 204,
                              let rawOffset = head.value(forHTTPHeaderField: "Upload-Offset"),
                              let offset = Int64(rawOffset), offset >= 0, offset <= grant.file.size else {
                            throw CandyTransferFailure.invalid("中转上传断点无效。")
                        }
                        if offset == grant.file.size { break }
                        let data = try await input.read(offset: offset, count: Int(min(1_048_576, grant.file.size - offset)))
                        guard !data.isEmpty else { throw CandyTransferFailure.source("源歌曲已不可读取。") }
                        try await self.uploadBudget.acquire(data.count)
                        var request = self.httpRequest(url, token: grant.token, method: "PUT")
                        request.setValue("bytes \(offset)-\(offset + Int64(data.count) - 1)/\(grant.file.size)", forHTTPHeaderField: "Content-Range")
                        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        let (_, result) = try await self.response(request, body: data, limit: 65_536)
                        try self.requireAuthorized(result)
                        guard [200, 201, 204, 409].contains(result.statusCode) else {
                            throw CandyTransferFailure.invalid("中转上传失败，HTTP \(result.statusCode)。")
                        }
                        retries = 0
                        // A single relay upload and two P2P senders have independent bounded pacing.
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        guard self.retryable(error), Date() < deadline else { throw error }
                        retries += 1
                        let delay = min(30, pow(2, Double(min(retries - 1, 5))))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
                try await input.close()
                source = nil
            } catch is CancellationError {
                if let source { try? await source.close() }
            } catch {
                if let source { try? await source.close() }
                self.failed?(nil, "歌曲中转上传失败：\(error.localizedDescription)")
                self.send?(CandyTransferEnvelope(type: "upload-error", transferId: grant.id, error: "Publisher upload failed."))
                if self.isSourceFailure(error) { self.sourceUnavailable(grant.file.id) }
            }
        }
    }

    private func startPeer(_ job: Job) {
        guard let grant = job.grant, let remote = grant.file.ownerId else { return }
        job.generation += 1
        let peer = makePeer(grant: grant, remote: remote, generation: job.generation, serving: false)
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let channel = peer.connection?.dataChannel(forLabel: "file-v2:\(grant.id)", configuration: config) else {
            retry(job, message: "无法创建可靠文件通道。")
            return
        }
        peer.attach(channel)
        peer.connection?.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self, weak peer] description, error in
            Task { @MainActor in
                guard let self, let peer, self.peers[grant.id] === peer else { return }
                guard let description else { self.retry(job, message: error?.localizedDescription ?? "创建连接失败。"); return }
                peer.connection?.setLocalDescription(description) { error in
                    Task { @MainActor in
                        guard self.peers[grant.id] === peer else { return }
                        if let error { self.retry(job, message: error.localizedDescription); return }
                        self.signal(peer, kind: "offer", description: description)
                    }
                }
            }
        }
    }

    private func makePeer(grant: CandyTransferGrant, remote: String, generation: Int, serving: Bool) -> CandyTransferPeer {
        closePeer(grant.id)
        let peer = CandyTransferPeer(id: grant.id, fileID: grant.file.id, remote: remote, generation: generation, serving: serving)
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: server.urls)
        }
        peer.connection = factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: peer)
        peers[grant.id] = peer
        let candidateKey = "\(grant.id):\(generation)"
        for candidate in earlyCandidates.removeValue(forKey: candidateKey) ?? [] {
            peer.add(RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
        }
        peer.onCandidate = { [weak self, weak peer] candidate in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            self.signal(peer, kind: "candidate", candidate: candidate)
        }
        peer.onOpen = { [weak self, weak peer] in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            if !serving, let job = self.jobs[grant.file.id] {
                Task { @MainActor in
                    do {
                        job.offset = try await self.prepareDisk(job)
                        guard self.peers[peer.id] === peer else { return }
                        try peer.control(CandyTransferControl(type: "resume", offset: job.offset, size: job.file.size, sha256: job.file.sha256))
                        job.lastProgress = Date()
                        self.changed?(job.file, self.progress(job), "点对点下载中")
                    } catch { self.fail(job, error.localizedDescription) }
                }
            }
        }
        peer.onData = { [weak self, weak peer] buffer in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            await self.receive(buffer, peer: peer, grant: grant)
        }
        peer.onFailure = { [weak self, weak peer] message in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            if !serving, let job = self.jobs[grant.file.id] { self.retry(job, message: message) }
            else { self.closePeer(peer.id); self.failed?(nil, message) }
        }
        return peer
    }

    private func signal(_ peer: CandyTransferPeer, kind: String, description: RTCSessionDescription? = nil, candidate: RTCIceCandidate? = nil) {
        let signal = CandyTransferSignal(kind: kind, transferId: peer.id, fileId: peer.fileID, generation: peer.generation,
            sdp: description.map { .init(type: kind, sdp: $0.sdp) },
            candidate: candidate.map { .init(candidate: $0.sdp, sdpMid: $0.sdpMid, sdpMLineIndex: $0.sdpMLineIndex) })
        do {
            let data = try JSONEncoder().encode(signal)
            send?(CandyTransferEnvelope(type: "signal", to: peer.remote, transferId: peer.id,
                generation: peer.generation, data: String(decoding: data, as: UTF8.self)))
        } catch { peer.onFailure?("无法编码连接信令：\(error.localizedDescription)") }
    }

    private func handleSignal(_ signal: CandyTransferSignal, remote: String) {
        if signal.kind == "candidate", peers[signal.transferId] == nil, let candidate = signal.candidate {
            guard authorized[signal.transferId] != nil || jobs.values.contains(where: { $0.grant?.id == signal.transferId }) else { return }
            let key = "\(signal.transferId):\(signal.generation)"
            guard earlyCandidates.count < 64, (earlyCandidates[key]?.count ?? 0) < 128 else {
                failed?(nil, "连接候选缓存超过限制。")
                return
            }
            earlyCandidates[key, default: []].append(candidate)
            return
        }
        let peer: CandyTransferPeer
        if signal.kind == "offer" {
            guard let grant = authorized[signal.transferId], recipients[signal.transferId] == remote,
                  grant.file.id == signal.fileId, grant.expiresAt > Int64(Date().timeIntervalSince1970) else { return }
            if let previous = peers[grant.id], previous.generation >= signal.generation { return }
            guard peers.values.filter({ $0.serving }).count < 2 || peers[grant.id] != nil else {
                failed?(nil, "发送并发超过授权上限。")
                return
            }
            peer = makePeer(grant: grant, remote: remote, generation: signal.generation, serving: true)
        } else {
            guard let existing = peers[signal.transferId], existing.remote == remote,
                  existing.generation == signal.generation, existing.fileID == signal.fileId else { return }
            peer = existing
        }
        if let candidate = signal.candidate, signal.kind == "candidate" {
            peer.add(RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
            return
        }
        guard let description = signal.sdp, signal.kind == "offer" || signal.kind == "answer" else { return }
        peer.connection?.setRemoteDescription(RTCSessionDescription(type: signal.kind == "offer" ? .offer : .answer, sdp: description.sdp)) { [weak self, weak peer] error in
            Task { @MainActor in
                guard let self, let peer, self.peers[peer.id] === peer else { return }
                if let error { peer.onFailure?(error.localizedDescription); return }
                peer.remoteDescriptionReady()
                guard signal.kind == "offer" else { return }
                peer.connection?.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                    Task { @MainActor in
                        guard self.peers[peer.id] === peer else { return }
                        guard let answer else { peer.onFailure?(error?.localizedDescription ?? "无法响应下载连接。"); return }
                        peer.connection?.setLocalDescription(answer) { error in
                            Task { @MainActor in
                                guard self.peers[peer.id] === peer else { return }
                                if let error { peer.onFailure?(error.localizedDescription); return }
                                self.signal(peer, kind: "answer", description: answer)
                            }
                        }
                    }
                }
            }
        }
    }

    private func receive(_ buffer: RTCDataBuffer, peer: CandyTransferPeer, grant: CandyTransferGrant) async {
        do {
            guard buffer.data.count <= 16_384 else { throw CandyTransferFailure.invalid("传输消息超出大小限制。") }
            if peer.serving {
                guard !buffer.isBinary else { throw CandyTransferFailure.invalid("发送端收到非预期的二进制数据。") }
                let control = try JSONDecoder().decode(CandyTransferControl.self, from: buffer.data)
                switch control.type {
                case "resume":
                    guard peer.worker == nil, control.sha256 == grant.file.sha256, control.size == grant.file.size,
                          let offset = control.offset, offset >= 0, offset <= grant.file.size else {
                        throw CandyTransferFailure.invalid("下载续传请求无效。")
                    }
                    peer.acknowledged = offset
                    transmit(peer, grant: grant, offset: offset)
                case "ack":
                    guard let offset = control.offset, offset >= peer.acknowledged, offset <= peer.sentOffset else {
                        throw CandyTransferFailure.invalid("下载确认断点越界。")
                    }
                    peer.acknowledged = offset
                    peer.lastProgress = Date()
                case "complete":
                    guard control.sha256 == grant.file.sha256, control.offset == grant.file.size else {
                        throw CandyTransferFailure.invalid("下载完成确认无效。")
                    }
                    closePeer(peer.id)
                    authorized.removeValue(forKey: peer.id)
                    recipients.removeValue(forKey: peer.id)
                default: throw CandyTransferFailure.invalid("无法识别下载控制消息。")
                }
            } else {
                guard let job = jobs[grant.file.id], job.grant?.id == peer.id else { return }
                if buffer.isBinary {
                    guard buffer.data.count > 8 else { throw CandyTransferFailure.invalid("文件分片缺少内容。") }
                    let offset = buffer.data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    guard offset <= UInt64(Int64.max) else { throw CandyTransferFailure.invalid("文件断点越界。") }
                    let bytes = Data(buffer.data.dropFirst(8))
                    let durable = try await job.disk.append(bytes, at: Int64(offset))
                    guard peers[peer.id] === peer else { return }
                    job.offset = Int64(offset) + Int64(bytes.count)
                    job.lastProgress = Date()
                    job.retryStarted = Date()
                    job.retries = 0
                    if let durable { try peer.control(CandyTransferControl(type: "ack", offset: durable)) }
                    if Date().timeIntervalSince(job.lastUIUpdate) >= 0.1 || job.offset == job.file.size {
                        job.lastUIUpdate = Date()
                        changed?(job.file, progress(job), "点对点下载中")
                    }
                } else {
                    let control = try JSONDecoder().decode(CandyTransferControl.self, from: buffer.data)
                    switch control.type {
                    case "meta":
                        guard control.size == job.file.size, control.sha256 == job.file.sha256 else {
                            throw CandyTransferFailure.invalid("发送端歌曲版本不一致。")
                        }
                    case "eof":
                        changed?(job.file, progress(job), "正在校验歌曲")
                        try await finish(job)
                    case "error": throw CandyTransferFailure.invalid(control.error ?? "发布者无法继续发送歌曲。")
                    default: throw CandyTransferFailure.invalid("无法识别文件传输消息。")
                    }
                }
            }
        } catch {
            if !peer.serving, let job = jobs[grant.file.id] { fail(job, error.localizedDescription) }
            else {
                try? peer.control(CandyTransferControl(type: "error", error: error.localizedDescription))
                closePeer(peer.id)
                failed?(nil, "歌曲发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func transmit(_ peer: CandyTransferPeer, grant: CandyTransferGrant, offset: Int64) {
        guard let publication = publications[grant.file.id] else { peer.onFailure?("源歌曲已不可用。"); return }
        peer.worker = Task { @MainActor [weak self, weak peer] in
            guard let self, let peer else { return }
            var source: CandyTransferSource?
            do {
                let manifest = try await CandyTransferDisk.manifest(publication.url)
                guard manifest.sha256 == grant.file.sha256, manifest.size == grant.file.size else {
                    throw CandyTransferFailure.source("分享文件已变更，下载已停止。")
                }
                let input = try CandyTransferSource(url: publication.url)
                source = input
                try peer.control(CandyTransferControl(type: "meta", size: grant.file.size, sha256: grant.file.sha256))
                peer.sentOffset = offset
                peer.lastProgress = Date()
                let started = Date()
                while peer.sentOffset < grant.file.size {
                    try Task.checkCancellation()
                    guard self.peers[peer.id] === peer, self.authorized[peer.id] != nil,
                          (self.authorized[peer.id]?.expiresAt ?? 0) > Int64(Date().timeIntervalSince1970),
                          peer.channel?.readyState == .open else { throw CandyTransferFailure.network("发送连接已关闭。") }
                    while peer.sentOffset - peer.acknowledged >= 1_048_576 || (peer.channel?.bufferedAmount ?? 0) > 524_288 {
                        try Task.checkCancellation()
                        guard Date().timeIntervalSince(peer.lastProgress) < 30 else { throw CandyTransferFailure.network("下载确认超时。") }
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                    let data = try await input.read(offset: peer.sentOffset, count: Int(min(16_376, grant.file.size - peer.sentOffset)))
                    guard !data.isEmpty else { throw CandyTransferFailure.source("源歌曲被删除或截断。") }
                    var value = UInt64(peer.sentOffset).bigEndian
                    var frame = withUnsafeBytes(of: &value) { Data($0) }
                    frame.append(data)
                    try await self.uploadBudget.acquire(frame.count)
                    guard peer.channel?.sendData(RTCDataBuffer(data: frame, isBinary: true)) == true else {
                        throw CandyTransferFailure.network("文件分片发送失败。")
                    }
                    peer.sentOffset += Int64(data.count)
                    let delay = Double(peer.sentOffset - offset) / 524_288 - Date().timeIntervalSince(started)
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                }
                while peer.acknowledged < grant.file.size {
                    try Task.checkCancellation()
                    guard Date().timeIntervalSince(peer.lastProgress) < 30 else { throw CandyTransferFailure.network("文件落盘确认超时。") }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                try peer.control(CandyTransferControl(type: "eof", size: grant.file.size, sha256: grant.file.sha256))
                try await input.close()
                source = nil
                let deadline = Date().addingTimeInterval(30)
                while self.peers[peer.id] === peer {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw CandyTransferFailure.network("歌曲完成确认超时。") }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch is CancellationError {
                if let source { try? await source.close() }
            } catch {
                if let source { try? await source.close() }
                guard self.peers[peer.id] === peer else { return }
                try? peer.control(CandyTransferControl(type: "error", error: error.localizedDescription))
                self.closePeer(peer.id)
                self.failed?(nil, "歌曲发送失败：\(error.localizedDescription)")
                if self.isSourceFailure(error) { self.sourceUnavailable(grant.file.id) }
            }
        }
    }

    private func closePeer(_ id: String) {
        earlyCandidates = earlyCandidates.filter { !$0.key.hasPrefix("\(id):") }
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.worker?.cancel()
        peer.channel?.close()
        peer.connection?.close()
    }

    private func sourceUnavailable(_ fileID: String) {
        guard publications.removeValue(forKey: fileID) != nil else { return }
        for (id, grant) in authorized where grant.file.id == fileID {
            closePeer(id)
            authorized.removeValue(forKey: id)
            recipients.removeValue(forKey: id)
        }
        for (id, sourceID) in uploadFiles where sourceID == fileID { uploads[id]?.cancel() }
        send?(CandyTransferEnvelope(type: "source-unavailable", fileId: fileID, error: "Source file was removed or changed."))
        publicationUnavailable?(fileID)
        failed?(nil, "源歌曲已删除或发生变化，相关分享和下载已撤销。")
    }

    private func isSourceFailure(_ error: Error) -> Bool {
        if let failure = error as? CandyTransferFailure, case .source = failure { return true }
        let failure = error as NSError
        return failure.domain == NSCocoaErrorDomain && [
            CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue,
            CocoaError.Code.fileReadNoPermission.rawValue
        ].contains(failure.code)
    }
}

private actor CandyTransferHTTP {
    private let redirectGuard = CandyTransferRedirectGuard()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: redirectGuard, delegateQueue: nil)

    func response(_ original: URLRequest, body: Data?, limit: Int) async throws -> (Data, HTTPURLResponse) {
        var request = original
        request.httpBody = body
        let (stream, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw CandyTransferFailure.network("下载网关响应无效。") }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < limit else { throw CandyTransferFailure.invalid("下载网关返回超出限制的数据。") }
            bytes.append(byte)
        }
        return (bytes, response)
    }
}

private final class CandyTransferRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class CandyTransferPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let id: String
    let fileID: String
    let remote: String
    let generation: Int
    let serving: Bool
    var connection: RTCPeerConnection?
    var channel: RTCDataChannel?
    var worker: Task<Void, Never>?
    var acknowledged: Int64 = 0
    var sentOffset: Int64 = 0
    var lastProgress = Date()
    let created = Date()
    var onCandidate: (@MainActor (RTCIceCandidate) -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var onData: (@MainActor (RTCDataBuffer) async -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var opened = false
    private let lock = NSLock()
    private var incoming: [RTCDataBuffer] = []
    private var incomingBytes = 0
    private var delivering = false

    init(id: String, fileID: String, remote: String, generation: Int, serving: Bool) {
        self.id = id
        self.fileID = fileID
        self.remote = remote
        self.generation = generation
        self.serving = serving
    }

    @MainActor func attach(_ channel: RTCDataChannel) {
        guard channel.label == "file-v2:\(id)", self.channel == nil else {
            channel.close()
            onFailure?("收到不支持或重复的文件通道。")
            return
        }
        self.channel = channel
        channel.delegate = self
        if channel.readyState == .open { open() }
    }

    @MainActor private func open() {
        guard !opened else { return }
        opened = true
        onOpen?()
    }

    @MainActor func control(_ control: CandyTransferControl) throws {
        let bytes = try JSONEncoder().encode(control)
        guard channel?.readyState == .open, channel?.sendData(RTCDataBuffer(data: bytes, isBinary: false)) == true else {
            throw CandyTransferFailure.network("下载控制消息发送失败。")
        }
    }

    @MainActor func add(_ candidate: RTCIceCandidate) {
        if hasRemoteDescription { connection?.add(candidate) }
        else if pendingCandidates.count < 128 { pendingCandidates.append(candidate) }
        else { onFailure?("连接候选超过限制。") }
    }

    @MainActor func remoteDescriptionReady() {
        hasRemoteDescription = true
        pendingCandidates.forEach { connection?.add($0) }
        pendingCandidates.removeAll()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in onCandidate?(candidate) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in attach(dataChannel) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .disconnected {
            Task { @MainActor in onFailure?("点对点连接中断，正在恢复。") }
        }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            if dataChannel.readyState == .open { open() }
            else if dataChannel.readyState == .closed { onFailure?("文件通道已关闭。") }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        lock.lock()
        guard buffer.data.count <= 16_384, incomingBytes + buffer.data.count <= 2_097_152, incoming.count < 1024 else {
            lock.unlock()
            Task { @MainActor in onFailure?("下载接收缓冲已满，正在恢复。") }
            return
        }
        incoming.append(buffer)
        incomingBytes += buffer.data.count
        let schedule = !delivering
        delivering = true
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor in
            while let next = pop() { await onData?(next) }
        }
    }
    private func pop() -> RTCDataBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !incoming.isEmpty else { delivering = false; return nil }
        let message = incoming.removeFirst()
        incomingBytes -= message.data.count
        return message
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}
