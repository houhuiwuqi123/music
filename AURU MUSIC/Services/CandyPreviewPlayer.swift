import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

// "听听看": play a plaza song while it downloads.
// The reliable transfer writes the song into its content-addressed partial file and
// reports how many bytes from the start passed the per-block SHA-256 check. AVPlayer
// reads through a resource loader that only ever serves those verified bytes, and
// waits (buffering) for ranges that have not arrived yet. When the download finishes
// the loader switches to the completed file, so playback continues seamlessly.

/// Serves byte ranges of a growing file to AVFoundation. All state lives on `queue`,
/// which is also the resource loader's delegate queue.
final class CandyStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "candy.preview.loader")
    private let size: Int64
    private let contentType: String
    private var source: URL
    private var available: Int64 = 0
    private var failure: Error?
    private var pending: [AVAssetResourceLoadingRequest] = []

    init(source: URL, size: Int64, contentType: String) {
        self.source = source
        self.size = size
        self.contentType = contentType
    }

    /// Verified bytes grew (or the file moved to its completed location).
    func update(available bytes: Int64, source url: URL? = nil) {
        queue.async {
            if let url { self.source = url }
            self.available = min(self.size, max(0, bytes))
            self.serve()
        }
    }

    func fail(_ error: Error) {
        queue.async {
            self.failure = error
            let requests = self.pending
            self.pending.removeAll()
            requests.forEach { $0.finishLoading(with: error) }
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let failure {
            loadingRequest.finishLoading(with: failure)
            return true
        }
        pending.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func serve() {
        guard !pending.isEmpty else { return }
        var handle: FileHandle?
        defer { try? handle?.close() }
        pending.removeAll { request in
            if request.isCancelled || request.isFinished { return true }
            if let info = request.contentInformationRequest {
                info.contentType = contentType
                info.contentLength = size
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else {
                request.finishLoading()
                return true
            }
            let end = data.requestsAllDataToEndOfResource ? size
                : min(size, data.requestedOffset + Int64(data.requestedLength))
            while data.currentOffset < min(end, available) {
                let start = data.currentOffset
                let count = Int(min(min(end, available) - start, 262_144))
                do {
                    if handle == nil { handle = try FileHandle(forReadingFrom: source) }
                    try handle?.seek(toOffset: UInt64(start))
                    guard let chunk = try handle?.read(upToCount: count), !chunk.isEmpty else { return false }
                    data.respond(with: chunk)
                } catch {
                    // The partial may be mid-rename to its completed location; retry on the next update.
                    try? handle?.close()
                    handle = nil
                    return false
                }
            }
            if data.currentOffset >= end {
                request.finishLoading()
                return true
            }
            return false
        }
    }
}

@MainActor
final class CandyPreviewPlayer: ObservableObject {
    enum Phase: Equatable {
        case idle, buffering, playing, paused
        case failed(String)
    }

    @Published private(set) var file: CandyPlazaFile?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    /// Fraction of the song that is downloaded and verified.
    @Published private(set) var buffered: Double = 0
    @Published private(set) var status = ""

    private let player = AVPlayer()
    private var loader: CandyStreamLoader?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var wantsPlay = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main) { [weak self] time in
            guard let player = self else { return }
            Task { @MainActor in player.tick(time) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            guard let player = self else { return }
            Task { @MainActor in player.refreshPhase() }
        })
    }

    var isActive: Bool { file != nil }

    static func canStream(_ name: String) -> Bool {
        !["ogg", "oga", "opus"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    /// Plays a song that is (being) downloaded into `partial`. `available` is the verified prefix.
    func stream(_ file: CandyPlazaFile, partial: URL, available: Int64) {
        guard Self.canStream(file.name) else {
            reset()
            self.file = file
            phase = .failed("该格式不支持边下边播，下载完成后可在接收记录中播放。")
            return
        }
        reset()
        self.file = file
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)?.identifier ?? UTType.mp3.identifier
        let loader = CandyStreamLoader(source: partial, size: file.size, contentType: type)
        self.loader = loader
        // A custom scheme routes every read through the loader instead of the network stack.
        var components = URLComponents()
        components.scheme = "candy-stream"
        components.host = "song"
        components.path = "/\(file.id)" + (ext.isEmpty ? "" : ".\(ext)")
        let asset = AVURLAsset(url: components.url ?? URL(string: "candy-stream://song/\(file.id)")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        start(AVPlayerItem(asset: asset))
        update(file.id, available: available)
        status = "正在连接对方…"
    }

    /// Plays an already downloaded copy.
    func playLocal(_ file: CandyPlazaFile, url: URL) {
        reset()
        self.file = file
        buffered = 1
        start(AVPlayerItem(url: url))
    }

    func update(_ fileID: String, available: Int64) {
        guard file?.id == fileID, let file else { return }
        if available == 0 && buffered > 0 {
            // Whole-file verification failed: what was played cannot be trusted.
            loader?.fail(CandyTransferFailure.invalid("歌曲校验失败"))
            phase = .failed("歌曲校验失败，已停止试听。")
            player.pause()
            return
        }
        buffered = file.size > 0 ? Double(available) / Double(file.size) : 0
        loader?.update(available: available)
    }

    func completed(_ fileID: String, url: URL) {
        guard file?.id == fileID, let file else { return }
        buffered = 1
        status = ""
        loader?.update(available: file.size, source: url)
    }

    func downloadStatus(_ fileID: String, _ message: String) {
        guard file?.id == fileID else { return }
        status = message
    }

    func toggle() {
        guard file != nil else { return }
        if wantsPlay { pause() } else { resume() }
    }

    func pause() {
        wantsPlay = false
        player.pause()
        refreshPhase()
    }

    func resume() {
        guard file != nil else { return }
        if case .failed = phase { return }
        if duration > 0, currentTime >= duration - 0.5 { player.seek(to: .zero) }
        wantsPlay = true
        player.play()
        refreshPhase()
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        // Only seek inside what has arrived; further ahead would just stall.
        let target = min(fraction, max(0, buffered - 0.01)) * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop() {
        reset()
        file = nil
        phase = .idle
    }

    private func start(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let player = self, item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "无法播放"
            Task { @MainActor in player.phase = .failed("无法播放：\(message)") }
        })
        observations.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            guard let player = self, seconds.isFinite, seconds > 0 else { return }
            Task { @MainActor in player.duration = seconds }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
            queue: .main) { [weak self] _ in
            guard let player = self else { return }
            Task { @MainActor in
                player.wantsPlay = false
                player.refreshPhase()
            }
        }
        player.replaceCurrentItem(with: item)
        wantsPlay = true
        phase = .buffering
        player.play()
    }

    private func reset() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.fail(CancellationError())
        loader = nil
        // Keep the player-level observation (index 0); drop the per-item ones.
        observations = Array(observations.prefix(1))
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        wantsPlay = false
        currentTime = 0
        duration = 0
        buffered = 0
        status = ""
    }

    private func tick(_ time: CMTime) {
        guard file != nil, time.seconds.isFinite else { return }
        currentTime = time.seconds
    }

    private func refreshPhase() {
        guard file != nil else { return }
        if case .failed = phase { return }
        switch player.timeControlStatus {
        case .playing: phase = .playing
        case .waitingToPlayAtSpecifiedRate: phase = .buffering
        case .paused: phase = wantsPlay ? .buffering : .paused
        @unknown default: break
        }
    }
}
