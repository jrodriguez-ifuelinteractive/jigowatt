import AppKit
import SwiftUI
import JigowattCore

/// Editable copy of a host; strings for fields that need parsing.
struct HostEditorDraft: Identifiable {
    var id: UUID { host.id }
    var host: SSHHost
    var isNew: Bool
    var port: String
    var tags: String
    var extraOptions: String
    var password = ""
    var hasSavedPassword: Bool

    init(host: SSHHost) {
        self.host = host
        self.isNew = host.hostname.isEmpty
        self.port = host.port.map(String.init) ?? ""
        self.tags = host.tags.joined(separator: ", ")
        self.extraOptions = host.extraOptions.joined(separator: "\n")
        self.hasSavedPassword = !host.hostname.isEmpty && KeychainStore.hasPassword(for: host.id)
    }
}

struct HostEditorView: View {
    @EnvironmentObject private var library: HostLibrary
    @Environment(\.dismiss) private var dismiss
    @State var draft: HostEditorDraft
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.host.name, prompt: Text("web-01"))
                    TextField("Host", text: $draft.host.hostname, prompt: Text("hostname, IP, or ~/.ssh/config alias"))
                    TextField("Port", text: $draft.port, prompt: Text("22"))
                    TextField("User", text: $draft.host.username, prompt: Text("from ~/.ssh/config or your login"))
                }
                Section {
                    HStack {
                        TextField("Group", text: $draft.host.group, prompt: Text("none"))
                        if !library.groups.isEmpty {
                            Menu {
                                ForEach(library.groups, id: \.self) { g in
                                    Button(g) { draft.host.group = g }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    TextField("Tags", text: $draft.tags, prompt: Text("comma separated"))
                }
                Section("Authentication") {
                    Picker("Method", selection: $draft.host.authMethod) {
                        Text("SSH key / agent").tag(AuthMethod.keyOrAgent)
                        Text("Password").tag(AuthMethod.password)
                    }
                    if draft.host.authMethod == .keyOrAgent {
                        HStack {
                            TextField("Identity file", text: $draft.host.identityFile, prompt: Text("optional, e.g. ~/.ssh/id_ed25519"))
                            Button("Choose…", action: chooseKey)
                        }
                    } else {
                        SecureField("Password", text: $draft.password,
                                    prompt: Text(draft.hasSavedPassword ? "saved in Keychain — type to replace" : "stored in the macOS Keychain"))
                    }
                }
                Section {
                    Toggle("Allow coding agent to run commands on this host", isOn: $draft.host.agentAllowed)
                    if draft.host.agentAllowed {
                        Label("Agents connected via MCP can run any command as \(draft.host.username.isEmpty ? "this user" : draft.host.username). Every command is logged in Agent Activity.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Agent access (MCP)")
                }
                Section("Advanced") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra ssh -o options, one per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.extraOptions)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 54)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes (visible to the agent)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.host.notes).frame(height: 54)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.host.hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.host.identityFile = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func save() {
        var host = draft.host
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.name = host.name.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        host.group = host.group.trimmingCharacters(in: .whitespaces)

        let portText = draft.port.trimmingCharacters(in: .whitespaces)
        if portText.isEmpty {
            host.port = nil
        } else if let p = Int(portText), (1...65535).contains(p) {
            host.port = p
        } else {
            error = "Port must be a number between 1 and 65535."
            return
        }
        host.tags = draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        host.extraOptions = draft.extraOptions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        if host.authMethod == .password, !draft.password.isEmpty {
            do {
                try KeychainStore.setPassword(draft.password, for: host.id, label: host.displayName,
                                              trustedApps: [JigowattPaths.helperExecutable.path])
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        library.upsert(host)
        dismiss()
    }
}
