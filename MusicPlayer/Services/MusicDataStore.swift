import Combine
import Foundation

@MainActor
final class MusicDataStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var playStats: [UUID: TrackPlayStats] = [:]

    private let fileManager = FileManager.default
    private let playlistsFile = "playlists.json"
    private let statsFile = "play-stats.json"

    init() {
        playlists = load([Playlist].self, file: playlistsFile) ?? []
        playStats = load([UUID: TrackPlayStats].self, file: statsFile) ?? [:]
    }

    func createPlaylist(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        playlists.append(Playlist(name: cleaned))
        save(playlists, file: playlistsFile)
    }

    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { playlists.remove(at: index) }
        save(playlists, file: playlistsFile)
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        save(playlists, file: playlistsFile)
    }

    func add(_ trackID: UUID, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[index].trackIDs.contains(trackID) {
            playlists[index].trackIDs.append(trackID)
            playlists[index].updatedAt = Date()
            save(playlists, file: playlistsFile)
        }
    }

    func remove(_ trackID: UUID, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        playlists[index].updatedAt = Date()
        save(playlists, file: playlistsFile)
    }

    func updateArtwork(_ artworkData: Data, for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].artworkData = artworkData
        playlists[index].updatedAt = Date()
        save(playlists, file: playlistsFile)
    }

    func tracks(in playlist: Playlist, library: [Track]) -> [Track] {
        playlist.trackIDs.compactMap { id in library.first(where: { $0.id == id }) }
    }

    func artists(from tracks: [Track], videos: [LocalVideo] = []) -> [Artist] {
        let groupedTracks = Dictionary(grouping: tracks, by: { $0.artist })
        let groupedVideos = Dictionary(grouping: videos, by: { $0.artist })
        return Set(groupedTracks.keys).union(groupedVideos.keys)
            .map { name in
                Artist(
                    name: name,
                    tracks: (groupedTracks[name] ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                    videos: (groupedVideos[name] ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reconcile(validTrackIDs: Set<UUID>) {
        var changed = false
        for index in playlists.indices {
            let validIDs = playlists[index].trackIDs.filter(validTrackIDs.contains)
            if validIDs != playlists[index].trackIDs {
                playlists[index].trackIDs = validIDs
                playlists[index].updatedAt = Date()
                changed = true
            }
        }
        if changed { save(playlists, file: playlistsFile) }

        let staleStats = playStats.keys.filter { !validTrackIDs.contains($0) }
        if !staleStats.isEmpty {
            staleStats.forEach { playStats.removeValue(forKey: $0) }
            save(playStats, file: statsFile)
        }
    }

    func recordPlay(trackID: UUID) {
        var stats = playStats[trackID] ?? TrackPlayStats()
        stats.playCount += 1
        stats.lastPlayedAt = Date()
        playStats[trackID] = stats
        save(playStats, file: statsFile)
    }

    func recentTracks(from tracks: [Track], limit: Int = 10) -> [Track] {
        tracks
            .filter { playStats[$0.id]?.lastPlayedAt != nil }
            .sorted { (playStats[$0.id]?.lastPlayedAt ?? .distantPast) > (playStats[$1.id]?.lastPlayedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func topTracks(from tracks: [Track], limit: Int = 10) -> [Track] {
        tracks
            .filter { (playStats[$0.id]?.playCount ?? 0) > 0 }
            .sorted { (playStats[$0.id]?.playCount ?? 0) > (playStats[$1.id]?.playCount ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    func playCount(for trackID: UUID) -> Int {
        playStats[trackID]?.playCount ?? 0
    }

    private func documentsURL() throws -> URL {
        try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private func load<T: Decodable>(_ type: T.Type, file: String) -> T? {
        guard let url = try? documentsURL().appendingPathComponent(file),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, file: String) {
        guard let url = try? documentsURL().appendingPathComponent(file),
              let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
