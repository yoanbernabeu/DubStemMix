import Foundation

/// A song the setlist workshop offers (PRD § 13), read without opening it.
public struct LibrarySong: Equatable, Identifiable, Sendable {
    public var url: URL
    public var title: String
    public var bpm: Double?
    public var duration: Double

    public var id: URL { url }

    public init(url: URL, title: String, bpm: Double? = nil, duration: Double = 0) {
        self.url = url
        self.title = title
        self.bpm = bpm
        self.duration = duration
    }

    /// The song's project, or nil when it can't be read.
    public init?(reading url: URL) {
        guard let project = try? Project.load(from: url) else { return nil }
        let fallback = url.deletingPathExtension().lastPathComponent
        self.init(url: url.standardizedFileURL, title: project.title.isEmpty ? fallback : project.title,
                  bpm: project.bpm, duration: project.duration)
    }
}

/// Every project found in `folders` (subfolders included) and the `extra` files dropped from the Finder, once each,
/// sorted by title. Files gone or unreadable are left out.
public enum SongLibrary {
    public static func scan(folders: [URL], extra: [URL] = []) -> [LibrarySong] {
        var seen = Set<URL>()
        var songs: [LibrarySong] = []
        func add(_ url: URL) {
            let url = url.standardizedFileURL
            guard url.pathExtension == Project.fileExtension, seen.insert(url).inserted, let song = LibrarySong(reading: url) else { return }
            songs.append(song)
        }
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walker { add(url) }
        }
        extra.forEach(add)
        return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Songs whose title holds every word typed, ignoring case and accents.
    public static func search(_ songs: [LibrarySong], _ query: String) -> [LibrarySong] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return songs }
        return songs.filter { song in
            words.allSatisfy { song.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
