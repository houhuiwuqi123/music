import Combine
import Foundation
import WebRTC

struct CandyPlazaFile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int64
    var ownerId: String? = nil
    var ownerName: String
}
struct CandyPlazaHistory: Codable, Identifiable {
    var id = UUID()
    var name: String
    var size: Int64
    var time: Date
    var fromName: String? = nil
    var fileID: String? = nil
    var localURL: URL? = nil
}

struct CandyPlazaListening: Codable, Identifiable, Equatable {
    var clientId: String
    var ownerName: String
    var title: String
    var artist: String
    var isPlaying: Bool
    var region: String? = nil
    var file: CandyPlazaFile? = nil
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
}

private struct CandyPlazaMessage: Codable {
    var type: String
    var file: CandyPlazaFile? = nil
    var fileId: String? = nil
    var files: [CandyPlazaFile]? = nil
    var to: String? = nil
    var from: String? = nil
    var data: String? = nil
    var listening: CandyPlazaListening? = nil
    var listeners: [CandyPlazaListening]? = nil
    var error: String? = nil

    init(
        type: String,
        file: CandyPlazaFile? = nil,
        fileId: String? = nil,
        files: [CandyPlazaFile]? = nil,
        to: String? = nil,
        from: String? = nil,
        data: String? = nil,
        listening: CandyPlazaListening? = nil
    ) {
        self.type = type
        self.file = file
        self.fileId = fileId
        self.files = files
        self.to = to
        self.from = from
        self.data = data
        self.listening = listening
    }
}

private struct CandyPlazaSignal: Codable {
    struct Description: Codable {
        var type: String
        var sdp: String
    }

    struct Candidate: Codable {
        var candidate: String
        var sdpMid: String?
        var sdpMLineIndex: Int32
    }

    var kind: String
    var sdp: Description?
    var candidate: Candidate?
}

private struct CandyPlazaTransferControl: Decodable {
    var type: String
    var name: String?
    var size: Int64?
}

@MainActor
final class CandyPlazaService: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected

        var title: String {
            switch self {
            case .connecting: return "连接中"
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

    let nickname: String

    private let userDefaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session = URLSession(configuration: .default)
    private let peerFactory: RTCPeerConnectionFactory
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var listeningHeartbeatTask: Task<Void, Never>?
    private var localListening: CandyPlazaListening?
    private var listeningTrack: Track?
    private var automaticShareTrackID: UUID?
    private var outgoingMessages: [String] = []
    private var outgoingMessageIndex = 0
    private var isSendingMessage = false
    private var hasStarted = false
    private var clientID = UUID().uuidString.lowercased()
    private var sharedFiles: [String: URL] = [:]
    private var servingPeers: [String: CandyPlazaPeer] = [:]
    private var fetchingPeers: [String: CandyPlazaPeer] = [:]
    private var earlyCandidates: [String: [CandyPlazaSignal.Candidate]] = [:]
    private let downloadFolder: URL

    init() {
        let defaults = UserDefaults.standard
        let storedNickname = defaults.string(forKey: "candy_nickname")
        let generatedNickname = "访客\(Int.random(in: 1000...9999))"
        let nickname = storedNickname ?? generatedNickname
        self.nickname = nickname
        sharesListening = defaults.object(forKey: "candy_shares_listening") as? Bool ?? true
        if storedNickname == nil {
            defaults.set(nickname, forKey: "candy_nickname")
        }

        RTCInitializeSSL()
        peerFactory = RTCPeerConnectionFactory()

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        downloadFolder = documents.appendingPathComponent("Candy Downloads", isDirectory: true)
        receiveHistory = Self.loadHistory(forKey: "candy_receive_log")
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        clientID = UUID().uuidString.lowercased()
        openSocket()
        listeningHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                guard let self, self.hasStarted else { return }
                self.sendListening()
            }
        }
    }

    func stop() {
        hasStarted = false
        listeningHeartbeatTask?.cancel()
        listeningHeartbeatTask = nil
        listeners = []
        supportsListening = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outgoingMessages.removeAll()
        outgoingMessageIndex = 0
        isSendingMessage = false
        connectionState = .disconnected
        files = []
        for peer in Array(servingPeers.values) + Array(fetchingPeers.values) {
            peer.connection?.close()
        }
        servingPeers.removeAll()
        fetchingPeers.removeAll()
        earlyCandidates.removeAll()
        for fileID in Array(downloads.keys) {
            guard var download = downloads[fileID],
                  case .downloading = download.state else { continue }
            download.state = .failed("广场连接已停止，请重新接收文件。")
            downloads[fileID] = download
        }
    }

    func retryConnection() {
        stop()
        start()
    }

    func setSharesListening(_ enabled: Bool) {
        sharesListening = enabled
        userDefaults.set(enabled, forKey: "candy_shares_listening")
        synchronizeAutomaticShare()
    }

    func updateListening(track: Track?, isPlaying: Bool) {
        let state = track.map {
            CandyPlazaListening(
                clientId: "", ownerName: nickname,
                title: String($0.title.prefix(300)),
                artist: String($0.artist.prefix(300)), isPlaying: isPlaying
            )
        }
        let changed = state != localListening || track?.fileURL != listeningTrack?.fileURL || track?.id != listeningTrack?.id
        listeningTrack = track
        localListening = state
        if changed { synchronizeAutomaticShare() }
    }

    private func sendListening() {
        guard connectionState == .connected, supportsListening else { return }
        var state = sharesListening ? localListening : nil
        state?.file = shares.values.first
        send(CandyPlazaMessage(type: "listening", listening: state))
    }

    func clearReceiveHistory() {
        receiveHistory = []
        userDefaults.removeObject(forKey: "candy_receive_log")
    }

    private func synchronizeAutomaticShare() {
        let currentURL = sharedFiles.values.first
        if !sharesListening || listeningTrack == nil ||
            automaticShareTrackID != listeningTrack?.id || currentURL != listeningTrack?.fileURL {
            let peers = Array(servingPeers.values)
            servingPeers.removeAll()
            peers.forEach { $0.channel?.close(); $0.connection?.close() }
            shares.removeAll()
            sharedFiles.removeAll()
            automaticShareTrackID = nil
        }
        if sharesListening, let track = listeningTrack, shares.isEmpty {
            do {
                let attributes = try track.fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, let size = attributes.fileSize else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                let file = CandyPlazaFile(
                    id: UUID().uuidString.lowercased(), name: track.fileURL.lastPathComponent,
                    size: Int64(size), ownerName: nickname
                )
                shares[file.id] = file
                sharedFiles[file.id] = track.fileURL
                automaticShareTrackID = track.id
            } catch {
                errorMessage = "当前歌曲无法自动分享：\(error.localizedDescription)"
            }
        }
        sendListening()
    }

    func download(_ file: CandyPlazaFile) {
        guard let ownerID = file.ownerId else {
            errorMessage = "该文件当前无法识别发布者，请刷新广场后重试。"
            return
        }
        guard fetchingPeers[ownerID] == nil else {
            errorMessage = "正在接收这位用户分享的另一个文件，请完成后再试。"
            return
        }
        guard connectionState == .connected else {
            errorMessage = "广场连接断开，请连接后重试。"
            return
        }
        guard listeners.contains(where: { $0.clientId == ownerID && $0.file?.id == file.id }) else {
            errorMessage = "这首歌曲已停止分享，请选择当前正在分享的歌曲。"
            return
        }
        downloads[file.id] = CandyPlazaDownload(file: file, progress: 0, state: .downloading)

        let peer = makePeer(remoteID: ownerID, isServing: false)
        peer.fileID = file.id
        guard let connection = peer.connection,
              let channel = connection.dataChannel(forLabel: "file:\(file.id)", configuration: RTCDataChannelConfiguration()) else {
            peer.connection?.close()
            failDownload(file.id, message: "无法创建文件连接。")
            return
        }
        peer.channel = channel
        channel.delegate = peer
        fetchingPeers[ownerID] = peer
        peer.onData = { [weak self, weak peer] buffer in
            Task { @MainActor in
                guard let self, let peer else { return }
                self.receive(buffer, for: peer)
            }
        }

        connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self, weak peer] description, error in
            Task { @MainActor in
                guard let self, let peer, let description else {
                    self?.failDownload(file.id, message: error?.localizedDescription ?? "无法创建文件连接。")
                    return
                }
                peer.connection?.setLocalDescription(description) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.failDownload(file.id, message: error.localizedDescription)
                            return
                        }
                        let signal = CandyPlazaSignal(
                            kind: "offer",
                            sdp: .init(type: "offer", sdp: description.sdp)
                        )
                        self.sendSignal(to: ownerID, signal: signal)
                    }
                }
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func openSocket() {
        guard hasStarted else { return }
        var components = URLComponents(string: "wss://music.webtrc.eu.cc/ws")
        components?.queryItems = [URLQueryItem(name: "id", value: clientID)]
        guard let url = components?.url else {
            errorMessage = "广场服务器地址无效。"
            return
        }
        connectionState = .connecting
        supportsListening = false
        listeners = []
        outgoingMessages.removeAll()
        outgoingMessageIndex = 0
        isSendingMessage = false
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        connectionTimeoutTask = Task { @MainActor [weak self, weak task] in
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch {
                return
            }
            guard let self, let task, self.socket === task else { return }
            self.disconnect(task, message: "广场连接超时：15 秒内未收到服务器快照，请检查网络或服务器状态。")
        }
        receiveMessages(from: task)
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
                    case .string(let string): data = Data(string.utf8)
                    case .data(let payload): data = payload
                    @unknown default: continue
                    }
                    let envelope = try self.decoder.decode(CandyPlazaMessage.self, from: data)
                    self.handle(envelope)
                } catch {
                    guard self.socket === task else { return }
                    let failure = error as NSError
                    let status = (task.response as? HTTPURLResponse).map { "，HTTP \($0.statusCode)" } ?? ""
                    self.disconnect(task, message: "广场连接失败：\(failure.localizedDescription)（\(failure.domain) \(failure.code)\(status)）。")
                    return
                }
            }
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
        listeners = []
        supportsListening = false
        connectionError = message
        files = []
        for fileID in Array(downloads.keys) {
            guard var download = downloads[fileID],
                  case .downloading = download.state else { continue }
            download.state = .failed(message)
            downloads[fileID] = download
        }
        let peers = Array(servingPeers.values) + Array(fetchingPeers.values)
        servingPeers.removeAll()
        fetchingPeers.removeAll()
        earlyCandidates.removeAll()
        peers.forEach { $0.connection?.close() }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard hasStarted, reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard let self, self.hasStarted else { return }
            self.reconnectTask = nil
            self.clientID = UUID().uuidString.lowercased()
            self.openSocket()
        }
    }

    private func handle(_ message: CandyPlazaMessage) {
        switch message.type {
        case "listeners":
            let firstSnapshot = !supportsListening
            supportsListening = true
            listeners = (message.listeners ?? [])
                .filter { $0.clientId != clientID }
                .sorted { $0.clientId < $1.clientId }
            if firstSnapshot { sendListening() }
        case "error":
            errorMessage = message.error ?? "广场服务器拒绝了请求。"
        case "plaza":
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            connectionState = .connected
            connectionError = nil
            files = message.files ?? []
        case "signal":
            guard let from = message.from, let payload = message.data,
                  let data = payload.data(using: .utf8),
                  let signal = try? decoder.decode(CandyPlazaSignal.self, from: data) else {
                errorMessage = "收到无法识别的连接信令。"
                return
            }
            handleSignal(from: from, signal: signal)
        default:
            break
        }
    }

    private func handleSignal(from remoteID: String, signal: CandyPlazaSignal) {
        switch signal.kind {
        case "offer":
            guard let offer = signal.sdp else { return }
            guard sharesListening, !shares.isEmpty else {
                errorMessage = "已拒绝文件请求：当前没有公开分享的歌曲。"
                return
            }
            let peer = makePeer(remoteID: remoteID, isServing: true)
            servingPeers[remoteID]?.connection?.close()
            servingPeers[remoteID] = peer
            for candidate in earlyCandidates.removeValue(forKey: remoteID) ?? [] {
                peer.addCandidate(candidate)
            }
            let type: RTCSdpType = offer.type == "offer" ? .offer : .answer
            peer.connection?.setRemoteDescription(RTCSessionDescription(type: type, sdp: offer.sdp)) { [weak self, weak peer] error in
                Task { @MainActor in
                    guard let self, let peer, let connection = peer.connection else { return }
                    if let error {
                        self.errorMessage = error.localizedDescription
                        return
                    }
                    peer.hasRemoteDescription = true
                    peer.flushCandidates()
                    connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                        guard let answer else {
                            Task { @MainActor in self.errorMessage = error?.localizedDescription ?? "无法响应文件连接。" }
                            return
                        }
                        connection.setLocalDescription(answer) { error in
                            Task { @MainActor in
                                if let error {
                                    self.errorMessage = error.localizedDescription
                                } else {
                                    self.sendSignal(
                                        to: remoteID,
                                        signal: CandyPlazaSignal(
                                            kind: "answer",
                                            sdp: .init(type: "answer", sdp: answer.sdp)
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        case "answer":
            guard let answer = signal.sdp, let peer = fetchingPeers[remoteID],
                  let connection = peer.connection else { return }
            connection.setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: answer.sdp)
            ) { [weak peer] error in
                Task { @MainActor in
                    guard let peer else { return }
                    if let error { peer.onFailure?(error.localizedDescription) }
                    else {
                        peer.hasRemoteDescription = true
                        peer.flushCandidates()
                    }
                }
            }
        case "candidate":
            guard let candidate = signal.candidate else { return }
            let peer = servingPeers[remoteID] ?? fetchingPeers[remoteID]
            if let peer {
                peer.addCandidate(candidate)
            } else {
                earlyCandidates[remoteID, default: []].append(candidate)
            }
        default:
            break
        }
    }

    private func makePeer(remoteID: String, isServing: Bool) -> CandyPlazaPeer {
        let peer = CandyPlazaPeer(remoteID: remoteID, isServing: isServing)
        let configuration = RTCConfiguration()
        configuration.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let connection = peerFactory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: peer
        )
        peer.connection = connection
        peer.onCandidate = { [weak self] candidate in
            Task { @MainActor in
                guard let self else { return }
                self.sendSignal(
                    to: remoteID,
                    signal: CandyPlazaSignal(
                        kind: "candidate",
                        candidate: .init(
                            candidate: candidate.sdp,
                            sdpMid: candidate.sdpMid,
                            sdpMLineIndex: candidate.sdpMLineIndex
                        )
                    )
                )
            }
        }
        peer.onRemoteChannel = { [weak self, weak peer] channel in
            Task { @MainActor in
                guard let self, let peer else { return }
                peer.channel = channel
                channel.delegate = peer
                peer.onData = { [weak self, weak peer] buffer in
                    Task { @MainActor in
                        guard let self, let peer else { return }
                        self.receive(buffer, for: peer)
                    }
                }
                if channel.readyState == .open,
                   let fileID = channel.label.split(separator: ":").last.map(String.init) {
                    peer.fileID = fileID
                    peer.onChannelOpen?(fileID, channel)
                }
            }
        }
        peer.onChannelOpen = { [weak self, weak peer] fileID, channel in
            Task { @MainActor in
                guard let self, let peer, peer.isServing else { return }
                self.sendFile(fileID, over: channel)
            }
        }
        peer.onFailure = { [weak self, weak peer] message in
            Task { @MainActor in
                guard let self else { return }
                if let fileID = peer?.fileID {
                    self.failDownload(fileID, message: message)
                } else {
                    self.errorMessage = message
                }
            }
        }
        peer.onClosed = { [weak self, weak peer] in
            Task { @MainActor in
                guard let self, let peer else { return }
                if peer.isServing {
                    guard self.servingPeers[remoteID] === peer else { return }
                    self.servingPeers.removeValue(forKey: remoteID)
                } else {
                    guard self.fetchingPeers[remoteID] === peer else { return }
                    self.fetchingPeers.removeValue(forKey: remoteID)
                    if let fileID = peer.fileID,
                           let download = self.downloads[fileID],
                           case .downloading = download.state {
                            self.failDownload(fileID, message: "文件连接已关闭。")
                        }
                }
            }
        }
        return peer
    }

    private func receive(_ buffer: RTCDataBuffer, for peer: CandyPlazaPeer) {
        guard let fileID = peer.fileID, var download = downloads[fileID] else { return }
        guard case .downloading = download.state else { return }
        if !buffer.isBinary {
            do {
                let control = try decoder.decode(CandyPlazaTransferControl.self, from: buffer.data)
                if control.type == "meta" {
                    download.file.name = control.name ?? download.file.name
                    if let size = control.size { download.file.size = size }
                    downloads[fileID] = download
                } else if control.type == "eof" {
                    finishDownload(fileID, peer: peer)
                }
            } catch {
                failDownload(fileID, message: "收到无法识别的文件数据。")
            }
            return
        }
        guard download.file.size >= 0,
              download.file.size <= Int64(Int.max) else {
            failDownload(fileID, message: "文件大小超出设备可处理范围。")
            return
        }
        guard peer.receivedData.count <= Int(download.file.size),
              buffer.data.count <= Int(download.file.size) - peer.receivedData.count else {
            failDownload(fileID, message: "接收数据超出文件声明大小。")
            return
        }
        peer.receivedData.append(buffer.data)
        download.progress = download.file.size == 0
            ? 0
            : min(1, Double(peer.receivedData.count) / Double(download.file.size))
        downloads[fileID] = download
    }

    private func finishDownload(_ fileID: String, peer: CandyPlazaPeer) {
        guard var download = downloads[fileID] else { return }
        guard case .downloading = download.state else { return }
        do {
            guard download.file.size == Int64(peer.receivedData.count) else {
                failDownload(fileID, message: "接收的文件大小与发布信息不一致。")
                return
            }
            try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
            let fileName = URL(fileURLWithPath: download.file.name).lastPathComponent
            let destination = uniqueURL(for: fileName, in: downloadFolder)
            try peer.receivedData.write(to: destination, options: .atomic)
            download.progress = 1
            download.state = .complete
            download.localURL = destination
            downloads[fileID] = download
            append(
                CandyPlazaHistory(
                    name: fileName,
                    size: Int64(peer.receivedData.count),
                    time: Date(),
                    fromName: download.file.ownerName,
                    fileID: fileID,
                    localURL: destination
                ),
                to: &receiveHistory,
                key: "candy_receive_log"
            )
            peer.receivedData.removeAll()
            peer.connection?.close()
        } catch {
            failDownload(fileID, message: error.localizedDescription)
        }
    }

    private func failDownload(_ fileID: String, message: String) {
        guard var download = downloads[fileID] else {
            errorMessage = message
            return
        }
        guard case .downloading = download.state else { return }
        download.state = .failed(message)
        downloads[fileID] = download
        if let peer = fetchingPeers.values.first(where: { $0.fileID == fileID }) {
            peer.receivedData.removeAll()
            peer.connection?.close()
            fetchingPeers.removeValue(forKey: peer.remoteID)
        }
        errorMessage = message
    }

    private func sendFile(_ fileID: String, over channel: RTCDataChannel) {
        guard sharesListening, let url = sharedFiles[fileID], let file = shares[fileID] else {
            errorMessage = "这首歌曲已撤回分享，无法发送。"
            channel.close()
            return
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            errorMessage = "无法读取分享的歌曲：\(error.localizedDescription)"
            channel.close()
            return
        }
        Task { @MainActor in
            defer {
                try? handle.close()
                channel.close()
            }
            guard let meta = try? JSONSerialization.data(withJSONObject: [
                "type": "meta", "name": file.name, "size": file.size
            ]) else { return }
            guard channel.sendData(RTCDataBuffer(data: meta, isBinary: false)) else {
                self.errorMessage = "无法发送文件信息。"
                return
            }
            do {
                while true {
                    guard self.sharesListening, self.shares[fileID] != nil,
                          channel.readyState == .open else { return }
                    if channel.bufferedAmount > 1_048_576 {
                        while channel.bufferedAmount > 524_288 {
                            guard self.sharesListening, self.shares[fileID] != nil,
                                  channel.readyState == .open else { return }
                            try await Task.sleep(nanoseconds: 25_000_000)
                        }
                    }
                    guard let chunk = try handle.read(upToCount: 16 * 1024), !chunk.isEmpty else { break }
                    guard channel.sendData(RTCDataBuffer(data: chunk, isBinary: true)) else {
                        self.errorMessage = "文件传输中断。"
                        return
                    }
                }
                if let eof = try? JSONSerialization.data(withJSONObject: ["type": "eof"]) {
                    guard channel.sendData(RTCDataBuffer(data: eof, isBinary: false)) else {
                        self.errorMessage = "无法发送歌曲传输结束标记。"
                        return
                    }
                    let deadline = Date().addingTimeInterval(30)
                    while channel.bufferedAmount > 0 {
                        guard self.sharesListening, self.shares[fileID] != nil,
                              channel.readyState == .open else { return }
                        guard Date() < deadline else {
                            self.errorMessage = "歌曲发送缓冲未能及时完成，请重新接收。"
                            return
                        }
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func sendSignal(to remoteID: String, signal: CandyPlazaSignal) {
        do {
            let innerData = try encoder.encode(signal)
            guard let innerJSON = String(data: innerData, encoding: .utf8) else {
                errorMessage = "无法编码文件连接信令。"
                return
            }
            send(CandyPlazaMessage(type: "signal", to: remoteID, data: innerJSON))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send(_ message: CandyPlazaMessage) {
        guard socket != nil else { return }
        do {
            let data = try encoder.encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = "无法编码广场消息。"
                return
            }
            outgoingMessages.append(text)
            flushOutgoingMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func flushOutgoingMessages() {
        guard !isSendingMessage, let socket else { return }
        isSendingMessage = true
        Task { @MainActor [weak self, weak socket] in
            guard let self, let socket else { return }
            while self.socket === socket, self.outgoingMessageIndex < self.outgoingMessages.count {
                let message = self.outgoingMessages[self.outgoingMessageIndex]
                self.outgoingMessageIndex += 1
                do {
                    try await socket.send(.string(message))
                } catch {
                    guard self.socket === socket else { return }
                    self.disconnect(socket, message: "广场消息发送失败：\(error.localizedDescription)")
                    return
                }
            }
            guard self.socket === socket else { return }
            self.outgoingMessages.removeAll()
            self.outgoingMessageIndex = 0
            self.isSendingMessage = false
        }
    }

    private func append(
        _ entry: CandyPlazaHistory,
        to history: inout [CandyPlazaHistory],
        key: String
    ) {
        history.insert(entry, at: 0)
        history = Array(history.prefix(100))
        do {
            userDefaults.set(try encoder.encode(history), forKey: key)
        } catch {
            errorMessage = "记录无法保存：\(error.localizedDescription)"
        }
    }

    private func uniqueURL(for name: String, in folder: URL) -> URL {
        let source = URL(fileURLWithPath: name)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixed = "\(base) \(suffix)"
            candidate = ext.isEmpty
                ? folder.appendingPathComponent(suffixed)
                : folder.appendingPathComponent(suffixed).appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private static func loadHistory(forKey key: String) -> [CandyPlazaHistory] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return Array(try JSONDecoder().decode([CandyPlazaHistory].self, from: data).prefix(100))
        } catch {
            return []
        }
    }
}

private final class CandyPlazaPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let remoteID: String
    let isServing: Bool
    var fileID: String?
    var connection: RTCPeerConnection?
    var channel: RTCDataChannel?
    var receivedData = Data()
    var hasRemoteDescription = false
    var onCandidate: ((RTCIceCandidate) -> Void)?
    var onRemoteChannel: ((RTCDataChannel) -> Void)?
    var onChannelOpen: ((String, RTCDataChannel) -> Void)?
    var onData: ((RTCDataBuffer) -> Void)?
    var onFailure: ((String) -> Void)?
    var onClosed: (() -> Void)?
    private var pendingCandidates: [RTCIceCandidate] = []
    private let incomingDataLock = NSLock()
    private var incomingData: [RTCDataBuffer] = []
    private var isDeliveringData = false

    init(remoteID: String, isServing: Bool) {
        self.remoteID = remoteID
        self.isServing = isServing
    }

    func addCandidate(_ candidate: CandyPlazaSignal.Candidate) {
        let ice = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        guard hasRemoteDescription else {
            pendingCandidates.append(ice)
            return
        }
        connection?.add(ice)
    }

    func flushCandidates() {
        pendingCandidates.forEach { connection?.add($0) }
        pendingCandidates.removeAll()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in onCandidate?(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in onRemoteChannel?(dataChannel) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed {
            Task { @MainActor in
                onFailure?("点对点连接失败，请稍后重试。")
                onClosed?()
            }
        } else if newState == .disconnected || newState == .closed {
            Task { @MainActor in onClosed?() }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open, isServing,
           let fileID = dataChannel.label.split(separator: ":").last.map(String.init) {
            self.fileID = fileID
            Task { @MainActor in onChannelOpen?(fileID, dataChannel) }
        }
        if dataChannel.readyState == .closed { Task { @MainActor in onClosed?() } }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        incomingDataLock.lock()
        incomingData.append(buffer)
        let shouldScheduleDelivery = !isDeliveringData
        isDeliveringData = true
        incomingDataLock.unlock()
        guard shouldScheduleDelivery else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.incomingDataLock.lock()
            let messages = self.incomingData
            self.incomingData.removeAll(keepingCapacity: true)
            self.isDeliveringData = false
            self.incomingDataLock.unlock()
            messages.forEach { self.onData?($0) }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}
}
