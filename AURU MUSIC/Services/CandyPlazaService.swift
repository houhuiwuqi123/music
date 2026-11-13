import Combine
import CoreLocation
import CryptoKit
import Foundation
import Network
import Security
import UIKit

// Candy广场 on the AURU DHT network.
// The iOS app has no libp2p stack, so it joins through a lightweight node's
// gateway WebSocket: the node runs Kademlia PROVIDE / GET_PROVIDERS and GossipSub
// on the app's behalf, while the app keeps its own Ed25519 libp2p identity, signs
// its own plaza announcements and moves files peer-to-peer over WebRTC.

struct CandyPlazaFile: Codable, Identifiable, Hashable, Sendable {
    var id: String // content CID (CIDv1 raw sha2-256)
    var name: String
    var size: Int64
    var ownerId: String? = nil // peer ID of the announcer
    var ownerName: String
    var sha256: String? = nil
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
    /// Coarse [latitude, longitude] from the announcing node's GeoIP (0.1°).
    var latitude: Double? = nil
    var longitude: Double? = nil
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
    var status = "查找提供者"
}

// MARK: - Wire types (see backend/README.md)

struct CandyNodeInfo: Codable, Sendable {
    var peerId: String
    var addrs: [String]? = nil
    var gateway: String? = nil
}

struct CandyEnvelope: Codable, Sendable {
    var body: String
    var sig: String
    var pub: String
}

struct CandyAnnouncedFile: Codable, Sendable {
    var cid: String
    var name: String
    var size: Int64
    var sha256: String
    var kind: String
    var mime: String? = nil
}

struct CandyAnnouncedListening: Codable, Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
}

struct CandyPlazaBody: Encodable, Sendable {
    var v = 1
    var peerId: String
    var name: String
    var avatar: String? = nil
    var region: String? = nil
    var geo: [Double]? = nil
    var client: String? = nil
    var via: [String]
    var listening: CandyAnnouncedListening? = nil
    var files: [CandyAnnouncedFile]
    var seq: Int64
    var bye: Bool? = nil
}

extension CandyPlazaBody: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        peerId = try c.decode(String.self, forKey: .peerId)
        name = try c.decode(String.self, forKey: .name)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        geo = try? c.decodeIfPresent([Double].self, forKey: .geo)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        via = try c.decodeIfPresent([String].self, forKey: .via) ?? []
        listening = try c.decodeIfPresent(CandyAnnouncedListening.self, forKey: .listening)
        files = try c.decodeIfPresent([CandyAnnouncedFile].self, forKey: .files) ?? []
        seq = try c.decode(Int64.self, forKey: .seq)
        bye = try c.decodeIfPresent(Bool.self, forKey: .bye)
    }
}

/// A node-verified announcement: the body fields plus the node's offline flag.
struct CandyPlazaEntry: Decodable, Sendable {
    var body: CandyPlazaBody
    var offline: Bool
    private enum Keys: String, CodingKey { case offline }
    init(from decoder: Decoder) throws {
        body = try CandyPlazaBody(from: decoder)
        offline = try decoder.container(keyedBy: Keys.self).decodeIfPresent(Bool.self, forKey: .offline) ?? false
    }
}

private struct CandyGatewayMessage: Codable {
    var type: String
    var id: String? = nil
    var error: String? = nil
    var nonce: String? = nil
    var publicKey: String? = nil
    var signature: String? = nil
    var peerId: String? = nil
    var region: String? = nil
    var node: CandyNodeInfo? = nil
    var iceServers: [CandyICEServer]? = nil
    var envelope: CandyEnvelope? = nil
    var cid: String? = nil
    var providers: [CandyCandidate]? = nil
    var signal: CandySignal? = nil
}

private struct CandyGatewayEvent: Decodable {
    var type: String
    var id: String?
    var error: String?
    var nonce: String?
    var peerId: String?
    var region: String?
    var geo: [Double]?
    var node: CandyNodeInfo?
    var iceServers: [CandyICEServer]?
    var providers: [CandyCandidate]?
    var signal: CandySignal?
    var entries: [CandyPlazaEntry]?
    var entry: CandyPlazaEntry?
}

// MARK: - Identity and codecs

enum CandyCodec {
    static let signaturePrefix = "auru-plaza:"
    static let authPrefix = "auru-node-auth:"

    /// libp2p peer ID of an Ed25519 key: base58btc(identity multihash(protobuf PublicKey)).
    static func peerID(_ key: Curve25519.Signing.PublicKey) -> String {
        base58(Data([0x00, 0x24]) + publicKeyProtobuf(key))
    }

    static func publicKeyProtobuf(_ key: Curve25519.Signing.PublicKey) -> Data {
        Data([0x08, 0x01, 0x12, 0x20]) + key.rawRepresentation
    }

    /// CIDv1(raw, sha2-256) in base32 ("bafkrei…"), identical to the Go and JS implementations.
    static func cid(sha256Hex: String) -> String? {
        guard sha256Hex.count == 64, sha256Hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        var bytes: [UInt8] = [0x01, 0x55, 0x12, 0x20]
        var index = sha256Hex.startIndex
        while index < sha256Hex.endIndex {
            let next = sha256Hex.index(index, offsetBy: 2)
            guard let byte = UInt8(sha256Hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return "b" + base32(bytes)
    }

    static func base58(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        let bytes = [UInt8](data)
        let zeros = bytes.prefix { $0 == 0 }.count
        var digits: [UInt8] = []
        for byte in bytes {
            var carry = Int(byte)
            for i in digits.indices {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        return String(repeating: "1", count: zeros) + String(digits.reversed().map { alphabet[Int($0)] })
    }

    static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }

    static func envelope(_ body: CandyPlazaBody, key: Curve25519.Signing.PrivateKey) throws -> CandyEnvelope {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(body), as: UTF8.self)
        let signature = try key.signature(for: Data((signaturePrefix + text).utf8))
        return CandyEnvelope(body: text, sig: signature.base64EncodedString(),
            pub: publicKeyProtobuf(key.publicKey).base64EncodedString())
    }

    /// Persistent Ed25519 identity in the Keychain (this device only).
    static func loadIdentity() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CandyDHTIdentity", kSecAttrAccount as String: "ed25519"]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let key = Curve25519.Signing.PrivateKey()
        var add = query
        add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(add as CFDictionary, nil)
        guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
        return key
    }
}

// MARK: - Service

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

    static let bootstrapURL = URL(string: "https://music.webtrc.eu.cc/api/bootstrap")!
    static let fallbackGateway = "wss://music.webtrc.eu.cc/ws"

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var listeners: [CandyPlazaListening] = []
    @Published private(set) var sharesListening: Bool
    @Published private(set) var downloads: [String: CandyPlazaDownload] = [:]
    @Published private(set) var receiveHistory: [CandyPlazaHistory]
    @Published private(set) var errorMessage: String?
    @Published private(set) var nickname: String
    @Published private(set) var avatar: String?
    @Published private(set) var peerID = ""
    /// Listen-while-downloading player for plaza songs.
    let preview = CandyPreviewPlayer()

    private let userDefaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session = URLSession(configuration: .default)
    private let downloadFolder: URL
    private var identity: Curve25519.Signing.PrivateKey?
    private var hasStarted = false

    // Gateway connection
    private var socket: URLSessionWebSocketTask?
    private var node: CandyNodeInfo?
    private var region: String?
    private var geo: [Double]?
    private var iceServers: [CandyICEServer] = [CandyICEServer(urls: ["stun:stun.l.google.com:19302"])]
    private var bootstrapNodes: [CandyNodeInfo] = []
    private var nodeIndex = 0
    private var failures = 0
    private var reconnectTask: Task<Void, Never>?
    private var handshakeTimeout: Task<Void, Never>?
    private var timers: [Task<Void, Never>] = []
    private var pendingFinds: [String: CheckedContinuation<[CandyCandidate], Error>] = [:]
    private let pathMonitor = NWPathMonitor()
    private var pathSignature = ""
    private var pathSatisfied = true
    private var foregroundObserver: NSObjectProtocol?

    // Plaza state
    private var entries: [String: CandyPlazaEntry] = [:]
    private var offlineSince: [String: Int64] = [:]
    /// Fallback for peers whose announcement has a region but no `geo` (older web pages and
    /// apps, or a node without coordinates): the region name is geocoded once and cached.
    /// An empty array caches "no result" so the name is not looked up again.
    private var regionCoordinates: [String: [Double]] =
        (UserDefaults.standard.dictionary(forKey: "candy_region_geo") as? [String: [Double]]) ?? [:]
    private var regionQueue: [String] = []
    private let regionGeocoder = CLGeocoder()
    private var listeningTrack: Track?
    private var listeningIsPlaying = false
    private var share: (trackID: UUID, file: CandyPlazaFile)?
    private var manifestTask: Task<Void, Never>?
    private var shareGeneration = 0
    private var lastSeq: Int64 = 0
    /// Server time minus device time (ms), from the bootstrap response's Date header. Nodes reject
    /// announcements more than 1 min ahead / 5 min behind their clock, so a skewed phone would vanish.
    private var clockOffsetMs: Int64 = 0
    private var didRefreshBootstrap = false
    private var announcedPresence = false
    private var previewFileObserver: AnyCancellable?

    private lazy var transfers: CandyReliableTransfer = {
        let engine = CandyReliableTransfer(folder: downloadFolder)
        engine.findProviders = { [weak self] cid in
            guard let self else { return [] }
            return try await self.findProviders(cid)
        }
        engine.sendSignal = { [weak self] signal in self?.send(CandyGatewayMessage(type: "signal", signal: signal)) }
        engine.iceServers = { [weak self] in self?.iceServers ?? [] }
        engine.isOnline = { [weak self] in self?.connectionState == .connected }
        engine.changed = { [weak self] file, progress, status in
            guard let self else { return }
            var download = self.downloads[file.id] ?? CandyPlazaDownload(file: file, progress: 0, state: .downloading)
            download.progress = progress
            download.status = status
            download.state = .downloading
            self.downloads[file.id] = download
            self.preview.downloadStatus(file.id, status)
        }
        engine.verified = { [weak self] file, bytes in
            self?.preview.update(file.id, available: bytes)
        }
        engine.completed = { [weak self] file, url in
            guard let self else { return }
            self.downloads[file.id] = CandyPlazaDownload(file: file, progress: 1, state: .complete, localURL: url, status: "已完成")
            self.preview.completed(file.id, url: url)
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
                self.preview.downloadStatus(file.id, message)
            } else {
                self.errorMessage = message
            }
        }
        engine.publicationUnavailable = { [weak self] cid in
            guard let self, self.share?.file.id == cid else { return }
            self.share = nil
            self.announce()
        }
        return engine
    }()

    init() {
        let defaults = UserDefaults.standard
        let initialNickname = defaults.string(forKey: "candy_nickname") ?? "游客\(Int.random(in: 1000...9999))"
        let initialAvatar = defaults.string(forKey: "candy_avatar")
        let initialSharesListening = defaults.object(forKey: "candy_shares_listening") as? Bool ?? true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let initialDownloadFolder = documents.appendingPathComponent("Candy Downloads", isDirectory: true)
        var initialHistory: [CandyPlazaHistory] = []
        var initialErrorMessage: String?
        if let data = defaults.data(forKey: "candy_receive_log") {
            do { initialHistory = Array(try JSONDecoder().decode([CandyPlazaHistory].self, from: data).prefix(100)) }
            catch { initialErrorMessage = "接收记录无法读取：\(error.localizedDescription)" }
        }
        var cachedNodes: [CandyNodeInfo] = []
        if let data = defaults.data(forKey: "candy_bootstrap_nodes"),
           let decoded = try? JSONDecoder().decode([CandyNodeInfo].self, from: data) {
            cachedNodes = decoded
        }
        nickname = initialNickname
        avatar = initialAvatar
        sharesListening = initialSharesListening
        downloadFolder = initialDownloadFolder
        receiveHistory = initialHistory
        errorMessage = initialErrorMessage
        bootstrapNodes = cachedNodes
        defaults.set(initialNickname, forKey: "candy_nickname")
        // Rows show which song is being previewed; forward only that (not the playback clock).
        previewFileObserver = preview.$file.map { $0?.id }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Lifecycle

    func start() {
        guard !hasStarted else {
            if connectionState == .disconnected { reconnectNow() }
            return
        }
        do {
            let key = try CandyCodec.loadIdentity()
            identity = key
            peerID = CandyCodec.peerID(key.publicKey)
        } catch {
            errorMessage = "无法读取广场身份：\(error.localizedDescription)"
            return
        }
        hasStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let kinds: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]
            let signature = "\(satisfied)|" + kinds.filter { path.usesInterfaceType($0) }.map { "\($0)" }.joined(separator: ",")
            guard let service = self else { return }
            Task { @MainActor in service.pathChanged(satisfied: satisfied, signature: signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "candy.path"))
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let service = self else { return }
            Task { @MainActor in
                guard service.hasStarted else { return }
                if service.connectionState == .disconnected { service.reconnectNow() } else { service.announce() }
            }
        }
        timers = [
            repeating(seconds: 30) { $0.announce() },
            repeating(seconds: 25) { service in
                service.socket?.sendPing { error in
                    guard error != nil else { return }
                    Task { @MainActor in service.connectionLost("心跳失败") }
                }
            },
            repeating(seconds: 1) { $0.expireOffline() },
        ]
        openSocket()
    }

    func stop() {
        hasStarted = false
        timers.forEach { $0.cancel() }
        timers = []
        pathMonitor.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        reconnectTask?.cancel()
        reconnectTask = nil
        closeSocket()
        connectionState = .disconnected
        listeners = []
        entries = [:]
    }

    func retryConnection() { reconnectNow() }

    private func repeating(seconds: Double, _ action: @escaping @MainActor (CandyPlazaService) -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                guard let self, self.hasStarted else { return }
                action(self)
            }
        }
    }

    // MARK: Network changes (Wi-Fi ↔ cellular)

    private func pathChanged(satisfied: Bool, signature: String) {
        let previous = pathSignature
        pathSignature = signature
        pathSatisfied = satisfied
        guard hasStarted, !previous.isEmpty, previous != signature else { return }
        // The old TCP/ICE paths are bound to the previous interface: drop them right away.
        transfers.networkChanged()
        if satisfied {
            reconnectNow()
        } else {
            closeSocket()
            connectionState = .disconnected
            markListenersOffline()
        }
    }

    private func reconnectNow() {
        guard hasStarted else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        failures = 0
        closeSocket()
        openSocket()
    }

    // MARK: Gateway socket

    private func openSocket() {
        guard hasStarted, socket == nil, pathSatisfied else { return }
        connectionState = .connecting
        Task { @MainActor in
            // Fetch the live node list once per launch (a cached list may name nodes that no longer
            // exist or another deployment), again when empty, and after repeated failures.
            if !self.didRefreshBootstrap || self.bootstrapNodes.isEmpty || self.failures % 3 == 2 {
                await self.refreshBootstrap()
            }
            guard self.hasStarted, self.socket == nil else { return }
            let gateways = self.bootstrapNodes.compactMap(\.gateway).filter { $0.hasPrefix("wss://") }
            let address = gateways.isEmpty ? Self.fallbackGateway : gateways[self.nodeIndex % gateways.count]
            guard let url = URL(string: address) else { return }
            let task = self.session.webSocketTask(with: url)
            task.maximumMessageSize = 4 * 1024 * 1024
            self.socket = task
            task.resume()
            self.handshakeTimeout = Task { @MainActor [weak self, weak task] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, let task, self.socket === task, self.connectionState != .connected else { return }
                self.connectionLost("节点 15 秒内未完成握手")
            }
            self.receive(from: task)
        }
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Initial node list from a lightweight node's /api/bootstrap, cached for offline starts.
    private func refreshBootstrap() async {
        var request = URLRequest(url: Self.bootstrapURL)
        request.timeoutInterval = 6
        guard let result = try? await session.data(for: request),
              let response = result.1 as? HTTPURLResponse, response.statusCode == 200 else { return }
        let data = result.0
        if let date = response.value(forHTTPHeaderField: "Date"), let server = Self.httpDate.date(from: date) {
            // The header has 1 s resolution; +500 ms centres the error.
            clockOffsetMs = Int64((server.timeIntervalSinceNow) * 1000) + 500
        }
        struct List: Decodable { var nodes: [CandyNodeInfo] }
        guard let list = try? decoder.decode(List.self, from: data), !list.nodes.isEmpty else { return }
        didRefreshBootstrap = true
        // The live list replaces the cache: keeping old entries could pin the app to a node from an
        // earlier deployment, where nobody else is. The cache is only used when this fetch fails.
        if bootstrapNodes.map(\.peerId) != list.nodes.map(\.peerId) { nodeIndex = 0 }
        bootstrapNodes = Array(list.nodes.prefix(16))
        if let encoded = try? encoder.encode(bootstrapNodes) { userDefaults.set(encoded, forKey: "candy_bootstrap_nodes") }
    }

    private func receive(from task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            while let self, self.socket === task {
                do {
                    let message = try await task.receive()
                    guard self.socket === task else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let payload): data = payload
                    @unknown default: continue
                    }
                    guard let event = try? self.decoder.decode(CandyGatewayEvent.self, from: data) else { continue }
                    self.handle(event)
                } catch {
                    guard self.socket === task else { return }
                    self.connectionLost(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handle(_ event: CandyGatewayEvent) {
        switch event.type {
        case "challenge":
            guard let nonce = event.nonce, let nodeID = event.node?.peerId, let identity else { return }
            do {
                let signature = try identity.signature(for: Data((CandyCodec.authPrefix + nonce + ":" + nodeID).utf8))
                send(CandyGatewayMessage(type: "hello", publicKey: identity.publicKey.rawRepresentation.base64EncodedString(),
                    signature: signature.base64EncodedString()))
            } catch { connectionLost("无法签名登录：\(error.localizedDescription)") }
        case "welcome":
            handshakeTimeout?.cancel()
            node = event.node
            region = event.region
            geo = event.geo.flatMap { $0.count == 2 ? $0 : nil }
            if let servers = event.iceServers, !servers.isEmpty { iceServers = servers }
            if event.peerId != peerID { errorMessage = "节点返回的身份与本机不一致。" }
            connectionState = .connected
            failures = 0
            replaceEntries(event.entries ?? [])
            announcedPresence = false
            announce()
            transfers.wake()
        case "plaza": replaceEntries(event.entries ?? [])
        case "plaza-update":
            if let entry = event.entry { upsert(entry) }
        case "plaza-remove":
            if let id = event.peerId {
                entries.removeValue(forKey: id)
                offlineSince.removeValue(forKey: id)
                rebuildListeners()
            }
        case "providers":
            guard let id = event.id, let continuation = pendingFinds.removeValue(forKey: id) else { return }
            if let error = event.error, (event.providers ?? []).isEmpty {
                continuation.resume(throwing: CandyTransferFailure.network(error))
            } else {
                continuation.resume(returning: event.providers ?? [])
            }
        case "signal":
            if let signal = event.signal { transfers.handle(signal) }
        case "signal-error":
            if let session = event.signal?.session { transfers.signalFailed(session: session, error: event.error ?? "unknown") }
        case "ice":
            if let servers = event.iceServers, !servers.isEmpty { iceServers = servers }
        case "error":
            if event.id?.hasPrefix("announce") == true, let error = event.error, !error.contains("stale") {
                if error.contains("clock") {
                    // Re-read the server time and try again instead of staying invisible.
                    let before = clockOffsetMs
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.refreshBootstrap()
                        // Only retry when the correction changed, so a persistent failure cannot loop.
                        if abs(self.clockOffsetMs - before) > 2000 { self.announce() }
                        else { self.errorMessage = "广场发布被节点拒绝：本机时间与节点相差过大，请开启自动设置时间。" }
                    }
                } else {
                    errorMessage = "广场发布被节点拒绝：\(error)"
                }
            }
        default: break
        }
    }

    private func connectionLost(_ reason: String) {
        guard socket != nil || connectionState != .disconnected else { return }
        closeSocket()
        connectionState = .disconnected
        markListenersOffline()
        failures += 1
        nodeIndex += 1 // rotate to the next bootstrap node
        scheduleReconnect()
    }

    private func closeSocket() {
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        node = nil
        let finds = pendingFinds
        pendingFinds.removeAll()
        finds.values.forEach { $0.resume(throwing: CandyTransferFailure.network("与节点的连接已断开")) }
    }

    private func scheduleReconnect() {
        guard hasStarted, reconnectTask == nil, pathSatisfied else { return }
        let delay = min(30, pow(2, Double(min(failures, 5)) - 1)) * Double.random(in: 0.75...1.25)
        reconnectTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.hasStarted else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }

    private func send(_ message: CandyGatewayMessage) {
        guard let socket, let data = try? encoder.encode(message) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard error != nil, let service = self else { return }
            Task { @MainActor in
                guard service.socket === socket else { return }
                service.connectionLost("发送失败")
            }
        }
    }

    // MARK: DHT lookups

    /// GET_PROVIDERS for a CID, executed by the node (which expands delegate providers).
    private func findProviders(_ cid: String) async throws -> [CandyCandidate] {
        guard connectionState == .connected else { throw CandyTransferFailure.network("与节点的连接已断开") }
        let id = UUID().uuidString.lowercased()
        // The continuation body is not main-actor isolated: register through a main-actor hop.
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in self.registerFind(id, cid: cid, continuation) }
        }
    }

    private func registerFind(_ id: String, cid: String, _ continuation: CheckedContinuation<[CandyCandidate], Error>) {
        guard connectionState == .connected, socket != nil else {
            continuation.resume(throwing: CandyTransferFailure.network("与节点的连接已断开"))
            return
        }
        pendingFinds[id] = continuation
        send(CandyGatewayMessage(type: "find", id: id, cid: cid))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            self?.pendingFinds.removeValue(forKey: id)?.resume(throwing: CandyTransferFailure.network("DHT 查询超时"))
        }
    }

    // MARK: Plaza entries

    private func replaceEntries(_ list: [CandyPlazaEntry]) {
        entries = [:]
        for entry in list where entry.body.peerId != peerID { entries[entry.body.peerId] = entry }
        offlineSince = offlineSince.filter { entries[$0.key]?.offline == true }
        rebuildListeners()
    }

    private func upsert(_ entry: CandyPlazaEntry) {
        guard entry.body.peerId != peerID else { return }
        if let current = entries[entry.body.peerId], current.body.seq > entry.body.seq { return }
        entries[entry.body.peerId] = entry
        if !entry.offline { offlineSince.removeValue(forKey: entry.body.peerId) }
        rebuildListeners()
    }

    private func rebuildListeners() {
        let now = Int64(Date().timeIntervalSince1970)
        listeners = entries.values.compactMap { entry -> CandyPlazaListening? in
            let body = entry.body
            // Prefer the song being listened to; web peers show their (first) uploaded file.
            let shared = body.files.first { $0.kind == "listening" } ?? body.files.first
            // Online users always show (e.g. a web page that shares nothing yet); offline ones only
            // while they still have something to offer.
            guard body.listening != nil || shared != nil || !entry.offline else { return nil }
            let file = shared.map { CandyPlazaFile(id: $0.cid, name: $0.name, size: $0.size, ownerId: body.peerId,
                ownerName: body.name, sha256: $0.sha256) }
            let title = body.listening?.title ?? shared.map { "分享：\($0.name)" } ?? "在线"
            var offlineAt: Int64?
            if entry.offline {
                offlineAt = offlineSince[body.peerId] ?? now
                offlineSince[body.peerId] = offlineAt
            }
            let geo = body.geo.flatMap { $0.count == 2 && abs($0[0]) <= 90 && abs($0[1]) <= 180 ? $0 : nil }
                ?? body.region.flatMap { regionGeo($0) }
            return CandyPlazaListening(clientId: body.peerId, ownerName: body.name, title: title,
                artist: body.listening?.artist ?? (body.client == "web" ? "网页端" : ""),
                isPlaying: body.listening?.isPlaying ?? (shared != nil), region: body.region,
                latitude: geo?[0], longitude: geo?[1], file: file, avatar: body.avatar,
                offlineAt: offlineAt)
        }.sorted { $0.clientId < $1.clientId }
    }

    private func regionGeo(_ raw: String) -> [Double]? {
        let region = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty, !["未知", "未知地区", "局域网", "本机"].contains(region) else { return nil }
        if let cached = regionCoordinates[region] { return cached.count == 2 ? cached : nil }
        if !regionQueue.contains(region) {
            regionQueue.append(region)
            geocodeNextRegion()
        }
        return nil
    }

    /// CLGeocoder handles one request at a time, so region names are looked up in turn.
    private func geocodeNextRegion() {
        guard !regionGeocoder.isGeocoding, let region = regionQueue.first else { return }
        regionGeocoder.geocodeAddressString(region) { [weak self] placemarks, error in
            let coordinate = placemarks?.first?.location?.coordinate
            let notFound = (error as? CLError)?.code == .geocodeFoundNoResult
            Task { @MainActor in
                guard let self else { return }
                self.regionQueue.removeAll { $0 == region }
                if let coordinate {
                    // Same 0.1° precision as node-provided geo.
                    self.regionCoordinates[region] = [(coordinate.latitude * 10).rounded() / 10,
                                                      (coordinate.longitude * 10).rounded() / 10]
                } else if notFound {
                    self.regionCoordinates[region] = []
                }
                if coordinate != nil || notFound {
                    self.userDefaults.set(self.regionCoordinates, forKey: "candy_region_geo")
                    self.rebuildListeners()
                }
                // Network errors are not cached; the name is retried on the next rebuild.
                self.geocodeNextRegion()
            }
        }
    }

    private func markListenersOffline() {
        let now = Int64(Date().timeIntervalSince1970)
        for (id, var entry) in entries where !entry.offline {
            entry.offline = true
            entries[id] = entry
            offlineSince[id] = now
        }
        rebuildListeners()
    }

    private func expireOffline() {
        let now = Int64(Date().timeIntervalSince1970)
        let expired = offlineSince.filter { now - $0.value >= 60 }.map(\.key)
        guard !expired.isEmpty else { return }
        for id in expired {
            entries.removeValue(forKey: id)
            offlineSince.removeValue(forKey: id)
        }
        rebuildListeners()
    }

    // MARK: Publishing

    func setSharesListening(_ enabled: Bool) {
        sharesListening = enabled
        userDefaults.set(enabled, forKey: "candy_shares_listening")
        synchronizeShare()
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
        if let current = share { share = (current.trackID, CandyPlazaFile(id: current.file.id, name: current.file.name,
            size: current.file.size, ownerId: peerID, ownerName: nickname, sha256: current.file.sha256)) }
        announce()
        return true
    }

    func updateListening(track: Track?, isPlaying: Bool) {
        let changed = track?.id != listeningTrack?.id || track?.fileURL != listeningTrack?.fileURL
        listeningTrack = track
        listeningIsPlaying = isPlaying
        if changed { synchronizeShare() } else { announce() }
    }

    /// Playing a song publishes it: hash → CID → delegated PROVIDE + plaza announcement.
    private func synchronizeShare() {
        guard sharesListening, let track = listeningTrack else {
            manifestTask?.cancel()
            shareGeneration += 1
            share = nil
            transfers.withdraw()
            announce()
            return
        }
        guard share?.trackID != track.id else { announce(); return }
        manifestTask?.cancel()
        shareGeneration += 1
        let generation = shareGeneration
        share = nil
        announce() // listening metadata goes out immediately; the file follows after hashing
        manifestTask = Task { @MainActor [weak self] in
            do {
                let manifest = try await CandyTransferDisk.manifest(track.fileURL)
                try Task.checkCancellation()
                guard let self, self.shareGeneration == generation, self.sharesListening,
                      let cid = CandyCodec.cid(sha256Hex: manifest.sha256) else { return }
                let file = CandyPlazaFile(id: cid, name: track.fileURL.lastPathComponent, size: manifest.size,
                    ownerId: self.peerID, ownerName: self.nickname, sha256: manifest.sha256)
                self.transfers.publish(file, url: track.fileURL, manifest: manifest)
                self.share = (track.id, file)
                self.manifestTask = nil
                self.announce()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.shareGeneration == generation else { return }
                self.manifestTask = nil
                self.errorMessage = "当前歌曲无法自动分享：\(error.localizedDescription)"
            }
        }
    }

    /// Signs and sends the plaza announcement (heartbeat every 30 s). Opt-out sends a signed "bye".
    private func announce() {
        guard connectionState == .connected, let identity, let node else { return }
        let visible = sharesListening && listeningTrack != nil
        guard visible || announcedPresence else { return }
        let via = (node.addrs ?? []).prefix(8).map { $0.contains("/p2p/") ? $0 : "\($0)/p2p/\(node.peerId)" }
        let now = Int64(Date().timeIntervalSince1970 * 1000) + clockOffsetMs
        lastSeq = max(now, lastSeq + 1)
        var body = CandyPlazaBody(peerId: peerID, name: nickname, avatar: avatar, region: region,
            geo: visible ? geo : nil, client: "ios", via: Array(via), files: [], seq: lastSeq)
        if visible, let track = listeningTrack {
            body.listening = CandyAnnouncedListening(title: String(track.title.prefix(300)),
                artist: String(track.artist.prefix(300)), isPlaying: listeningIsPlaying)
            if let file = share?.file, let sha = file.sha256 {
                body.files = [CandyAnnouncedFile(cid: file.id, name: file.name, size: file.size, sha256: sha,
                    kind: "listening", mime: nil)]
            }
        } else {
            body.bye = true
            body.avatar = nil
        }
        do {
            let envelope = try CandyCodec.envelope(body, key: identity)
            send(CandyGatewayMessage(type: "announce", id: "announce-\(lastSeq)", envelope: envelope))
            announcedPresence = visible
        } catch {
            errorMessage = "无法签名广场信息：\(error.localizedDescription)"
        }
    }

    // MARK: Downloads

    func download(_ file: CandyPlazaFile) {
        guard connectionState == .connected else {
            errorMessage = "广场连接断开，请连接后重试。"
            return
        }
        transfers.download(file)
    }

    /// "听听看": plays a plaza song while it downloads (or the local copy if it is already here).
    func listen(_ file: CandyPlazaFile) {
        if let url = localCopy(of: file) {
            preview.playLocal(file, url: url)
            return
        }
        guard connectionState == .connected else {
            errorMessage = "广场连接断开，请连接后重试。"
            return
        }
        preview.stream(file, partial: transfers.partialURL(for: file), available: transfers.verifiedBytes(file.id) ?? 0)
        if !transfers.isDownloading(file.id) { transfers.download(file) }
    }

    func localCopy(of file: CandyPlazaFile) -> URL? {
        let candidates = [downloads[file.id]?.localURL] + receiveHistory.filter { $0.fileID == file.id }.map(\.localURL)
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func cancelDownload(_ fileID: String) {
        transfers.cancel(fileID)
        if let current = preview.file, current.id == fileID, localCopy(of: current) == nil { preview.stop() }
    }
    func retryDownload(_ file: CandyPlazaFile) { transfers.download(file) }
    func clearDownloadPartial(_ file: CandyPlazaFile) {
        if preview.file?.id == file.id { preview.stop() }
        transfers.clearPartial(file)
        downloads.removeValue(forKey: file.id)
    }
    func dismissError() { errorMessage = nil }
    func clearReceiveHistory() {
        receiveHistory = []
        userDefaults.removeObject(forKey: "candy_receive_log")
    }
}
