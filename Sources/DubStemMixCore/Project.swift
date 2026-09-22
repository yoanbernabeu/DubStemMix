import Foundation

/// Référence à un fichier, enregistrée de deux façons pour survivre aux déménagements :
/// chemin absolu (le projet seul a bougé) et chemin relatif au document (le dossier entier a bougé).
public struct FileReference: Codable, Equatable, Sendable {
    public var path: String
    public var relativePath: String

    public init(_ url: URL, relativeTo document: URL) {
        path = url.standardizedFileURL.path
        relativePath = Self.relativePath(from: document.deletingLastPathComponent(), to: url)
    }

    /// Le fichier s'il existe encore : d'abord à son chemin absolu, sinon relativement au document.
    public func resolve(relativeTo document: URL) -> URL? {
        let candidates = [
            URL(fileURLWithPath: path),
            document.deletingLastPathComponent().appending(path: relativePath).standardizedFileURL,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    static func relativePath(from folder: URL, to file: URL) -> String {
        let base = folder.standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents
        let shared = zip(base, target).prefix { $0 == $1 }.count
        let up = Array(repeating: "..", count: base.count - shared)
        return (up + target.dropFirst(shared)).joined(separator: "/")
    }
}

/// Un morceau (.dubstem) : quels stems sur quelles tranches, et les réglages d'effets.
/// Les positions de faders, d'envois et de mutes ne sont pas enregistrées : la console physique fait foi.
public struct Project: Codable, Equatable, Sendable {
    public static let fileExtension = "dubstem"

    public struct StemEntry: Codable, Equatable, Sendable {
        public var file: FileReference
        public var strip: Int

        public init(file: FileReference, strip: Int) {
            self.file = file
            self.strip = strip
        }
    }

    /// Plugin AU chargé sur un bus à la place de l'effet intégré.
    public struct SlotEntry: Codable, Equatable, Sendable {
        public var plugin: PluginInfo
        /// État complet du plugin (ses réglages, son preset), tel qu'il le fournit lui-même.
        public var state: Data?
        public var macros: [PluginParameter?]

        public init(plugin: PluginInfo, state: Data?, macros: [PluginParameter?]) {
            self.plugin = plugin
            self.state = state
            self.macros = macros
        }
    }

    public var version = 1
    public var title = ""
    public var duration = 0.0
    public var bpm: Double?
    public var delaySync = false
    public var loop = true
    public var stems: [StemEntry] = []
    /// Fichiers importés mais posés sur aucune tranche.
    public var pool: [FileReference] = []
    /// Paramètres d'effets normalisés 0…1, par nom (`FXParameter.rawValue`).
    public var fx: [String: Double] = [:]
    /// Par bus (`SendBus.key`). Absent des projets d'avant les plugins.
    public var slots: [String: SlotEntry]?
    /// Strip names typed by the user, keyed by strip number ("0"…"7"); the others are derived from file names.
    public var stripNames: [String: String]?

    public init() {}

    public static func load(from url: URL) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Une setlist (.dubset) : une liste ordonnée de projets.
public struct Setlist: Codable, Equatable, Sendable {
    public static let fileExtension = "dubset"

    public var version = 1
    public var name = ""
    public var projects: [FileReference] = []

    public init(name: String = "") { self.name = name }

    public static func load(from url: URL) throws -> Setlist {
        try JSONDecoder().decode(Setlist.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
