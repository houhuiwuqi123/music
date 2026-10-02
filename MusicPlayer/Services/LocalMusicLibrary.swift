import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LocalMusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var videos: [LocalVideo] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    // `.item` keeps provider-specific audio/video types selectable. Files are
    // validated after selection before being copied into the app sandbox.
    static let importableTypes: [UTType] = [.item]

    static let supportedAudioExtensions: Set<String> = [
        "aac", "ac3", "aif", "aifc", "aiff", "amr", "au", "caf", "eac3", "flac",
        "m4a", "m4b", "m4p", "mp1", "mp2", "mp3", "mpa", "ogg", "oga", "opus",
        "snd", "wav", "wave", "wma"
    ]
    static let supportedVideoExtensions: Set<String> = [
        "3g2", "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ts", "webm"
    ]

    private let fileManager = FileManager.default
    private let indexFileName = "music-library.json"
    private let videoIndexFileName = "video-library.json"
    private let hiddenTracksFileName = "hidden-tracks.json"
    private let audioFolderName = "Imported Music"
    private var hiddenTrackPaths: Set<String> = []

    init() {
        loadHiddenTrackPaths()
        loadLibrary()
        deduplicateTracks()
    }

    func refreshDocuments() async {
        importError = nil
        do {
            let documents = try documentsURL()
            _ = try audioFolderURL()
            let discovered = fileManager.enumerator(
                at: documents,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )?
            .compactMap { $0 as? URL }
            .filter { Self.isSupported($0) && !hiddenTrackPaths.contains($0.standardizedFileURL.path) } ?? []

            let uniqueURLs = Dictionary(grouping: discovered, by: { $0.standardizedFileURL.path })
                .compactMap { $0.value.first }
            let knownPaths = Set((tracks.map(\.fileURL) + videos.map(\.fileURL)).map { $0.standardizedFileURL.path })
            let newURLs = uniqueURLs.filter { !knownPaths.contains($0.standardizedFileURL.path) }
            var failures: [String] = []

            for url in newURLs {
                do {
                    if Self.isVideo(url) {
                        videos.append(try await makeVideo(from: url))
                    } else {
                        let track = try await makeTrack(from: url)
                        if !containsDuplicate(of: track, in: tracks) { tracks.append(track) }
                    }
                } catch {
                    failures.append(url.lastPathComponent)
                }
            }
            tracks.removeAll { !fileManager.fileExists(atPath: $0.fileURL.path) }
            videos.removeAll { !fileManager.fileExists(atPath: $0.fileURL.path) }
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            videos.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            saveLibrary()
            if !failures.isEmpty { importError = "Unable to read: \(failures.joined(separator: ", "))" }
        } catch {
            importError = error.localizedDescription
        }
    }

    func importFiles(from urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        importError = nil

        do {
            let folder = try audioFolderURL()
            var imported: [Track] = []
            var importedVideos: [LocalVideo] = []
            var failures: [String] = []

            for sourceURL in urls {
                guard Self.isSupported(sourceURL) else {
                    failures.append(sourceURL.lastPathComponent)
                    continue
                }
                do {
                    let result = try await importFile(sourceURL, into: folder)
                    switch result {
                    case .audio(let track):
                        if containsDuplicate(of: track, in: tracks + imported) {
                            try? fileManager.removeItem(at: track.fileURL)
                        } else {
                            imported.append(track)
                        }
                    case .video(let video): importedVideos.append(video)
                    }
                } catch {
                    failures.append(sourceURL.lastPathComponent)
                }
            }

            tracks.append(contentsOf: imported)
            videos.append(contentsOf: importedVideos)
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            videos.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            saveLibrary()
            if !failures.isEmpty { importError = "Unable to import: \(failures.joined(separator: ", "))" }
        } catch {
            importError = error.localizedDescription
        }
    }

    private enum ImportedMedia {
        case audio(Track)
        case video(LocalVideo)
    }

    private func importFile(_ sourceURL: URL, into folder: URL) async throws -> ImportedMedia {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let destination = uniqueDestination(for: sourceURL, in: folder)
        do {
            try coordinatedCopy(from: sourceURL, to: destination)
            if Self.isVideo(destination) {
                return .video(try await makeVideo(from: destination))
            }
            return .audio(try await makeTrack(from: destination))
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func coordinatedCopy(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                try fileManager.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
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

    func removeTrack(id: UUID, deleteFile: Bool = true) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let path = tracks[index].fileURL.standardizedFileURL.path
        if deleteFile {
            try? fileManager.removeItem(at: tracks[index].fileURL)
            hiddenTrackPaths.remove(path)
        } else {
            hiddenTrackPaths.insert(path)
        }
        tracks.remove(at: index)
        saveHiddenTrackPaths()
        saveLibrary()
    }

    func updateArtwork(_ artworkData: Data, for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].artworkData = artworkData
        saveLibrary()
    }

    func renameTrack(id: UUID, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].title = cleaned
        tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        saveLibrary()
    }

    func updateLyrics(_ lyrics: String, for trackID: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].lyrics = lyrics
        saveLibrary()
    }

    func readSecurityScopedData(from url: URL) throws -> Data {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            readResult = Result { try Data(contentsOf: readableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw CocoaError(.fileReadUnknown) }
        return try readResult.get()
    }

    private func makeTrack(from url: URL) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.commonMetadata)

        let title = await metadata.text(for: .commonIdentifierTitle)
            ?? url.deletingPathExtension().lastPathComponent
        let artist = await metadata.text(for: .commonIdentifierArtist) ?? "Unknown Artist"
        let album = await metadata.text(for: .commonIdentifierAlbumName) ?? "Unknown Album"
        let artworkData = await metadata.data(for: .commonIdentifierArtwork)
        let embeddedLyrics = await metadata.text(containingIdentifier: "lyrics")
        let sidecarLyrics = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8)

        return Track(
            title: title,
            artist: artist,
            albumName: album,
            duration: duration.isFinite ? duration : 0,
            fileURL: url,
            artworkData: artworkData,
            lyrics: embeddedLyrics ?? sidecarLyrics
        )
    }

    private func makeVideo(from url: URL) async throws -> LocalVideo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.commonMetadata)
        let title = await metadata.text(for: .commonIdentifierTitle) ?? url.deletingPathExtension().lastPathComponent
        let artist = await metadata.text(for: .commonIdentifierArtist) ?? "Unknown Artist"
        return LocalVideo(
            title: title,
            artist: artist,
            duration: duration.isFinite ? duration : 0,
            fileURL: url
        )
    }

    private func loadLibrary() {
        do {
            let data = try Data(contentsOf: try indexURL())
            let decoded = try JSONDecoder().decode([Track].self, from: data)
            tracks = decoded.filter {
                fileManager.fileExists(atPath: $0.fileURL.path)
                    && !hiddenTrackPaths.contains($0.fileURL.standardizedFileURL.path)
            }
        } catch {
            tracks = []
        }
        if let data = try? Data(contentsOf: try videoIndexURL()),
           let decoded = try? JSONDecoder().decode([LocalVideo].self, from: data) {
            videos = decoded.filter { fileManager.fileExists(atPath: $0.fileURL.path) }
        }
    }

    private func saveLibrary() {
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: indexURL(), options: .atomic)
            let videoData = try JSONEncoder().encode(videos)
            try videoData.write(to: videoIndexURL(), options: .atomic)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func loadHiddenTrackPaths() {
        guard let data = try? Data(contentsOf: try hiddenTracksURL()),
              let paths = try? JSONDecoder().decode(Set<String>.self, from: data) else { return }
        hiddenTrackPaths = paths
    }

    private func saveHiddenTrackPaths() {
        guard let data = try? JSONEncoder().encode(hiddenTrackPaths) else { return }
        try? data.write(to: hiddenTracksURL(), options: .atomic)
    }

    private func deduplicateTracks() {
        var signatures = Set<String>()
        tracks = tracks.filter { signatures.insert(duplicateSignature(for: $0)).inserted }
        tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        saveLibrary()
    }

    private func containsDuplicate(of track: Track, in collection: [Track]) -> Bool {
        let signature = duplicateSignature(for: track)
        return collection.contains { duplicateSignature(for: $0) == signature }
    }

    private func duplicateSignature(for track: Track) -> String {
        let values = [track.title, track.artist, track.albumName].map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return values.joined(separator: "|") + "|\(Int(track.duration.rounded()))"
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

    private func videoIndexURL() throws -> URL {
        try documentsURL().appendingPathComponent(videoIndexFileName)
    }

    private func hiddenTracksURL() throws -> URL {
        try documentsURL().appendingPathComponent(hiddenTracksFileName)
    }

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let ext = source.pathExtension.lowercased()
        let baseName = source.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return destination
    }

    private static func isSupported(_ url: URL) -> Bool {
        isAudio(url) || isVideo(url)
    }

    private static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedAudioExtensions.contains(ext)
            || UTType(filenameExtension: ext)?.conforms(to: .audio) == true
    }

    private static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext)
            || UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }
}

private extension Array where Element == AVMetadataItem {
    func text(for identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier).first else {
            return nil
        }
        return try? await item.load(.stringValue)
    }

    func data(for identifier: AVMetadataIdentifier) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: self, filteredByIdentifier: identifier).first else {
            return nil
        }
        return try? await item.load(.dataValue)
    }

    func text(containingIdentifier fragment: String) async -> String? {
        guard let item = first(where: { $0.identifier?.rawValue.localizedCaseInsensitiveContains(fragment) == true }) else {
            return nil
        }
        return try? await item.load(.stringValue)
    }
}
