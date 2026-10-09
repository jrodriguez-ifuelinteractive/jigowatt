import CryptoKit
import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    /// Keys from ~/.ssh, ssh-agent, or whatever ~/.ssh/config specifies.
    case keyOrAgent
    /// Password stored in the macOS Keychain and supplied through SSH_ASKPASS.
    case password
}

/// A configured SSH machine. Named `SSHHost` to avoid clashing with Foundation's `Host`.
public struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Hostname, IP, or an alias from ~/.ssh/config.
    public var hostname: String
    public var port: Int?
    public var username: String
    /// Folder shown in the sidebar. Empty means ungrouped.
    public var group: String
    public var tags: [String]
    public var authMethod: AuthMethod
    public var identityFile: String
    /// Extra `-o Key=Value` options, one per entry (e.g. "ServerAliveInterval=30").
    public var extraOptions: [String]
    public var notes: String
    /// When true, the MCP server may run commands on this host.
    public var agentAllowed: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int? = nil,
        username: String = "",
        group: String = "",
        tags: [String] = [],
        authMethod: AuthMethod = .keyOrAgent,
        identityFile: String = "",
        extraOptions: [String] = [],
        notes: String = "",
        agentAllowed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.group = group
        self.tags = tags
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.extraOptions = extraOptions
        self.notes = notes
        self.agentAllowed = agentAllowed
    }

    /// Name shown in lists; falls back to the hostname.
    public var displayName: String { name.isEmpty ? hostname : name }

    /// `user@host:port` summary for display.
    public var summary: String {
        var s = username.isEmpty ? hostname : "\(username)@\(hostname)"
        if let port { s += ":\(port)" }
        return s
    }

    // Tolerant decoding so older/hand-edited files with missing keys still load.
    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, group, tags, authMethod, identityFile, extraOptions, notes, agentAllowed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decode(String.self, forKey: .hostname)
        // Hand-written entries may omit the id; derive a stable one so it doesn't change between loads.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? Self.stableID(name: name, hostname: hostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .keyOrAgent
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        extraOptions = try c.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        agentAllowed = try c.decodeIfPresent(Bool.self, forKey: .agentAllowed) ?? false
    }

    static func stableID(name: String, hostname: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data("\(name)|\(hostname)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30  // version 3 (name-based, MD5)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
