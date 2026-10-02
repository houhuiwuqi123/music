import AVFoundation
import Combine
import Foundation

@MainActor
final class MusicPlayerViewModel: ObservableObject {
    enum RepeatMode: String, CaseIterable, Identifiable {
        case list = "List Loop"
        case one = "Repeat One"

        var id: String { rawValue }
        var icon: String { self == .one ? "repeat.1" : "repeat" }
    }

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .list
    @Published var shuffleEnabled = false

    var onTrackStarted: ((UUID) -> Void)?

    private let player = AVPlayer()
    private var queue: [Track] = []
    private var currentIndex: Int?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        configureAudioSession()
        observePlayback()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ track: Track, in tracks: [Track]) {
        queue = tracks
        currentIndex = tracks.firstIndex(where: { $0.id == track.id })
        currentTrack = track
        duration = track.duration
        currentTime = 0
        let item = AVPlayerItem(url: track.fileURL)
        observePlaybackEnd(for: item)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        onTrackStarted?(track.id)
    }

    func togglePlayback() {
        guard player.currentItem != nil else {
            if let first = queue.first { play(first, in: queue) }
            return
        }

        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let target = min(max(seconds, 0), duration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func next() {
        guard !queue.isEmpty else { return }
        let nextIndex: Int
        if shuffleEnabled, queue.count > 1 {
            let candidates = queue.indices.filter { $0 != currentIndex }
            nextIndex = candidates.randomElement() ?? 0
        } else {
            nextIndex = ((currentIndex ?? -1) + 1) % queue.count
        }
        play(queue[nextIndex], in: queue)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let index = currentIndex ?? 0
        let previousIndex = (index - 1 + queue.count) % queue.count
        play(queue[previousIndex], in: queue)
    }

    func updateQueue(_ tracks: [Track]) {
        queue = tracks
        if let id = currentTrack?.id {
            currentIndex = tracks.firstIndex(where: { $0.id == id })
        }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
    }

    func playAll(_ tracks: [Track], shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = shuffled
        let first = shuffled ? (tracks.randomElement() ?? tracks[0]) : tracks[0]
        play(first, in: tracks)
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
    }

    private func observePlayback() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite {
                    self.duration = seconds
                }
            }
        }
    }

    private func observePlaybackEnd(for item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            player.play()
            isPlaying = true
        case .list:
            next()
        }
    }
}
