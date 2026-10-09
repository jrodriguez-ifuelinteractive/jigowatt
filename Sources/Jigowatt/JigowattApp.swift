import AppKit
import SwiftUI
import JigowattCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct JigowattApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = HostLibrary()
    @StateObject private var sessions = SessionManager()
    @StateObject private var ui = UIState()

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
