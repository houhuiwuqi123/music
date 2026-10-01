import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @State private var showsImporter = false
    @State private var showsNowPlaying = false

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    emptyState
                } else {
                    trackList
                }
            }
            .navigationTitle("My Music")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showsImporter = true }) {
                        Label("Import Music", systemImage: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MiniPlayerView(player: player, onExpand: { showsNowPlaying = true })
            }
            .sheet(isPresented: $showsImporter) {
                DocumentPicker(contentTypes: LocalMusicLibrary.supportedTypes) { urls in
                    Task {
                        await library.importFiles(from: urls)
                        player.updateQueue(library.tracks)
                    }
                }
            }
            .sheet(isPresented: $showsNowPlaying) {
                NowPlayingView(player: player)
                    .presentationDragIndicator(.visible)
            }
            .alert("Import Failed", isPresented: importErrorIsPresented) {
                Button("OK") { library.importError = nil }
            } message: {
                Text(library.importError ?? "Unknown error")
            }
            .onChange(of: library.tracks) { tracks in
                player.updateQueue(tracks)
            }
        }
    }

    private var trackList: some View {
        List {
            Section {
                ForEach(library.tracks) { track in
                    Button {
                        player.play(track, in: library.tracks)
                    } label: {
                        HStack(spacing: 13) {
                            ArtworkView(track: track)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(track.artist) · \(track.albumName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 6)

                            VStack(alignment: .trailing, spacing: 6) {
                                if player.currentTrack?.id == track.id {
                                    Image(systemName: player.isPlaying ? "waveform" : "pause.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                                Text(track.duration.musicTime)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let removedCurrent = offsets.contains { library.tracks[$0].id == player.currentTrack?.id }
                    if removedCurrent { player.pause() }
                    library.removeTracks(at: offsets)
                }
            } header: {
                Text("\(library.tracks.count) Tracks")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Local Music")
                .font(.title2.bold())
            Text("Import MP3, M4A, or WAV files from Files to start listening.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Import Music") { showsImporter = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importErrorIsPresented: Binding<Bool> {
        Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )
    }
}
