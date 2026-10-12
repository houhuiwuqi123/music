import CryptoKit
import Foundation

@main
struct DiskVerification {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    static func main() async throws {
        let fixture = """
        {"type":"transfer","requestId":"request","transfer":{"id":"grant","file":{"id":"file","name":"song.mp3","size":123,"ownerId":"owner","ownerName":"Visitor","sha256":"HASH","protocolVersion":2},"mode":"p2p","token":"TOKEN","downloadURL":"https://music.webtrc.eu.cc/gateway/v2/transfers/grant/download","expiresAt":2000000000,"status":"ready","generation":4}}
        """
        let envelope = try JSONDecoder().decode(CandyTransferEnvelope.self, from: Data(fixture.utf8))
        try require(envelope.transfer?.generation == 4, "Server is authoritative for peer generation")
        let encoded = try JSONEncoder().encode(CandyTransferEnvelope(type: "transfer-request",
            requestId: "resume-request", fileId: "file", to: "owner", transferId: "grant", mode: "relay"))
        let request = try JSONDecoder().decode(CandyTransferEnvelope.self, from: encoded)
        try require(request.transferId == "grant" && request.mode == "relay", "Same-grant relay fallback contract")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("candy-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { print("Test artifact cleanup failed: \(error)") }
        }
        for count in [0, 300_001, 2_097_153] {
            let bytes = Data((0..<count).map { UInt8($0 % 251) })
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let file = CandyPlazaFile(id: UUID().uuidString, name: "../song-\(count).mp3", size: Int64(count),
                ownerId: "owner", ownerName: "owner", sha256: hash, protocolVersion: 2)
            var disk = CandyTransferDisk(file: file, folder: folder)
            let initial = try await disk.prepare()
            try require(initial == 0, "Initial checkpoint")
            var offset = 0
            while offset < min(count, 262_144) {
                let end = min(count, offset + 16_376, 262_144)
                _ = try await disk.append(bytes.subdata(in: offset..<end), at: Int64(offset))
                offset = end
            }
            try await disk.close()
            disk = CandyTransferDisk(file: file, folder: folder)
            let resumed = try await disk.prepare()
            try require(resumed == Int64(offset), "Resume from durable prefix, not zero")
            if count > 0 {
                do {
                    _ = try await disk.append(Data([1]), at: Int64(offset + 1))
                    throw NSError(domain: "Wrong offset accepted", code: 1)
                } catch CandyTransferFailure.invalid { }
            }
            while offset < count {
                let end = min(count, offset + 16_376)
                _ = try await disk.append(bytes.subdata(in: offset..<end), at: Int64(offset))
                offset = end
            }
            let destination = try await disk.finish()
            try require(destination.deletingLastPathComponent() == folder, "Filename traversal must be confined")
            try require(try Data(contentsOf: destination) == bytes, "Saved bytes must match")
            let again = try await disk.finish()
            try require(destination == again, "Completion must be idempotent")
            let relaunched = CandyTransferDisk(file: file, folder: folder)
            let restored = try await relaunched.prepare()
            try require(restored == Int64(count), "Completed checkpoint recovery")
            let recoveredURL = try await relaunched.finish()
            try require(recoveredURL == destination, "No duplicate completed file")
        }
        let valid = Data(repeating: 7, count: 300_000)
        let hash = SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined()
        let file = CandyPlazaFile(id: "invalid", name: "invalid.mp3", size: 300_000, ownerId: "owner",
            ownerName: "owner", sha256: hash, protocolVersion: 2)
        let bad = CandyTransferDisk(file: file, folder: folder)
        _ = try await bad.prepare()
        _ = try await bad.append(Data(repeating: 8, count: 300_000), at: 0)
        do {
            _ = try await bad.finish()
            throw NSError(domain: "Incorrect hash accepted", code: 1)
        } catch CandyTransferFailure.invalid { }
        try await bad.clear()
        let cleared = try await bad.prepare()
        try require(cleared == 0, "Clear damaged checkpoint")
        try await bad.close()
        let prefix = CandyTransferDisk(file: file, folder: folder)
        _ = try await prefix.prepare()
        _ = try await prefix.append(valid.prefix(262_144), at: 0)
        try await prefix.close()
        let ownerHash = SHA256.hash(data: Data("owner".utf8)).map { String(format: "%02x", $0) }.joined()
        let partial = folder.appendingPathComponent(".partial").appendingPathComponent("\(ownerHash)-\(hash).part")
        try Data(repeating: 9, count: 262_144).write(to: partial)
        let corrupt = CandyTransferDisk(file: file, folder: folder)
        do {
            _ = try await corrupt.prepare()
            throw NSError(domain: "Corrupted persisted prefix accepted", code: 1)
        } catch CandyTransferFailure.invalid { }
        let budget = CandyUploadBudget()
        try await budget.acquire(1_048_576)
        let started = Date()
        try await budget.acquire(1_048_576)
        try require(Date().timeIntervalSince(started) >= 0.8, "Aggregate upload rate must be bounded")
        let cancelled = Task { try await budget.acquire(1_048_576) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        do {
            try await cancelled.value
            throw NSError(domain: "Cancelled rate-limit waiter completed", code: 1)
        } catch is CancellationError { }
        print("PASS: production Swift disk/upload actors: streaming, durable resume, completion recovery, hash/offset validation, path confinement, total rate limit and cancellation.")
    }
}
