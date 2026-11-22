import AppKit
import JigowattCore

/// Asks the user before a coding agent opens (or reopens) an ssh session on a host.
@MainActor
enum AgentApproval {
    /// Unanswered prompts are denied, so a command can't start after the agent stopped waiting.
    static let timeout: TimeInterval = 60

    static func ask(host: SSHHost, command: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            // Run the modal from a fresh main-queue turn rather than inside the caller's task.
            DispatchQueue.main.async {
                continuation.resume(returning: runAlert(host: host, command: command))
            }
        }
    }

    private static func runAlert(host: SSHHost, command: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow the coding agent to connect to \(host.displayName)?"
        var info = "\(host.summary)\n\nThe agent gets its own tab on this host and can run commands there until you close the tab or the connection ends."
        if let command, !command.isEmpty {
            let shown = command.count > 300 ? String(command.prefix(300)) + "…" : command
            info += "\n\nFirst command:\n\(shown)"
        }
        info += "\n\nNot answering within \(Int(timeout)) seconds denies the request."
        alert.informativeText = info
        // "Don't Allow" is the default button so a stray Return can't approve the request.
        alert.addButton(withTitle: "Don't Allow")
        let allow = alert.addButton(withTitle: "Allow")
        allow.keyEquivalent = ""

        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
