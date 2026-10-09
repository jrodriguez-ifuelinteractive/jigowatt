import AppKit
import SwiftUI
import JigowattCore

struct SettingsView: View {
    var body: some View {
        TabView {
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            MCPSettings().tabItem { Label("Agent (MCP)", systemImage: "sparkles") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

private struct TerminalSettings: View {
    @AppStorage(TerminalPreferences.useGhosttyConfigKey) private var useGhosttyConfig = true
    @AppStorage(TerminalPreferences.fontSizeKey) private var fontSize = 0

    var body: some View {
        Form {
            ThemePickerSection()

            Section("Font") {
                Stepper(value: $fontSize, in: 0...48) {
                    Text(fontSize == 0 ? "Size: Ghostty default" : "Size: \(fontSize) pt")
                }
            }

            Section("Ghostty config") {
                Toggle("Use my Ghostty config (~/.config/ghostty/config)", isOn: $useGhosttyConfig)
                Text("Settings here override your config. Window, tab and split shortcuts are managed by Jigowatt.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Ghostty Config") {
                        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ghostty/config")
                        if !FileManager.default.fileExists(atPath: url.path) {
                            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            FileManager.default.createFile(atPath: url.path, contents: Data())
                        }
                        NSWorkspace.shared.open(url)
                    }
                    Button("Reload Config") { GhosttyRuntime.shared.reloadConfig() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: useGhosttyConfig) { GhosttyRuntime.shared.reloadConfig() }
        .onChange(of: fontSize) { GhosttyRuntime.shared.reloadConfig() }
    }
}

private struct ThemePickerSection: View {
    @StateObject private var catalog = ThemeCatalog.shared
    @AppStorage(TerminalPreferences.themeKey) private var theme = ""
    @AppStorage(TerminalPreferences.lightThemeKey) private var lightTheme = ""
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var editingLight = false

    enum Filter: String, CaseIterable { case all = "All", dark = "Dark", light = "Light" }

    private var separateLight: Binding<Bool> {
        Binding(
            get: { !lightTheme.isEmpty },
            set: { on in
                if on {
                    lightTheme = catalog.themes.first { !$0.isDark && $0.name.contains(theme.split(separator: " ").first.map(String.init) ?? "") }?.name
                        ?? catalog.themes.first { !$0.isDark }?.name ?? theme
                    if theme.isEmpty { theme = catalog.themes.first { $0.isDark }?.name ?? "" }
                    editingLight = true
                    filter = .light
                } else {
                    lightTheme = ""
                    editingLight = false
                    filter = .all
                }
            })
    }

    /// The preference the list currently edits.
    private var selection: Binding<String> {
        editingLight && !lightTheme.isEmpty ? $lightTheme : $theme
    }

    private var visibleThemes: [GhosttyTheme] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return catalog.themes.filter { t in
            (filter == .all || (filter == .dark) == t.isDark)
                && (q.isEmpty || t.name.localizedCaseInsensitiveContains(q))
        }
    }

    private func row(_ content: ThemeRow, id: String, action: @escaping () -> Void) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(content.isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .id(id)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let target = selection.wrappedValue
        // Wait a beat so the List has laid out its rows before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(target, anchor: .center) }
    }

    var body: some View {
        Section {
            Toggle("Use a different theme in Light Mode", isOn: separateLight)
            if !lightTheme.isEmpty {
                Picker("Editing", selection: $editingLight) {
                    Text("Dark Mode: \(theme)").tag(false)
                    Text("Light Mode: \(lightTheme)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: editingLight) { filter = editingLight ? .light : .dark }
            }

            HStack {
                TextField("Search", text: $search, prompt: Text("Search \(catalog.themes.count) themes"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            ScrollViewReader { proxy in
                // ScrollView rather than List: a List nested in a grouped Form can't scrollTo reliably.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if lightTheme.isEmpty && search.isEmpty {
                            row(ThemeRow(theme: nil, isSelected: theme.isEmpty), id: "") { theme = "" }
                        }
                        ForEach(visibleThemes) { t in
                            row(ThemeRow(theme: t, isSelected: selection.wrappedValue == t.name), id: t.name) {
                                selection.wrappedValue = t.name
                            }
                        }
                    }
                }
                .frame(height: 280)
                .onAppear {
                    catalog.loadIfNeeded()
                    if catalog.isLoaded { scrollToSelection(proxy) }
                }
                .onChange(of: catalog.isLoaded) { scrollToSelection(proxy) }
                .onChange(of: editingLight) { scrollToSelection(proxy) }
            }

            HStack {
                Text("Add your own themes to ~/.config/ghostty/themes.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Themes Folder") {
                    let dir = ThemeCatalog.userThemesDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                Button("Refresh") { catalog.reload() }
            }
        } header: {
            Text("Theme")
        }
        .onChange(of: theme) { GhosttyRuntime.shared.reloadConfig() }
        .onChange(of: lightTheme) { GhosttyRuntime.shared.reloadConfig() }
    }
}

private struct ThemeRow: View {
    /// nil = "use Ghostty config / default".
    let theme: GhosttyTheme?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let theme {
                ThemeSwatch(theme: theme)
                Text(theme.name)
                if theme.isUserTheme {
                    Text("custom")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .frame(width: 92, height: 26)
                    .overlay(Image(systemName: "gearshape").foregroundStyle(.secondary))
                Text("From Ghostty config (or Ghostty default)")
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ThemeSwatch: View {
    let theme: GhosttyTheme

    var body: some View {
        HStack(spacing: 5) {
            Text("Aa")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.foreground)
            // Normal ANSI colors 1–6 give a quick sense of the palette.
            HStack(spacing: 2) {
                ForEach(1..<7) { i in
                    Circle().fill(theme.palette[i]).frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 92, height: 26, alignment: .leading)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

private struct MCPSettings: View {
    private var helperPath: String { JigowattPaths.helperExecutable.path }

    private var claudeCommand: String {
        "claude mcp add --scope user jigowatt -- \"\(helperPath)\""
    }

    private var copilotCommand: String {
        "copilot mcp add jigowatt -- \"\(helperPath)\""
    }

    private var codexCommand: String {
        "codex mcp add jigowatt -- \"\(helperPath)\""
    }

    var body: some View {
        Form {
            Section {
                Text("Coding agents can list your hosts and run commands on hosts where you've turned on **Allow coding agent**. Every command is logged in Window → Agent Activity.")
                    .fixedSize(horizontal: false, vertical: true)
                if !FileManager.default.isExecutableFile(atPath: helperPath) {
                    Label("MCP binary not found at this path. Build with `make app`.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("Claude Code") {
                CopyableText(text: claudeCommand)
            }
            Section("GitHub Copilot CLI") {
                CopyableText(text: copilotCommand)
            }
            Section("Codex CLI") {
                CopyableText(text: codexCommand)
            }
            Section("Files") {
                HStack {
                    Button("Show Hosts File") { NSWorkspace.shared.activateFileViewerSelecting([JigowattPaths.hostsFile]) }
                    Button("Show Audit Log") { NSWorkspace.shared.activateFileViewerSelecting([JigowattPaths.auditLog]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CopyableText: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        }
    }
}
