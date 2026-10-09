import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "Keychain error \(s): \(msg)"
        }
    }
}

/// Host passwords, stored as generic passwords keyed by host id.
public enum KeychainStore {
    /// Kept from the app's old name (SSH Toolbox) so existing saved passwords still resolve.
    public static let service = "com.sshtoolbox.host"

    private static func baseQuery(_ hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
        ]
    }

    /// Saves (or replaces) a password. `trustedApps` are executable paths allowed to read the
    /// item without a prompt, in addition to the caller — pass the askpass/MCP helper here.
    public static func setPassword(_ password: String, for hostID: UUID, label: String, trustedApps: [String] = []) throws {
        deletePassword(for: hostID)

        var query = baseQuery(hostID)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrLabel as String] = "Jigowatt: \(label)"
        if let access = makeAccess(label: label, trustedApps: trustedApps) {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func password(for hostID: UUID) -> String? {
        var query = baseQuery(hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasPassword(for hostID: UUID) -> Bool {
        var query = baseQuery(hostID)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func deletePassword(for hostID: UUID) -> Bool {
        SecItemDelete(baseQuery(hostID) as CFDictionary) == errSecSuccess
    }

    /// Builds an ACL that trusts the calling app plus the given executables.
    /// Uses the legacy (file-based keychain) API, which is what non-sandboxed Mac apps get.
    private static func makeAccess(label: String, trustedApps: [String]) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { apps.append(me) }
        for path in trustedApps where FileManager.default.isExecutableFile(atPath: path) {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
