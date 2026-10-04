import AVKit
import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: MusicPlayerViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isSeeking = false
    @State private var seekValue: TimeInterval = 0
    @State private var selectedPage = 0

    var body: some View {
        NavigationStack {
            ZStack {
                DarkBackground()

                VStack(spacing: 26) {
                    Spacer(minLength: 8)

                    if player.isVideo {
                        VideoPlayer(player: player.playbackPlayer)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12)) }
                            .padding(.horizontal, 20)
                            .frame(height: 310)
                    } else {
                        TabView(selection: $selectedPage) {
                            ArtworkView(track: player.currentTrack, size: 282, cornerRadius: 30)
                                .rotationEffect(.degrees(player.isPlaying ? 360 : 0))
                                .animation(
                                    player.isPlaying
                                        ? .linear(duration: 24).repeatForever(autoreverses: false)
                                        : .default,
                                    value: player.isPlaying
                                )
                                .tag(0)
                            SyncedLyricsView(
                                lyrics: player.currentTrack?.lyrics,
                                currentTime: player.currentTime,
                                duration: player.duration,
                                emptyText: settings.text("noLyrics"),
                                onSeek: player.seek,
                                onShowArtwork: { withAnimation { selectedPage = 0 } }
                            )
                            .padding(.horizontal, 24)
                            .tag(1)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .automatic))
                        .frame(height: 310)
                    }

                    VStack(spacing: 7) {
                        Text(player.currentTitle.isEmpty ? "Not Playing" : player.currentTitle)
                            .font(.title2.bold())
                            .lineLimit(1)
                        Text(player.currentArtist)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(player.currentTrack?.albumName ?? (player.isVideo ? settings.text("video") : ""))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal)

                    VStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekValue : player.currentTime },
                                set: { seekValue = $0 }
                            ),
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                isSeeking = editing
                                if !editing { player.seek(to: seekValue) }
                            }
                        )
                        .tint(.primary)

                        HStack {
                            Text((isSeeking ? seekValue : player.currentTime).musicTime)
                            Spacer()
                            Text(player.duration.musicTime)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 26)

                    HStack(spacing: 16) {
                        Button(action: player.toggleShuffle) {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.shuffleEnabled ? Color.purple : Color.primary)
                                .frame(width: 44, height: 48)
                        }

                        Button(action: player.previous) {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .frame(width: 48, height: 48)
                        }

                        Button(action: player.togglePlayback) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 48, height: 48)
                        }

                        Button(action: player.next) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                                .frame(width: 48, height: 48)
                        }

                        Button {
                            player.repeatMode = player.repeatMode == .list ? .one : .list
                        } label: {
                            Image(systemName: player.repeatMode.icon)
                                .foregroundStyle(player.repeatMode == .one ? Color.purple : Color.primary)
                                .frame(width: 44, height: 48)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 14)
                }
            }
            .navigationTitle(settings.text("nowPlaying"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
    }
}

private struct LyricLine: Identifiable {
    let id: Int
    let time: TimeInterval
    let text: String
}

private struct SyncedLyricsView: View {
    let lyrics: String?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let emptyText: String
    let onSeek: (TimeInterval) -> Void
    let onShowArtwork: () -> Void
    private let lines: [LyricLine]
    @State private var isDragging = false
    @State private var isDragSettled = false
    @State private var dragStartTime: TimeInterval = 0
    @State private var draggedTime: TimeInterval?
    @State private var dragUpdateToken = 0

    init(
        lyrics: String?,
        currentTime: TimeInterval,
        duration: TimeInterval,
        emptyText: String,
        onSeek: @escaping (TimeInterval) -> Void,
        onShowArtwork: @escaping () -> Void
    ) {
        self.lyrics = lyrics
        self.currentTime = currentTime
        self.duration = duration
        self.emptyText = emptyText
        self.onSeek = onSeek
        self.onShowArtwork = onShowArtwork
        lines = Self.parse(lyrics ?? "")
    }

    private var hasTimedLyrics: Bool { lines.contains(where: { $0.time.isFinite }) }
    private var displayTime: TimeInterval { draggedTime ?? currentTime }
    private var activeLineID: Int? {
        lines.last(where: { $0.time.isFinite && $0.time <= displayTime + 0.05 })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                if lines.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 270)
                } else {
                    LazyVStack(spacing: 18) {
                        Color.clear.frame(height: 100)
                        ForEach(lines) { line in
                            Button {
                                guard line.time.isFinite else { return }
                                onSeek(line.time)
                                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line.id, anchor: .center) }
                            } label: {
                                Text(line.text)
                                    .font(activeLineID == line.id ? .title3.bold() : .body)
                                    .foregroundStyle(activeLineID == line.id ? Color.primary : Color.secondary)
                                    .multilineTextAlignment(.center)
                                    .scaleEffect(activeLineID == line.id ? 1 : 0.94)
                                    .animation(.easeInOut(duration: 0.25), value: activeLineID)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .id(line.id)
                        }
                        Color.clear.frame(height: 100)
                    }
                }
            }
            .scrollDisabled(lines.isEmpty)
            .onChange(of: activeLineID) { id in
                guard let id, !isDragging else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay { scrubIndicator }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        guard hasTimedLyrics, duration > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            dragStartTime = currentTime
                        }
                        isDragSettled = false
                        dragUpdateToken += 1
                        let token = dragUpdateToken
                        let target = min(max(dragStartTime - Double(value.translation.height) * 0.12, 0), max(duration, 0))
                        draggedTime = target
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(140))
                            guard isDragging, token == dragUpdateToken else { return }
                            withAnimation(.easeOut(duration: 0.16)) { isDragSettled = true }
                        }
                    }
                    .onEnded { value in
                        guard isDragging else {
                            if value.translation.width > 45 && abs(value.translation.width) > abs(value.translation.height) {
                                onShowArtwork()
                            }
                            return
                        }
                        if let draggedTime { onSeek(draggedTime) }
                        self.draggedTime = nil
                        isDragging = false
                        isDragSettled = false
                        dragUpdateToken += 1
                    }
            )
        }
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var scrubIndicator: some View {
        if isDragging {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.purple.opacity(isDragSettled ? 0.72 : 0.22))
                    .frame(height: 1)
                HStack(spacing: 6) {
                    Text(displayTime.musicTime)
                        .font(.caption.bold().monospacedDigit())
                    Image(systemName: "play.fill").font(.caption)
                }
                .foregroundStyle(Color.purple.opacity(isDragSettled ? 1 : 0.48))
                .frame(width: 150)
                Rectangle()
                    .fill(Color.purple.opacity(isDragSettled ? 0.72 : 0.22))
                    .frame(height: 1)
            }
            .animation(.easeOut(duration: 0.12), value: isDragSettled)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private static func parse(_ source: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var parsed: [(TimeInterval, String)] = []

        for rawLine in source.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            let text = regex.stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !matches.isEmpty, !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine) else { continue }
                let minutes = Double(rawLine[minuteRange]) ?? 0
                let seconds = Double(rawLine[secondRange]) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append((minutes * 60 + seconds + fraction, text))
            }
        }

        if parsed.isEmpty {
            return source.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: .infinity, text: $0.element) }
        }
        return parsed.sorted { $0.0 < $1.0 }.enumerated().map {
            LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1)
        }
    }
}
