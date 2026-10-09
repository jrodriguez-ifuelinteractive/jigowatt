import SwiftUI
import JigowattCore

struct ContentView: View {
    @EnvironmentObject private var library: HostLibrary
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var ui: UIState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if !sessions.sessions.isEmpty {
                    TabBarView()
                    Divider()
                }
                TerminalArea()
            }
        }
        .onAppear {
            if SelfTest.outputDirectory != nil { SelfTest.run(library: library, sessions: sessions) }
        }
        .sheet(item: $ui.editing) { draft in
            HostEditorView(draft: draft)
        }
        .alert("Error", isPresented: Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )) {
            Button("OK") { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: HostLibrary
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var ui: UIState
    @State private var search = ""

    var body: some View {
        List(selection: $ui.selectedHostIDs) {
            ForEach(library.grouped(matching: search), id: \.group) { section in
                Section(section.group.isEmpty ? "Hosts" : section.group) {
                    ForEach(section.hosts) { host in
                        HostRow(host: host).tag(host.id)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter hosts")
        .contextMenu(forSelectionType: SSHHost.ID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            connect(ids)
        }
        .overlay {
            if library.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add the machines you connect to.")
                } actions: {
                    Button("Add Host…") { ui.editing = HostEditorDraft(host: SSHHost()) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { ui.editing = HostEditorDraft(host: SSHHost()) } label: {
                    Label("New Host", systemImage: "plus")
                }
                .help("New host (⌘N)")
                Button { connect(ui.selectedHostIDs) } label: {
                    Label("Connect", systemImage: "play.fill")
                }
                .help("Connect (⌘O)")
                .disabled(ui.selectedHostIDs.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<SSHHost.ID>) -> some View {
        if !ids.isEmpty {
            Button("Connect") { connect(ids) }
            if ids.count == 1, let id = ids.first, let host = library.host(id) {
                Button("Edit…") { ui.editing = HostEditorDraft(host: host) }
                Button("Duplicate") {
                    if let copy = library.duplicate(id) { ui.selectedHostIDs = [copy.id] }
                }
                Button("Copy SSH Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        TerminalSession.shellCommand(for: host),
                        forType: .string)
                }
            }
            Divider()
            let allAllowed = ids.allSatisfy { library.host($0)?.agentAllowed == true }
            Button(allAllowed ? "Disable Agent Access" : "Allow Agent Access") {
                library.setAgentAllowed(ids, !allAllowed)
            }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete(ids) }
        }
    }

    private func connect(_ ids: Set<SSHHost.ID>) {
        for id in ids { if let host = library.host(id) { sessions.open(host) } }
    }

    private func confirmDelete(_ ids: Set<SSHHost.ID>) {
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Delete \(library.host(ids.first)?.displayName ?? "host")?" : "Delete \(ids.count) hosts?"
        alert.informativeText = "Saved passwords for these hosts are also removed from the Keychain."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            library.delete(ids)
            ui.selectedHostIDs.subtract(ids)
        }
    }
}

struct HostRow: View {
    let host: SSHHost

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: host.authMethod == .password ? "key.horizontal" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName).lineLimit(1)
                Text(host.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if host.agentAllowed {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .help("Your coding agent can run commands on this host")
            }
        }
        .padding(.vertical, 2)
    }
}
