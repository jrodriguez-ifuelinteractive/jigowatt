import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Opens each game in its own window; opening a game that is already open just brings it forward.
@MainActor
enum GameLauncher {
    private static var windows: [String: NSWindow] = [:]

    static func open(_ game: GameInfo) {
        if let window = windows[game.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: game.width, height: game.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = game.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 520)
        window.contentView = NSHostingView(rootView: GameWebView(game: game).ignoresSafeArea())
        window.center()
        windows[game.id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Drop the web view right away so the game's audio stops with the window.
                windows[game.id]?.contentView = nil
                windows[game.id] = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Serves jigowatt-game://<game id>/<path> from that game's folder, giving each game
/// its own origin so localStorage (high scores, options) persists between launches.
final class GameSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "jigowatt-game"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let id = url.host, let game = GameCatalog.game(id), let root = GameCatalog.root else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let dir = root.appendingPathComponent(game.id, isDirectory: true).standardizedFileURL
        let path = url.path.isEmpty || url.path == "/" ? game.entry : String(url.path.dropFirst())
        let file = dir.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(dir.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct GameWebView: NSViewRepresentable {
    let game: GameInfo

    func makeNSView(context: Context) -> FocusedWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(GameSchemeHandler(), forURLScheme: GameSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = FocusedWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground") // no white flash before the page paints
        #if DEBUG
        if #available(macOS 13.3, *) { web.isInspectable = true }
        #endif
        web.load(URLRequest(url: URL(string: "\(GameSchemeHandler.scheme)://\(game.id)/\(game.entry)")!))
        return web
    }

    func updateNSView(_ web: FocusedWebView, context: Context) {}

    static func dismantleNSView(_ web: FocusedWebView, coordinator: ()) {
        // Tear the page down so audio stops as soon as the window closes.
        web.loadHTMLString("", baseURL: nil)
    }
}

/// Takes keyboard focus when its window appears so the game receives keys immediately.
final class FocusedWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
