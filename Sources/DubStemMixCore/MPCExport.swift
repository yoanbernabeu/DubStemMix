import AVFoundation
import CryptoKit
import Foundation

/// A setlist written for the DubStemMix plugin on an Akai MPC (PRD § 16.2 quater), on a card or in a folder:
///
///     <root>/VST2 Plugins/YoanDev - VST - DubStemMix/
///       plugin.json, version.xml, VST/, Plugin Skins/    (the plugin shipped in the app, replaced each time)
///       Content/Songs/
///         01 Roots Steppa/
///           song.json                                    (title, BPM, strip names, where it came from)
///           1 - DRUMS.wav, 2 - BASS.wav…                 (one 44.1 kHz WAV per strip, its stems mixed)
///
/// The card becomes exactly the setlist, in its order. A song already there and unchanged (same stems, same
/// strips, same names) is not written again: its folder is only renamed into place.
public struct MPCExport: Sendable {
    public static let pluginFolderName = "YoanDev - VST - DubStemMix"
    public static let stripCount = 6
    public static let sampleRate = 44_100.0
    /// Bumped when what is written changes: songs exported before are then written again.
    static let formatVersion = 1

    public struct Song: Sendable, Equatable {
        public var title: String
        public var bpm: Double?
        /// Stems per strip (the app's first 6 strips), already found on disk.
        public var strips: [[URL]]
        public var stripNames: [String]
        /// Identifies what would be written: an unchanged song on the card has the same.
        public var fingerprint: String
        /// Audio frames of the longest strip at 44.1 kHz.
        public var frames: Int64
    }

    public struct Report: Equatable, Sendable {
        public var songs = 0
        public var written = 0
        public var reused = 0
        public var removed = 0
        /// Songs or stems that could not be found, hence not exported.
        public var missing: [String] = []
    }

    public enum Failure: LocalizedError, Equatable {
        case noRoom(needed: Int64, available: Int64)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case let .noRoom(needed, available):
                let f = ByteCountFormatter()
                return "Not enough room: \(f.string(fromByteCount: needed)) needed, \(f.string(fromByteCount: available)) free"
            case let .unreadable(name): return "Could not read \(name)"
            }
        }
    }

    public let root: URL
    public let bundledPlugin: URL?
    public private(set) var songs: [Song] = []
    public private(set) var missing: [String] = []

    public var pluginFolder: URL { root.appending(path: "VST2 Plugins/\(Self.pluginFolderName)", directoryHint: .isDirectory) }
    public var songsFolder: URL { pluginFolder.appending(path: "Content/Songs", directoryHint: .isDirectory) }
    /// A DubStemMix folder is already there (offer the backup).
    public var hasExisting: Bool { FileManager.default.fileExists(atPath: pluginFolder.path) }

    /// Plans the export (reads the songs, nothing is written). `bundledPlugin`: the plugin folder shipped in the app.
    public init(setlist: Setlist, at setlistURL: URL, to root: URL, bundledPlugin: URL?) {
        self.root = root
        self.bundledPlugin = bundledPlugin
        for reference in setlist.projects {
            let name = URL(fileURLWithPath: reference.file.path).deletingPathExtension().lastPathComponent
            guard let document = reference.file.resolve(relativeTo: setlistURL), let project = try? Project.load(from: document) else {
                missing.append(name)
                continue
            }
            songs.append(Self.plan(project, at: document, fallbackTitle: name, missing: &missing))
        }
    }

    static func plan(_ project: Project, at document: URL, fallbackTitle: String, missing: inout [String]) -> Song {
        let title = project.title.isEmpty ? fallbackTitle : project.title
        // Strip names as the app shows them: the one typed, else the first stem's, cleaned with all the song's files.
        let all = project.stems.map(\.file) + project.pool
        let cleaned = StemImporter.stripNames(for: all.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent })
        var derived: [String: String] = [:]
        for (file, name) in zip(all, cleaned) where derived[file.path] == nil { derived[file.path] = name }

        var strips = [[URL]](repeating: [], count: stripCount)
        var names = [String](repeating: "", count: stripCount)
        var identity: [String] = ["format \(formatVersion)", "bpm \(project.bpm ?? 0)"]
        var frames: Int64 = 0
        for strip in 0..<stripCount {
            let entries = project.stems.filter { $0.strip == strip }
            for entry in entries {
                guard let url = entry.file.resolve(relativeTo: document)?.standardizedFileURL else {
                    missing.append("\(title): \(entry.file.fileName)")
                    continue
                }
                strips[strip].append(url)
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                identity.append("\(strip) \(url.path) \(values?.fileSize ?? 0) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
                if let file = try? AVAudioFile(forReading: url) {
                    frames = max(frames, Int64(Double(file.length) * sampleRate / file.fileFormat.sampleRate))
                }
            }
            if !strips[strip].isEmpty {
                names[strip] = (project.stripNames?["\(strip)"] ?? entries.first.flatMap { derived[$0.file.path] } ?? "").uppercased()
            }
            identity.append("name \(strip) \(names[strip])")
        }
        identity.append("title \(title)")
        let digest = SHA256.hash(data: Data(identity.joined(separator: "\n").utf8))
        return Song(title: title, bpm: project.bpm, strips: strips, stripNames: names,
                    fingerprint: digest.map { String(format: "%02x", $0) }.joined(), frames: frames)
    }

    // MARK: Card

    /// Song folders already on the card, by the fingerprint in their song.json.
    func existingSongs() -> [String: URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: songsFolder, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "song.json")),
                  let json = try? JSONDecoder().decode(SongFile.self, from: data), let source = json.source else { continue }
            found[source] = folder
        }
        return found
    }

    /// Bytes to write (songs not on the card yet, 16-bit stereo), and bytes the songs leaving the card give back.
    public func bytesNeeded() -> (write: Int64, freed: Int64) {
        let existing = existingSongs()
        let kept = Set(songs.map(\.fingerprint))
        var write: Int64 = 0
        for song in songs where existing[song.fingerprint] == nil {
            write += song.frames * 4 * Int64(song.strips.filter { !$0.isEmpty }.count) + 4096
        }
        var freed: Int64 = 0
        for (fingerprint, folder) in existing where !kept.contains(fingerprint) { freed += Self.size(of: folder) }
        return (write, freed)
    }

    static func size(of folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    /// Copies the DubStemMix folder now on the card into `folder` (created), before it is replaced.
    public func backUp(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pluginFolder, to: folder)
    }

    // MARK: Writing

    struct SongFile: Codable {
        var title: String
        var bpm: Double?
        var strips: [String]
        var source: String?
        var format: Int?
    }

    /// Writes everything. `progress` gets 0…1 from any thread.
    public func run(progress: @Sendable (Double) -> Void = { _ in }) throws -> Report {
        let fm = FileManager.default
        var report = Report(songs: songs.count, missing: missing)
        try fm.createDirectory(at: songsFolder, withIntermediateDirectories: true)
        let (needed, freed) = bytesNeeded()
        if let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available > 0, Int64(available) + freed < needed {
            throw Failure.noRoom(needed: needed, available: Int64(available) + freed)
        }

        try installPlugin()

        // Songs leaving the card go first (room), those staying are set aside under hidden names (the plugin
        // skips names starting with a dot), new ones are written hidden too, then all take their final names.
        var existing = existingSongs()
        let wanted = Set(songs.map(\.fingerprint))
        for (fingerprint, folder) in existing where !wanted.contains(fingerprint) {
            try fm.removeItem(at: folder)
            existing[fingerprint] = nil
            report.removed += 1
        }
        // Anything else in the songs folder (songs copied by hand, old leftovers) belongs to the old card too.
        let kept = Set(existing.values.map(\.standardizedFileURL))
        for item in (try? fm.contentsOfDirectory(at: songsFolder, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(item.standardizedFileURL) {
            try fm.removeItem(at: item)
            if !item.lastPathComponent.hasPrefix(".") { report.removed += 1 }
        }
        var staged: [URL] = []
        for (index, song) in songs.enumerated() {
            let temporary = songsFolder.appending(path: ".song-\(index)", directoryHint: .isDirectory)
            if let folder = existing[song.fingerprint] {
                existing[song.fingerprint] = nil   // a song twice in the setlist is written twice
                try fm.moveItem(at: folder, to: temporary)
                report.reused += 1
            } else {
                try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
                try write(song, to: temporary) { fraction in progress((Double(index) + fraction) / Double(max(songs.count, 1))) }
                report.written += 1
            }
            staged.append(temporary)
            progress(Double(index + 1) / Double(max(songs.count, 1)))
        }
        for (index, temporary) in staged.enumerated() {
            try fm.moveItem(at: temporary, to: songsFolder.appending(path: Self.folderName(index: index, title: songs[index].title)))
        }
        Self.removeAppleDouble(in: pluginFolder)
        return report
    }

    /// The "._name" files macOS leaves next to every file on a FAT card (the MPC's): useless there, so cleared.
    static func removeAppleDouble(in folder: URL) {
        let fm = FileManager.default
        guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        var doubles: [URL] = []
        while let item = items.nextObject() as? URL {
            if item.lastPathComponent.hasPrefix("._") { doubles.append(item) }
        }
        for item in doubles { try? fm.removeItem(at: item) }
    }

    /// "07 Zion Gate Dub": the number keeps the setlist's order, the title is made safe for any card.
    static func folderName(index: Int, title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|#@,;^").union(.controlCharacters)
        let safe = title.unicodeScalars.map { illegal.contains($0) ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(format: "%02d ", index + 1) + String((safe.isEmpty ? "Song" : safe).prefix(60))
    }

    /// The plugin shipped in the app, in place of the one on the card (the songs are left alone).
    func installPlugin() throws {
        guard let bundledPlugin else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: bundledPlugin, includingPropertiesForKeys: nil) where item.lastPathComponent != "Content" {
            let target = pluginFolder.appending(path: item.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: item, to: target)
        }
    }

    /// One song: song.json, and one WAV per strip that has stems.
    func write(_ song: Song, to folder: URL, progress: (Double) -> Void) throws {
        let used = song.strips.indices.filter { !song.strips[$0].isEmpty }
        for (done, strip) in used.enumerated() {
            let name = song.stripNames[strip].isEmpty ? "STRIP \(strip + 1)" : song.stripNames[strip]
            let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? String($0) : " " }.joined()
            try Self.render(song.strips[strip], frames: song.frames, to: folder.appending(path: "\(strip + 1) - \(safe).wav"))
            progress(Double(done + 1) / Double(max(used.count, 1)))
        }
        let json = SongFile(title: song.title, bpm: song.bpm, strips: song.stripNames, source: song.fingerprint, format: Self.formatVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(json).write(to: folder.appending(path: "song.json"))
    }

    /// Mixes `stems` into one stereo 44.1 kHz WAV, `frames` long (shorter stems end in silence). 16-bit, or
    /// 32-bit float when the mix goes over full scale (several loud stems on one strip), so nothing clips.
    static func render(_ stems: [URL], frames: Int64, to url: URL) throws {
        let count = Int(frames)
        var left = [Float](repeating: 0, count: count), right = [Float](repeating: 0, count: count)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
        else { throw Failure.unreadable(url.lastPathComponent) }
        for stem in stems {
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: stem) } catch { throw Failure.unreadable(stem.lastPathComponent) }
            let source = file.processingFormat
            guard let converter = AVAudioConverter(from: source, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_384),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384 * 4)
            else { throw Failure.unreadable(stem.lastPathComponent) }
            if source.channelCount == 1 { converter.channelMap = [0, 0] }   // a mono stem on both sides
            var position = 0
            var finished = false
            while !finished {
                var readError: Error?
                let status = converter.convert(to: output, error: nil) { _, outStatus in
                    if file.framePosition >= file.length {   // reading past the end throws
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try file.read(into: input)
                    } catch {
                        readError = error
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if input.frameLength == 0 {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return input
                }
                if readError != nil { throw Failure.unreadable(stem.lastPathComponent) }
                let n = Int(output.frameLength)
                if let l = output.floatChannelData?[0], let r = output.floatChannelData?[1] {
                    for i in 0..<min(n, count - position) {
                        left[position + i] += l[i]
                        right[position + i] += r[i]
                    }
                }
                position += n
                finished = status == .endOfStream || status == .error || n == 0
            }
        }
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(left[i]), abs(right[i])) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: peak > 1 ? 32 : 16, AVLinearPCMIsFloatKey: peak > 1,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var start = 0
        while start < count {
            let n = min(chunk, count - start)
            buffer.frameLength = AVAudioFrameCount(n)
            left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: n) }
            right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress! + start, count: n) }
            try out.write(from: buffer)
            start += n
        }
    }
}
