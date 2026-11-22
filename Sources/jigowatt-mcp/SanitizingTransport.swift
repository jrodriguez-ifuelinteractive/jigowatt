import Foundation
import Logging
import MCP

/// Wraps a transport and removes `capabilities.experimental` from incoming `initialize` requests.
///
/// The spec defines `experimental` as a map of arbitrary objects, and Codex sends one
/// (e.g. `{"codex/sandbox-state": {...}}`), but swift-sdk decodes it as `[String: String]`.
/// That makes the whole handshake fail with -32603 and the client never sees any tools.
/// We don't use client experimental capabilities, so dropping the field is safe.
actor SanitizingTransport: Transport {
    private let base: StdioTransport

    let logger: Logger

    init(wrapping base: StdioTransport, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in await base.receive() {
                        continuation.yield(Self.sanitize(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func sanitize(_ data: Data) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["method"] as? String == "initialize",
              var params = json["params"] as? [String: Any],
              var caps = params["capabilities"] as? [String: Any],
              caps["experimental"] != nil
        else { return data }
        caps.removeValue(forKey: "experimental")
        params["capabilities"] = caps
        json["params"] = params
        return (try? JSONSerialization.data(withJSONObject: json)) ?? data
    }
}
