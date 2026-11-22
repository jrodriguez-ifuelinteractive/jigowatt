import AppKit
import SwiftUI
import JigowattCore

/// Objects that outlive the main window: when Jigowatt keeps running in the menu bar,
/// sessions (including agent tabs) stay alive after the window is closed.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let library = HostLibrary()
    let sessions = SessionManager()
    let ui = UIState()
    private(set) lazy var broker = AgentBroker(library: library, sessions: sessions)
}

enum AppPreferences {
    /// Defaults to true when unset; `bool(forKey:)` also accepts "YES"/"NO" launch arguments.
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    static let keepRunningKey = "keepRunningInMenuBar"
    /// Show a menu bar icon and keep running (without a Dock icon) after the window closes.
    static var keepRunning: Bool {
        flag(keepRunningKey)
    }

    static let confirmAgentSessionsKey = "confirmAgentSessions"
    /// Ask before a coding agent opens an ssh session on a host.
    static var confirmAgentSessions: Bool {
        flag(confirmAgentSessionsKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `jigowatt-mcp` launches the app with this flag when an agent needs it.
    static let backgroundFlag = "--background"
    /// Only honored with the menu bar item on; otherwise a background app would have no UI at all,
    /// so it opens its window (without taking focus) instead.
    private var launchedInBackground = CommandLine.arguments.contains(AppDelegate.backgroundFlag) && AppPreferences.keepRunning

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.broker.start() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            self?.windowWillClose(note.object as? NSWindow)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            if let window = note.object as? NSWindow, Self.isAppWindow(window), NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        }

        if launchedInBackground {
            NSApp.setActivationPolicy(.accessory)
            // SwiftUI opens the main window at launch; put it away for a background start.
            DispatchQueue.main.async {
                NSApp.windows.filter(Self.isAppWindow).forEach { $0.close() }
            }
        } else if CommandLine.arguments.contains(Self.backgroundFlag) {
            NSApp.setActivationPolicy(.regular)
        } else {
            // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.broker.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(AppPreferences.keepRunning || launchedInBackground)
    }

    /// Reopening from Finder/Dock/`open` shows the main window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launchedInBackground = false
        return true
    }

    private func windowWillClose(_ window: NSWindow?) {
        guard let window, Self.isAppWindow(window), AppPreferences.keepRunning || launchedInBackground else { return }
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && Self.isAppWindow($0) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Titled app windows (not the status item or menus).
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.className != "NSStatusBarWindow"
    }
}

@main
struct JigowattApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = AppModel.shared.library
    @StateObject private var sessions = AppModel.shared.sessions
    @StateObject private var ui = AppModel.shared.ui
    @AppStorage(AppPreferences.keepRunningKey) private var keepRunning = true

    init() {
        GhosttyRuntime.initialize()
    }

    var body: some Scene {
        Window("Jigowatt", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(sessions)
                .environmentObject(ui)
                .frame(minWidth: 800, minHeight: 480)
        }
        .commands { AppCommands(library: library, sessions: sessions, ui: ui) }

        Window("Agent Activity", id: "activity") {
            ActivityView()
                .frame(minWidth: 640, minHeight: 320)
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Jigowatt", systemImage: "terminal", isInserted: $keepRunning) {
            MenuBarMenu()
                .environmentObject(library)
                .environmentObject(sessions)
        }
    }
}

/// Cross-view UI state reachable from menu commands.
@MainActor
final class UIState: ObservableObject {
    @Published var selectedHostIDs: Set<SSHHost.ID> = []
    @Published var editing: HostEditorDraft?
}

struct AppCommands: Commands {
    @ObservedObject var library: HostLibrary
    @ObservedObject var sessions: SessionManager
    @ObservedObject var ui: UIState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Host…") { ui.editing = HostEditorDraft(host: SSHHost()) }
                .keyboardShortcut("n")
            Button("Connect") {
                for id in ui.selectedHostIDs { if let h = library.host(id) { sessions.open(h) } }
            }
            .keyboardShortcut("o")
            .disabled(ui.selectedHostIDs.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            Button(sessions.selectedID == nil ? "Close Window" : "Close Tab") { sessions.closeSelectedOrWindow() }
                .keyboardShortcut("w")
        }
        CommandMenu("Session") {
            Button("Reconnect") { sessions.selected?.connect() }
                .keyboardShortcut("r")
                .disabled(sessions.selected == nil)
            Divider()
            Button("Next Tab") { sessions.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { sessions.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                Button("Tab \(n)") { sessions.select(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
            }
        }
        CommandGroup(before: .windowList) {
            Button("Agent Activity") { openWindow(id: "activity") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
        }
    }
}

/// The menu bar icon's menu: open tabs (agent tabs marked), hosts to connect to, and app commands.
struct MenuBarMenu: View {
    @EnvironmentObject private var library: HostLibrary
    @EnvironmentObject private var sessions: SessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Jigowatt") { showMain() }
        if !sessions.sessions.isEmpty {
            Divider()
            Section("Sessions") {
                ForEach(sessions.sessions) { session in
                    Button(label(for: session)) { showMain(select: session.id) }
                }
            }
        }
        if !library.hosts.isEmpty {
            Menu("Connect") {
                ForEach(library.grouped(matching: ""), id: \.group) { group in
                    Section(group.group.isEmpty ? "Hosts" : group.group) {
                        ForEach(group.hosts) { host in
                            Button(host.displayName) {
                                sessions.open(host)
                                showMain()
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Button("Agent Activity") {
            openWindow(id: "activity")
            activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Jigowatt") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for session: TerminalSession) -> String {
        var s = session.isAgent ? "✦ \(session.title)" : session.title
        if session.agentBusy { s += " — running" }
        if session.state != .running { s += " — ended" }
        return s
    }

    private func showMain(select id: TerminalSession.ID? = nil) {
        if let id { sessions.selectedID = id }
        openWindow(id: "main")
        activate()
    }

    private func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
