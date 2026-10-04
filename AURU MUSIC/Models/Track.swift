import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var albumName: String
    var duration: TimeInterval
    var fileURL: URL
    var artworkData: Data?
    var lyrics: String?
    var addedAt: Date?
    var titleWasEdited: Bool?
    var artistWasEdited: Bool?
    var artworkWasEdited: Bool?
    var lyricsWereEdited: Bool?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Unknown Artist",
        albumName: String = "Unknown Album",
        duration: TimeInterval,
        fileURL: URL,
        artworkData: Data? = nil,
        lyrics: String? = nil,
        addedAt: Date? = Date(),
        titleWasEdited: Bool? = nil,
        artistWasEdited: Bool? = nil,
        artworkWasEdited: Bool? = nil,
        lyricsWereEdited: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumName = albumName
        self.duration = duration
        self.fileURL = fileURL
        self.artworkData = artworkData
        self.lyrics = lyrics
        self.addedAt = addedAt
        self.titleWasEdited = titleWasEdited
        self.artistWasEdited = artistWasEdited
        self.artworkWasEdited = artworkWasEdited
        self.lyricsWereEdited = lyricsWereEdited
    }
}

extension TimeInterval {
    var musicTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let totalSeconds = Int(self.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
