import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers

struct RootView: View {
    /// Tab bar order: Home / Plaza / Library / Settings. `index` is the tab bar position,
    /// which is what the tab (re)select notifications carry.
    enum Tab: Hashable {
        case home, plaza, library, settings

        var index: Int {
            switch self {
            case .home: return 0
            case .plaza: return 1
            case .library: return 2
            case .settings: return 3
            }
        }

        /// Songs, Artists and Playlists used to be tabs and still listen for their old tab
        /// numbers; inside Library nothing posts these, and LibraryView handles reselect.
        static let legacySongs = -1, legacyArtists = -2, legacyPlaylists = -4

        /// Settings draws its own large navigation title.
        var showsTopBar: Bool { self != .settings }
        /// Plaza has its own user search, so it gets no search button.
        var hasSearch: Bool { self == .home || self == .library }
        var hasImport: Bool { self != .settings }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .plaza: return "sparkles"
            case .library:
                if #available(iOS 17.0, *) { return "music.note.square.stack.fill" }
                return "square.stack.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var plaza: CandyPlazaService
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .home
    @State private var searchText = ""
    /// The search bar stays hidden until the search button is tapped.
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool
    @State private var librarySection: LibraryView.Entry?
    @State private var showsImporter = false
    @State private var showsNowPlaying = false
    @State private var selectedArtist: Artist?
    @State private var selectedPlaylist: Playlist?

    var body: some View {
        ZStack(alignment: .top) {
            DarkBackground()

            VStack(spacing: 10) {
                if selectedTab.showsTopBar {
                    topBar
                    if showsSearch && selectedTab.hasSearch {
                        searchBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                // The system tab bar is hidden; `tabBar` below replaces it.
                TabView(selection: $selectedTab) {
                    HomeView().tag(Tab.home).toolbar(.hidden, for: .tabBar)
                    CandyPlazaView().tag(Tab.plaza).toolbar(.hidden, for: .tabBar)
                    LibraryView(section: $librarySection, tabIndex: Tab.library.index)
                        .tag(Tab.library)
                        .toolbar(.hidden, for: .tabBar)
                    SettingsView(showsDone: false).tag(Tab.settings).toolbar(.hidden, for: .tabBar)
                }
                .tint(.purple)
                // The tab bar floats over the page with a clear background.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 6) {
                        if player.hasCurrentMedia {
                            MiniPlayerView(player: player, onExpand: { showsNowPlaying = true })
                        }
                        tabBar
                    }
                    .zIndex(100)
                }
            }
            .padding(.top, 8)

            if showsSearch && selectedTab.hasSearch && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
                    .padding(.top, 124)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
            }

            if library.isImporting {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.purple)
                    Text(settings.text("importing")).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .glassCard(cornerRadius: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.35))
                .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: LocalMusicLibrary.importableTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
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
            plaza.start()
            await library.refreshDocuments()
            player.updateQueue(library.tracks)
            player.updateVideoQueue(library.videos)
            dataStore.reconcile(
                validTrackIDs: Set(library.tracks.map(\.id)),
                validVideoIDs: Set(library.videos.map(\.id))
            )
            player.onTrackStarted = { id in dataStore.recordPlaybackStarted(trackID: id) }
            player.onVideoStarted = { id in
                dataStore.recordPlaybackStarted(trackID: id)
                showsNowPlaying = true
            }
            player.onTrackCompleted = { id in dataStore.recordPlay(trackID: id) }
            player.onVideoCompleted = { id in dataStore.recordPlay(trackID: id) }
        }
        .onChange(of: library.tracks) {
            player.updateQueue($0)
            dataStore.reconcile(
                validTrackIDs: Set($0.map(\.id)),
                validVideoIDs: Set(library.videos.map(\.id))
            )
        }
        .onReceive(Publishers.CombineLatest(player.$currentTrack, player.$isPlaying)) { state in
            plaza.updateListening(track: state.0, isPlaying: state.1)
        }
        .onChange(of: library.videos) { videos in
            player.updateVideoQueue(videos)
            dataStore.reconcile(
                validTrackIDs: Set(library.tracks.map(\.id)),
                validVideoIDs: Set(videos.map(\.id))
            )
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await library.refreshDocuments() } }
        }
        .onChange(of: selectedTab) { tab in
            searchText = ""
            showsSearch = false
            NotificationCenter.default.post(name: .auruTabSelected, object: tab.index)
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabReselected)) { _ in
            searchText = ""
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: searchText)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: showsSearch)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if selectedTab == .library, let section = librarySection {
                Button { librarySection = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel(settings.text("library"))
                Text(settings.text(section.titleKey))
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text(currentTitle)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            if selectedTab.hasSearch {
                Button(action: toggleSearch) {
                    Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel(settings.text("search"))
            }
            if selectedTab.hasImport {
                Button { showsImporter = true } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 42, height: 42).background(.thinMaterial, in: Circle())
                }
                .disabled(library.isImporting)
                .accessibilityLabel(settings.text("import"))
            }
        }
        .buttonStyle(.plain)
        .frame(height: 46)
        .padding(.leading, 20)
        .padding(.trailing, 17)
    }

    private func toggleSearch() {
        showsSearch.toggle()
        if showsSearch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
        } else {
            searchText = ""
            searchFocused = false
        }
    }

    /// Home / Plaza / Library in one bordered capsule, Setting as its own circle on the right.
    /// No fill, so the page shows through; 8pt between the buttons and the border all round.
    private var tabBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach([Tab.home, .plaza, .library], id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(8)
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))

            Button { select(.settings) } label: {
                Image(systemName: Tab.settings.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selectedTab == .settings ? Color.purple : .white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.white.opacity(selectedTab == .settings ? 0.12 : 0)))
                    .padding(8)
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.text("settings"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let selected = selectedTab == tab
        return Button { select(tab) } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 24)
                Text(title(of: tab))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.purple : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule().fill(.white.opacity(selected ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Tapping the current tab again posts a reselect, which sends the page back to its top.
    private func select(_ tab: Tab) {
        if selectedTab == tab {
            NotificationCenter.default.post(name: .auruTabReselected, object: tab.index)
        } else {
            selectedTab = tab
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(settings.text("search"), text: $searchText)
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
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
        let videos = library.videos.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tracks.prefix(8)) { track in
                    TrackRow(track: track) { player.play(track, in: library.tracks); searchText = "" }
                        .padding(.vertical, 10)
                }
                ForEach(artists.prefix(5)) { artist in
                    Button { selectedArtist = artist; searchText = "" } label: {
                        Label(artist.name, systemImage: "person.crop.circle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.vertical, 10)
                }
                ForEach(playlists.prefix(5)) { playlist in
                    Button { selectedPlaylist = playlist; searchText = "" } label: {
                        Label(playlist.name, systemImage: "rectangle.stack").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(.vertical, 10)
                }
                ForEach(videos.prefix(5)) { video in
                    Button { player.play(video, in: library.videos); searchText = "" } label: {
                        HStack {
                            Label(video.title, systemImage: "play.rectangle.fill")
                            Spacer()
                            Text(settings.text("video")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).padding(.vertical, 10)
                }
                if tracks.isEmpty && artists.isEmpty && playlists.isEmpty && videos.isEmpty {
                    Text(settings.text("noResults")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
        .frame(maxHeight: 430)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 16)
    }

    private var currentTitle: String { title(of: selectedTab) }

    private func title(of tab: Tab) -> String {
        switch tab {
        case .home: return settings.text("home")
        case .plaza: return settings.text("plaza")
        case .library: return settings.text("library")
        case .settings: return settings.text("settings")
        }
    }

    private var importErrorIsPresented: Binding<Bool> {
        Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                let previousCount = library.tracks.count + library.videos.count
                await library.importFiles(from: urls)
                player.updateQueue(library.tracks)
                let importedCount = library.tracks.count + library.videos.count - previousCount
                settings.notifyImportCompleted(count: importedCount)
            }
        case .failure(let error):
            library.importError = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let auruTabSelected = Notification.Name("AURUMusicTabSelected")
    static let auruTabReselected = Notification.Name("AURUMusicTabReselected")
}
