import AVKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let recent = dataStore.recentTracks(from: library.tracks)
                    SectionHeader(title: settings.text("recent"), subtitle: "\(recent.count)")
                    if recent.isEmpty {
                        emptyCard(text: settings.text("importHint"))
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 15) {
                                ForEach(recent) { track in
                                    Button { player.play(track, in: library.tracks) } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            ArtworkView(track: track, size: 142, cornerRadius: 24)
                                            Text(track.title).font(.subheadline.bold()).lineLimit(1)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 142, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    let top = dataStore.topTracks(from: library.tracks)
                    SectionHeader(title: settings.text("top"), subtitle: "\(top.count)")
                    VStack(spacing: 16) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                                TrackRow(track: track, trailingText: "\(dataStore.playCount(for: track.id)) \(settings.text("plays"))") {
                                    player.play(track, in: library.tracks)
                                }
                            }
                        }
                        if top.isEmpty { Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity) }
                    }
                    .padding(18)
                    .glassCard()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 120)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func emptyCard(text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
    }
}

struct SongsView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.tracks) { track in
                        TrackRow(track: track, trailingText: track.duration.musicTime) {
                            player.play(track, in: library.tracks)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .contextMenu {
                            if !dataStore.playlists.isEmpty {
                                Menu(settings.text("addPlaylist")) {
                                    ForEach(dataStore.playlists) { playlist in
                                        Button(playlist.name) { dataStore.add(track.id, to: playlist.id) }
                                    }
                                }
                            }
                            Button(settings.text("delete"), role: .destructive) {
                                library.removeTrack(id: track.id)
                                dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)))
                            }
                        }
                        Divider().opacity(0.12).padding(.leading, 80)
                    }
                }
                .padding(.vertical, 8)
                .glassCard()
                .padding(.horizontal, 14)
                .padding(.bottom, 120)
            }
            .overlay {
                if library.tracks.isEmpty { EmptyMusicView() }
            }
        }
    }
}

struct ArtistsView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(dataStore.artists(from: library.tracks, videos: library.videos)) { artist in
                        NavigationLink(value: artist) {
                            HStack(spacing: 14) {
                                ArtworkView(track: artist.tracks.first, size: 62, cornerRadius: 31)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(artist.name).font(.headline)
                                    Text("\(artist.tracks.count) \(settings.text("tracks")) · \(artist.videos.count) \(settings.text("videos"))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 120)
            }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        }
    }
}

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedVideo: LocalVideo?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ArtworkView(track: artist.tracks.first, size: 170, cornerRadius: 85)
                Text(artist.name).font(.largeTitle.bold())
                queueButtons(tracks: artist.tracks)
                VStack(alignment: .leading, spacing: 15) {
                    SectionHeader(title: settings.text("songsSection"))
                    ForEach(artist.tracks) { track in
                        TrackRow(track: track, trailingText: track.duration.musicTime) { player.play(track, in: artist.tracks) }
                            .contextMenu {
                                if !dataStore.playlists.isEmpty {
                                    Menu(settings.text("addPlaylist")) {
                                        ForEach(dataStore.playlists) { playlist in
                                            Button(playlist.name) { dataStore.add(track.id, to: playlist.id) }
                                        }
                                    }
                                }
                            }
                    }
                }
                .padding(18)
                .glassCard()
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: settings.text("musicVideos"), subtitle: "\(artist.videos.count)")
                    if artist.videos.isEmpty {
                        Label(settings.text("noVideos"), systemImage: "video.slash").foregroundStyle(.secondary)
                    } else {
                        ForEach(artist.videos) { video in
                            Button { player.pause(); selectedVideo = video } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.purple)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(video.title).font(.headline).foregroundStyle(.primary)
                                        Text(video.duration.musicTime).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            }
            .padding(18)
            .padding(.bottom, 110)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedVideo) { LocalVideoPlayerSheet(video: $0) }
    }

    private func queueButtons(tracks: [Track]) -> some View {
        HStack(spacing: 12) {
            Button { player.playAll(tracks) } label: {
                Label(settings.text("playAll"), systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { player.playAll(tracks, shuffled: true) } label: {
                Label(settings.text("shufflePlay"), systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showsCreate = false
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(dataStore.playlists) { playlist in
                        NavigationLink(value: playlist.id) {
                            HStack(spacing: 14) {
                                ArtworkView(track: dataStore.tracks(in: playlist, library: library.tracks).first, size: 66, cornerRadius: 18)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlist.trackIDs.count) \(settings.text("tracks"))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(14).glassCard(cornerRadius: 20)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(settings.text("deletePlaylist"), role: .destructive) { dataStore.deletePlaylist(id: playlist.id) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 120)
            }
            .overlay(alignment: .bottomTrailing) {
                Button { showsCreate = true } label: {
                    Image(systemName: "plus").font(.title2.bold()).frame(width: 58, height: 58).background(.purple, in: Circle()).shadow(radius: 15)
                }
                .buttonStyle(.plain).padding(.trailing, 22).padding(.bottom, 120)
            }
            .navigationDestination(for: UUID.self) { id in
                PlaylistDetailView(playlistID: id)
            }
            .alert(settings.text("newPlaylist"), isPresented: $showsCreate) {
                TextField(settings.text("playlistName"), text: $playlistName)
                Button(settings.text("cancel"), role: .cancel) { playlistName = "" }
                Button(settings.text("create")) { dataStore.createPlaylist(named: playlistName); playlistName = "" }
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var playlist: Playlist? { dataStore.playlists.first(where: { $0.id == playlistID }) }
    var tracks: [Track] { playlist.map { dataStore.tracks(in: $0, library: library.tracks) } ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ArtworkView(track: tracks.first, size: 176, cornerRadius: 34)
                Text(playlist?.name ?? "").font(.largeTitle.bold())
                HStack(spacing: 12) {
                    Button { player.playAll(tracks) } label: {
                        Label(settings.text("playAll"), systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    Button { player.playAll(tracks, shuffled: true) } label: {
                        Label(settings.text("shufflePlay"), systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(tracks.isEmpty)
                VStack(spacing: 15) {
                    ForEach(tracks) { track in
                        TrackRow(track: track, trailingText: track.duration.musicTime) { player.play(track, in: tracks) }
                            .contextMenu { Button(settings.text("removePlaylist"), role: .destructive) { dataStore.remove(track.id, from: playlistID) } }
                    }
                }
                .padding(18).glassCard()
            }
            .padding(18).padding(.bottom, 110)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    dataStore.deletePlaylist(id: playlistID)
                    dismiss()
                } label: { Image(systemName: "trash") }
            }
        }
    }
}

struct LocalVideoPlayerSheet: View {
    let video: LocalVideo
    @State private var player: AVPlayer

    init(video: LocalVideo) {
        self.video = video
        _player = State(initialValue: AVPlayer(url: video.fileURL))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

struct EmptyMusicView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(settings.text("noMusic")).font(.title3.bold())
            Text(settings.text("importHint")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 34)
        }
    }
}
