import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var rankingTab: MediaLibraryTab = .songs
    @State private var scrollResetToken = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let recent = dataStore.recentTracks(from: library.tracks)
                    SectionHeader(title: settings.text("recent"))
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

                    SectionHeader(title: settings.text("top"))
                    Picker(settings.text("top"), selection: $rankingTab) {
                        Text(settings.text("songTab")).tag(MediaLibraryTab.songs)
                        Text(settings.text("videoTab")).tag(MediaLibraryTab.videos)
                    }
                    .pickerStyle(.segmented)
                    VStack(spacing: 3) {
                        if rankingTab == .songs {
                            let top = dataStore.topTracks(from: library.tracks)
                            ForEach(Array(top.enumerated()), id: \.element.id) { index, track in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                                        .lineLimit(1).frame(minWidth: 28, alignment: .trailing)
                                    TrackRow(track: track, trailingText: "\(dataStore.playCount(for: track.id)) \(settings.text("plays"))") {
                                        player.play(track, in: library.tracks)
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                            if top.isEmpty { Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity) }
                        } else {
                            let topVideos = dataStore.topVideos(from: library.videos)
                            ForEach(Array(topVideos.enumerated()), id: \.element.id) { index, video in
                                Button { player.play(video, in: library.videos) } label: {
                                    HStack(spacing: 12) {
                                        Text("\(index + 1)")
                                            .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                                            .lineLimit(1).frame(minWidth: 28, alignment: .trailing)
                                        Image(systemName: "play.rectangle.fill").foregroundStyle(.purple)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(video.title).font(.body.weight(.semibold)).lineLimit(1)
                                            Text(video.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Text("\(dataStore.playCount(for: video.id)) \(settings.text("plays"))")
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 10)
                            }
                            if topVideos.isEmpty { Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity) }
                        }
                    }
                    .padding(18)
                    .glassCard()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 120)
            }
            .scrollContentBackground(.hidden)
            .id(scrollResetToken)
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabReselected)) { notification in
            guard notification.object as? Int == 0 else { return }
            rankingTab = .songs
            scrollResetToken += 1
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

private enum MediaLibraryTab: String, CaseIterable, Identifiable {
    case songs, videos
    var id: String { rawValue }
}

private enum TrackSortOption: String, CaseIterable, Identifiable {
    case title, artist, newestAdded, recentlyPlayed, mostPlayed

    var id: String { rawValue }
    var textKey: String {
        switch self {
        case .title: return "sortTitle"
        case .artist: return "sortArtist"
        case .newestAdded: return "sortNewestAdded"
        case .recentlyPlayed: return "sortRecentlyPlayed"
        case .mostPlayed: return "sortMostPlayed"
        }
    }
    var icon: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "person"
        case .newestAdded: return "plus.circle"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .mostPlayed: return "chart.bar.fill"
        }
    }

    @MainActor
    func sorted(_ tracks: [Track], using dataStore: MusicDataStore) -> [Track] {
        tracks.sorted { lhs, rhs in
            switch self {
            case .title:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .artist:
                let comparison = lhs.artist.localizedCaseInsensitiveCompare(rhs.artist)
                return comparison == .orderedSame
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    : comparison == .orderedAscending
            case .newestAdded:
                return (lhs.addedAt ?? .distantPast) > (rhs.addedAt ?? .distantPast)
            case .recentlyPlayed:
                return (dataStore.playStats[lhs.id]?.lastPlayedAt ?? .distantPast)
                    > (dataStore.playStats[rhs.id]?.lastPlayedAt ?? .distantPast)
            case .mostPlayed:
                let lhsCount = dataStore.playCount(for: lhs.id)
                let rhsCount = dataStore.playCount(for: rhs.id)
                return lhsCount == rhsCount
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    : lhsCount > rhsCount
            }
        }
    }
}

private enum ArtistSortOption: String, CaseIterable, Identifiable {
    case name, newestAdded, recentlyPlayed

    var id: String { rawValue }
    var textKey: String {
        switch self {
        case .name: return "sortArtist"
        case .newestAdded: return "sortNewestAdded"
        case .recentlyPlayed: return "sortRecentlyPlayed"
        }
    }
    var icon: String {
        switch self {
        case .name: return "person"
        case .newestAdded: return "plus.circle"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        }
    }

    @MainActor
    func sorted(_ artists: [Artist], using dataStore: MusicDataStore) -> [Artist] {
        artists.sorted { lhs, rhs in
            switch self {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .newestAdded:
                let lhsDate = lhs.tracks.compactMap(\.addedAt).max() ?? .distantPast
                let rhsDate = rhs.tracks.compactMap(\.addedAt).max() ?? .distantPast
                return lhsDate == rhsDate
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhsDate > rhsDate
            case .recentlyPlayed:
                let lhsDate = (lhs.tracks.map(\.id) + lhs.videos.map(\.id))
                    .compactMap { dataStore.playStats[$0]?.lastPlayedAt }.max() ?? .distantPast
                let rhsDate = (rhs.tracks.map(\.id) + rhs.videos.map(\.id))
                    .compactMap { dataStore.playStats[$0]?.lastPlayedAt }.max() ?? .distantPast
                return lhsDate == rhsDate
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhsDate > rhsDate
            }
        }
    }
}

private struct ArtistSortMenu: View {
    @Binding var selection: ArtistSortOption
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            Picker(settings.text("sortBy"), selection: $selection) {
                ForEach(ArtistSortOption.allCases) { option in
                    Label(settings.text(option.textKey), systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Label(settings.text(selection.textKey), systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
        }
    }
}

private struct TrackSortMenu: View {
    @Binding var selection: TrackSortOption
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            Picker(settings.text("sortBy"), selection: $selection) {
                ForEach(TrackSortOption.allCases) { option in
                    Label(settings.text(option.textKey), systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Label(settings.text(selection.textKey), systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
        }
    }
}

struct SongsView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var navigationPath: [Track] = []
    @State private var renamingTrack: Track?
    @State private var deletingTrack: Track?
    @State private var editedName = ""
    @State private var mediaTab: MediaLibraryTab = .songs
    @State private var editingVideo: LocalVideo?
    @State private var deletingVideo: LocalVideo?
    @State private var editedVideoTitle = ""
    @State private var editedVideoArtist = ""
    @AppStorage("music-library-sort-option") private var trackSort: TrackSortOption = .title
    @State private var scrollResetToken = 0

    private var sortedTracks: [Track] { trackSort.sorted(library.tracks, using: dataStore) }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                Picker(settings.text("songs"), selection: $mediaTab) {
                    Text(settings.text("songTab")).tag(MediaLibraryTab.songs)
                    Text(settings.text("videoTab")).tag(MediaLibraryTab.videos)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .zIndex(1)

                if mediaTab == .songs, !library.tracks.isEmpty {
                    HStack {
                        Spacer()
                        TrackSortMenu(selection: $trackSort)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 5)
                }

                Group {
                    if mediaTab == .songs {
                        if library.tracks.isEmpty {
                            EmptyMusicView()
                        } else {
                            List {
                                ForEach(sortedTracks) { track in
                                    HStack(spacing: 10) {
                                        TrackRow(track: track, trailingText: track.duration.musicTime) {
                                            player.play(track, in: sortedTracks)
                                        }
                                        Menu {
                                            Button { navigationPath.append(track) } label: { Label(settings.text("details"), systemImage: "info.circle") }
                                            if !dataStore.playlists.isEmpty {
                                                Menu(settings.text("addPlaylist")) {
                                                    ForEach(dataStore.playlists) { playlist in
                                                        Button { dataStore.add(track.id, to: playlist.id) } label: {
                                                            if playlist.trackIDs.contains(track.id) {
                                                                Label(playlist.name, systemImage: "checkmark")
                                                            } else {
                                                                Text(playlist.name)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            Button { player.insertNext(track) } label: { Label(settings.text("playNext"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                                            Button { editedName = track.title; renamingTrack = track } label: { Label(settings.text("rename"), systemImage: "pencil") }
                                            Button(role: .destructive) { deletingTrack = track } label: { Label(settings.text("delete"), systemImage: "trash") }
                                        } label: {
                                            Image(systemName: "ellipsis").font(.title3.bold()).frame(width: 34, height: 40).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10).glassCard(cornerRadius: 18)
                                    .listRowInsets(EdgeInsets(top: 1.5, leading: 14, bottom: 1.5, trailing: 14))
                                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) { deletingTrack = track } label: { Label(settings.text("delete"), systemImage: "trash") }
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                Color.clear.frame(height: player.hasCurrentMedia ? 68 : 0)
                            }
                            .id("songs-\(scrollResetToken)")
                        }
                    } else if library.videos.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash").font(.system(size: 48)).foregroundStyle(.secondary)
                            Text(settings.text("noVideos")).font(.title3.bold())
                        }
                    } else {
                        List {
                            ForEach(library.videos) { video in
                                HStack(spacing: 12) {
                                    Button { player.play(video, in: library.videos) } label: {
                                        HStack(spacing: 13) {
                                            Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.purple).frame(width: 50)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(video.title).font(.body.weight(.semibold)).lineLimit(1)
                                                Text(video.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                            Text(video.duration.musicTime).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                        }
                                    }.buttonStyle(.plain)
                                    Menu {
                                        Button {
                                            editedVideoTitle = video.title
                                            editedVideoArtist = video.artist
                                            editingVideo = video
                                        } label: { Label(settings.text("editVideoInfo"), systemImage: "pencil") }
                                        Button(role: .destructive) { deletingVideo = video } label: { Label(settings.text("delete"), systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis").frame(width: 34, height: 40) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10).glassCard(cornerRadius: 18)
                                .listRowInsets(EdgeInsets(top: 1.5, leading: 14, bottom: 1.5, trailing: 14))
                                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { deletingVideo = video } label: { Label(settings.text("delete"), systemImage: "trash") }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: player.hasCurrentMedia ? 68 : 0)
                        }
                        .id("videos-\(scrollResetToken)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationDestination(for: Track.self) { TrackDetailView(trackID: $0.id) }
            .sheet(item: $renamingTrack) { track in
                RenameTrackSheet(name: $editedName) {
                    library.renameTrack(id: track.id, to: editedName)
                    renamingTrack = nil
                }
            }
            .sheet(item: $editingVideo) { video in
                EditTrackInfoSheet(title: $editedVideoTitle, artist: $editedVideoArtist, titleKey: "editVideoInfo", nameKey: "videoName") {
                    library.updateVideoInfo(id: video.id, title: editedVideoTitle, artist: editedVideoArtist)
                    editingVideo = nil
                }
            }
            .confirmationDialog(
                settings.text("deleteSongTitle"),
                isPresented: Binding(get: { deletingTrack != nil }, set: { if !$0 { deletingTrack = nil } }),
                titleVisibility: .visible
            ) {
                Button(settings.text("removeFromLibrary")) { deletePendingTrack(deleteFile: false) }
                Button(settings.text("deleteLocalFile"), role: .destructive) { deletePendingTrack(deleteFile: true) }
                Button(settings.text("cancel"), role: .cancel) { deletingTrack = nil }
            } message: {
                Text(settings.text("deleteLocalMessage"))
            }
            .confirmationDialog(
                settings.text("deleteVideoTitle"),
                isPresented: Binding(get: { deletingVideo != nil }, set: { if !$0 { deletingVideo = nil } }),
                titleVisibility: .visible
            ) {
                Button(settings.text("deleteLocalFile"), role: .destructive) {
                    if let video = deletingVideo { library.removeVideo(id: video.id) }
                    deletingVideo = nil
                }
                Button(settings.text("cancel"), role: .cancel) { deletingVideo = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabSelected)) { notification in
            guard notification.object as? Int == 1 else { return }
            navigationPath.removeAll()
            mediaTab = .songs
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabReselected)) { notification in
            guard notification.object as? Int == 1 else { return }
            navigationPath.removeAll()
            mediaTab = .songs
            scrollResetToken += 1
        }
    }

    private func deletePendingTrack(deleteFile: Bool) {
        guard let track = deletingTrack else { return }
        library.removeTrack(id: track.id, deleteFile: deleteFile)
        dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)), validVideoIDs: Set(library.videos.map(\.id)))
        deletingTrack = nil
    }
}

struct TrackDetailView: View {
    let trackID: UUID
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showsLyricsImporter = false
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var showsDeleteOptions = false
    @State private var showsInfoEditor = false
    @State private var editedTitle = ""
    @State private var editedArtist = ""

    private var track: Track? { library.tracks.first(where: { $0.id == trackID }) }

    var body: some View {
        ScrollView {
            if let track {
                VStack(spacing: 22) {
                    PhotosPicker(selection: $selectedCoverItem, matching: .images, photoLibrary: .shared()) {
                        ZStack(alignment: .bottom) {
                            ArtworkView(track: track, size: 238, cornerRadius: 38)
                            Label(settings.text("changeCover"), systemImage: "photo.badge.plus")
                                .font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 12)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 5) {
                        Text(track.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text(track.artist).foregroundStyle(.secondary)
                    }

                    Button {
                        editedTitle = track.title
                        editedArtist = track.artist
                        showsInfoEditor = true
                    } label: {
                        Label(settings.text("editSongInfo"), systemImage: "pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { player.play(track, in: library.tracks) } label: {
                        Label(settings.text("playAll"), systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)

                    Button { showsLyricsImporter = true } label: {
                        Label(settings.text("uploadLyrics"), systemImage: "text.quote").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent(settings.text("album"), value: track.albumName).padding(.vertical, 10)
                        LabeledContent(settings.text("duration"), value: track.duration.musicTime).padding(.vertical, 10)
                        LabeledContent(settings.text("file"), value: track.fileURL.lastPathComponent).padding(.vertical, 10)
                    }
                    .padding(18).glassCard()

                    if !dataStore.playlists.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            SectionHeader(title: settings.text("addPlaylist"))
                            ForEach(dataStore.playlists) { playlist in
                                Button {
                                    dataStore.add(track.id, to: playlist.id)
                                } label: {
                                    HStack {
                                        Text(playlist.name)
                                        Spacer()
                                        if playlist.trackIDs.contains(track.id) {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                                        } else {
                                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 10)
                                .disabled(playlist.trackIDs.contains(track.id))
                            }
                        }
                        .padding(18).glassCard()
                    }

                    Button(role: .destructive) {
                        showsDeleteOptions = true
                    } label: {
                        Label(settings.text("delete"), systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(18).padding(.bottom, 150)
            }
        }
        .navigationTitle(settings.text("details"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedCoverItem) { item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    try library.updateArtwork(from: data, for: trackID)
                } catch {
                    library.importError = error.localizedDescription
                }
                selectedCoverItem = nil
            }
        }
        .fileImporter(isPresented: $showsLyricsImporter, allowedContentTypes: [.plainText]) { result in
            guard case .success(let url) = result else { return }
            do {
                let data = try library.readSecurityScopedData(from: url)
                guard let lyrics = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                library.updateLyrics(lyrics, for: trackID)
            } catch {
                library.importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsInfoEditor) {
            EditTrackInfoSheet(title: $editedTitle, artist: $editedArtist) {
                library.updateTrackInfo(id: trackID, title: editedTitle, artist: editedArtist)
                showsInfoEditor = false
            }
        }
        .confirmationDialog(
            settings.text("deleteSongTitle"),
            isPresented: $showsDeleteOptions,
            titleVisibility: .visible
        ) {
            Button(settings.text("removeFromLibrary")) { removeTrack(deleteFile: false) }
            Button(settings.text("deleteLocalFile"), role: .destructive) { removeTrack(deleteFile: true) }
            Button(settings.text("cancel"), role: .cancel) {}
        } message: {
            Text(settings.text("deleteLocalMessage"))
        }
    }

    private func removeTrack(deleteFile: Bool) {
        library.removeTrack(id: trackID, deleteFile: deleteFile)
        dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)), validVideoIDs: Set(library.videos.map(\.id)))
        dismiss()
    }
}

struct ArtistsView: View {
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var navigationPath: [Artist] = []
    @AppStorage("artist-sort-option") private var artistSort: ArtistSortOption = .name
    @State private var scrollResetToken = 0

    var body: some View {
        NavigationStack(path: $navigationPath) {
            let artists = artistSort.sorted(dataStore.artists(from: library.tracks, videos: library.videos), using: dataStore)
            VStack(spacing: 0) {
                if !artists.isEmpty {
                    HStack {
                        Spacer()
                        ArtistSortMenu(selection: $artistSort)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 5)
                }
                if artists.isEmpty {
                    Color.clear
                } else {
                    List {
                            ForEach(artists) { artist in
                                Button { navigationPath.append(artist) } label: {
                                    HStack(spacing: 14) {
                                        ArtworkView(track: artist.tracks.first, size: 50, cornerRadius: 14)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(artist.name).font(.headline)
                                            HStack(spacing: 10) {
                                                Text("\(artist.tracks.count) \(settings.text("tracks"))")
                                                Text("\(artist.videos.count) \(settings.text("videos"))")
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .glassCard(cornerRadius: 18)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 1.5, leading: 14, bottom: 1.5, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: player.hasCurrentMedia ? 68 : 0)
                    }
                    .id(scrollResetToken)
                }
            }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabSelected)) { notification in
            guard notification.object as? Int == 2 else { return }
            navigationPath.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabReselected)) { notification in
            guard notification.object as? Int == 2 else { return }
            navigationPath.removeAll()
            scrollResetToken += 1
        }
    }
}

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var detailTrack: Track?
    @State private var renamingTrack: Track?
    @State private var deletingTrack: Track?
    @State private var editedName = ""

    private var currentArtistTracks: [Track] {
        let tracks = library.tracks.filter { $0.artist == artist.name }
        return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ArtworkView(track: artist.tracks.first, size: 170, cornerRadius: 85)
                Text(artist.name).font(.largeTitle.bold())
                queueButtons(tracks: currentArtistTracks)
                VStack(alignment: .leading, spacing: 3) {
                    SectionHeader(title: settings.text("songsSection"))
                    ForEach(currentArtistTracks) { track in
                        HStack(spacing: 10) {
                            TrackRow(track: track, trailingText: track.duration.musicTime) {
                                player.play(track, in: currentArtistTracks)
                            }
                            Menu {
                                Button { detailTrack = track } label: {
                                    Label(settings.text("details"), systemImage: "info.circle")
                                }
                                if !dataStore.playlists.isEmpty {
                                    Menu(settings.text("addPlaylist")) {
                                        ForEach(dataStore.playlists) { playlist in
                                            Button { dataStore.add(track.id, to: playlist.id) } label: {
                                                if playlist.trackIDs.contains(track.id) {
                                                    Label(playlist.name, systemImage: "checkmark")
                                                } else {
                                                    Text(playlist.name)
                                                }
                                            }
                                        }
                                    }
                                }
                                Button { player.insertNext(track) } label: {
                                    Label(settings.text("playNext"), systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button {
                                    editedName = track.title
                                    renamingTrack = track
                                } label: {
                                    Label(settings.text("rename"), systemImage: "pencil")
                                }
                                Button(role: .destructive) { deletingTrack = track } label: {
                                    Label(settings.text("delete"), systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.title3.bold())
                                    .foregroundStyle(Color.purple)
                                    .frame(width: 40, height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(width: 40, height: 44)
                            .layoutPriority(2)
                            .zIndex(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .glassCard()
                VStack(alignment: .leading, spacing: 3) {
                    SectionHeader(title: settings.text("musicVideos"))
                    if artist.videos.isEmpty {
                        Label(settings.text("noVideos"), systemImage: "video.slash").foregroundStyle(.secondary)
                    } else {
                        ForEach(artist.videos) { video in
                            Button { player.play(video, in: artist.videos) } label: {
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
                            .padding(.vertical, 10)
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            }
            .padding(18)
            .padding(.bottom, 110)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailTrack) { track in
            NavigationStack { TrackDetailView(trackID: track.id) }
        }
        .sheet(item: $renamingTrack) { track in
            RenameTrackSheet(name: $editedName) {
                library.renameTrack(id: track.id, to: editedName)
                renamingTrack = nil
            }
        }
        .confirmationDialog(
            settings.text("deleteSongTitle"),
            isPresented: Binding(get: { deletingTrack != nil }, set: { if !$0 { deletingTrack = nil } }),
            titleVisibility: .visible
        ) {
            Button(settings.text("removeFromLibrary")) { deletePendingTrack(deleteFile: false) }
            Button(settings.text("deleteLocalFile"), role: .destructive) { deletePendingTrack(deleteFile: true) }
            Button(settings.text("cancel"), role: .cancel) { deletingTrack = nil }
        } message: {
            Text(settings.text("deleteLocalMessage"))
        }
    }

    private func deletePendingTrack(deleteFile: Bool) {
        guard let track = deletingTrack else { return }
        library.removeTrack(id: track.id, deleteFile: deleteFile)
        dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)), validVideoIDs: Set(library.videos.map(\.id)))
        deletingTrack = nil
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
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @State private var showsCreate = false
    @State private var playlistName = ""
    @State private var deletingPlaylist: Playlist?
    @State private var navigationPath: [UUID] = []
    @State private var scrollResetToken = 0

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if dataStore.playlists.isEmpty {
                    Color.clear
                } else {
                    List {
                    ForEach(dataStore.playlists) { playlist in
                        Button { navigationPath.append(playlist.id) } label: {
                            let playlistTracks = dataStore.tracks(in: playlist, library: library.tracks)
                            HStack(spacing: 14) {
                                ArtworkView(track: playlistTracks.first, artworkData: playlist.artworkData, size: 50, cornerRadius: 14)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(playlistTracks.count) \(settings.text("tracks"))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassCard(cornerRadius: 18)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 1.5, leading: 14, bottom: 1.5, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deletingPlaylist = playlist } label: {
                                Label(settings.text("delete"), systemImage: "trash")
                            }
                        }
                    }
                }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: player.hasCurrentMedia ? 68 : 0)
                    }
                    .id(scrollResetToken)
                }
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
            .sheet(isPresented: $showsCreate) {
                CreatePlaylistSheet(name: $playlistName) {
                    dataStore.createPlaylist(named: playlistName)
                    playlistName = ""
                    showsCreate = false
                }
            }
            .confirmationDialog(
                settings.text("deletePlaylistTitle"),
                isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }),
                titleVisibility: .visible
            ) {
                Button(settings.text("playlistOnly")) { deletePendingPlaylist(songAction: .keep) }
                Button(settings.text("playlistAndLibrary"), role: .destructive) { deletePendingPlaylist(songAction: .removeFromLibrary) }
                Button(settings.text("playlistAndFiles"), role: .destructive) { deletePendingPlaylist(songAction: .deleteFiles) }
                Button(settings.text("cancel"), role: .cancel) { deletingPlaylist = nil }
            } message: {
                Text(settings.text("deletePlaylistMessage"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .auruTabReselected)) { notification in
            guard notification.object as? Int == 3 else { return }
            navigationPath.removeAll()
            scrollResetToken += 1
        }
    }

    private enum PlaylistSongAction: Equatable { case keep, removeFromLibrary, deleteFiles }

    private func deletePendingPlaylist(songAction: PlaylistSongAction) {
        guard let playlist = deletingPlaylist else { return }
        if songAction != .keep {
            for track in dataStore.tracks(in: playlist, library: library.tracks) {
                library.removeTrack(id: track.id, deleteFile: songAction == .deleteFiles)
            }
            dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)), validVideoIDs: Set(library.videos.map(\.id)))
        }
        dataStore.deletePlaylist(id: playlist.id)
        deletingPlaylist = nil
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var player: MusicPlayerViewModel
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var showsSongManager = false
    @State private var showsRename = false
    @State private var showsDeleteOptions = false
    @State private var editedPlaylistName = ""
    @State private var detailTrack: Track?
    @State private var renamingTrack: Track?
    @State private var editedTrackName = ""

    var playlist: Playlist? { dataStore.playlists.first(where: { $0.id == playlistID }) }
    var tracks: [Track] { playlist.map { dataStore.tracks(in: $0, library: library.tracks) } ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PhotosPicker(selection: $selectedCoverItem, matching: .images, photoLibrary: .shared()) {
                    ZStack(alignment: .bottom) {
                        ArtworkView(track: tracks.first, artworkData: playlist?.artworkData, size: 176, cornerRadius: 34)
                        Label(settings.text("changeCover"), systemImage: "photo.badge.plus")
                            .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 10)
                    }
                }
                .buttonStyle(.plain)
                Text(playlist?.name ?? "").font(.largeTitle.bold())
                Button { showsSongManager = true } label: {
                    Label(settings.text("manageSongs"), systemImage: "music.note.list").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
                VStack(spacing: 3) {
                    ForEach(tracks) { track in
                        HStack(spacing: 10) {
                            TrackRow(track: track, trailingText: track.duration.musicTime) {
                                player.play(track, in: tracks)
                            }
                            Menu {
                                Button { detailTrack = track } label: {
                                    Label(settings.text("details"), systemImage: "info.circle")
                                }
                                if !dataStore.playlists.isEmpty {
                                    Menu(settings.text("addPlaylist")) {
                                        ForEach(dataStore.playlists) { destination in
                                            Button { dataStore.add(track.id, to: destination.id) } label: {
                                                if destination.trackIDs.contains(track.id) {
                                                    Label(destination.name, systemImage: "checkmark")
                                                } else {
                                                    Text(destination.name)
                                                }
                                            }
                                        }
                                    }
                                }
                                Button { player.insertNext(track) } label: {
                                    Label(settings.text("playNext"), systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button {
                                    editedTrackName = track.title
                                    renamingTrack = track
                                } label: {
                                    Label(settings.text("rename"), systemImage: "pencil")
                                }
                                Button(role: .destructive) { dataStore.remove(track.id, from: playlistID) } label: {
                                    Label(settings.text("removePlaylist"), systemImage: "minus.circle")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.title3.bold())
                                    .foregroundStyle(Color.purple)
                                    .frame(width: 40, height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(width: 40, height: 44)
                            .layoutPriority(2)
                            .zIndex(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                }
                .padding(18).frame(maxWidth: .infinity).glassCard()
            }
            .padding(18).padding(.bottom, 110)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedCoverItem) { item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    dataStore.updateArtwork(try library.normalizedArtworkData(from: data), for: playlistID)
                } catch {
                    library.importError = error.localizedDescription
                }
                selectedCoverItem = nil
            }
        }
        .sheet(isPresented: $showsSongManager) {
            ManagePlaylistSongsView(playlistID: playlistID)
        }
        .sheet(item: $detailTrack) { track in
            NavigationStack { TrackDetailView(trackID: track.id) }
        }
        .sheet(item: $renamingTrack) { track in
            RenameTrackSheet(name: $editedTrackName) {
                library.renameTrack(id: track.id, to: editedTrackName)
                renamingTrack = nil
            }
        }
        .sheet(isPresented: $showsRename) {
            RenamePlaylistSheet(name: $editedPlaylistName) {
                dataStore.renamePlaylist(id: playlistID, to: editedPlaylistName)
                showsRename = false
            }
        }
        .confirmationDialog(
            settings.text("deletePlaylistTitle"),
            isPresented: $showsDeleteOptions,
            titleVisibility: .visible
        ) {
            Button(settings.text("playlistOnly")) { deletePlaylist(songAction: .keep) }
            Button(settings.text("playlistAndLibrary"), role: .destructive) { deletePlaylist(songAction: .removeFromLibrary) }
            Button(settings.text("playlistAndFiles"), role: .destructive) { deletePlaylist(songAction: .deleteFiles) }
            Button(settings.text("cancel"), role: .cancel) {}
        } message: {
            Text(settings.text("deletePlaylistMessage"))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showsSongManager = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editedPlaylistName = playlist?.name ?? ""
                        showsRename = true
                    } label: { Label(settings.text("renamePlaylist"), systemImage: "pencil") }
                    Button(role: .destructive) { showsDeleteOptions = true } label: {
                        Label(settings.text("deletePlaylist"), systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private enum DetailPlaylistSongAction: Equatable { case keep, removeFromLibrary, deleteFiles }

    private func deletePlaylist(songAction: DetailPlaylistSongAction) {
        if songAction != .keep {
            for track in tracks {
                library.removeTrack(id: track.id, deleteFile: songAction == .deleteFiles)
            }
            dataStore.reconcile(validTrackIDs: Set(library.tracks.map(\.id)), validVideoIDs: Set(library.videos.map(\.id)))
        }
        dataStore.deletePlaylist(id: playlistID)
        dismiss()
    }
}

private struct CreatePlaylistSheet: View {
    @Binding var name: String
    let onCreate: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(settings.text("newPlaylist")).font(.title2.bold()).foregroundStyle(.black)
            TextField(text: $name) {
                Text(settings.text("playlistName"))
                    .foregroundStyle(Color.black.opacity(0.45))
            }
                .textInputAutocapitalization(.words)
                .foregroundStyle(.black)
                .tint(.purple)
                .padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)) }
            HStack {
                Button(settings.text("cancel")) { name = ""; dismiss() }
                    .foregroundStyle(.secondary)
                Spacer()
                Button(settings.text("create"), action: onCreate)
                    .buttonStyle(.borderedProminent).tint(.purple).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(Color(white: 0.94).ignoresSafeArea())
        .presentationDetents([.height(230)])
    }
}

private struct RenameTrackSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(settings.text("rename")).font(.title2.bold()).foregroundStyle(.black)
            TextField(settings.text("songName"), text: $name)
                .foregroundStyle(.black).tint(.purple).padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)) }
            HStack {
                Button(settings.text("cancel")) { dismiss() }.foregroundStyle(.secondary)
                Spacer()
                Button(settings.text("save"), action: onSave)
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(Color(white: 0.94).ignoresSafeArea())
        .presentationDetents([.height(230)])
    }
}

private struct EditTrackInfoSheet: View {
    @Binding var title: String
    @Binding var artist: String
    var titleKey = "editSongInfo"
    var nameKey = "songName"
    let onSave: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(settings.text(titleKey)).font(.title2.bold()).foregroundStyle(.black)
            TextField(settings.text(nameKey), text: $title)
                .textInputAutocapitalization(.words)
                .foregroundStyle(.black).tint(.purple).padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)) }
            TextField(settings.text("artistName"), text: $artist)
                .textInputAutocapitalization(.words)
                .foregroundStyle(.black).tint(.purple).padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)) }
            HStack {
                Button(settings.text("cancel")) { dismiss() }.foregroundStyle(.secondary)
                Spacer()
                Button(settings.text("save"), action: onSave)
                    .buttonStyle(.borderedProminent).tint(.purple).disabled(!canSave)
            }
        }
        .padding(24)
        .background(Color(white: 0.94).ignoresSafeArea())
        .presentationDetents([.height(310)])
    }
}

private struct RenamePlaylistSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(settings.text("renamePlaylist")).font(.title2.bold()).foregroundStyle(.black)
            TextField(settings.text("playlistName"), text: $name)
                .foregroundStyle(.black).tint(.purple).padding(14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.15)) }
            HStack {
                Button(settings.text("cancel")) { dismiss() }.foregroundStyle(.secondary)
                Spacer()
                Button(settings.text("save"), action: onSave)
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .background(Color(white: 0.94).ignoresSafeArea())
        .presentationDetents([.height(230)])
    }
}

private struct ManagePlaylistSongsView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: LocalMusicLibrary
    @EnvironmentObject private var dataStore: MusicDataStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var playlist: Playlist? { dataStore.playlists.first(where: { $0.id == playlistID }) }

    var body: some View {
        NavigationStack {
            List(library.tracks) { track in
                let isAdded = playlist?.trackIDs.contains(track.id) == true
                Button {
                    if isAdded { dataStore.remove(track.id, from: playlistID) }
                    else { dataStore.add(track.id, to: playlistID) }
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(track: track, size: 44, cornerRadius: 10)
                        VStack(alignment: .leading) {
                            Text(track.title).foregroundStyle(.primary)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(isAdded ? Color.purple : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 18)
                .listRowInsets(EdgeInsets(top: 1.5, leading: 14, bottom: 1.5, trailing: 14))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(settings.text("manageSongs"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(settings.text("done")) { dismiss() } }
            }
        }
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
