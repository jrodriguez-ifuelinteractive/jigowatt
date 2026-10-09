import AppKit
import CoreImage
import GhosttyKit
import IOSurface
import SwiftUI

/// Smoke test for the embedded terminal, enabled with JIGOWATT_SELFTEST=<output dir>.
/// Connects the first host, types a command, then writes the terminal text and
/// snapshots of the window and of Ghostty's rendered surface, and quits.
@MainActor
enum SelfTest {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["JIGOWATT_SELFTEST"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(library: HostLibrary, sessions: SessionManager) {
        guard let out = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(to: out.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8) }

        guard let host = library.hosts.first else { note("FAIL no hosts"); NSApp.terminate(nil); return }
        note("connecting \(host.displayName)")
        sessions.open(host)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let session = sessions.selected, let view = session.surfaceView, let surface = view.surface else {
                note("FAIL no surface"); NSApp.terminate(nil); return
            }
            note("first responder is surface: \(view.window?.firstResponder === view)")
            let cmd = "echo hello-from-$((40+2)); printf '\\e[1;32mgreen\\e[0m\\n'; tput cols; tput lines"
            cmd.withCString { ghostty_surface_text(surface, $0, UInt(cmd.utf8.count)) }
            if let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                view.keyDown(with: ret)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                note("viewport text:\n" + viewportText(surface))
                note("surface size px: \(view.convertToBacking(view.bounds).size), session state: \(session.state)")
                snapshotWindow(view.window, to: out.appendingPathComponent("window.png"))
                note("ghostty surface snapshot: \(snapshotSurface(view, to: out.appendingPathComponent("terminal.png")))")
                snapshotSettings(to: out.appendingPathComponent("settings.png")) {
                    note("DONE")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func viewportText(_ surface: ghostty_surface_t) -> String {
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "<read failed>" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Renders the Settings window content offscreen.
    private static func snapshotSettings(to url: URL, then done: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 980), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView())
        window.orderBack(nil)
        // Give the theme catalog time to load and the list to scroll to the selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            snapshotWindow(window, to: url)
            window.orderOut(nil)
            done()
        }
    }

    private static func snapshotWindow(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Ghostty renders into an IOSurface set as layer contents; grab it directly.
    private static func snapshotSurface(_ view: NSView, to url: URL) -> String {
        var layers = [view.layer].compactMap { $0 }
        while let layer = layers.popLast() {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let image = CIImage(ioSurface: contents as! IOSurface)
                let rep = NSBitmapImageRep(ciImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                return "ok \(Int(image.extent.width))x\(Int(image.extent.height))"
            }
            layers += layer.sublayers ?? []
        }
        return "no IOSurface layer found (layer: \(String(describing: view.layer)))"
    }
}
