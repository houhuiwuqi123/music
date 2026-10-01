import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var albumName: String
    var duration: TimeInterval
    var fileURL: URL

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Unknown Artist",
        albumName: String = "Unknown Album",
        duration: TimeInterval,
        fileURL: URL
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumName = albumName
        self.duration = duration
        self.fileURL = fileURL
    }
}

extension TimeInterval {
    var musicTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let totalSeconds = Int(self.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
