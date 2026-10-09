import AppKit
import GhosttyKit
import JigowattCore

/// Owns the single libghostty app instance and routes its callbacks.
///
/// Adapted from Ghostty's own macOS host (macos/Sources/Ghostty/Ghostty.App.swift, MIT license),
/// trimmed to what an SSH session tab needs.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var appearanceObservation: NSKeyValueObservation?

    /// Call once at launch, before any surface is created.
    static func initialize() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("ghostty_init failed")
        }
    }

    private init() {
        config = Self.makeConfig()

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { GhosttyRuntime.shared.tick() } },
            action_cb: { app, target, action in GhosttyRuntime.handleAction(app, target: target, action: action) },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { _, location, content, len, _ in
                GhosttyRuntime.writeClipboard(location: location, content: content, len: len)
            },
            close_surface_cb: { userdata, processAlive in
                guard let view = TerminalSurfaceView.from(userdata) else { return }
                DispatchQueue.main.async { view.onClose?(processAlive) }
            }
        )

        guard let config, let app = ghostty_app_new(&runtime, config) else {
            NSLog("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        applyColorScheme()
        // Lets `theme = light:…,dark:…` follow the macOS appearance.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { GhosttyRuntime.shared.applyColorScheme() }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) } }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) } }
        }
    }

    func applyColorScheme() {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, NSApp.effectiveAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    // MARK: Config

    /// Loads the user's Ghostty config (if enabled), then our overrides on top.
    private static func makeConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        if TerminalPreferences.useGhosttyConfig {
            ghostty_config_load_default_files(cfg)
            ghostty_config_load_recursive_files(cfg)
        }
        if let overrides = writeOverrides() {
            ghostty_config_load_file(cfg, overrides.path)
        }
        ghostty_config_finalize(cfg)

        let count = ghostty_config_diagnostics_count(cfg)
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message { NSLog("ghostty config: %@", String(cString: msg)) }
        }
        return cfg
    }

    /// Settings that must hold for SSH tabs inside this app, regardless of the user's Ghostty config.
    private static func writeOverrides() -> URL? {
        let lines = [
            // Remote hosts rarely have Ghostty's terminfo installed.
            "term = xterm-256color",
            // We show our own "session ended" bar instead of keeping the surface open.
            "wait-after-command = false",
            "confirm-close-surface = false",
            "quit-after-last-window-closed = false",
            // Tabs, windows and splits are handled by Jigowatt, so drop Ghostty's
            // window-management shortcuts and keep only in-terminal ones.
            "keybind = clear",
            "keybind = super+c=copy_to_clipboard",
            "keybind = super+v=paste_from_clipboard",
            "keybind = super+a=select_all",
            "keybind = super+k=clear_screen",
            "keybind = super+equal=increase_font_size:1",
            "keybind = super+plus=increase_font_size:1",
            "keybind = super+minus=decrease_font_size:1",
            "keybind = super+zero=reset_font_size",
            "keybind = super+home=scroll_to_top",
            "keybind = super+end=scroll_to_bottom",
            "keybind = super+page_up=scroll_page_up",
            "keybind = super+page_down=scroll_page_down",
            "keybind = shift+page_up=scroll_page_up",
            "keybind = shift+page_down=scroll_page_down",
            "keybind = super+left=text:\\x01",
            "keybind = super+right=text:\\x05",
            "keybind = super+backspace=text:\\x15",
            "keybind = alt+left=esc:b",
            "keybind = alt+right=esc:f",
        ]
        + (TerminalPreferences.fontSize > 0 ? ["font-size = \(TerminalPreferences.fontSize)"] : [])
        + [TerminalPreferences.themeConfigLine].compactMap { $0 }

        do {
            try JigowattPaths.ensureSupportDirectory()
            let url = JigowattPaths.supportDirectory.appendingPathComponent("ghostty-overrides.conf")
            try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("could not write ghostty overrides: \(error)")
            return nil
        }
    }

    /// Re-reads config (e.g. after the user changes preferences) and applies it to all surfaces.
    func reloadConfig() {
        guard let app, let newConfig = Self.makeConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        if let old = config { ghostty_config_free(old) }
        config = newConfig
    }

    // MARK: Actions

    nonisolated private static func handleAction(_ app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Actions may arrive off the main thread; copy what we need first.
        let view: TerminalSurfaceView? = {
            guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
            return TerminalSurfaceView.from(ghostty_surface_userdata(surface))
        }()

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let ptr = action.action.set_title.title else { return false }
            let title = String(cString: ptr)
            DispatchQueue.main.async { view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let view else { return false }
            let code = action.action.child_exited.exit_code
            DispatchQueue.main.async { view.onChildExited?(Int32(bitPattern: code)) }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.setCursorShape(shape) }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(!visible) }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let data = Data(bytes: ptr, count: Int(u.len))
            guard let str = String(data: data, encoding: .utf8), let url = URL(string: str) else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { NSSound.beep() }
            return true

        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT:
            // Nothing for us to do; acknowledge so libghostty doesn't log.
            return true

        default:
            return false
        }
    }

    // MARK: Clipboard

    nonisolated private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        location == GHOSTTY_CLIPBOARD_STANDARD ? .general : nil
    }

    nonisolated private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let view = TerminalSurfaceView.from(userdata), let surface = view.surface,
              let pb = pasteboard(location) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        // We only serve plain text.
        var wantsText = mimesLen == 0
        if let mimes {
            for i in 0..<mimesLen {
                if let p = mimes[i], String(cString: p).hasPrefix("text/plain") { wantsText = true }
            }
        }
        let text = wantsText ? pb.string(forType: .string) : nil
        if text == nil && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        complete(surface, text: text, list: list, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    nonisolated private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalSurfaceView.from(userdata), let surface = view.surface else { return }
        // Only user-initiated pastes may be confirmed; programs reading the clipboard are denied.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        var text = ""
        let c = confirm.pointee
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
                text = String(decoding: Data(bytes: data, count: item.len), as: UTF8.self)
                break
            }
        }

        let stateBits = UInt(bitPattern: state)
        let surfaceBits = UInt(bitPattern: surface)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Paste multiple lines?"
            alert.informativeText = "The text may run commands on the remote machine as soon as it's pasted.\n\n"
                + String(text.prefix(500)) + (text.count > 500 ? "…" : "")
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            let surface = ghostty_surface_t(bitPattern: surfaceBits)!
            let state = UnsafeMutableRawPointer(bitPattern: stateBits)
            if alert.runModal() == .alertFirstButtonReturn {
                complete(surface, text: text, list: false, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    nonisolated private static func complete(_ surface: ghostty_surface_t, text: String?, list: Bool,
                                             state: UnsafeMutableRawPointer?, confirmed: Bool) {
        let mime = strdup("text/plain;charset=utf-8")!
        defer { free(mime) }
        let available: [UnsafePointer<CChar>?] = list && text != nil ? [UnsafePointer(mime)] : []

        func finish(_ contents: [ghostty_clipboard_content_s]) {
            contents.withUnsafeBufferPointer { cbuf in
                available.withUnsafeBufferPointer { abuf in
                    var done = ghostty_clipboard_complete_s(
                        contents: cbuf.baseAddress, contents_len: cbuf.count,
                        available: abuf.baseAddress, available_len: abuf.count,
                        confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &done, state)
                }
            }
        }

        guard let text else { return finish([]) }
        let utf8 = Array(text.utf8CString)
        utf8.withUnsafeBufferPointer { buf in
            finish([ghostty_clipboard_content_s(mime: mime, data: buf.baseAddress, len: buf.count - 1)])
        }
    }

    nonisolated private static func writeClipboard(location: ghostty_clipboard_e,
                                                   content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int) {
        guard let content, len > 0 else { return }
        for i in 0..<len {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
            let text = String(decoding: Data(bytes: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                guard let pb = pasteboard(location) else { return }
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            return
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
