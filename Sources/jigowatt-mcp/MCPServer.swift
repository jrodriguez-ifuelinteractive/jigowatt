import Foundation
import MCP
import JigowattCore

enum MCPServer {
    static let version = "0.1.0"
    static let maxTimeout = 600.0

    static func run() async throws {
        let server = Server(
            name: "jigowatt",
            version: version,
            instructions: """
                Access to the user's SSH machines configured in Jigowatt. Call list_hosts first. \
                run_command only works on hosts where agentAllowed is true; the user controls that in the app. \
                Commands run non-interactively (no TTY, no stdin). Every command is logged for the user.
                """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                switch params.name {
                case "list_hosts":
                    return .init(content: [text(try listHosts())], isError: false)
                case "run_command":
                    return try await runCommand(params.arguments ?? [:])
                default:
                    return .init(content: [text("Unknown tool: \(params.name)")], isError: true)
                }
            } catch {
                return .init(content: [text(error.localizedDescription)], isError: true)
            }
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    static let tools: [Tool] = [
        Tool(
            name: "list_hosts",
            description: "List the SSH hosts configured in Jigowatt, including whether the agent may run commands on each.",
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "run_command",
            description: """
                Run a shell command on a configured SSH host and return its exit code, stdout and stderr. \
                Only works on hosts with agentAllowed=true. Non-interactive: no TTY and no stdin, so avoid \
                commands that prompt (use flags like -y, or sudo -n).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "host": .object([
                        "type": "string",
                        "description": "Host name, hostname, or id from list_hosts.",
                    ]),
                    "command": .object([
                        "type": "string",
                        "description": "Shell command to run on the remote host.",
                    ]),
                    "timeout_seconds": .object([
                        "type": "integer",
                        "description": "Kill the command after this many seconds (default 60, max 600).",
                    ]),
                ]),
                "required": .array(["host", "command"]),
            ]),
            annotations: .init(destructiveHint: true, openWorldHint: true)
        ),
    ]

    static func listHosts() throws -> String {
        let hosts = try HostStore().load().sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: ["hosts": rows], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func runCommand(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let query = args["host"]?.stringValue, !query.isEmpty else {
            return .init(content: [text("Missing 'host'.")], isError: true)
        }
        guard let command = args["command"]?.stringValue, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .init(content: [text("Missing 'command'.")], isError: true)
        }
        let timeout = min(maxTimeout, max(1, Double(args["timeout_seconds"]?.intValue ?? 60)))
        let audit = AuditLog()
        let hosts = try HostStore().load()

        let host: SSHHost
        do {
            host = try AgentAccess.authorize(query, in: hosts)
        } catch {
            let resolved = try? AgentAccess.resolve(query, in: hosts)
            audit.append(AuditEntry(hostName: resolved?.displayName ?? query, hostID: resolved?.id, command: command,
                                    exitCode: nil, durationSeconds: nil, outcome: "refused", client: "mcp"))
            throw error
        }

        let result = try await SSHRunner.run(
            host: host, command: command, timeout: timeout,
            helperPath: JigowattPaths.helperExecutable.path)

        audit.append(AuditEntry(hostName: host.displayName, hostID: host.id, command: command,
                                exitCode: result.exitCode, durationSeconds: result.duration,
                                outcome: result.timedOut ? "timeout" : (result.exitCode == 0 ? "ok" : "failed"),
                                client: "mcp"))

        var body = "exit_code: \(result.exitCode)"
        if result.timedOut { body += " (killed after \(Int(timeout))s timeout)" }
        // ssh itself exits 255 on connection/auth failures.
        if result.exitCode == 255 && !result.timedOut {
            body += "\nnote: ssh could not connect or authenticate. If the host key is unknown, the user must connect once from Jigowatt to accept it."
        }
        body += "\n--- stdout ---\n\(result.stdout)"
        // Drop ssh's connection-multiplexing chatter; it isn't output from the command.
        let stderr = result.stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("disabling multiplexing") && !$0.hasPrefix("mux_client_") }
            .joined(separator: "\n")
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body += "\n--- stderr ---\n\(stderr)" }
        return .init(content: [text(body)], isError: result.exitCode != 0)
    }

    private static func text(_ s: String) -> Tool.Content {
        .text(text: s, annotations: nil, _meta: nil)
    }
}
