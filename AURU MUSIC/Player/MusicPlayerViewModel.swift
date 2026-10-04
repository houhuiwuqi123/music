import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

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
        setupRemoteTransportControls()
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
        updateNowPlayingInfo()
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
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func seek(to seconds: TimeInterval) {
        let target = min(max(seconds, 0), duration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        updateNowPlayingInfo()
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
            if let updatedTrack = tracks.first(where: { $0.id == id }) { currentTrack = updatedTrack }
            updateNowPlayingInfo()
        }
    }

    func insertNext(_ track: Track) {
        queue.removeAll { $0.id == track.id && $0.id != currentTrack?.id }
        if let currentID = currentTrack?.id {
            currentIndex = queue.firstIndex(where: { $0.id == currentID })
        }
        let insertionIndex = min((currentIndex ?? -1) + 1, queue.count)
        queue.insert(track, at: insertionIndex)
        if let currentID = currentTrack?.id {
            currentIndex = queue.firstIndex(where: { $0.id == currentID })
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
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
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
                self.updateNowPlayingInfo()
            }
        }
    }

    private func setupRemoteTransportControls() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true

        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.togglePlayback()
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.albumName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let data = track.artworkData, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
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
