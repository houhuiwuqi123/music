import Combine
import Foundation
import Security
import UIKit

struct CandyPlazaFile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var size: Int64
    var ownerId: String? = nil
    var ownerName: String
    var sha256: String? = nil
    var protocolVersion: Int? = nil
}

struct CandyPlazaHistory: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var size: Int64
    var time: Date
    var fromName: String? = nil
    var fileID: String? = nil
    var localURL: URL? = nil
}

struct CandyPlazaListening: Codable, Identifiable, Equatable, Sendable {
    var clientId: String
    var ownerName: String
    var title: String
    var artist: String
    var isPlaying: Bool
    var region: String? = nil
    var file: CandyPlazaFile? = nil
    var avatar: String? = nil
    var offlineAt: Int64? = nil
    var isOffline: Bool { offlineAt != nil }
    var id: String { clientId }
}

struct CandyPlazaDownload: Identifiable {
    enum State {
        case downloading
        case complete
        case failed(String)
    }
    var id: String { file.id }
    var file: CandyPlazaFile
    var progress: Double
    var state: State
    var localURL: URL?
    var status = "等待授权"
}

private struct CandyPlazaMessage: Codable {
    var type: String
    var files: [CandyPlazaFile]? = nil
    var listening: CandyPlazaListening? = nil
    var listeners: [CandyPlazaListening]? = nil
    var error: String? = nil
}

@MainActor
final class CandyPlazaService: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting, connected, disconnected
        var title: String {
            switch self {
            case .connecting: return "连线中"
            case .connected: return "在线"
            case .disconnected: return "离线"
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectionError: String?
    @Published private(set) var listeners: [CandyPlazaListening] = []
    @Published private(set) var supportsListening = false
    @Published private(set) var sharesListening: Bool
    @Published private(set) var files: [CandyPlazaFile] = []
    @Published private(set) var shares: [String: CandyPlazaFile] = [:]
    @Published private(set) var downloads: [String: CandyPlazaDownload] = [:]
    @Published private(set) var receiveHistory: [CandyPlazaHistory]
    @Published private(set) var errorMessage: String?
    @Published private(set) var nickname: String
    @Published private(set) var avatar: String?

    private let userDefaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var listeningHeartbeatTask: Task<Void, Never>?
    private var offlineCleanupTask: Task<Void, Never>?
    private var manifestTask: Task<Void, Never>?
    private var localListening: CandyPlazaListening?
    private var listeningTrack: Track?
    private var automaticShareTrackID: UUID?
    private var shareGeneration = 0
    private var hasSourceLease = false
    private var outgoingMessages: [String] = []
    private var outgoingMessageIndex = 0
    private var isSendingMessage = false
    private var hasStarted = false
    private let clientID: String
    private let downloadFolder: URL
    private lazy var transfers: CandyReliableTransfer = {
        let engine = CandyReliableTransfer(folder: downloadFolder)
        engine.send = { [weak self] message in
            guard let self else { return }
            do { self.sendData(try self.encoder.encode(message)) }
            catch { self.errorMessage = "无法编码下载请求：\(error.localizedDescription)" }
        }
        engine.changed = { [weak self] file, progress, status in
            guard let self else { return }
            var download = self.downloads[file.id] ?? CandyPlazaDownload(file: file, progress: 0, state: .downloading)
            download.progress = progress
            download.status = status
            download.state = .downloading
            self.downloads[file.id] = download
        }
        engine.completed = { [weak self] file, url in
            guard let self else { return }
            self.downloads[file.id] = CandyPlazaDownload(file: file, progress: 1, state: .complete, localURL: url, status: "已完成")
            guard !self.receiveHistory.contains(where: { $0.localURL == url }) else { return }
            self.receiveHistory.insert(CandyPlazaHistory(name: url.lastPathComponent, size: file.size, time: Date(),
                fromName: file.ownerName, fileID: file.id, localURL: url), at: 0)
            self.receiveHistory = Array(self.receiveHistory.prefix(100))
            do { self.userDefaults.set(try self.encoder.encode(self.receiveHistory), forKey: "candy_receive_log") }
            catch { self.errorMessage = "记录无法保存：\(error.localizedDescription)" }
        }
        engine.failed = { [weak self] file, message in
            guard let self else { return }
            if let file {
                var download = self.downloads[file.id] ?? CandyPlazaDownload(file: file, progress: 0, state: .failed(message))
                download.state = .failed(message)
                download.status = message
                self.downloads[file.id] = download
            }
            self.errorMessage = message
        }
        engine.publicationUnavailable = { [weak self] fileID in
            guard let self, self.shares[fileID] != nil else { return }
            self.shares.removeValue(forKey: fileID)
            self.automaticShareTrackID = nil
            self.sendListening()
        }
        return engine
    }()

    init() {
        let defaults = UserDefaults.standard
        let initialClientID = defaults.string(forKey: "candy_client_id") ?? UUID().uuidString.lowercased()
        let initialNickname = defaults.string(forKey: "candy_nickname") ?? "游客\(Int.random(in: 1000...9999))"
        let initialAvatar = defaults.string(forKey: "candy_avatar")
        let initialSharesListening = defaults.object(forKey: "candy_shares_listening") as? Bool ?? true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let initialDownloadFolder = documents.appendingPathComponent("Candy Downloads", isDirectory: true)

        var initialHistory: [CandyPlazaHistory] = []
        var initialErrorMessage: String?
        if let data = defaults.data(forKey: "candy_receive_log") {
            do {
                initialHistory = Array(try JSONDecoder().decode([CandyPlazaHistory].self, from: data).prefix(100))
            } catch {
                initialErrorMessage = "接收记录无法读取：\(error.localizedDescription)"
            }
        }

        // 严格遵循 Swift 两段式初始化：在所有存储属性赋初值前，绝不调用任何方法或触发属性 observer/defaults
        self.clientID = initialClientID
        self.nickname = initialNickname
        self.avatar = initialAvatar
        self.sharesListening = initialSharesListening
        self.downloadFolder = initialDownloadFolder
        self.receiveHistory = initialHistory
        self.errorMessage = initialErrorMessage

        // 初始化完成后再执行副作用
        defaults.set(initialClientID, forKey: "candy_client_id")
        defaults.set(initialNickname, forKey: "candy_nickname")
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        openSocket()
        offlineCleanupTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                let now = Int64(Date().timeIntervalSince1970)
                self.listeners.removeAll { $0.offlineAt.map { now - $0 >= 60 } ?? false }
            }
        }
        listeningHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, self.hasStarted else { return }
                self.sendListening()
            }
        }
    }

    func stop() {
        hasStarted = false
        offlineCleanupTask?.cancel()
        listeningHeartbeatTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTimeoutTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outgoingMessages.removeAll()
        outgoingMessageIndex = 0
        isSendingMessage = false
        connectionState = .disconnected
        supportsListening = false
        listeners = []
        files = []
        transfers.setConnected(false)
    }

    func retryConnection() { stop(); start() }

    func setSharesListening(_ enabled: Bool) {
        sharesListening = enabled
        userDefaults.set(enabled, forKey: "candy_shares_listening")
        synchronizeAutomaticShare()
    }

    func updateProfile(name: String, image: UIImage?, removeAvatar: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else {
            errorMessage = "昵称需为 1 至 40 个字符。"
            return false
        }
        if let image {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format)
            let thumbnail = renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 96, height: 96)) }
            guard let data = thumbnail.jpegData(compressionQuality: 0.65), data.count <= 32768 else {
                errorMessage = "头像无法压缩到支持的大小。"
                return false
            }
            avatar = data.base64EncodedString()
        } else if removeAvatar { avatar = nil }
        nickname = trimmed
        userDefaults.set(nickname, forKey: "candy_nickname")
        userDefaults.set(avatar, forKey: "candy_avatar")
        localListening?.ownerName = nickname
        localListening?.avatar = avatar
        for id in Array(shares.keys) { shares[id]?.ownerName = nickname }
        sendListening()
        return true
    }

    func updateListening(track: Track?, isPlaying: Bool) {
        let changed = track?.id != listeningTrack?.id || track?.fileURL != listeningTrack?.fileURL
        listeningTrack = track
        localListening = track.map {
            CandyPlazaListening(clientId: "", ownerName: nickname, title: String($0.title.prefix(300)),
                artist: String($0.artist.prefix(300)), isPlaying: isPlaying)
        }
        if changed { synchronizeAutomaticShare() } else { sendListening() }
    }

    private func synchronizeAutomaticShare() {
        if !sharesListening || listeningTrack == nil {
            manifestTask?.cancel()
            shareGeneration += 1
            shares.removeAll()
            automaticShareTrackID = nil
            transfers.withdraw()
            sendListening()
            return
        }
        guard let track = listeningTrack, automaticShareTrackID != track.id || shares.isEmpty else {
            sendListening()
            return
        }
        manifestTask?.cancel()
        shareGeneration += 1
        let generation = shareGeneration
        automaticShareTrackID = track.id
        if let previous = shares.values.first {
            do { sendData(try encoder.encode(CandyTransferEnvelope(type: "share-retire", fileId: previous.id))) }
            catch { errorMessage = "无法撤回旧歌曲的新下载入口：\(error.localizedDescription)" }
        }
        shares.removeAll()
        // Retire new admissions immediately; publish the replacement only after hashing.
        manifestTask = Task { @MainActor [weak self] in
            do {
                let hash = try await CandyTransferDisk.manifest(track.fileURL)
                try Task.checkCancellation()
                guard let self, self.shareGeneration == generation, self.sharesListening else { return }
                let file = CandyPlazaFile(id: UUID().uuidString.lowercased(), name: track.fileURL.lastPathComponent,
                    size: hash.size, ownerName: self.nickname, sha256: hash.sha256, protocolVersion: 2)
                self.shares[file.id] = file
                try self.transfers.publish(file, url: track.fileURL)
                self.manifestTask = nil
                self.sendListening()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.shareGeneration == generation else { return }
                self.automaticShareTrackID = nil
                self.manifestTask = nil
                self.errorMessage = "当前歌曲无法自动分享：\(error.localizedDescription)"
                self.sendListening()
            }
        }
    }

    private func sendListening() {
        guard connectionState == .connected, supportsListening else { return }
        if sharesListening, listeningTrack != nil, shares.isEmpty {
            guard hasSourceLease else { return }
            do { sendData(try encoder.encode(CandyTransferEnvelope(type: "lease-refresh"))) }
            catch { errorMessage = "无法刷新在线分享授权：\(error.localizedDescription)" }
            return
        }
        var state = sharesListening ? localListening : nil
        state?.avatar = avatar
        state?.ownerName = nickname
        state?.file = shares.values.first
        do {
            sendData(try encoder.encode(CandyPlazaMessage(type: "listening", listening: state)))
            hasSourceLease = state?.file != nil
        }
        catch { errorMessage = "无法编码分享状态：\(error.localizedDescription)" }
    }

    func download(_ file: CandyPlazaFile) {
        guard connectionState == .connected else {
            errorMessage = "广场连接断开，请连接后重试。"
            return
        }
        guard listeners.contains(where: { !$0.isOffline && $0.file?.id == file.id }) else {
            errorMessage = "这首歌曲已停止分享，请选择当前正在分享的歌曲。"
            return
        }
        transfers.download(file)
    }

    func cancelDownload(_ fileID: String) { transfers.cancel(fileID) }
    func retryDownload(_ file: CandyPlazaFile) { transfers.download(file) }
    func clearDownloadPartial(_ file: CandyPlazaFile) { transfers.clearPartial(file) }
    func dismissError() { errorMessage = nil }
    func clearReceiveHistory() {
        receiveHistory = []
        userDefaults.removeObject(forKey: "candy_receive_log")
    }

    private func openSocket() {
        guard hasStarted else { return }
        do {
            var components = URLComponents(string: "wss://music.webtrc.eu.cc/ws")
            components?.queryItems = [
                URLQueryItem(name: "id", value: clientID),
                URLQueryItem(name: "secret", value: try identitySecret())
            ]
            guard let url = components?.url else { throw URLError(.badURL) }
            connectionState = .connecting
            supportsListening = false
            hasSourceLease = false
            markListenersOffline()
            outgoingMessages.removeAll()
            outgoingMessageIndex = 0
            isSendingMessage = false
            let task = session.webSocketTask(with: url)
            socket = task
            task.resume()
            connectionTimeoutTask = Task { @MainActor [weak self, weak task] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, let task, self.socket === task else { return }
                self.disconnect(task, message: "广场连接超时：15 秒内未收到服务器快照。")
            }
            receiveMessages(from: task)
        } catch {
            connectionState = .disconnected
            errorMessage = "无法初始化广场连接：\(error.localizedDescription)"
        }
    }

    private func identitySecret() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CandyPlazaIdentity", kSecAttrAccount as String: clientID]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) {
            return secret
        }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let secret = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(add as CFDictionary, nil)
        guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
        return secret
    }

    private func receiveMessages(from task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.hasStarted, self.socket === task {
                do {
                    let message = try await task.receive()
                    guard self.hasStarted, self.socket === task else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let payload): data = payload
                    @unknown default: continue
                    }
                    let envelope = try self.decoder.decode(CandyPlazaMessage.self, from: data)
                    self.handle(envelope)
                    self.transfers.handle(try self.decoder.decode(CandyTransferEnvelope.self, from: data))
                } catch {
                    guard self.socket === task else { return }
                    let failure = error as NSError
                    let status = (task.response as? HTTPURLResponse).map { "，HTTP \($0.statusCode)" } ?? ""
                    self.disconnect(task, message: "广场连接失败：\(failure.localizedDescription)（\(failure.domain) \(failure.code)\(status)）。")
                }
            }
        }
    }

    private func handle(_ message: CandyPlazaMessage) {
        switch message.type {
        case "listeners":
            let firstSnapshot = !supportsListening
            supportsListening = true
            listeners = (message.listeners ?? []).filter { $0.clientId != clientID }.sorted { $0.clientId < $1.clientId }
            if firstSnapshot { sendListening() }
        case "plaza":
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            connectionState = .connected
            connectionError = nil
            files = message.files ?? []
            transfers.setConnected(true)
        case "error": errorMessage = message.error ?? "广场服务器拒绝了请求。"
        default: break
        }
    }

    private func disconnect(_ task: URLSessionWebSocketTask, message: String) {
        guard socket === task else { return }
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
        outgoingMessages.removeAll()
        outgoingMessageIndex = 0
        isSendingMessage = false
        connectionState = .disconnected
        supportsListening = false
        hasSourceLease = false
        markListenersOffline()
        connectionError = message
        files = []
        transfers.setConnected(false)
        scheduleReconnect()
    }

    private func markListenersOffline() {
        let now = Int64(Date().timeIntervalSince1970)
        listeners = listeners.map { listener in
            var value = listener
            if value.offlineAt == nil { value.offlineAt = now }
            return value
        }
    }

    private func scheduleReconnect() {
        guard hasStarted, reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.hasStarted else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }

    private func sendData(_ data: Data) {
        guard socket != nil else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            errorMessage = "无法编码广场消息。"
            return
        }
        guard outgoingMessages.count - outgoingMessageIndex < 256 else {
            if let socket { disconnect(socket, message: "广场发送队列已满，正在重新连接。") }
            return
        }
        outgoingMessages.append(text)
        flushOutgoingMessages()
    }

    private func flushOutgoingMessages() {
        guard !isSendingMessage, let socket else { return }
        isSendingMessage = true
        Task { @MainActor [weak self, weak socket] in
            guard let self, let socket else { return }
            while self.socket === socket, self.outgoingMessageIndex < self.outgoingMessages.count {
                let message = self.outgoingMessages[self.outgoingMessageIndex]
                self.outgoingMessageIndex += 1
                do { try await socket.send(.string(message)) }
                catch {
                    guard self.socket === socket else { return }
                    self.disconnect(socket, message: "广场消息发送失败：\(error.localizedDescription)")
                    return
                }
                if self.socket === socket, self.outgoingMessageIndex >= 128 {
                    self.outgoingMessages.removeFirst(self.outgoingMessageIndex)
                    self.outgoingMessageIndex = 0
                }
            }
            guard self.socket === socket else { return }
            self.outgoingMessages.removeAll()
            self.outgoingMessageIndex = 0
            self.isSendingMessage = false
        }
    }
}
