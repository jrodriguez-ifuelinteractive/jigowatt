import Foundation
import Logging
import MCP
import JigowattCore

/// MCP stdio server. It is a thin relay: commands run in visible agent tabs inside the
/// Jigowatt app, which does authorization and audit logging. The app is started in the
/// background if it isn't running.
enum MCPServer {
    static let version = "0.2.0"

    static func run() async throws {
        let server = Server(
            name: "jigowatt",
            version: version,
            instructions: """
                Access to the user's SSH machines configured in Jigowatt. Call list_hosts first; tools only work \
                on hosts where agentAllowed is true (the user controls that in the app). \
                Commands run in a real interactive shell in a Jigowatt tab the user can watch: one persistent \
                session per host, so cd, environment variables and other shell state carry over between \
                run_command calls. If a command is still running when run_command returns (timeout, or a \
                prompt waiting for input), use read_screen to check it and send_input to answer or interrupt it \
                (keys ["ctrl_c"]). Every request is logged for the user.
                """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            do {
                switch params.name {
                case "list_hosts":
                    return .init(content: [text(try listHosts())], isError: false)
                case "run_command":
                    let timeout = number(args["timeout_seconds"]) ?? 60
                    return try await relay(AgentRequest(
                        tool: .runCommand, host: args["host"]?.stringValue, command: args["command"]?.stringValue,
                        timeoutSeconds: timeout), waitUpTo: min(600, timeout) + 60)
                case "send_input":
                    let keys = args["keys"]?.arrayValue?.compactMap(\.stringValue)
                    let wait = number(args["wait_ms"]).map { Int($0) }
                    return try await relay(AgentRequest(
                        tool: .sendInput, host: args["host"]?.stringValue, text: args["text"]?.stringValue,
                        keys: keys, waitMilliseconds: wait), waitUpTo: 90)
                case "read_screen":
                    return try await relay(AgentRequest(
                        tool: .readScreen, host: args["host"]?.stringValue,
                        scrollbackLines: number(args["scrollback_lines"]).map { Int($0) }), waitUpTo: 30, launch: false)
                case "close_session":
                    return try await relay(AgentRequest(tool: .closeSession, host: args["host"]?.stringValue),
                                           waitUpTo: 30, launch: false)
                default:
                    return .init(content: [text("Unknown tool: \(params.name)")], isError: true)
                }
            } catch {
                return .init(content: [text(error.localizedDescription)], isError: true)
            }
        }

        try await server.start(transport: SanitizingTransport(wrapping: StdioTransport(), logger: Logger(label: "jigowatt-mcp")))
        await server.waitUntilCompleted()
    }

    static func hostProperty() -> Value {
        .object(["type": "string", "description": "Host name, hostname, or id from list_hosts."])
    }

    static let tools: [Tool] = [
        Tool(
            name: "list_hosts",
            description: """
                List the SSH hosts configured in Jigowatt: whether the agent may use each one (agentAllowed), \
                and the state of its agent session if one is open (idle, busy, or ended).
                """,
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "run_command",
            description: """
                Run a shell command in the host's agent session, a real interactive shell in a Jigowatt tab the \
                user can watch. Opens the session on first use; shell state (cwd, env, activated virtualenvs) \
                persists between calls. Returns the exit code, the working directory afterwards, and the \
                terminal output (stdout and stderr together, as shown in the terminal, last 100 KB). \
                If the command is still running at the timeout it is NOT killed: use read_screen and send_input. \
                Commands that wait for input (a sudo password, a y/n prompt) show their prompt in the output. \
                Avoid starting nested interactive shells (sudo -i, bash, ssh, docker exec -it): run_command \
                can't frame commands inside them; use sudo -n <cmd> or send_input instead.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "host": hostProperty(),
                    "command": .object([
                        "type": "string",
                        "description": "Shell command to run. Multi-line scripts are fine.",
                    ]),
                    "timeout_seconds": .object([
                        "type": "number",
                        "description": "Wait at most this long for the command to finish (default 60, max 600).",
                    ]),
                ]),
                "required": .array(["host", "command"]),
            ]),
            annotations: .init(destructiveHint: true, openWorldHint: true)
        ),
        Tool(
            name: "send_input",
            description: """
                Type into the host's agent session: answer a prompt, drive an interactive program, or interrupt \
                a command. Text is typed as-is (add keys ["enter"] to submit). If no command is running, the \
                input goes to the shell prompt. Returns the visible screen afterwards, and the exit code if the \
                running command finished.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "host": hostProperty(),
                    "text": .object(["type": "string", "description": "Text to type."]),
                    "keys": .object([
                        "type": "array",
                        "items": .object(["type": "string", "enum": .array(AgentKeys.names.map { .string($0) })]),
                        "description": "Special keys to press after the text, in order.",
                    ]),
                    "wait_ms": .object([
                        "type": "integer",
                        "description": "How long to wait before reading the screen (default 500, max 30000).",
                    ]),
                ]),
                "required": .array(["host"]),
            ]),
            annotations: .init(destructiveHint: true, openWorldHint: true)
        ),
        Tool(
            name: "read_screen",
            description: "Read the host's agent session terminal: the visible screen, plus scrollback lines if requested.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "host": hostProperty(),
                    "scrollback_lines": .object([
                        "type": "integer",
                        "description": "Return the last N lines including scrollback instead of just the visible screen.",
                    ]),
                ]),
                "required": .array(["host"]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "close_session",
            description: "Close the host's agent session tab (ends its ssh connection and any running command).",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["host": hostProperty()]),
                "required": .array(["host"]),
            ]),
            annotations: .init(destructiveHint: true, idempotentHint: true, openWorldHint: false)
        ),
    ]

    // MARK: list_hosts (read locally so it works without starting the app)

    static func listHosts() throws -> String {
        let hosts = try HostStore().load().sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let sessionStates = openSessionStates()
        let rows: [[String: Any]] = hosts.map { h in
            var row: [String: Any] = [
                "id": h.id.uuidString,
                "name": h.displayName,
                "hostname": h.hostname,
                "agentAllowed": h.agentAllowed,
            ]
            if !h.username.isEmpty { row["user"] = h.username }
            if let port = h.port { row["port"] = port }
            if !h.group.isEmpty { row["group"] = h.group }
            if !h.tags.isEmpty { row["tags"] = h.tags }
            if !h.notes.isEmpty { row["notes"] = h.notes }
            if let state = sessionStates[h.id.uuidString] { row["agentSession"] = state }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["hosts": rows], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Agent session state per host id, if the app is running. Never launches it.
    static func openSessionStates() -> [String: String] {
        guard AgentSocketServer.isListening(),
              let response = try? AgentSocket.send(AgentRequest(tool: .listSessions), timeout: 5),
              !response.isError,
              let rows = try? JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [[String: String]]
        else { return [:] }
        var out: [String: String] = [:]
        for row in rows { if let id = row["hostID"], let state = row["state"] { out[id] = state } }
        return out
    }

    // MARK: Relay to the app

    static func relay(_ request: AgentRequest, waitUpTo timeout: TimeInterval, launch: Bool = true) async throws -> CallTool.Result {
        if !AgentSocketServer.isListening() {
            guard launch else {
                return .init(content: [text("Jigowatt isn't running, so no agent session is open.")], isError: true)
            }
            try await AppLauncher.launchAndWait()
        }
        // Blocking socket I/O; keep it off the cooperative pool's critical path.
        let response = try await Task.detached { try AgentSocket.send(request, timeout: timeout) }.value
        return .init(content: [text(response.text)], isError: response.isError)
    }

    static func number(_ value: Value?) -> Double? {
        guard let value else { return nil }
        if let d = value.doubleValue { return d }
        if let i = value.intValue { return Double(i) }
        if let s = value.stringValue { return Double(s) }
        return nil
    }

    private static func text(_ s: String) -> Tool.Content {
        .text(text: s, annotations: nil, _meta: nil)
    }
}

/// Starts Jigowatt in the background (menu bar only, no window) and waits for its socket.
enum AppLauncher {
    struct LaunchError: LocalizedError {
        let errorDescription: String?
    }

    static func launchAndWait(timeout: TimeInterval = 20) async throws {
        let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let macOSDir = me.deletingLastPathComponent()
        let bundle = macOSDir.deletingLastPathComponent().deletingLastPathComponent()

        let process = Process()
        if bundle.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", bundle.path, "--args", "--background"]
        } else {
            // Development build: the app executable sits next to this one in .build/<config>.
            process.executableURL = macOSDir.appendingPathComponent("Jigowatt")
            process.arguments = ["--background"]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw LaunchError(errorDescription: "Jigowatt isn't running and couldn't be started: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if AgentSocketServer.isListening() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LaunchError(errorDescription: "Started Jigowatt, but it didn't become ready within \(Int(timeout))s. Ask the user to open Jigowatt.")
    }
}
