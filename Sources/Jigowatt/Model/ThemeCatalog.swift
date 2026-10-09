import AppKit
import SwiftUI

/// A Ghostty color theme: the colors needed to preview it.
struct GhosttyTheme: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isUserTheme: Bool
    let background: Color
    let foreground: Color
    /// ANSI colors 0–15 (missing entries are clear).
    let palette: [Color]
    let isDark: Bool
}

/// Lists the themes libghostty can load: the ones bundled with the app (Ghostty's
/// resources dir) plus the user's own in ~/.config/ghostty/themes, which win on name clashes.
@MainActor
final class ThemeCatalog: ObservableObject {
    static let shared = ThemeCatalog()

    @Published private(set) var themes: [GhosttyTheme] = []
    @Published private(set) var isLoaded = false

    func loadIfNeeded() {
        guard !isLoaded else { return }
        reload()
    }

    func reload() {
        let dirs: [(URL, Bool)] = [Self.bundledThemesDirectory.map { ($0, false) }, (Self.userThemesDirectory, true)].compactMap { $0 }
        Task.detached(priority: .userInitiated) {
            var byName: [String: GhosttyTheme] = [:]
            for (dir, isUser) in dirs {
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for file in files where !file.lastPathComponent.hasPrefix(".") {
                    if let theme = Self.parse(file, isUser: isUser) { byName[theme.name] = theme }
                }
            }
            let sorted = byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            await MainActor.run {
                self.themes = sorted
                self.isLoaded = true
            }
        }
    }

    func theme(named name: String) -> GhosttyTheme? {
        themes.first { $0.name == name }
    }

    // MARK: Locations

    static var userThemesDirectory: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let base = env.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("ghostty/themes", isDirectory: true)
    }

    /// Inside the .app: Contents/Resources/ghostty/themes. During development (swift run),
    /// fall back to the libghostty build output in vendor/.
    static var bundledThemesDirectory: URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes"), fm.fileExists(atPath: res.path) {
            return res
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.path != "/" {
            let candidate = d.appendingPathComponent("vendor/ghostty/zig-out/share/ghostty/themes")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Parsing

    nonisolated private static func parse(_ url: URL, isUser: Bool) -> GhosttyTheme? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var bg: NSColor?
        var fg: NSColor?
        var palette = [NSColor?](repeating: nil, count: 16)

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": bg = color(value)
            case "foreground": fg = color(value)
            case "palette":
                // palette = N=#rrggbb
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i) { palette[i] = color(parts[1]) }
            default: break
            }
        }
        // Themes without colors (or non-theme files) aren't worth listing.
        guard let bg else { return nil }
        let fgColor = fg ?? (luminance(bg) < 0.5 ? .white : .black)
        return GhosttyTheme(
            name: url.lastPathComponent,
            isUserTheme: isUser,
            background: Color(nsColor: bg),
            foreground: Color(nsColor: fgColor),
            palette: palette.map { $0.map { Color(nsColor: $0) } ?? .clear },
            isDark: luminance(bg) < 0.5)
    }

    nonisolated private static func color(_ value: String) -> NSColor? {
        var hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    nonisolated private static func luminance(_ c: NSColor) -> CGFloat {
        guard let rgb = c.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
