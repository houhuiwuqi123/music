import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var player: MusicPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSeeking = false
    @State private var seekValue: TimeInterval = 0

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.indigo.opacity(0.22), Color(.systemBackground)],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()

                VStack(spacing: 26) {
                    Spacer(minLength: 8)

                    ArtworkView(track: player.currentTrack, size: 292, cornerRadius: 30)
                        .rotationEffect(.degrees(player.isPlaying ? 360 : 0))
                        .animation(
                            player.isPlaying
                                ? .linear(duration: 24).repeatForever(autoreverses: false)
                                : .default,
                            value: player.isPlaying
                        )

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

                    HStack(spacing: 42) {
                        Button(action: player.previous) {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .frame(width: 48, height: 48)
                        }

                        Button(action: player.togglePlayback) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .frame(width: 72, height: 72)
                                .background(.primary, in: Circle())
                                .foregroundStyle(Color(.systemBackground))
                        }

                        Button(action: player.next) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                                .frame(width: 48, height: 48)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.repeatMode = player.repeatMode == .list ? .one : .list
                    } label: {
                        Label(player.repeatMode.rawValue, systemImage: player.repeatMode.icon)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.thinMaterial, in: Capsule())
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
