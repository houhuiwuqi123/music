import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    let onExpand: () -> Void

    var body: some View {
        if player.hasCurrentMedia {
            HStack(spacing: 12) {
                Button(action: onExpand) {
                    HStack(spacing: 12) {
                        if let track = player.currentTrack {
                            ArtworkView(track: track, size: 46, cornerRadius: 10)
                        } else {
                            Image(systemName: "play.rectangle.fill")
                                .font(.title2)
                                .foregroundStyle(.purple)
                                .frame(width: 46, height: 46)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.currentTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(player.currentArtist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let track = player.currentTrack {
                    Menu {
                        if dataStore.playlists.isEmpty {
                            Text(settings.text("noPlaylists"))
                        } else {
                            ForEach(dataStore.playlists) { playlist in
                                Button(playlist.name) { dataStore.add(track.id, to: playlist.id) }
                            }
                        }
                    } label: {
                        Image(systemName: "text.badge.plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.text("addPlaylist"))
                }

                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button(action: player.next) {
                    Image(systemName: "forward.fill")
                        .frame(width: 34, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12)) }
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .overlay(alignment: .bottomLeading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(player.currentTime / player.duration, 0), 1))
    }
}
