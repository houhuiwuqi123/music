import AVFoundation
import CryptoKit
import SwiftUI
import UIKit
import Vision

struct FeedSupportView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var qrMessage: String?

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
                                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .onLongPressGesture(minimumDuration: 0.6) { recognizeAndOpenQRCode(image) }
                                .contextMenu {
                                    Button { recognizeAndOpenQRCode(image) } label: {
                                        Label(settings.text("openWechatPay"), systemImage: "qrcode.viewfinder")
                                    }
                                }
                            Text(settings.text("tipMessage"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(5)
                                .padding(.horizontal, 8)
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
        .alert(settings.text("tipQRCode"), isPresented: Binding(
            get: { qrMessage != nil },
            set: { if !$0 { qrMessage = nil } }
        )) {
            Button(settings.text("ok")) { qrMessage = nil }
        } message: {
            Text(qrMessage ?? "")
        }
    }

    private func recognizeAndOpenQRCode(_ image: UIImage) {
        guard let cgImage = image.cgImage else {
            qrMessage = settings.text("qrRecognitionFailed")
            return
        }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            guard let payload = request.results?.first?.payloadStringValue, !payload.isEmpty else {
                qrMessage = settings.text("qrRecognitionFailed")
                return
            }
            UIPasteboard.general.string = payload
            let application = UIApplication.shared
            if let paymentURL = URL(string: payload), application.canOpenURL(paymentURL) {
                application.open(paymentURL)
            } else if let scannerURL = URL(string: "weixin://scanqrcode"), application.canOpenURL(scannerURL) {
                application.open(scannerURL)
                qrMessage = settings.text("qrCopiedHint")
            } else if let wechatURL = URL(string: "weixin://"), application.canOpenURL(wechatURL) {
                application.open(wechatURL)
                qrMessage = settings.text("qrCopiedHint")
            } else {
                qrMessage = settings.text("wechatUnavailable")
            }
        } catch {
            qrMessage = settings.text("qrRecognitionFailed")
        }
    }
}

@MainActor
final class SongRecognitionService: NSObject, ObservableObject {
    enum State: Equatable { case idle, listening, found, failed(String), denied, unavailable }

    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artworkURL: URL?

    private enum ACRCloud {
        static let host = "identify-ap-southeast-1.acrcloud.com"
        static let accessKey = "4b4e7a046007a357be1743088cb74a6e"
        static let accessSecret = "MisLNrNBsjsDMiIW0lWwnmGfYOZxpgNAlbTab9IL"
        static let path = "/v1/identify"
    }

    private var recorder: AVAudioRecorder?
    private var recognitionTask: Task<Void, Never>?
    private var recordingURL: URL?

    func toggle() {
        state == .listening ? stop() : requestPermissionAndStart()
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recorder?.stop()
        recorder = nil
        removeRecording()
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
            try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            try audioSession.setActive(true)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("auru-recognition-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else { throw RecognitionError.recordingFailed }
            self.recorder = recorder
            recordingURL = url
            state = .listening
            recognitionTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self, self.state == .listening else { return }
                    self.recorder?.stop()
                    self.recorder = nil
                    let result = try await self.identifyRecording(at: url)
                    guard !Task.isCancelled else { return }
                    self.title = result.title
                    self.artist = result.artist
                    self.artworkURL = result.artworkURL
                    self.state = .found
                    self.finishAudioSession()
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.state = .failed(error.localizedDescription)
                    self.finishAudioSession()
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            finishAudioSession()
        }
    }

    private func identifyRecording(at url: URL) async throws -> RecognitionResult {
        let sample = try Data(contentsOf: url)
        guard !sample.isEmpty else { throw RecognitionError.recordingFailed }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let stringToSign = ["POST", ACRCloud.path, ACRCloud.accessKey, "audio", "1", timestamp].joined(separator: "\n")
        let key = SymmetricKey(data: Data(ACRCloud.accessSecret.utf8))
        let authentication = HMAC<Insecure.SHA1>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        let signature = Data(authentication).base64EncodedString()
        let boundary = "Boundary-\(UUID().uuidString)"

        guard let endpoint = URL(string: "https://\(ACRCloud.host)\(ACRCloud.path)") else {
            throw RecognitionError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, fields: [
            "access_key": ACRCloud.accessKey,
            "data_type": "audio",
            "signature_version": "1",
            "signature": signature,
            "sample_bytes": String(sample.count),
            "timestamp": timestamp
        ], sample: sample)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RecognitionError.serverUnavailable
        }
        return try parseResponse(data)
    }

    private func multipartBody(boundary: String, fields: [String: String], sample: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"sample\"; filename=\"sample.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(sample)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func parseResponse(_ data: Data) throws -> RecognitionResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? [String: Any],
              let code = status["code"] as? Int else { throw RecognitionError.invalidResponse }
        guard code == 0,
              let metadata = root["metadata"] as? [String: Any],
              let songs = metadata["music"] as? [[String: Any]],
              let song = songs.first,
              let title = song["title"] as? String else {
            if code == 1001 { throw RecognitionError.noMatch }
            let message = status["msg"] as? String
            throw RecognitionError.service(message ?? "ACRCloud error \(code)")
        }
        let artists = (song["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let external = song["external_metadata"] as? [String: Any]
        let spotify = external?["spotify"] as? [String: Any]
        let album = spotify?["album"] as? [String: Any]
        let images = album?["images"] as? [[String: Any]]
        let artworkURL = (images?.first?["url"] as? String).flatMap(URL.init(string:))
        return RecognitionResult(title: title, artist: artists.joined(separator: ", "), artworkURL: artworkURL)
    }

    private func finishAudioSession() {
        recorder?.stop()
        recorder = nil
        removeRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func removeRecording() {
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    private struct RecognitionResult {
        let title: String
        let artist: String
        let artworkURL: URL?
    }

    private enum RecognitionError: LocalizedError {
        case recordingFailed, invalidResponse, serverUnavailable, noMatch, service(String)

        var errorDescription: String? {
            switch self {
            case .recordingFailed: return "Unable to record microphone audio."
            case .invalidResponse: return "ACRCloud returned an invalid response."
            case .serverUnavailable: return "ACRCloud is currently unavailable."
            case .noMatch: return ""
            case .service(let message): return message
            }
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
        case .failed(let detail):
            VStack(spacing: 6) {
                Text(settings.text("noRecognition"))
                if !detail.isEmpty { Text(detail).font(.caption) }
            }
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .denied:
            Text(settings.text("microphoneDenied")).foregroundStyle(.orange).multilineTextAlignment(.center)
        case .unavailable:
            Text(settings.text("recognitionDevelopmentDisabled"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .idle:
            Text(settings.text("recognizeHint")).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
