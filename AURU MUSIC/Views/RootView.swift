import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var showsFeedSupport = false
    @State private var showsRecognition = false
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
                .toolbarBackground(Color(red: 0.025, green: 0.03, blue: 0.055), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .background(TabReselectDetector())
            }
            .padding(.top, 8)

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
                    .padding(.top, 116)
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
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                MiniPlayerView(player: player, onExpand: { showsNowPlaying = true })
                    .padding(.bottom, proxy.safeAreaInsets.bottom + 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .zIndex(100)
            }
            .allowsHitTesting(player.hasCurrentMedia)
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: LocalMusicLibrary.importableTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $showsFeedSupport) { FeedSupportView() }
        .fullScreenCover(isPresented: $showsRecognition) { SongRecognitionView() }
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
            player.updateVideoQueue(library.videos)
            dataStore.reconcile(
                validTrackIDs: Set(library.tracks.map(\.id)),
                validVideoIDs: Set(library.videos.map(\.id))
            )
            player.onTrackStarted = { id in dataStore.recordPlay(trackID: id) }
            player.onVideoStarted = { id in
                dataStore.recordPlay(trackID: id)
                showsNowPlaying = true
            }
        }
        .onChange(of: library.tracks) {
            player.updateQueue($0)
            dataStore.reconcile(
                validTrackIDs: Set($0.map(\.id)),
                validVideoIDs: Set(library.videos.map(\.id))
            )
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
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: searchText)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showsSettings = true } label: {
                Image(systemName: "gearshape.fill").frame(width: 42, height: 42).background(.thinMaterial, in: Circle())
            }
            Button { showsFeedSupport = true } label: {
                Text(settings.text("feedMe"))
                    .font(.subheadline.bold())
                    .foregroundStyle(.purple)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("AURU MUSIC")
                    .font(.caption.weight(.black)).tracking(2)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: true, vertical: false)
                Text(currentTitle).font(.headline)
            }
            Spacer()
            Button { showsRecognition = true } label: {
                Image(systemName: "shazam.logo").frame(width: 42, height: 42).background(.thinMaterial, in: Circle())
            }
            Button { showsImporter = true } label: {
                Image(systemName: "square.and.arrow.down.fill").frame(width: 42, height: 42).background(.thinMaterial, in: Circle())
            }
            .disabled(library.isImporting)
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
    static let auruTabReselected = Notification.Name("AURUMusicTabReselected")
}

private struct TabReselectDetector: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DetectorViewController {
        DetectorViewController()
    }

    func updateUIViewController(_ uiViewController: DetectorViewController, context: Context) {}

    final class DetectorViewController: UIViewController, UITabBarControllerDelegate {
        private weak var previousDelegate: UITabBarControllerDelegate?
        private var lastIndex: Int?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let controller = tabBarController, controller.delegate !== self else { return }
            previousDelegate = controller.delegate
            lastIndex = controller.selectedIndex
            controller.delegate = self
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            let index = tabBarController.selectedIndex
            if lastIndex == index {
                NotificationCenter.default.post(name: .auruTabReselected, object: index)
            }
            lastIndex = index
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }
    }
}
