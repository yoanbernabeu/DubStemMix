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

    /// The file among `candidates` (files found by name, e.g. in a folder and its subfolders) that is this one:
    /// the only one with its name, or else the only one in a folder named like its old folder. Stems of different
    /// songs often share names (drums.wav, bass.wav…): never a guess between two.
    public func bestMatch(in candidates: [String: [URL]]) -> URL? {
        guard let found = candidates[fileName], !found.isEmpty else { return nil }
        if found.count == 1 { return found[0] }
        let folderName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        let sameFolder = found.filter { $0.deletingLastPathComponent().lastPathComponent == folderName }
        return sameFolder.count == 1 ? sameFolder[0] : nil
    }

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
    /// Strips marked KEEP: they survive the DROP gesture (PRD § 11.6).
    public var keep: [Int]?
    /// Built-in reverb model (`ReverbModel.rawValue`) and dub throw target (`ThrowTarget.rawValue`), PRD § 11.4.
    public var reverbModel: String?
    public var throwTarget: String?
    /// Built-in effect on bus 3 (`Bus3Model.rawValue`), PRD § 11.5.
    public var bus3Model: String?
    /// Bus-to-bus sends (issue #1): source `SendBus.key` → target key or "none". Absent (older projects) = DLY→REV only.
    public var busSends: [String: String]?

    /// A strip insert (PRD § 11.5): a built-in insert with its normalized values, or a plugin with its state.
    public struct InsertEntry: Codable, Equatable, Sendable {
        public var kind: String?
        public var values: [Double]?
        public var plugin: PluginInfo?
        public var state: Data?
        public var macros: [PluginParameter?]?

        public init(kind: String, values: [Double]) {
            self.kind = kind
            self.values = values
        }

        public init(plugin: PluginInfo, state: Data?, macros: [PluginParameter?]) {
            self.plugin = plugin
            self.state = state
            self.macros = macros
        }
    }

    /// Per strip number ("0"…"7").
    public var inserts: [String: InsertEntry]?

    public init() {}

    /// The song's own rack (see `Rack`).
    public var rack: Rack {
        get { Rack(reverbModel: reverbModel, bus3Model: bus3Model, busSends: busSends, slots: slots) }
        set {
            reverbModel = newValue.reverbModel
            bus3Model = newValue.bus3Model
            busSends = newValue.busSends
            slots = newValue.slots
        }
    }

    public static func load(from url: URL) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What is patched on the buses: the reverb and bus 3 effects, the bus-to-bus sends, the plugins on the buses.
/// Same encoding as in `Project`. In a setlist it belongs to the setlist, not to each song: the rack stays wired
/// all night, so going from one song to the next never rewires the audio graph and the effect tails go on.
public struct Rack: Codable, Equatable, Sendable {
    public var reverbModel: String?
    public var bus3Model: String?
    public var busSends: [String: String]?
    public var slots: [String: Project.SlotEntry]?

    public init(reverbModel: String? = nil, bus3Model: String? = nil, busSends: [String: String]? = nil,
                slots: [String: Project.SlotEntry]? = nil) {
        self.reverbModel = reverbModel
        self.bus3Model = bus3Model
        self.busSends = busSends
        self.slots = slots
    }

    /// Same effects and plugins, patched the same way, whatever the plugins' current settings.
    public func isWiredLike(_ other: Rack) -> Bool {
        func plugins(_ rack: Rack) -> [String: String] { (rack.slots ?? [:]).mapValues(\.plugin.id) }
        return (reverbModel ?? "plate") == (other.reverbModel ?? "plate")
            && (bus3Model ?? "phaser") == (other.bus3Model ?? "phaser")
            && BusRouting(projectValue: busSends) == BusRouting(projectValue: other.busSends)
            && plugins(self) == plugins(other)
    }
}

/// Une setlist (.dubset) : une liste ordonnée de projets.
public struct Setlist: Codable, Equatable, Sendable {
    public static let fileExtension = "dubset"

    public var version = 1
    public var name = ""
    public var projects: [FileReference] = []
    /// The rack the whole set plays through (absent until a first song of the setlist is opened, and in setlists
    /// saved before it existed).
    public var rack: Rack?

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
