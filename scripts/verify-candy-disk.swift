import CryptoKit
import Foundation

// Compiled together with slices of the production sources by verify-candy-disk.cjs (macOS only).
@main
struct DiskVerification {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func main() async throws {
        // Codecs: fixed vectors shared with the Go node and js-libp2p.
        try require(CandyCodec.cid(sha256Hex: hex(Data("hello".utf8))) == "bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq",
            "CIDv1 raw sha2-256 base32 vector")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map { UInt8($0) }))
        let peerID = CandyCodec.peerID(key.publicKey)
        try require(peerID == "12D3KooWA4Xop1JaT3MHxwYMkCepYsv4iPVopMXwCz5iHYdBfeSB", "libp2p Ed25519 peer ID vector")
        let sha = hex(Data("song".utf8))
        let body = CandyPlazaBody(peerId: peerID, name: "游客1234", region: "测试", client: "ios",
            via: ["/dns4/music.webtrc.eu.cc/tcp/443/wss/p2p/12D3KooWA4Xop1JaT3MHxwYMkCepYsv4iPVopMXwCz5iHYdBfeSB"],
            listening: CandyAnnouncedListening(title: "晴天", artist: "周杰伦", isPlaying: true),
            files: [CandyAnnouncedFile(cid: CandyCodec.cid(sha256Hex: sha)!, name: "song.mp3", size: 4, sha256: sha, kind: "listening")],
            seq: Int64(Date().timeIntervalSince1970 * 1000))
        let envelope = try CandyCodec.envelope(body, key: key)
        let signature = Data(base64Encoded: envelope.sig)!
        try require(key.publicKey.isValidSignature(signature, for: Data((CandyCodec.signaturePrefix + envelope.body).utf8)),
            "Envelope signature")
        let decoded = try JSONDecoder().decode(CandyPlazaEntry.self, from: Data(envelope.body.utf8))
        try require(decoded.body.peerId == peerID && !decoded.offline && decoded.body.files.count == 1, "Entry decoding")
        // The runner verifies this envelope with the JS implementation (same checks as the Go node).
        print("ENVELOPE:" + String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("candy-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { print("Test artifact cleanup failed: \(error)") }
        }

        for count in [0, 1, 300_001, 2_097_152, 3 * 1_048_576 + 12_345] {
            let bytes = Data((0..<count).map { UInt8(($0 * 7 + ($0 >> 11)) % 251) })
            let source = folder.appendingPathComponent("source-\(count).bin")
            try bytes.write(to: source)
            let manifest = try await CandyTransferDisk.manifest(source)
            try require(manifest.sha256 == hex(bytes) && manifest.size == Int64(count), "Manifest whole-file hash")
            try require(manifest.blocks.count == (count + candyBlockSize - 1) / candyBlockSize, "Manifest block count")
            for (index, block) in manifest.blocks.enumerated() {
                let range = (index * candyBlockSize)..<min(count, (index + 1) * candyBlockSize)
                try require(block == hex(bytes.subdata(in: range)), "Manifest block \(index)")
            }

            let file = CandyPlazaFile(id: CandyCodec.cid(sha256Hex: manifest.sha256)!, name: "../song-\(count).mp3",
                size: Int64(count), ownerId: peerID, ownerName: "owner", sha256: manifest.sha256)
            var disk = CandyTransferDisk(file: file, folder: folder)
            try require(try await disk.prepare() == 0, "Initial checkpoint")
            var offset = 0
            let firstStop = min(count, 1_048_576 + 300_000)
            while offset < firstStop {
                let end = min(firstStop, offset + candyChunkSize)
                try await disk.append(bytes.subdata(in: offset..<end), at: Int64(offset))
                offset = end
            }
            try await disk.close()
            disk = CandyTransferDisk(file: file, folder: folder)
            let resumed = try await disk.prepare()
            try require(resumed == Int64(offset), "Resume from durable prefix, not zero")
            if count > 0 {
                do {
                    try await disk.append(Data([1]), at: Int64(offset + 1))
                    throw NSError(domain: "Wrong offset accepted", code: 1)
                } catch CandyTransferFailure.invalid { }
            }
            // Resume is block-aligned: rewind to the last verified block boundary.
            let aligned = Int64(offset - offset % candyBlockSize)
            try await disk.rewind(to: aligned)
            try require(try await disk.durableOffset() == aligned, "Rewind to block boundary")
            offset = Int(aligned)
            while offset < count {
                let end = min(count, offset + candyChunkSize)
                try await disk.append(bytes.subdata(in: offset..<end), at: Int64(offset))
                offset = end
            }
            let destination = try await disk.finish()
            try require(destination.deletingLastPathComponent() == folder, "Filename traversal must be confined")
            try require(try Data(contentsOf: destination) == bytes, "Saved bytes must match")
            try require(try await disk.finish() == destination, "Completion must be idempotent")
            let relaunched = CandyTransferDisk(file: file, folder: folder)
            try require(try await relaunched.prepare() == Int64(count), "Completed checkpoint recovery")
            try require(await relaunched.isCompleted, "Completed flag after relaunch")
            try require(try await relaunched.finish() == destination, "No duplicate completed file")
        }

        let valid = Data(repeating: 7, count: 300_000)
        let hash = hex(valid)
        let file = CandyPlazaFile(id: CandyCodec.cid(sha256Hex: hash)!, name: "invalid.mp3", size: 300_000,
            ownerId: "owner", ownerName: "owner", sha256: hash)
        let bad = CandyTransferDisk(file: file, folder: folder)
        _ = try await bad.prepare()
        try await bad.append(Data(repeating: 8, count: 300_000), at: 0)
        do {
            _ = try await bad.finish()
            throw NSError(domain: "Incorrect hash accepted", code: 1)
        } catch CandyTransferFailure.invalid { }
        try await bad.clear()
        try require(try await bad.prepare() == 0, "Clear damaged checkpoint")
        try await bad.close()
        let prefix = CandyTransferDisk(file: file, folder: folder)
        _ = try await prefix.prepare()
        try await prefix.append(valid.prefix(262_144), at: 0)
        try await prefix.close()
        let namespace = hex(Data("auru-dht".utf8))
        let partial = folder.appendingPathComponent(".partial").appendingPathComponent("\(namespace)-\(hash).part")
        try Data(repeating: 9, count: 262_144).write(to: partial)
        let corrupt = CandyTransferDisk(file: file, folder: folder)
        do {
            _ = try await corrupt.prepare()
            throw NSError(domain: "Corrupted persisted prefix accepted", code: 1)
        } catch CandyTransferFailure.invalid { }
        print("PASS: production Swift codecs (CID, peer ID, signed envelope) and disk actor: block manifests, durable resume, block-aligned rewind, completion recovery, hash/offset validation and path confinement.")
    }
}
