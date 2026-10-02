import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, trackIDs: [UUID] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Artist: Identifiable, Hashable {
    let name: String
    let tracks: [Track]
    let videos: [LocalVideo]

    var id: String { name }
}

struct LocalVideo: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var duration: TimeInterval
    var fileURL: URL

    init(id: UUID = UUID(), title: String, artist: String, duration: TimeInterval, fileURL: URL) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileURL = fileURL
    }
}

struct TrackPlayStats: Codable, Hashable {
    var playCount = 0
    var lastPlayedAt: Date?
}
