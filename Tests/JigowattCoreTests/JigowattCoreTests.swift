import Foundation
import Testing
@testable import JigowattCore

@Suite struct SSHCommandBuilderTests {
    @Test func interactiveArguments() {
        let host = SSHHost(name: "web", hostname: "web.example.com", port: 2222, username: "deploy",
                           identityFile: "~/.ssh/id_ed25519", extraOptions: ["ServerAliveInterval=30", " "])
        let args = SSHCommandBuilder.arguments(for: host, mode: .interactive)
        let home = NSHomeDirectory()
        #expect(args == ["-p", "2222", "-l", "deploy", "-i", "\(home)/.ssh/id_ed25519",
                         "-o", "ServerAliveInterval=30", "-t", "--", "web.example.com"])
    }

    @Test func agentSessionIsInteractiveButNeverPrompts() {
        let host = SSHHost(hostname: "db")
        let args = SSHCommandBuilder.arguments(for: host, mode: .agentSession)
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("-t"))
        #expect(Array(args.suffix(2)) == ["--", "db"])
    }

    @Test func passwordHostsUseAskpassNotBatchMode() {
        let host = SSHHost(hostname: "legacy", authMethod: .password)
        let args = SSHCommandBuilder.arguments(for: host, mode: .agentSession)
        #expect(!args.contains("BatchMode=yes"))
        #expect(args.contains("NumberOfPasswordPrompts=1"))

        let env = SSHCommandBuilder.askpassEnvironment(for: host, helperPath: "/x/helper", interactive: false)
        #expect(env["SSH_ASKPASS"] == "/x/helper")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env[AskpassEnv.hostID] == host.id.uuidString)
        #expect(env[AskpassEnv.interactive] == nil)
    }

    @Test func keyHostsGetNoAskpassEnvironment() {
        #expect(SSHCommandBuilder.askpassEnvironment(for: SSHHost(hostname: "a"), helperPath: "/x", interactive: true).isEmpty)
    }
}

@Suite struct HostStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sshtb-\(UUID().uuidString)/hosts.json")
    }

    @Test func roundTrip() throws {
        let store = HostStore(url: tempURL())
        #expect(try store.load().isEmpty)
        let hosts = [SSHHost(name: "a", hostname: "a.local", tags: ["x"], agentAllowed: true),
                     SSHHost(name: "b", hostname: "b.local", authMethod: .password)]
        try store.save(hosts)
        #expect(try store.load() == hosts)
    }

    @Test func toleratesMissingFieldsWithStableIDs() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"hosts":[{"hostname":"bare"}]}"#.utf8).write(to: url)
        let first = try HostStore(url: url).load()
        let second = try HostStore(url: url).load()
        #expect(first.count == 1)
        #expect(first[0].authMethod == .keyOrAgent)
        #expect(first[0].agentAllowed == false)
        #expect(first[0].id == second[0].id)
    }
}

@Suite struct AgentAccessTests {
    let allowed = SSHHost(name: "web", hostname: "10.0.0.1", agentAllowed: true)
    let blocked = SSHHost(name: "prod-db", hostname: "10.0.0.2", agentAllowed: false)
    var hosts: [SSHHost] { [allowed, blocked] }

    @Test func resolvesByNameHostnameAndID() throws {
        #expect(try AgentAccess.resolve("WEB", in: hosts).id == allowed.id)
        #expect(try AgentAccess.resolve("10.0.0.2", in: hosts).id == blocked.id)
        #expect(try AgentAccess.resolve(blocked.id.uuidString, in: hosts).id == blocked.id)
    }

    @Test func refusesHostsWithoutOptIn() {
        #expect(throws: AgentAccessError.notAllowed("prod-db")) {
            try AgentAccess.authorize("prod-db", in: hosts)
        }
        #expect(throws: AgentAccessError.notFound("nope")) {
            try AgentAccess.authorize("nope", in: hosts)
        }
    }

    @Test func ambiguousNamesAreRejected() {
        let dupes = [SSHHost(name: "x", hostname: "1"), SSHHost(name: "x", hostname: "2")]
        #expect(throws: AgentAccessError.self) { try AgentAccess.resolve("x", in: dupes) }
    }
}

@Suite struct AuditLogTests {
    @Test func appendsAndReadsNewestFirst() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sshtb-\(UUID().uuidString)/audit.jsonl")
        let log = AuditLog(url: url)
        log.append(AuditEntry(hostName: "a", hostID: nil, command: "one", exitCode: 0, durationSeconds: 0.1, outcome: "ok", client: "test"))
        log.append(AuditEntry(hostName: "a", hostID: nil, command: "two", exitCode: nil, durationSeconds: nil, outcome: "refused", client: "test"))
        #expect(log.read().map(\.command) == ["two", "one"])
    }
}

@Suite struct AuditLogUpdateTests {
    @Test func laterLinesWithSameIDReplaceEarlierOnes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jgw-\(UUID().uuidString)/audit.jsonl")
        let log = AuditLog(url: url)
        var entry = AuditEntry(hostName: "a", hostID: nil, command: "sleep 5", exitCode: nil, durationSeconds: nil, outcome: "running", client: "test")
        log.append(entry)
        log.append(AuditEntry(hostName: "a", hostID: nil, command: "other", exitCode: 0, durationSeconds: 0, outcome: "ok", client: "test"))
        entry.outcome = "ok"
        entry.exitCode = 0
        log.append(entry)
        let rows = log.read()
        #expect(rows.map(\.command) == ["other", "sleep 5"])
        #expect(rows[1].outcome == "ok")
    }
}

@Suite struct ShellFrameTests {
    /// Runs a command through a real non-interactive shell, after the session setup, and
    /// returns roughly what the terminal would show (escape sequences stripped, as Ghostty's
    /// text read does). Prompt hooks don't run in `-c` mode, so `extra` can call `__jgw_e`.
    private func simulate(_ shell: String, _ frame: ShellFrame, _ command: String, extra: String = "") throws -> String {
        let setup = ShellFrame()
        let script = setup.wrapStandalone(ShellFrame.sessionSetup) + "\n" + frame.wrap(command) + "\n" + extra
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", script]
        p.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let output = Self.rendered(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let echo = "user@host:~$ " + script.replacingOccurrences(of: "\n", with: "\n> ")
        return echo + "\n" + output + "user@host:/tmp$ "
    }

    /// Roughly what Ghostty's text read returns: "\r ESC[K" clears the line, SGR codes vanish.
    static func rendered(_ raw: String) -> String {
        raw.replacingOccurrences(of: "[^\n]*\r\u{1B}\\[K", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    // macOS /bin/sh is bash in POSIX mode, so only bash and zsh are checked here.
    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func sessionSetupReportsShellKind(shell: String) throws {
        let setup = ShellFrame()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", setup.wrapStandalone(ShellFrame.sessionSetup)]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let r = try #require(setup.parse(Self.rendered(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))))
        #expect(ShellFrame.setupInstalledPromptHook(r.output))
        #expect(!ShellFrame.setupInstalledPromptHook("other"))
        #expect(r.exitCode == 0)
    }

    @Test func sessionSetupParsesInDash() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/dash") else { return }
        let setup = ShellFrame()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/dash")
        p.arguments = ["-c", setup.wrapStandalone(ShellFrame.sessionSetup)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let r = try #require(setup.parse(Self.rendered(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))))
        #expect(r.output == "other")
        #expect(r.exitCode == 0)
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh", "/bin/sh", "/bin/dash"])
    func recoversOutputExitCodeAndCwd(shell: String) throws {
        let frame = ShellFrame()
        let r = try #require(frame.parse(try simulate(shell, frame, "cd /usr; echo hello; echo oops >&2; false")))
        #expect(r.output == "hello\noops")
        #expect(r.exitCode == 1)
        #expect(r.workingDirectory == "/usr")
        #expect(r.sawStart)
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh", "/bin/sh"])
    func handlesCommentsHeredocsAndMissingTrailingNewline(shell: String) throws {
        let frame = ShellFrame()
        let script = "cat <<'EOF'\nline one\nEOF\nprintf 'no newline' # trailing comment"
        let r = try #require(frame.parse(try simulate(shell, frame, script)))
        #expect(r.output == "line one\nno newline")
        #expect(r.exitCode == 0)
    }

    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func promptHookReportsOnlyOnce(shell: String) throws {
        // The explicit end call reports and clears the marker; a following prompt hook adds nothing.
        let frame = ShellFrame()
        let screen = try simulate(shell, frame, "(exit 7)", extra: "__jgw_e")
        #expect(screen.components(separatedBy: frame.endPrefix).count == 2)
        #expect(frame.parse(screen)?.exitCode == 7)
    }

    @Test func emptyOutput() throws {
        let frame = ShellFrame()
        let r = try #require(frame.parse(try simulate("/bin/bash", frame, "true")))
        #expect(r.output == "")
        #expect(r.exitCode == 0)
    }

    @Test func controlCharactersAreBase64Encoded() throws {
        let frame = ShellFrame()
        #expect(frame.wrap("printf 'a\u{07}b'").contains("base64 -d"))
        #expect(!frame.wrap("echo 'tab\there'").contains("base64"))
    }

    @Test func echoedCommandIsNotMistakenForMarkers() {
        let frame = ShellFrame()
        #expect(frame.parse("user@host:~$ " + frame.wrap("sleep 100")) == nil)
        #expect(frame.parse("user@host:~$ " + frame.wrapStandalone("sleep 100")) == nil)
    }

    @Test func stillRunningCommandHasNoExitCode() {
        let frame = ShellFrame()
        let r = frame.parse("$ cmd\n\(frame.startMarker)\npartial\n")
        #expect(r?.exitCode == nil)
        #expect(r?.output == "partial")
    }

    @Test func outputTailIsKept() {
        let s = TextLimit.tail("abcdef", limit: 2)
        #expect(s.hasSuffix("\nef"))
        #expect(s.contains("4 characters omitted"))
    }

    @Test func textActionEscaping() {
        #expect(TerminalEscape.textAction("a\\b\r\u{03}") == "text:a\\\\b\\x0d\\x03")
    }
}

@Suite struct AgentSocketTests {
    @Test func requestRoundTripsThroughSocket() async throws {
        let path = "/tmp/jgw-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AgentSocketServer(path: path) { req in
            AgentResponse(text: "\(req.tool.rawValue) \(req.host ?? "") \(req.command ?? "")", isError: req.host == nil)
        }
        try server.start()
        defer { server.stop() }
        #expect(AgentSocketServer.isListening(path))

        let reply = try await Task.detached {
            try AgentSocket.send(AgentRequest(tool: .runCommand, host: "web", command: "uptime"), path: path, timeout: 5)
        }.value
        #expect(reply == AgentResponse(text: "run_command web uptime"))

        let err = try await Task.detached { try AgentSocket.send(AgentRequest(tool: .readScreen), path: path, timeout: 5) }.value
        #expect(err.isError)
    }

    @Test func missingSocketReportsNotRunning() {
        do {
            _ = try AgentSocket.send(AgentRequest(tool: .listSessions), path: "/tmp/jgw-none-\(UUID().uuidString.prefix(8)).sock", timeout: 1)
            Issue.record("expected failure")
        } catch let e as AgentSocketError {
            #expect(e.isNotRunning)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
