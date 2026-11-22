import Foundation
import JigowattCore

/// Runs coding-agent requests (relayed by `jigowatt-mcp` over the agent socket) in visible
/// Jigowatt tabs. Each allowed host gets one long-lived agent tab whose shell state persists
/// between commands. Agent tools never read from or type into tabs the user opened.
@MainActor
final class AgentBroker {
    static let maxTimeout = 600.0
    static let readyTimeout = 20.0
    /// How long a command's start marker may take to appear before it counts as not started.
    static let startGrace = 5.0

    private let library: HostLibrary
    private let sessions: SessionManager
    private let audit = AuditLog()
    private var server: AgentSocketServer?
    /// Agent tab per host id.
    private var tabs: [UUID: TerminalSession] = [:]
    /// Command still running in an agent tab (after a timeout), keyed by session id.
    private var pending: [UUID: Pending] = [:]
    /// Agent tabs whose shell has the prompt hook (bash/zsh), so Ctrl-C still reports an exit code.
    private var hooked: Set<UUID> = []
    /// Surface generation each agent tab's shell was set up in. A user reconnect (⌘R) starts a
    /// fresh shell without the helpers, so setup runs again when this changes.
    private var setUpGeneration: [UUID: Int] = [:]

    private struct Pending {
        var frame: ShellFrame
        var entry: AuditEntry
        var started: Date
    }

    struct Failure: Error { let message: String }

    init(library: HostLibrary, sessions: SessionManager) {
        self.library = library
        self.sessions = sessions
    }

    func start() {
        guard server == nil else { return }
        let server = AgentSocketServer { [weak self] request in
            guard let self else { return .error("Jigowatt is shutting down.") }
            return await self.handle(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Jigowatt: agent socket unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// Hosts that currently have an agent tab, for list_hosts.
    var openSessionHostIDs: [UUID: String] {
        var out: [UUID: String] = [:]
        for (hostID, session) in tabs where sessions.sessions.contains(where: { $0 === session }) {
            out[hostID] = session.state != .running ? "ended" : (pending[session.id] != nil ? "busy" : "idle")
        }
        return out
    }

    func handle(_ request: AgentRequest) async -> AgentResponse {
        do {
            switch request.tool {
            case .runCommand: return try await runCommand(request)
            case .sendInput: return try await sendInput(request)
            case .readScreen: return try readScreen(request)
            case .closeSession: return try closeSession(request)
            case .listSessions: return listSessions()
            }
        } catch let failure as Failure {
            return .error(failure.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: Tools

    private func runCommand(_ r: AgentRequest) async throws -> AgentResponse {
        guard let command = r.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Missing 'command'.")
        }
        let host = try authorize(r.host, logging: command)
        let timeout = min(Self.maxTimeout, max(1, r.timeoutSeconds ?? 60))
        let session = try await agentSession(for: host, create: true, command: command)

        if let busy = refreshPending(session) {
            throw Failure(message: """
                The agent session on \(host.displayName) is still running a command (started \(Int(Date().timeIntervalSince(busy.started)))s ago). \
                Use read_screen to watch it, send_input with keys ["ctrl_c"] to interrupt it, or close_session.
                --- screen ---
                \(screen(session))
                """)
        }

        let frame = ShellFrame()
        let started = Date()
        var entry = AuditEntry(hostName: host.displayName, hostID: host.id, command: command,
                               exitCode: nil, durationSeconds: nil, outcome: "running", client: "mcp")
        audit.append(entry)
        pending[session.id] = Pending(frame: frame, entry: entry, started: started)
        session.agentBusy = true

        guard let view = session.surfaceView else { throw Failure(message: "The agent tab has no terminal.") }
        view.paste(frame.wrap(command))
        view.type("\r")

        // Wait for the end marker. Independently of the timeout, give the start marker a few
        // seconds to appear: if it doesn't, the shell rejected or is still reading the line
        // (syntax error, unclosed quote or heredoc) and nothing is running.
        let deadline = started.addingTimeInterval(timeout)
        let startDeadline = started.addingTimeInterval(Self.startGrace)
        var sawStart = false
        while session.state == .running, isOpen(session) {
            let parsed = frame.parse(view.readText(includeScrollback: false))
            if parsed?.exitCode != nil { break }
            if parsed != nil { sawStart = true }
            let now = Date()
            if now >= (sawStart ? deadline : startDeadline) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        if !isOpen(session) {
            finish(session, outcome: "closed", exitCode: nil)
            return .error("The user closed the agent tab while the command was running.")
        }

        let result = frame.parse(view.readText(includeScrollback: true))
        if result == nil, session.state == .running {
            // Never started: clear whatever the shell is holding and report what it showed.
            view.type(AgentKeys.bytes["ctrl_c"]!)
            finish(session, outcome: "failed", exitCode: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .error("""
                The command didn't start: the shell rejected it or is waiting for more input \
                (syntax error, unclosed quote, bracket or heredoc). It was cancelled with Ctrl-C.
                --- screen ---
                \(screen(session))
                """)
        }
        let output = TextLimit.tail(result?.output ?? "")
        var notes: [String] = []
        if let result, !result.sawStart { notes.append("note: the start of the output scrolled out of the terminal's scrollback.") }

        if let code = result?.exitCode {
            finish(session, outcome: code == 0 ? "ok" : "failed", exitCode: code)
            var body = "exit_code: \(code)"
            if let cwd = result?.workingDirectory, !cwd.isEmpty { body += "\ncwd: \(cwd)" }
            notes.forEach { body += "\n\($0)" }
            return .init(text: body + "\n--- output ---\n" + output)
        }

        if session.state != .running {
            finish(session, outcome: "failed", exitCode: nil)
            return .error("The ssh session ended while the command was running.\n--- screen ---\n" + screen(session, scrollback: 40))
        }

        // Still running: leave it in the tab, the agent can poll or interrupt it.
        entry.outcome = "timeout"
        entry.durationSeconds = Date().timeIntervalSince(started)
        audit.append(entry)
        pending[session.id]?.entry = entry
        var body = """
            status: still running after \(Int(timeout))s (the command was not killed).
            Use read_screen to check on it, send_input with keys ["ctrl_c"] to interrupt it, \
            or send_input with text to answer a prompt.
            """
        notes.forEach { body += "\n\($0)" }
        return .init(text: body + "\n--- output so far ---\n" + (output.isEmpty ? "(no output yet)" : output))
    }

    private func sendInput(_ r: AgentRequest) async throws -> AgentResponse {
        let keys = r.keys ?? []
        if let bad = keys.first(where: { AgentKeys.bytes[$0] == nil }) {
            throw Failure(message: "Unknown key '\(bad)'. Known keys: \(AgentKeys.names.joined(separator: ", ")).")
        }
        let text = r.text ?? ""
        guard !text.isEmpty || !keys.isEmpty else { throw Failure(message: "Pass 'text', 'keys', or both.") }

        let description = ([text.isEmpty ? nil : "text \(text.debugDescription)"] + keys.map { "key \($0)" })
            .compactMap { $0 }.joined(separator: ", ")
        let host = try authorize(r.host, logging: "[input] \(description)")
        let session = try await agentSession(for: host, create: false)
        guard let view = session.surfaceView, session.state == .running else {
            throw Failure(message: "The agent session on \(host.displayName) has ended. Run a command to reconnect.")
        }
        audit.append(AuditEntry(hostName: host.displayName, hostID: host.id, command: "[input] \(description)",
                                exitCode: nil, durationSeconds: nil, outcome: "sent", client: "mcp"))

        view.type(text + keys.compactMap { AgentKeys.bytes[$0] }.joined())
        let wait = min(30_000, max(0, r.waitMilliseconds ?? 500))
        try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)

        var body = ""
        if let p = pending[session.id], let code = p.frame.parse(view.readText(includeScrollback: true))?.exitCode {
            finish(session, outcome: code == 0 ? "ok" : (code == 130 ? "interrupted" : "failed"), exitCode: code)
            body = "The running command finished: exit_code \(code)\n"
        } else if pending[session.id] != nil, keys.contains("ctrl_c"), !hooked.contains(session.id) {
            // Without a prompt hook an interrupted command line never prints its end marker.
            finish(session, outcome: "interrupted", exitCode: nil)
            body = "Sent Ctrl-C; the command was probably interrupted (exit status unknown in this shell).\n"
        } else if pending[session.id] != nil {
            body = "A command is still running.\n"
        } else {
            body = "No agent command was running, so the input went to the shell prompt.\n"
        }
        return .init(text: body + "--- screen ---\n" + screen(session))
    }

    private func readScreen(_ r: AgentRequest) throws -> AgentResponse {
        let host = try resolveAllowed(r.host)
        guard let session = existingSession(for: host) else {
            throw Failure(message: "No agent session is open on \(host.displayName). run_command opens one.")
        }
        var status = "state: \(session.state == .running ? "connected" : "ended")"
        if let p = refreshPending(session) {
            status += ", command running for \(Int(Date().timeIntervalSince(p.started)))s"
        }
        let lines = max(0, r.scrollbackLines ?? 0)
        return .init(text: status + "\n--- screen ---\n" + screen(session, scrollback: lines))
    }

    private func closeSession(_ r: AgentRequest) throws -> AgentResponse {
        let host = try resolveAllowed(r.host)
        guard let session = existingSession(for: host) else {
            return .init(text: "No agent session was open on \(host.displayName).")
        }
        if pending[session.id] != nil { finish(session, outcome: "closed", exitCode: nil) }
        audit.append(AuditEntry(hostName: host.displayName, hostID: host.id, command: "[close session]",
                                exitCode: nil, durationSeconds: nil, outcome: "ok", client: "mcp"))
        sessions.close(session.id)
        tabs[host.id] = nil
        return .init(text: "Closed the agent session on \(host.displayName).")
    }

    private func listSessions() -> AgentResponse {
        let rows = openSessionHostIDs.map { ["hostID": $0.key.uuidString, "state": $0.value] }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data("[]".utf8)
        return .init(text: String(decoding: data, as: UTF8.self))
    }

    // MARK: Hosts and sessions

    private func resolveAllowed(_ query: String?) throws -> SSHHost {
        guard let query, !query.isEmpty else { throw Failure(message: "Missing 'host'.") }
        return try AgentAccess.authorize(query, in: library.hosts)
    }

    /// Authorizes, logging a refusal with the command that was attempted.
    private func authorize(_ query: String?, logging command: String) throws -> SSHHost {
        do {
            return try resolveAllowed(query)
        } catch {
            let resolved = try? AgentAccess.resolve(query ?? "", in: library.hosts)
            audit.append(AuditEntry(hostName: resolved?.displayName ?? (query ?? "?"), hostID: resolved?.id, command: command,
                                    exitCode: nil, durationSeconds: nil, outcome: "refused", client: "mcp"))
            throw error
        }
    }

    private func isOpen(_ session: TerminalSession) -> Bool {
        sessions.sessions.contains { $0 === session }
    }

    private func existingSession(for host: SSHHost) -> TerminalSession? {
        guard let session = tabs[host.id] else { return nil }
        guard isOpen(session) else {
            // The user closed the tab.
            if pending[session.id] != nil { finish(session, outcome: "closed", exitCode: nil) }
            hooked.remove(session.id)
            setUpGeneration[session.id] = nil
            tabs[host.id] = nil
            return nil
        }
        if let generation = setUpGeneration[session.id], generation != session.generation {
            // Reconnected by the user: the old command and shell setup are gone.
            if pending[session.id] != nil { finish(session, outcome: "failed", exitCode: nil) }
            hooked.remove(session.id)
            setUpGeneration[session.id] = nil
        }
        return session
    }

    /// Approval prompts in flight, per host, so concurrent requests share one prompt.
    private var approvals: [UUID: Task<Bool, Never>] = [:]

    /// Asks the user before the agent opens a connection (unless turned off in Settings).
    private func requireApproval(for host: SSHHost, command: String?) async throws {
        guard AppPreferences.confirmAgentSessions else { return }
        let task = approvals[host.id] ?? Task { await AgentApproval.ask(host: host, command: command) }
        approvals[host.id] = task
        let allowed = await task.value
        approvals[host.id] = nil
        guard allowed else {
            audit.append(AuditEntry(hostName: host.displayName, hostID: host.id, command: command ?? "[open session]",
                                    exitCode: nil, durationSeconds: nil, outcome: "denied", client: "mcp"))
            throw Failure(message: "The user didn't allow the agent to connect to \(host.displayName) (denied or no answer within \(Int(AgentApproval.timeout))s). Ask the user before trying again.")
        }
    }

    private func agentSession(for host: SSHHost, create: Bool, command: String? = nil) async throws -> TerminalSession {
        if let session = existingSession(for: host) {
            if session.state == .running {
                if setUpGeneration[session.id] == nil, create { try await waitUntilReady(session) }
                return session
            }
            guard create else { return session }
            try await requireApproval(for: host, command: command)
            // Another request may have reconnected it while the prompt was open.
            if session.state == .running, isOpen(session) { return session }
            pending[session.id] = nil
            hooked.remove(session.id)
            session.agentBusy = false
            session.connect()
            try await waitUntilReady(session)
            return session
        }
        guard create else {
            throw Failure(message: "No agent session is open on \(host.displayName). run_command opens one.")
        }
        try await requireApproval(for: host, command: command)
        // Another request for this host may have opened the tab while the prompt was open.
        if let session = existingSession(for: host), session.state == .running { return session }
        let session = sessions.openAgentSession(host)
        tabs[host.id] = session
        try await waitUntilReady(session)
        return session
    }

    /// Waits for the login to finish, then runs a setup command through a frame, which proves
    /// the shell is reading input and that marker parsing works there.
    private func waitUntilReady(_ session: TerminalSession) async throws {
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        var last = "", stableTicks = 0
        while Date() < deadline {
            guard session.state == .running, let view = session.surfaceView, !view.processExited else {
                throw Failure(message: "Could not connect to \(session.host.displayName).\n--- terminal ---\n" + screen(session, scrollback: 40)
                              + "\nIf this is a host-key error, connect to the host once from Jigowatt to accept its key.")
            }
            let text = view.readText(includeScrollback: false).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text == last { stableTicks += 1 } else { stableTicks = 0 }
            last = text
            if stableTicks >= 3 { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        guard let view = session.surfaceView else { return }
        let frame = ShellFrame()
        view.paste(frame.wrapStandalone(ShellFrame.sessionSetup))
        view.type("\r")
        while Date() < deadline.addingTimeInterval(10), session.state == .running {
            if let result = frame.parse(view.readText(includeScrollback: false)), result.exitCode != nil {
                if ShellFrame.setupInstalledPromptHook(result.output) { hooked.insert(session.id) }
                setUpGeneration[session.id] = session.generation
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw Failure(message: session.state == .running
            ? "Connected to \(session.host.displayName), but the shell didn't answer a test command. The agent session needs a POSIX shell (bash, zsh, sh).\n--- screen ---\n" + screen(session)
            : "The ssh session to \(session.host.displayName) ended during login.\n--- terminal ---\n" + screen(session, scrollback: 40))
    }

    /// Clears a pending command whose end marker has appeared since. Returns it if still running.
    private func refreshPending(_ session: TerminalSession) -> Pending? {
        guard let p = pending[session.id] else { return nil }
        if session.state != .running {
            finish(session, outcome: "failed", exitCode: nil)
            return nil
        }
        if let code = p.frame.parse(session.surfaceView?.readText(includeScrollback: true) ?? "")?.exitCode {
            finish(session, outcome: code == 0 ? "ok" : "failed", exitCode: code)
            return nil
        }
        return p
    }

    private func finish(_ session: TerminalSession, outcome: String, exitCode: Int32?) {
        if var entry = pending[session.id]?.entry, let started = pending[session.id]?.started {
            entry.outcome = outcome
            entry.exitCode = exitCode
            entry.durationSeconds = Date().timeIntervalSince(started)
            audit.append(entry)
        }
        pending[session.id] = nil
        session.agentBusy = false
    }

    private func screen(_ session: TerminalSession, scrollback lines: Int = 0) -> String {
        guard let view = session.surfaceView else { return "" }
        var text = view.readText(includeScrollback: lines > 0)
        if lines > 0 {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
        while text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
        return TextLimit.tail(text)
    }
}
