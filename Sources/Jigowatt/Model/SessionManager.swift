import AppKit
import SwiftUI
import JigowattCore

/// One SSH tab, backed by a Ghostty surface running /usr/bin/ssh.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case ended(exitCode: Int32?)
    }

    let id = UUID()
    let host: SSHHost
    /// Opened by the coding agent over MCP. Agent tools only ever touch these tabs.
    let isAgent: Bool
    /// True while an agent command is running in this tab.
    @Published var agentBusy = false
    @Published private(set) var title: String
    @Published private(set) var state: State = .running
    /// Bumped whenever a new surface view replaces the old one (reconnect).
    @Published private(set) var generation = 0
    private(set) var surfaceView: TerminalSurfaceView?
    private var lastExitCode: Int32?

    init(host: SSHHost, isAgent: Bool = false) {
        self.host = host
        self.isAgent = isAgent
        self.title = host.displayName
        connect()
    }

    func connect() {
        surfaceView?.destroy()
        surfaceView = nil
        lastExitCode = nil

        guard let app = GhosttyRuntime.shared.app else {
            state = .ended(exitCode: nil)
            return
        }

        let view = TerminalSurfaceView(app: app, launch: .init(
            command: Self.shellCommand(for: host, mode: isAgent ? .agentSession : .interactive),
            environment: SSHCommandBuilder.askpassEnvironment(
                for: host, helperPath: JigowattPaths.helperExecutable.path, interactive: !isAgent),
            fontSize: Float(TerminalPreferences.fontSize)))
        view.onTitleChange = { [weak self] title in
            // Agent tabs keep the host name; the shell would title them with the typed scaffolding.
            guard let self, !self.isAgent, !title.isEmpty else { return }
            self.title = title
        }
        // Ghostty keeps the surface open (instead of closing it) when the child exits very quickly,
        // e.g. ssh failing to connect, so treat the exit itself as the end of the session.
        view.onChildExited = { [weak self] code in
            self?.lastExitCode = code
            self?.markEnded()
        }
        view.onClose = { [weak self] _ in self?.markEnded() }

        surfaceView = view
        title = host.displayName
        state = .running
        generation += 1
    }

    private func markEnded() {
        state = .ended(exitCode: lastExitCode)
    }

    func close() {
        surfaceView?.destroy()
        surfaceView = nil
    }

    func focus() {
        guard let view = surfaceView else { return }
        view.window?.makeFirstResponder(view)
    }

    /// libghostty runs the command through `bash -c "exec -l …"` on macOS, so quote each argument.
    static func shellCommand(for host: SSHHost, mode: SSHCommandBuilder.Mode = .interactive) -> String {
        let args = [SSHCommandBuilder.sshPath] + SSHCommandBuilder.arguments(for: host, mode: mode)
        return args.map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The open tabs and which one is selected.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID? {
        didSet { updateVisibility() }
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    func open(_ host: SSHHost) {
        if let game = GameCatalog.game(unlockedBy: host) {
            GameLauncher.open(game)
            return
        }
        let session = TerminalSession(host: host)
        sessions.append(session)
        selectedID = session.id
    }

    /// Opens a tab for the agent without taking focus from the user's current tab.
    func openAgentSession(_ host: SSHHost) -> TerminalSession {
        let session = TerminalSession(host: host, isAgent: true)
        // Give the terminal a real size even if the window is closed (background mode).
        if let view = session.surfaceView { view.setFrameSize(view.frame.size) }
        sessions.append(session)
        if selectedID == nil { selectedID = session.id } else { session.surfaceView?.setVisible(false) }
        return session
    }

    func close(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].close()
        sessions.remove(at: index)
        if selectedID == id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }

    func closeSelectedOrWindow() {
        if let selectedID {
            close(selectedID)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func selectNext(_ offset: Int) {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedID } ?? 0
        let next = (current + offset + sessions.count) % sessions.count
        selectedID = sessions[next].id
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    func closeAll() {
        sessions.forEach { $0.close() }
        sessions.removeAll()
        selectedID = nil
    }

    private func updateVisibility() {
        for s in sessions { s.surfaceView?.setVisible(s.id == selectedID) }
        DispatchQueue.main.async { [weak self] in self?.selected?.focus() }
    }
}
