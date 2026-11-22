import Foundation

public struct AuditEntry: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var timestamp: Date
    public var hostName: String
    public var hostID: UUID?
    public var command: String
    /// nil when the command was refused before running.
    public var exitCode: Int32?
    public var durationSeconds: Double?
    public var outcome: String
    public var client: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), hostName: String, hostID: UUID?, command: String,
                exitCode: Int32?, durationSeconds: Double?, outcome: String, client: String) {
        self.id = id
        self.timestamp = timestamp
        self.hostName = hostName
        self.hostID = hostID
        self.command = command
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.outcome = outcome
        self.client = client
    }
}

/// Append-only JSON Lines log of every command the agent asked to run.
/// An entry is written when a request arrives ("running") and again with the same id when
/// it finishes; readers keep the latest line per id.
///
/// Rotated by size: once `audit.jsonl` reaches `maxBytes` it becomes `audit.1.jsonl`, older
/// archives shift up (`.1` → `.2` …) and anything past `archiveCount` is deleted.
/// The app is the only writer, so rotation needs no cross-process locking.
public struct AuditLog: Sendable {
    public static let defaultMaxBytes = 5 * 1024 * 1024
    public static let defaultArchiveCount = 3

    public let url: URL
    public let maxBytes: Int
    public let archiveCount: Int

    public init(url: URL = JigowattPaths.auditLog, maxBytes: Int = defaultMaxBytes, archiveCount: Int = defaultArchiveCount) {
        self.url = url
        self.maxBytes = maxBytes
        self.archiveCount = max(0, archiveCount)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `audit.<n>.jsonl` next to the live file; n = 1 is the most recent archive.
    public func archiveURL(_ n: Int) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(n).\(url.pathExtension)")
    }

    public func append(_ entry: AuditEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(adding: line.count)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: [.atomic])
        }
    }

    /// Rotates before a write that would take the live file past `maxBytes`.
    func rotateIfNeeded(adding bytes: Int) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 0, size + bytes > maxBytes else { return }
        guard archiveCount > 0 else {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.removeItem(at: archiveURL(archiveCount))
        for n in stride(from: archiveCount - 1, through: 1, by: -1) where fm.fileExists(atPath: archiveURL(n).path) {
            try? fm.moveItem(at: archiveURL(n), to: archiveURL(n + 1))
        }
        try? fm.moveItem(at: url, to: archiveURL(1))
    }

    /// Most recent first, one row per entry id (its latest state). Reads into the archives
    /// when the live file holds fewer than `limit` entries.
    public func read(limit: Int = 500) -> [AuditEntry] {
        // Newest file first; stop once there are clearly enough lines.
        var chunks: [Data] = []
        var lineCount = 0
        for file in [url] + (0..<archiveCount).map({ archiveURL($0 + 1) }) {
            guard let data = try? Data(contentsOf: file) else { continue }
            chunks.append(data)
            lineCount += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if lineCount >= limit * 2 { break }
        }
        var order: [UUID] = []
        var latest: [UUID: AuditEntry] = [:]
        for data in chunks.reversed() {  // oldest first, so later lines win
            for line in data.split(separator: 0x0A) {
                guard let entry = try? Self.decoder.decode(AuditEntry.self, from: Data(line)) else { continue }
                if latest[entry.id] == nil { order.append(entry.id) }
                latest[entry.id] = entry
            }
        }
        return order.suffix(limit).reversed().compactMap { latest[$0] }
    }
}
