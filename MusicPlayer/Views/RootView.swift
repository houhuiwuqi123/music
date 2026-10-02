import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case home, songs, artists, playlists }

    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .home
    @State private var searchText = ""
    @State private var showsImporter = false
    @State private var showsSettings = false
    @State private var showsNowPlaying = false
    @State private var selectedArtist: Artist?
    @State private var selectedPlaylist: Playlist?

    var body: some View {
        ZStack(alignment: .top) {
            DarkBackground()

            VStack(spacing: 10) {
                topBar
                searchBar

                TabView(selection: $selectedTab) {
                    HomeView().tag(Tab.home).tabItem { Label(settings.text("home"), systemImage: "house.fill") }
                    SongsView().tag(Tab.songs).tabItem { Label(settings.text("songs"), systemImage: "music.note.list") }
                    ArtistsView().tag(Tab.artists).tabItem { Label(settings.text("artists"), systemImage: "person.2.fill") }
                    PlaylistsView().tag(Tab.playlists).tabItem { Label(settings.text("playlists"), systemImage: "rectangle.stack.fill") }
                }
                .tint(.purple)
            }

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
                    .padding(.top, 116)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom, spacing: -1) {
            MiniPlayerView(player: player, onExpand: { showsNowPlaying = true })
        }
        .sheet(isPresented: $showsImporter) {
            DocumentPicker(contentTypes: LocalMusicLibrary.supportedTypes) { urls in
                Task {
                    let previousCount = library.tracks.count + library.videos.count
                    await library.importFiles(from: urls)
                    player.updateQueue(library.tracks)
                    let importedCount = library.tracks.count + library.videos.count - previousCount
                    settings.notifyImportCompleted(count: importedCount)
                }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistDetailView(artist: artist) }
        }
        .sheet(item: $selectedPlaylist) { playlist in
            NavigationStack { PlaylistDetailView(playlistID: playlist.id) }
        }
        .sheet(isPresented: $showsNowPlaying) {
            NowPlayingView(player: player)
                .presentationDragIndicator(.visible)
        }
        .alert(settings.text("importFailed"), isPresented: importErrorIsPresented) {
            Button(settings.text("ok")) { library.importError = nil }
        } message: {
            Text(library.importError ?? "Unknown error")
        }
        .task {
            await library.refreshDocuments()
            player.updateQueue(library.tracks)
            dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)))
            player.onTrackStarted = { id in dataStore.recordPlay(trackID: id) }
        }
        .onChange(of: library.tracks) {
            player.updateQueue($0)
            dataStore.reconcile(validTrackIDs: Set($0.map(\.id)))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await library.refreshDocuments() } }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: searchText)
    }

    private var topBar: some View {
        HStack {
            Button { showsSettings = true } label: {
                Image(systemName: "gearshape.fill").frame(width: 42, height: 42).background(.thinMaterial, in: Circle())
            }
            Spacer()
            VStack(spacing: 1) {
                Text("AURA").font(.caption.weight(.black)).tracking(4).foregroundStyle(.purple)
                Text(currentTitle).font(.headline)
            }
            Spacer()
            Button { showsImporter = true } label: {
                Image(systemName: "square.and.arrow.down.fill").frame(width: 42, height: 42).background(.thinMaterial, in: Circle())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 17)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(settings.text("search"), text: $searchText)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 44)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
    }

    private var searchResults: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracks = library.tracks.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) || $0.albumName.localizedCaseInsensitiveContains(query) }
        let artists = dataStore.artists(from: library.tracks, videos: library.videos).filter { $0.name.localizedCaseInsensitiveContains(query) }
        let playlists = dataStore.playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(tracks.prefix(8)) { track in
                    TrackRow(track: track) { player.play(track, in: library.tracks); searchText = "" }
                }
                ForEach(artists.prefix(5)) { artist in
                    Button { selectedArtist = artist; searchText = "" } label: {
                        Label(artist.name, systemImage: "person.crop.circle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                ForEach(playlists.prefix(5)) { playlist in
                    Button { selectedPlaylist = playlist; searchText = "" } label: {
                        Label(playlist.name, systemImage: "rectangle.stack").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                if tracks.isEmpty && artists.isEmpty && playlists.isEmpty {
                    Text(settings.text("noResults")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
        .frame(maxHeight: 430)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 16)
    }

    private var currentTitle: String {
        switch selectedTab {
        case .home: return settings.text("home")
        case .songs: return settings.text("songs")
        case .artists: return settings.text("artists")
        case .playlists: return settings.text("playlists")
        }
    }

    private var importErrorIsPresented: Binding<Bool> {
        Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })
    }
}
