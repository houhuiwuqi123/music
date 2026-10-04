import AVFoundation
import ShazamKit
import SwiftUI
import UIKit

struct FeedSupportView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DarkBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        if let image = UIImage(named: "FeedQRCode") {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        } else {
                            VStack(spacing: 18) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 150, weight: .light))
                                Text(settings.text("feedThanks"))
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 360)
                            .glassCard()
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(settings.text("feedSupport"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(settings.text("done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
final class SongRecognitionService: NSObject, ObservableObject, SHSessionDelegate {
    enum State: Equatable { case idle, listening, found, failed, denied }

    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artworkURL: URL?

    private let session = SHSession()
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false

    override init() {
        super.init()
        session.delegate = self
    }

    func toggle() {
        state == .listening ? stop() : requestPermissionAndStart()
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? AVAudioSession.sharedInstance().setActive(true)
        if state == .listening { state = .idle }
    }

    private func requestPermissionAndStart() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted { self.start() } else { self.state = .denied }
            }
        }
    }

    private func start() {
        stop()
        title = ""
        artist = ""
        artworkURL = nil

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
                self?.session.matchStreamingBuffer(buffer, at: time)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
        } catch {
            state = .failed
            stop()
        }
    }

    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        Task { @MainActor [weak self] in
            self?.title = item.title ?? ""
            self?.artist = item.artist ?? ""
            self?.artworkURL = item.artworkURL
            self?.state = .found
            self?.stop()
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        Task { @MainActor [weak self] in
            self?.state = .failed
            self?.stop()
        }
    }
}

struct SongRecognitionView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: MusicPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recognizer = SongRecognitionService()
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            ZStack {
                DarkBackground()
                VStack(spacing: 34) {
                    Spacer()
                    radar
                    result
                    Button {
                        if recognizer.state != .listening { player.pause() }
                        recognizer.toggle()
                    } label: {
                        Label(
                            settings.text(recognizer.state == .listening ? "stopRecognizing" : "startRecognizing"),
                            systemImage: recognizer.state == .listening ? "stop.fill" : "waveform"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .padding(.horizontal, 38)
                    Spacer()
                }
            }
            .navigationTitle(settings.text("recognizeMusic"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { pulse = true }
        .onChange(of: recognizer.state) { state in
            guard state == .listening else { return }
            pulse = false
            DispatchQueue.main.async { pulse = true }
        }
        .onDisappear { recognizer.stop() }
    }

    private var radar: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.purple.opacity(0.45 - Double(index) * 0.1), lineWidth: 2)
                    .frame(width: 130, height: 130)
                    .scaleEffect(recognizer.state == .listening && pulse ? 2.15 : 0.75)
                    .opacity(recognizer.state == .listening && pulse ? 0 : 0.7)
                    .animation(
                        recognizer.state == .listening
                            ? .easeOut(duration: 2).repeatForever(autoreverses: false).delay(Double(index) * 0.55)
                            : .default,
                        value: pulse
                    )
            }
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 126, height: 126)
                .overlay {
                    Image(systemName: "shazam.logo")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.purple)
                }
                .shadow(color: .purple.opacity(0.45), radius: 30)
        }
        .frame(height: 280)
    }

    @ViewBuilder private var result: some View {
        switch recognizer.state {
        case .found:
            VStack(spacing: 10) {
                AsyncImage(url: recognizer.artworkURL) { image in image.resizable().scaledToFill() } placeholder: {
                    Image(systemName: "music.note").font(.largeTitle)
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                Text(recognizer.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(recognizer.artist).foregroundStyle(.secondary)
            }
        case .listening:
            Text(settings.text("recognizing")).font(.title3.bold())
        case .failed:
            Text(settings.text("noRecognition")).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .denied:
            Text(settings.text("microphoneDenied")).foregroundStyle(.orange).multilineTextAlignment(.center)
        case .idle:
            Text(settings.text("recognizeHint")).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
