import SwiftUI
import JigowattCore

/// Commands the coding agent ran (or tried to run) through the MCP server.
struct ActivityView: View {
    @State private var entries: [AuditEntry] = []
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Table(entries) {
            TableColumn("Time") { e in
                Text(e.timestamp.formatted(date: .abbreviated, time: .standard))
            }
            .width(min: 140, ideal: 160)
            TableColumn("Host", value: \.hostName)
                .width(min: 80, ideal: 120)
            TableColumn("Command") { e in
                Text(e.command)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                    .help(e.command)
            }
            TableColumn("Result") { e in
                Text(resultText(e))
                    .foregroundStyle(e.outcome == "ok" ? Color.secondary : Color.orange)
            }
            .width(min: 90, ideal: 120)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Agent Activity", systemImage: "sparkles",
                                       description: Text("Commands run by your coding agent appear here."))
            }
        }
        .onAppear(perform: load)
        .onReceive(timer) { _ in load() }
        .navigationTitle("Agent Activity")
    }

    private func load() {
        entries = AuditLog().read()
    }

    private func resultText(_ e: AuditEntry) -> String {
        switch e.outcome {
        case "refused": return "refused"
        case "timeout": return "timed out"
        default:
            let code = e.exitCode.map { "exit \($0)" } ?? ""
            let dur = e.durationSeconds.map { String(format: " · %.1fs", $0) } ?? ""
            return code + dur
        }
    }
}
