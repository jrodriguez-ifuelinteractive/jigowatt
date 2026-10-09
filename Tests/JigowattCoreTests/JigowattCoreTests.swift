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

    @Test func agentCommandUsesBatchModeForKeys() {
        let host = SSHHost(hostname: "db")
        let args = SSHCommandBuilder.arguments(for: host, mode: .agentCommand(connectTimeout: 5), remoteCommand: "uptime")
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("-T"))
        #expect(Array(args.suffix(3)) == ["--", "db", "uptime"])
    }

    @Test func passwordHostsUseAskpassNotBatchMode() {
        let host = SSHHost(hostname: "legacy", authMethod: .password)
        let args = SSHCommandBuilder.arguments(for: host, mode: .agentCommand(connectTimeout: 5), remoteCommand: "ls")
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

@Suite struct SSHRunnerTests {
    @Test func outputIsTruncatedAtLimit() {
        let buffer = LimitedBuffer(limit: 4)
        buffer.append(Data("abcdef".utf8))
        #expect(buffer.string == "abcd\n[output truncated: 2 more bytes]")
    }
}
