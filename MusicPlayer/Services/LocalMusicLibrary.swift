import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LocalMusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published var importError: String?

    static let supportedTypes: [UTType] = [
        UTType.mp3,
        UTType.mpeg4Audio,
        UTType.wav
    ]

    private let fileManager = FileManager.default
    private let indexFileName = "music-library.json"
    private let audioFolderName = "Imported Music"

    init() {
        loadLibrary()
    }

    func importFiles(from urls: [URL]) async {
        importError = nil

        do {
            let folder = try audioFolderURL()
            var imported: [Track] = []

            for sourceURL in urls where Self.isSupported(sourceURL) {
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
                }

                let destination = uniqueDestination(for: sourceURL, in: folder)
                try fileManager.copyItem(at: sourceURL, to: destination)
                imported.append(try await makeTrack(from: destination))
            }

            tracks.append(contentsOf: imported)
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            saveLibrary()
        } catch {
            importError = error.localizedDescription
        }
    }

    func removeTracks(at offsets: IndexSet) {
        for index in offsets {
            try? fileManager.removeItem(at: tracks[index].fileURL)
        }
        for index in offsets.sorted(by: >) {
            tracks.remove(at: index)
        }
        saveLibrary()
    }

    private func makeTrack(from url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.commonMetadata)

        let title = await metadata.text(for: .commonIdentifierTitle)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await metadata.text(for: .commonIdentifierArtist) ?? "Unknown Artist"
        let album = await metadata.text(for: .commonIdentifierAlbumName) ?? "Unknown Album"

        return Track(
            title: title,
            artist: artist,
            albumName: album,
            duration: duration.isFinite ? duration : 0,
            fileURL: url
        )
    }

    private func loadLibrary() {
        do {
            let data = try Data(contentsOf: try indexURL())
            let decoded = try JSONDecoder().decode([Track].self, from: data)
            tracks = decoded.filter { fileManager.fileExists(atPath: $0.fileURL.path) }
        } catch {
            tracks = []
        }
    }

    private func saveLibrary() {
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: indexURL(), options: .atomic)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func documentsURL() throws -> URL {
        try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func audioFolderURL() throws -> URL {
        let folder = try documentsURL().appendingPathComponent(audioFolderName, isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    private func indexURL() throws -> URL {
        try documentsURL().appendingPathComponent(indexFileName)
    }

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let ext = source.pathExtension.lowercased()
        return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private static func isSupported(_ url: URL) -> Bool {
        ["mp3", "m4a", "wav"].contains(url.pathExtension.lowercased())
    }
}

private extension Array where Element == AVMetadataItem {
    func text(for identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier).first else {
            return nil
        }
        return try? await item.load(.stringValue)
    }
}
