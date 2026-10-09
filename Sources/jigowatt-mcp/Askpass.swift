import Foundation
import JigowattCore

enum Askpass {
    /// Prints the answer for ssh on stdout. Returns the process exit code.
    static func run(hostID: String, prompt: String) -> Int32 {
        let interactive = ProcessInfo.processInfo.environment[AskpassEnv.interactive] == "1"
        let lower = prompt.lowercased()

        if lower.contains("password"), let id = UUID(uuidString: hostID), let password = KeychainStore.password(for: id) {
            print(password)
            return 0
        }
        // Agent runs never prompt a human.
        guard interactive else { return 1 }

        if lower.contains("(yes/no") {
            guard let answer = dialog(prompt, buttons: ["No", "Yes"], hidden: false) else { return 1 }
            print(answer == "Yes" ? "yes" : "no")
            return 0
        }
        guard let answer = dialog(prompt, buttons: ["Cancel", "OK"], hidden: true) else { return 1 }
        print(answer)
        return 0
    }

    /// Shows a dialog through osascript. Returns the button (for yes/no) or the typed text.
    private static func dialog(_ prompt: String, buttons: [String], hidden: Bool) -> String? {
        let buttonList = buttons.map { "\"\($0)\"" }.joined(separator: ", ")
        let script: [String]
        if hidden {
            script = [
                "on run argv",
                "set r to display dialog (item 1 of argv) default answer \"\" with hidden answer buttons {\(buttonList)} default button \"OK\" with title \"Jigowatt\"",
                "return text returned of r",
                "end run",
            ]
        } else {
            script = [
                "on run argv",
                "set r to display dialog (item 1 of argv) buttons {\(buttonList)} default button \"No\" with title \"Jigowatt\"",
                "return button returned of r",
                "end run",
            ]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = script.flatMap { ["-e", $0] } + [prompt]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
