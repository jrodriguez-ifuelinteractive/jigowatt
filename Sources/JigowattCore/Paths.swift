import Foundation

public enum JigowattPaths {
    /// ~/Library/Application Support/Jigowatt. Override with JIGOWATT_HOME (used by tests).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["JIGOWATT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultSupportDirectory
    }

    /// The app was called SSH Toolbox before; move its data directory over on first use.
    private static let defaultSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Jigowatt", isDirectory: true)
        let legacy = base.appendingPathComponent("SSHToolbox", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        return dir
    }()

    public static var hostsFile: URL { supportDirectory.appendingPathComponent("hosts.json") }
    public static var auditLog: URL { supportDirectory.appendingPathComponent("audit.jsonl") }

    /// Short path for ssh ControlMaster sockets (unix socket paths are limited to ~104 bytes).
    public static let controlPath = "~/.ssh/jgw-%C"

    /// The MCP/askpass helper binary, which sits next to the app executable
    /// (inside the .app bundle, or in .build/<config> during development).
    public static var helperExecutable: URL {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("jigowatt-mcp")
    }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
