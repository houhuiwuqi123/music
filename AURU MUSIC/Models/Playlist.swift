import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    var artworkData: Data?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, trackIDs: [UUID] = [], artworkData: Data? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.artworkData = artworkData
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
    var titleWasEdited: Bool?
    var artistWasEdited: Bool?

    init(id: UUID = UUID(), title: String, artist: String, duration: TimeInterval, fileURL: URL, titleWasEdited: Bool? = nil, artistWasEdited: Bool? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.fileURL = fileURL
        self.titleWasEdited = titleWasEdited
        self.artistWasEdited = artistWasEdited
    }
}

struct TrackPlayStats: Codable, Hashable {
    var playCount = 0
    var lastPlayedAt: Date?
}
