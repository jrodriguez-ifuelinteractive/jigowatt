import Darwin
import Foundation

public enum AgentSocketError: Error, LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case closed

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let p): return "Socket path is too long: \(p)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .closed: return "Jigowatt closed the connection without answering."
        }
    }

    /// The app isn't listening (not running, or a stale socket file).
    public var isNotRunning: Bool {
        if case .system("connect", let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }
}

/// Unix-domain socket between `jigowatt-mcp` and the app. One JSON request line per
/// connection, answered by one JSON response line.
public enum AgentSocket {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw AgentSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Sends one request and waits up to `timeout` seconds for the answer.
    public static func send(_ request: AgentRequest, path: String = JigowattPaths.agentSocket, timeout: TimeInterval) throws -> AgentResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("socket", errno) }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw AgentSocketError.system("connect", errno) }
        setTimeout(fd, SO_RCVTIMEO, timeout)
        setTimeout(fd, SO_SNDTIMEO, 10)

        var line = try encoder.encode(request)
        line.append(0x0A)
        try writeAll(fd, line)
        guard let reply = try readLine(fd) else { throw AgentSocketError.closed }
        return try decoder.decode(AgentResponse.self, from: reply)
    }

    static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AgentSocketError.system("write", errno)
                }
                offset += n
            }
        }
    }

    /// Reads until a newline or EOF. Returns nil on EOF with nothing read.
    static func readLine(_ fd: Int32, limit: Int = 16 << 20) throws -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw AgentSocketError.system("read", errno)
            }
            if n == 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl])
                return data
            }
            data.append(contentsOf: buf[0..<n])
        }
        return data.isEmpty ? nil : data
    }
}

/// Listens on the agent socket and hands each request to `handler`.
/// Only connections from the same user are accepted.
public final class AgentSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentRequest) async -> AgentResponse

    public let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1

    public init(path: String = JigowattPaths.agentSocket, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A previous instance may have left the file behind; only remove it if nobody answers.
        if FileManager.default.fileExists(atPath: path) {
            if Self.isListening(path) { throw AgentSocketError.system("bind", EADDRINUSE) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError.system("socket", errno) }
        var addr = try AgentSocket.address(path)
        let oldMask = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard rc == 0 else { let e = errno; close(fd); throw AgentSocketError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw AgentSocketError.system("listen", e) }
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "jigowatt.agent-socket"
        thread.start()
    }

    public func stop() {
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(path)
    }

    public static func isListening(_ path: String = JigowattPaths.agentSocket) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = try? AgentSocket.address(path) else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // listening socket closed
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            AgentSocket.setTimeout(client, SO_RCVTIMEO, 10)

            let handler = self.handler
            Task.detached {
                defer { close(client) }
                let response: AgentResponse
                do {
                    guard let line = try AgentSocket.readLine(client) else { return }
                    let request = try JSONDecoder().decode(AgentRequest.self, from: line)
                    response = await handler(request)
                } catch {
                    response = .error("Bad request: \(error.localizedDescription)")
                }
                guard var out = try? JSONEncoder().encode(response) else { return }
                out.append(0x0A)
                try? AgentSocket.writeAll(client, out)
            }
        }
    }
}
