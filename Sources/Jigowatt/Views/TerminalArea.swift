import SwiftUI
import JigowattCore

struct TabBarView: View {
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(sessions.sessions) { session in
                    TabButton(session: session, isSelected: session.id == sessions.selectedID)
                }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabButton: View {
    @EnvironmentObject private var sessions: SessionManager
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.state == .running ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            Button {
                sessions.close(session.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { sessions.selectedID = session.id }
        .onHover { hovering = $0 }
        .help(session.host.summary)
    }
}

struct TerminalArea: View {
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        ZStack {
            if sessions.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Open Sessions", systemImage: "terminal")
                } description: {
                    Text("Double-click a host to connect.")
                }
            }
            // Keep every tab's terminal alive; only the selected one is visible and interactive.
            ForEach(sessions.sessions) { session in
                SessionView(session: session)
                    .opacity(session.id == sessions.selectedID ? 1 : 0)
                    .allowsHitTesting(session.id == sessions.selectedID)
            }
        }
    }
}

private struct SessionView: View {
    @EnvironmentObject private var sessions: SessionManager
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            SurfaceRepresentable(view: session.surfaceView)
                .id(session.generation)
            if case .ended(let code) = session.state {
                HStack {
                    Image(systemName: "bolt.horizontal.circle")
                    Text(code.map { "Session ended (exit \($0))." } ?? "Session ended.")
                    Spacer()
                    Button("Close") { sessions.close(session.id) }
                    Button("Reconnect") { session.connect() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

private struct SurfaceRepresentable: NSViewRepresentable {
    let view: TerminalSurfaceView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== view { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
