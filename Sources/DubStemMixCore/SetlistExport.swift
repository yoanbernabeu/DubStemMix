import Foundation

/// A setlist copied into one folder, with everything its songs need, to be played on another Mac:
///
///     SUNDAY SESSION/
///       Sunday Session.dubset
///       PLUGINS.txt                (only when Audio Unit plugins are used: they can't be copied)
///       Roots Steppa/
///         Roots Steppa.dubstem
///         drums.wav, bass.wav…     (the stems and the files kept aside)
///
/// Every file is referenced relatively, so the folder can be moved anywhere. Files that can't be found are not
/// copied: they stay in the songs as they were (still shown as missing, still locatable by name).
public struct SetlistExport: Sendable {
    public struct Copy: Equatable, Sendable {
        public var source: URL
        public var destination: URL
    }

    public struct Report: Equatable, Sendable {
        public var songs = 0
        public var files = 0
        /// Files (or whole songs) that could not be found, hence not exported.
        public var missing: [String] = []
        /// Audio Unit plugins the setlist uses, to install on the other Mac.
        public var plugins: [String] = []
    }

    public let folder: URL
    public let setlistFile: URL
    public private(set) var setlist: Setlist
    public private(set) var projects: [(url: URL, project: Project)] = []
    public private(set) var copies: [Copy] = []
    public private(set) var report = Report()

    /// Plans the export (reads the songs, nothing is written): `folder` is the folder to create.
    public init(setlist source: Setlist, at sourceURL: URL, to folder: URL) {
        self.folder = folder
        setlistFile = folder.appending(path: sourceURL.lastPathComponent)
        setlist = source
        setlist.projects = []
        var songFolders = UniqueNames()
        var plugins: [String: Set<String>] = [:]
        for plugin in (source.rack?.slots ?? [:]).values.map(\.plugin) { plugins[Self.label(plugin), default: []].insert("setlist rack") }

        for reference in source.projects {
            guard let document = reference.resolve(relativeTo: sourceURL), var project = try? Project.load(from: document) else {
                report.missing.append(URL(fileURLWithPath: reference.path).lastPathComponent)
                continue
            }
            let songName = document.deletingPathExtension().lastPathComponent
            let songFolder = folder.appending(path: songFolders.take(songName), directoryHint: .isDirectory)
            let newDocument = songFolder.appending(path: document.lastPathComponent)
            var fileNames = UniqueNames()
            var copied: [URL: URL] = [:] // a file used twice in the song is copied once
            func relocate(_ file: FileReference) -> FileReference {
                guard let found = file.resolve(relativeTo: document)?.standardizedFileURL else {
                    report.missing.append("\(songName): \(file.fileName)")
                    return file
                }
                let destination = copied[found] ?? songFolder.appending(path: fileNames.take(found.lastPathComponent))
                if copied[found] == nil { copies.append(Copy(source: found, destination: destination)) }
                copied[found] = destination
                return FileReference(destination, relativeTo: newDocument)
            }
            for index in project.stems.indices { project.stems[index].file = relocate(project.stems[index].file) }
            project.pool = project.pool.map(relocate)

            let title = project.title.isEmpty ? songName : project.title
            for plugin in (project.slots ?? [:]).values.map(\.plugin) { plugins[Self.label(plugin), default: []].insert("\(title) (bus)") }
            for (strip, insert) in project.inserts ?? [:] {
                guard let plugin = insert.plugin else { continue }
                plugins[Self.label(plugin), default: []].insert("\(title) (insert, strip \((Int(strip) ?? 0) + 1))")
            }
            projects.append((newDocument, project))
            setlist.projects.append(FileReference(newDocument, relativeTo: setlistFile))
        }
        report.songs = projects.count
        report.files = copies.count
        report.plugins = plugins.keys.sorted().map { "\($0) — used by: \(plugins[$0]!.sorted().joined(separator: ", "))" }
    }

    public var totalBytes: Int64 { copies.reduce(0) { $0 + Self.size(of: $1.source) } }

    /// Writes the folder. `progress` receives the fraction copied (by size) after each file.
    /// The folder must not exist yet: an export never replaces anything.
    public func run(progress: (Double) -> Void = { _ in }) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: folder.path) else { throw ExportError.folderExists(folder.lastPathComponent) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try write(progress: progress) } catch {
            try? files.removeItem(at: folder) // created just above: never a half-exported set left behind
            throw error
        }
    }

    private func write(progress: (Double) -> Void) throws {
        let files = FileManager.default
        let total = max(1, totalBytes)
        var done: Int64 = 0
        for copy in copies {
            try Task.checkCancellation()
            try files.createDirectory(at: copy.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: copy.source, to: copy.destination)
            done += Self.size(of: copy.source)
            progress(Double(done) / Double(total))
        }
        for (url, project) in projects {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try project.save(to: url)
        }
        try setlist.save(to: setlistFile)
        if !report.plugins.isEmpty {
            let text = "Audio Unit plugins used by this setlist. Install them on this Mac: without them, "
                + "the built-in effects are used instead (bus) or the insert is bypassed.\n\n"
                + report.plugins.map { "- \($0)" }.joined(separator: "\n") + "\n"
            try text.write(to: folder.appending(path: "PLUGINS.txt"), atomically: true, encoding: .utf8)
        }
    }

    public enum ExportError: LocalizedError {
        case folderExists(String)

        public var errorDescription: String? {
            switch self {
            case let .folderExists(name): "\"\(name)\" already exists, choose another name"
            }
        }
    }

    private static func label(_ plugin: PluginInfo) -> String {
        plugin.manufacturer.isEmpty ? plugin.name : "\(plugin.name) (\(plugin.manufacturer))"
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Two songs (or two stems of a song) with the same name get "name 2", "name 3"… (the extension is kept).
private struct UniqueNames {
    private var taken: Set<String> = []

    mutating func take(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var candidate = name
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(number)\(suffix)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
