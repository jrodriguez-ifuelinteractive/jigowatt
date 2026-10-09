import Foundation

/// Reads and writes the host list as JSON. Shared by the app and the MCP server.
public struct HostStore: Sendable {
    public let url: URL

    public init(url: URL = JigowattPaths.hostsFile) {
        self.url = url
    }

    private struct FileFormat: Codable {
        var version: Int
        var hosts: [SSHHost]
    }

    /// Returns an empty list when the file does not exist yet.
    public func load() throws -> [SSHHost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FileFormat.self, from: data).hosts
    }

    public func save(_ hosts: [SSHHost]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(version: 1, hosts: hosts))
        try data.write(to: url, options: [.atomic])
    }
}
