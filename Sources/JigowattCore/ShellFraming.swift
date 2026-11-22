import Foundation

/// Wraps an agent command typed into an interactive remote shell with start/end marker
/// lines, and parses the terminal text to recover the output, exit status and cwd.
///
/// Each agent session first runs `sessionSetup` (framed with `wrapStandalone`), which defines
/// two small helpers so later commands only show ` __jgw_b <id>; {` … `}; __jgw_e` around them:
/// - `__jgw_b` prints the start marker; `__jgw_e` prints the end marker with `$?` and `$PWD`.
/// - On bash/zsh `__jgw_e` is also the prompt hook, so a command interrupted with Ctrl-C (which
///   aborts the rest of the command line) still reports back, with exit 130.
/// Markers are printed as concealed text, so they show as blank lines in the tab. The start
/// marker first clears its line: shells without a line editor (dash) leave `> ` continuation
/// prompts there. Parsing only
/// accepts whole-line matches, and the echoed command line never contains a full marker.
/// Needs a POSIX-style shell on the remote side (bash, zsh, sh, ksh, dash).
public struct ShellFrame: Sendable, Equatable {
    public let nonce: String

    public init(nonce: String = ShellFrame.makeNonce()) {
        self.nonce = nonce
    }

    public static func makeNonce() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    public var startMarker: String { "__JGW_\(nonce)__S" }
    public var endPrefix: String { "__JGW_\(nonce)__E_" }

    /// Defines the helpers, disables `!` history expansion, installs the prompt hook on
    /// bash/zsh, and prints which kind of shell it found ("bash", "zsh", "other").
    /// Shell-specific syntax sits inside `eval` so plain POSIX shells (dash) can still parse it.
    public static let sessionSetup = """
        __jgw_b() { __JGW_N="__JGW_$1"; printf '\\r\\033[K\\033[8m%s__S\\033[0m\\n' "$__JGW_N"; }
        __jgw_e() { __jgw_s=$?; if [ -n "${__JGW_N-}" ]; then printf '\\n\\033[8m%s__E_%s_%s\\033[0m\\n' "$__JGW_N" "$__jgw_s" "$PWD"; unset __JGW_N; fi; return $__jgw_s; }
        if [ -n "${ZSH_VERSION-}" ]; then eval 'setopt no_bang_hist; PROMPT_EOL_MARK=""; precmd_functions=(__jgw_e $precmd_functions)'; echo zsh
        elif [ -n "${BASH_VERSION-}" ]; then eval 'set +H; PROMPT_COMMAND="__jgw_e${PROMPT_COMMAND:+; $PROMPT_COMMAND}"'; echo bash
        else echo other; fi
        """

    /// Whether `sessionSetup` output means a prompt hook was installed.
    public static func setupInstalledPromptHook(_ output: String) -> Bool {
        let kind = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == "zsh" || kind == "bash"
    }

    /// Text to paste into a shell that has run `sessionSetup` (send Enter afterwards).
    /// The leading space keeps it out of history on shells configured with ignorespace.
    public func wrap(_ command: String) -> String {
        // `}` goes on its own line so trailing comments, `&` or heredocs in the command still parse.
        " __jgw_b \(nonce); {\n\(Self.body(command))\n}; __jgw_e"
    }

    /// Self-contained form that needs no helpers, used to run `sessionSetup` itself.
    /// The marker words are split across printf arguments so the echo never matches.
    public func wrapStandalone(_ command: String) -> String {
        let head = "__JGW_" + nonce.prefix(6), tail = String(nonce.dropFirst(6))
        return " printf '\\r\\033[K%s%s\\n' \(head) \(tail)__S; {\n\(Self.body(command))\n}; printf '\\n%s%s_%s_%s\\n' \(head) \(tail)__E \"$?\" \"$PWD\""
    }

    static func body(_ command: String) -> String {
        var body = command.replacingOccurrences(of: "\r\n", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        if needsEncoding(body) {
            let b64 = Data(body.utf8).base64EncodedString()
            body = "eval \"$(printf %s '\(b64)' | base64 -d)\""
        }
        return body
    }

    /// Control characters (other than newline and tab) would be interpreted by the line editor.
    static func needsEncoding(_ s: String) -> Bool {
        s.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7F }
    }

    public struct Result: Sendable, Equatable {
        public var output: String
        /// nil while the command is still running.
        public var exitCode: Int32?
        public var workingDirectory: String?
        /// False when the start marker scrolled out of the scrollback.
        public var sawStart: Bool
    }

    /// Finds this frame's output in terminal text. Returns nil if the start marker hasn't
    /// appeared yet (command not started) and the end marker isn't there either.
    public func parse(_ screen: String) -> Result? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingTrailingWhitespace() }
        let endIndex = lines.lastIndex { $0.hasPrefix(endPrefix) }
        let searchEnd = endIndex ?? lines.endIndex
        let startIndex = lines[..<searchEnd].lastIndex { $0 == startMarker }
        guard startIndex != nil || endIndex != nil else { return nil }

        let from = startIndex.map { $0 + 1 } ?? lines.startIndex
        var body = Array(lines[from..<searchEnd])
        var exitCode: Int32?
        var cwd: String?
        if let endIndex {
            let rest = lines[endIndex].dropFirst(endPrefix.count)
            if let sep = rest.firstIndex(of: "_") {
                exitCode = Int32(rest[..<sep])
                cwd = String(rest[rest.index(after: sep)...])
            } else {
                exitCode = Int32(rest)
            }
            // The end marker starts with "\n", which leaves one blank line when output ended in a newline.
            if body.last == "" { body.removeLast() }
        } else {
            while body.last == "" { body.removeLast() }
        }
        return Result(output: body.joined(separator: "\n"), exitCode: exitCode,
                      workingDirectory: cwd, sawStart: startIndex != nil)
    }
}

public enum TextLimit {
    /// Keeps the last `limit` characters, since the end of output is usually what matters.
    public static func tail(_ s: String, limit: Int = 100_000) -> String {
        guard s.count > limit else { return s }
        let dropped = s.count - limit
        return "[output truncated: first \(dropped) characters omitted]\n" + String(s.suffix(limit))
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s.removeLast() }
        return String(s)
    }
}

public enum TerminalEscape {
    /// Escapes text for Ghostty's `text:` binding action, which parses Zig string-literal escapes.
    public static func textAction(_ s: String) -> String {
        var out = "text:"
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"
            case 0..<0x20, 0x7F: out += String(format: "\\x%02x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
