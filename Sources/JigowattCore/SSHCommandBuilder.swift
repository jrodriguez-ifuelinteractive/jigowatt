import Foundation

/// Builds argv/environment for /usr/bin/ssh. The system ssh is used on purpose so that
/// ~/.ssh/config, agents, known_hosts and keys behave exactly as they do in a normal shell.
public enum SSHCommandBuilder {
    public static let sshPath = "/usr/bin/ssh"

    public enum Mode: Sendable {
        /// Interactive terminal session (PTY).
        case interactive
        /// Non-interactive remote command for the agent.
        case agentCommand(connectTimeout: Int)
    }

    /// Arguments after the executable name.
    public static func arguments(for host: SSHHost, mode: Mode, remoteCommand: String? = nil) -> [String] {
        var args: [String] = []

        if let port = host.port { args += ["-p", String(port)] }
        if !host.username.isEmpty { args += ["-l", host.username] }
        if !host.identityFile.isEmpty {
            args += ["-i", (host.identityFile as NSString).expandingTildeInPath]
        }
        for option in host.extraOptions {
            let trimmed = option.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { args += ["-o", trimmed] }
        }

        if host.authMethod == .password {
            // The askpass helper answers once; don't loop on a wrong password.
            args += ["-o", "NumberOfPasswordPrompts=1"]
        }

        switch mode {
        case .interactive:
            args.append("-t")
        case .agentCommand(let timeout):
            args += [
                "-T",
                "-o", "ConnectTimeout=\(timeout)",
                // Nobody can answer a host-key prompt; connect once from the app first.
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(JigowattPaths.controlPath)",
                "-o", "ControlPersist=60s",
                "-o", "ServerAliveInterval=15",
            ]
            if host.authMethod == .keyOrAgent {
                // Fail instead of hanging on a password/passphrase prompt.
                args += ["-o", "BatchMode=yes"]
            }
        }

        args += ["--", host.hostname]
        if let remoteCommand { args.append(remoteCommand) }
        return args
    }

    /// Environment additions that make ssh fetch the password via our askpass helper.
    public static func askpassEnvironment(for host: SSHHost, helperPath: String, interactive: Bool) -> [String: String] {
        guard host.authMethod == .password else { return [:] }
        var env = [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            AskpassEnv.hostID: host.id.uuidString,
        ]
        if interactive { env[AskpassEnv.interactive] = "1" }
        return env
    }
}

public enum AskpassEnv {
    public static let hostID = "JIGOWATT_HOST_ID"
    public static let interactive = "JIGOWATT_INTERACTIVE"
}
