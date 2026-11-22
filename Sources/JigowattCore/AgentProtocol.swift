import Foundation

/// One tool call relayed from `jigowatt-mcp` to the running app over the agent socket.
/// The app owns the terminal sessions, so it does authorization, auditing and execution.
public struct AgentRequest: Codable, Sendable, Equatable {
    public enum Tool: String, Codable, Sendable {
        case runCommand = "run_command"
        case sendInput = "send_input"
        case readScreen = "read_screen"
        case closeSession = "close_session"
        case listSessions = "list_sessions"
    }

    public var tool: Tool
    public var host: String?
    public var command: String?
    public var timeoutSeconds: Double?
    public var text: String?
    public var keys: [String]?
    public var waitMilliseconds: Int?
    public var scrollbackLines: Int?

    public init(tool: Tool, host: String? = nil, command: String? = nil, timeoutSeconds: Double? = nil,
                text: String? = nil, keys: [String]? = nil, waitMilliseconds: Int? = nil, scrollbackLines: Int? = nil) {
        self.tool = tool
        self.host = host
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.text = text
        self.keys = keys
        self.waitMilliseconds = waitMilliseconds
        self.scrollbackLines = scrollbackLines
    }
}

public struct AgentResponse: Codable, Sendable, Equatable {
    public var text: String
    /// True only when the tool itself failed (refused, no session, bad input),
    /// not when a remote command exited nonzero.
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> AgentResponse { .init(text: text, isError: true) }
}

/// Keys `send_input` understands, mapped to the bytes a terminal would send.
public enum AgentKeys {
    public static let bytes: [String: String] = [
        "enter": "\r",
        "tab": "\t",
        "escape": "\u{1B}",
        "backspace": "\u{7F}",
        "space": " ",
        "up": "\u{1B}[A",
        "down": "\u{1B}[B",
        "right": "\u{1B}[C",
        "left": "\u{1B}[D",
        "ctrl_c": "\u{03}",
        "ctrl_d": "\u{04}",
        "ctrl_z": "\u{1A}",
        "ctrl_l": "\u{0C}",
        "ctrl_u": "\u{15}",
    ]

    public static var names: [String] { bytes.keys.sorted() }
}
