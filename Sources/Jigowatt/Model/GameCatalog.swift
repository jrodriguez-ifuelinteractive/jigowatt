import Foundation
import JigowattCore

/// An HTML5 game bundled under Resources/Games/<id>/ with a manifest.json.
/// Games are easter eggs: connecting to one of a game's `secretHosts` launches it instead of SSH.
struct GameInfo: Identifiable, Hashable, Decodable {
    var id: String = ""
    let name: String
    var entry: String = "index.html"
    var width: Double = 960
    var height: Double = 760
    var secretHosts: [String] = []

    private enum CodingKeys: String, CodingKey { case name, entry, width, height, secretHosts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? entry
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? height
        secretHosts = try c.decodeIfPresent([String].self, forKey: .secretHosts) ?? []
    }
}

/// Discovers games by scanning the Games directory; adding a game is just adding a folder.
enum GameCatalog {
    static let root: URL? = {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Games", isDirectory: true),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        // `swift run` has no app bundle; use the source tree (Sources/Jigowatt/Model/ -> repo root).
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent("Resources/Games", isDirectory: true)
        return fm.fileExists(atPath: source.path) ? source : nil
    }()

    static let all: [GameInfo] = {
        guard let root,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return dirs.compactMap { dir -> GameInfo? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  var game = try? JSONDecoder().decode(GameInfo.self, from: data)
            else { return nil }
            game.id = dir.lastPathComponent
            return game
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func game(_ id: String) -> GameInfo? { all.first { $0.id == id } }

    /// The game unlocked by a host whose name or hostname is a secret word ("88mph", "88 MPH", "OUTATIME"…).
    static func game(unlockedBy host: SSHHost) -> GameInfo? {
        let normalize = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let candidates = Set([host.name, host.hostname].map(normalize).filter { !$0.isEmpty })
        guard !candidates.isEmpty else { return nil }
        return all.first { game in game.secretHosts.contains { candidates.contains(normalize($0)) } }
    }
}
