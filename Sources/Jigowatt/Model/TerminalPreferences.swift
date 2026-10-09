import Foundation

/// App-level terminal preferences (UserDefaults). Anything not set here comes from the user's Ghostty config.
enum TerminalPreferences {
    static let useGhosttyConfigKey = "useGhosttyConfig"
    static let fontSizeKey = "terminalFontSize"
    static let themeKey = "terminalTheme"
    static let lightThemeKey = "terminalLightTheme"

    static var useGhosttyConfig: Bool {
        UserDefaults.standard.object(forKey: useGhosttyConfigKey) as? Bool ?? true
    }

    /// 0 means "use Ghostty's default / the user's Ghostty config".
    static var fontSize: Int {
        UserDefaults.standard.integer(forKey: fontSizeKey)
    }

    /// Empty means "use the theme from the Ghostty config (or Ghostty's default)".
    static var theme: String {
        UserDefaults.standard.string(forKey: themeKey) ?? ""
    }

    /// Optional theme used while macOS is in Light Mode. Empty means use `theme` always.
    static var lightTheme: String {
        UserDefaults.standard.string(forKey: lightThemeKey) ?? ""
    }

    /// The `theme = …` config line for the chosen theme(s), if any.
    static var themeConfigLine: String? {
        let dark = theme, light = lightTheme
        if dark.isEmpty { return nil }
        if light.isEmpty || light == dark { return "theme = \(dark)" }
        return "theme = light:\(light),dark:\(dark)"
    }
}
