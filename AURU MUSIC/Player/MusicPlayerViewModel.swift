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
    @Published private(set) var currentVideo: LocalVideo?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var repeatMode: RepeatMode = .list
    @Published var shuffleEnabled = false

    var onTrackStarted: ((UUID) -> Void)?
    var onVideoStarted: ((UUID) -> Void)?

    var hasCurrentMedia: Bool { currentTrack != nil || currentVideo != nil }
    var currentTitle: String { currentTrack?.title ?? currentVideo?.title ?? "" }
    var currentArtist: String { currentTrack?.artist ?? currentVideo?.artist ?? "" }
    var isVideo: Bool { currentVideo != nil }

    let playbackPlayer = AVPlayer()
    private var trackQueue: [Track] = []
    private var videoQueue: [LocalVideo] = []
    private var currentIndex: Int?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        configureAudioSession()
        setupRemoteTransportControls()
        observePlayback()
    }

    deinit {
        if let timeObserver { playbackPlayer.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func play(_ track: Track, in tracks: [Track]) {
        trackQueue = tracks
        videoQueue = []
        currentIndex = tracks.firstIndex(where: { $0.id == track.id })
        currentTrack = track
        currentVideo = nil
        duration = track.duration
        currentTime = 0
        let item = AVPlayerItem(url: track.fileURL)
        observePlaybackEnd(for: item)
        playbackPlayer.replaceCurrentItem(with: item)
        playbackPlayer.play()
        isPlaying = true
        updateNowPlayingInfo()
        onTrackStarted?(track.id)
    }

    func play(_ video: LocalVideo, in videos: [LocalVideo]) {
        videoQueue = videos
        trackQueue = []
        currentIndex = videos.firstIndex(where: { $0.id == video.id })
        currentVideo = video
        currentTrack = nil
        duration = video.duration
        currentTime = 0
        let item = AVPlayerItem(url: video.fileURL)
        observePlaybackEnd(for: item)
        playbackPlayer.replaceCurrentItem(with: item)
        playbackPlayer.play()
        isPlaying = true
        updateNowPlayingInfo()
        onVideoStarted?(video.id)
    }

    func togglePlayback() {
        guard playbackPlayer.currentItem != nil else {
            if let first = trackQueue.first { play(first, in: trackQueue) }
            else if let first = videoQueue.first { play(first, in: videoQueue) }
            return
        }

        if isPlaying {
            playbackPlayer.pause()
        } else {
            playbackPlayer.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    func pause() {
        playbackPlayer.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func seek(to seconds: TimeInterval) {
        let target = min(max(seconds, 0), duration)
        playbackPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        updateNowPlayingInfo()
    }

    func next() {
        let count = currentVideo == nil ? trackQueue.count : videoQueue.count
        guard count > 0 else { return }
        let nextIndex: Int
        if shuffleEnabled, count > 1 {
            let candidates = (0..<count).filter { $0 != currentIndex }
            nextIndex = candidates.randomElement() ?? 0
        } else {
            nextIndex = ((currentIndex ?? -1) + 1) % count
        }
        if currentVideo != nil { play(videoQueue[nextIndex], in: videoQueue) }
        else { play(trackQueue[nextIndex], in: trackQueue) }
    }

    func previous() {
        let count = currentVideo == nil ? trackQueue.count : videoQueue.count
        guard count > 0 else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let index = currentIndex ?? 0
        let previousIndex = (index - 1 + count) % count
        if currentVideo != nil { play(videoQueue[previousIndex], in: videoQueue) }
        else { play(trackQueue[previousIndex], in: trackQueue) }
    }

    func updateQueue(_ tracks: [Track]) {
        trackQueue = tracks
        if let id = currentTrack?.id {
            currentIndex = tracks.firstIndex(where: { $0.id == id })
            guard let updatedTrack = tracks.first(where: { $0.id == id }) else {
                clearCurrentMedia()
                return
            }
            currentTrack = updatedTrack
            updateNowPlayingInfo()
        }
    }

    func updateVideoQueue(_ videos: [LocalVideo]) {
        videoQueue = videos
        if let id = currentVideo?.id {
            currentIndex = videos.firstIndex(where: { $0.id == id })
            guard let updatedVideo = videos.first(where: { $0.id == id }) else {
                clearCurrentMedia()
                return
            }
            currentVideo = updatedVideo
            updateNowPlayingInfo()
        }
    }

    func clearCurrentMedia() {
        playbackPlayer.pause()
        playbackPlayer.replaceCurrentItem(with: nil)
        currentTrack = nil
        currentVideo = nil
        currentIndex = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func insertNext(_ track: Track) {
        trackQueue.removeAll { $0.id == track.id && $0.id != currentTrack?.id }
        if let currentID = currentTrack?.id {
            currentIndex = trackQueue.firstIndex(where: { $0.id == currentID })
        }
        let insertionIndex = min((currentIndex ?? -1) + 1, trackQueue.count)
        trackQueue.insert(track, at: insertionIndex)
        if let currentID = currentTrack?.id {
            currentIndex = trackQueue.firstIndex(where: { $0.id == currentID })
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
        timeObserver = playbackPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.playbackPlayer.currentItem?.duration.seconds, seconds.isFinite {
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
        guard hasCurrentMedia else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentArtist,
            MPMediaItemPropertyAlbumTitle: currentTrack?.albumName ?? "Video",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let data = currentTrack?.artworkData, let image = UIImage(data: data) {
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
            playbackPlayer.play()
            isPlaying = true
        case .list:
            next()
        }
    }
}
