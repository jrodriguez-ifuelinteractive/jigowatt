import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var duration: TimeInterval
}

/// Runs a single non-interactive command over ssh.
public enum SSHRunner {
    public static let defaultOutputLimit = 100_000

    public static func run(
        host: SSHHost,
        command: String,
        timeout: TimeInterval,
        helperPath: String,
        outputLimit: Int = defaultOutputLimit
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommandBuilder.sshPath)
        process.arguments = SSHCommandBuilder.arguments(
            for: host, mode: .agentCommand(connectTimeout: 10), remoteCommand: command)

        var env = ProcessInfo.processInfo.environment
        env.merge(SSHCommandBuilder.askpassEnvironment(for: host, helperPath: helperPath, interactive: false)) { $1 }
        process.environment = env

        // Never let ssh read our stdin: in the MCP server, stdin is the protocol stream.
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuffer = LimitedBuffer(limit: outputLimit)
        let errBuffer = LimitedBuffer(limit: outputLimit)
        outPipe.fileHandleForReading.readabilityHandler = { h in outBuffer.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errBuffer.append(h.availableData) }

        let start = Date()
        let timedOut = TimeoutFlag()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: CommandResult(
                    exitCode: p.terminationStatus,
                    stdout: outBuffer.string,
                    stderr: errBuffer.string,
                    timedOut: timedOut.value,
                    duration: Date().timeIntervalSince(start)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut.set()
                    process.terminate()
                }
            }
        }
    }
}

/// Thread-safe byte buffer that stops growing past `limit` and notes truncation.
final class LimitedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var dropped = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let room = max(0, limit - data.count)
        data.append(chunk.prefix(room))
        dropped += max(0, chunk.count - room)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        var s = String(decoding: data, as: UTF8.self)
        if dropped > 0 { s += "\n[output truncated: \(dropped) more bytes]" }
        return s
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
