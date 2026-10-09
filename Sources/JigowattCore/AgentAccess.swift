import Foundation

public enum AgentAccessError: Error, LocalizedError, Equatable {
    case notFound(String)
    case ambiguous(String, [String])
    case notAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let q):
            return "No host named '\(q)'. Use list_hosts to see configured hosts."
        case .ambiguous(let q, let names):
            return "'\(q)' matches several hosts (\(names.joined(separator: ", "))). Use the host id instead."
        case .notAllowed(let name):
            return "Agent access is disabled for '\(name)'. The user can enable it in Jigowatt (Edit host → Allow agent)."
        }
    }
}

/// Resolves which host an agent request refers to and enforces the per-host opt-in.
public enum AgentAccess {
    /// Matches by id, then exact name (case-insensitive), then hostname.
    public static func resolve(_ query: String, in hosts: [SSHHost]) throws -> SSHHost {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: q), let host = hosts.first(where: { $0.id == id }) {
            return host
        }
        for key in [\SSHHost.displayName, \SSHHost.hostname] {
            let matches = hosts.filter { $0[keyPath: key].caseInsensitiveCompare(q) == .orderedSame }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw AgentAccessError.ambiguous(q, matches.map(\.displayName)) }
        }
        throw AgentAccessError.notFound(q)
    }

    public static func authorize(_ query: String, in hosts: [SSHHost]) throws -> SSHHost {
        let host = try resolve(query, in: hosts)
        guard host.agentAllowed else { throw AgentAccessError.notAllowed(host.displayName) }
        return host
    }
}
