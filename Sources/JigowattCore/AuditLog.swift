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

    public init(timestamp: Date = Date(), hostName: String, hostID: UUID?, command: String,
                exitCode: Int32?, durationSeconds: Double?, outcome: String, client: String) {
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
public struct AuditLog: Sendable {
    public let url: URL

    public init(url: URL = JigowattPaths.auditLog) { self.url = url }

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

    public func append(_ entry: AuditEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: [.atomic])
        }
    }

    /// Most recent first.
    public func read(limit: Int = 500) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let entries = data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(AuditEntry.self, from: Data($0)) }
        return Array(entries.suffix(limit).reversed())
    }
}
