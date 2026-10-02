import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: MusicPlayerViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isSeeking = false
    @State private var seekValue: TimeInterval = 0

    var body: some View {
        NavigationStack {
            ZStack {
                DarkBackground()

                VStack(spacing: 26) {
                    Spacer(minLength: 8)

                    TabView {
                        ArtworkView(track: player.currentTrack, size: 282, cornerRadius: 30)
                            .rotationEffect(.degrees(player.isPlaying ? 360 : 0))
                            .animation(
                                player.isPlaying
                                    ? .linear(duration: 24).repeatForever(autoreverses: false)
                                    : .default,
                                value: player.isPlaying
                            )
                        SyncedLyricsView(
                            lyrics: player.currentTrack?.lyrics,
                            currentTime: player.currentTime,
                            emptyText: settings.text("noLyrics")
                        )
                        .padding(.horizontal, 24)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .frame(height: 310)

                    VStack(spacing: 7) {
                        Text(player.currentTrack?.title ?? "Not Playing")
                            .font(.title2.bold())
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(player.currentTrack?.albumName ?? "")
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
            .navigationTitle("Now Playing")
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
    let emptyText: String

    private var lines: [LyricLine] { Self.parse(lyrics ?? "") }
    private var activeLineID: Int? {
        lines.last(where: { $0.time <= currentTime + 0.05 })?.id
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
                            Text(line.text)
                                .font(activeLineID == line.id ? .title3.bold() : .body)
                                .foregroundStyle(activeLineID == line.id ? Color.primary : Color.secondary)
                                .multilineTextAlignment(.center)
                                .scaleEffect(activeLineID == line.id ? 1 : 0.94)
                                .animation(.easeInOut(duration: 0.25), value: activeLineID)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 100)
                    }
                }
            }
            .onChange(of: activeLineID) { id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
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
