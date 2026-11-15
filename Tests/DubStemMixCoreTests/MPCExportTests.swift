import AVFoundation
import Foundation
import Testing
@testable import DubStemMixCore

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dsm-mpc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A constant-level stem (easy to check once mixed and resampled).
private func writeStem(_ url: URL, level: Float, seconds: Double, rate: Double, channels: AVAudioChannelCount) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for c in 0..<Int(channels) { buffer.floatChannelData![c].update(repeating: level, count: Int(frames)) }
    try file.write(from: buffer)
}

private func song(_ folder: URL, _ name: String, bpm: Double?, stems: [(file: String, strip: Int, level: Float, rate: Double, channels: AVAudioChannelCount)],
                  names: [String: String]? = nil) throws -> URL {
    let document = folder.appending(path: "\(name).dubstem")
    var project = Project()
    project.title = name.uppercased()
    project.bpm = bpm
    for stem in stems {
        let url = folder.appending(path: "\(name) stems/\(stem.file)")
        try writeStem(url, level: stem.level, seconds: 1, rate: stem.rate, channels: stem.channels)
        project.stems.append(.init(file: FileReference(url, relativeTo: document), strip: stem.strip))
    }
    project.stripNames = names
    try project.save(to: document)
    return document
}

private func setlist(_ folder: URL, _ songs: [URL]) throws -> (Setlist, URL) {
    let document = folder.appending(path: "set.dubset")
    var setlist = Setlist(name: "SET")
    setlist.projects = songs.map { SetlistSong(FileReference($0, relativeTo: document)) }
    try setlist.save(to: document)
    return (setlist, document)
}

private func listing(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Test func aSetlistIsWrittenForTheMPC() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try song(folder, "Zion Gate", bpm: 72, stems: [
        ("drums.wav", 0, 0.2, 48_000, 2),
        ("bass.wav", 1, 0.3, 44_100, 1),       // mono: on both sides
        ("bass dub.wav", 1, 0.3, 44_100, 2),   // a second stem on the same strip: mixed
        ("vocals.wav", 3, 0.1, 48_000, 2),     // strip 3 left empty in between
    ], names: ["3": "vox"])
    let b = try song(folder, "Rockers", bpm: nil, stems: [("drums.wav", 0, 0.5, 44_100, 2)])
    let (set, document) = try setlist(folder, [a, b])

    // The plugin shipped in the app; its Content (test songs on a dev machine) must not travel.
    let plugin = folder.appending(path: "bundle/\(MPCExport.pluginFolderName)")
    try FileManager.default.createDirectory(at: plugin.appending(path: "VST"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: plugin.appending(path: "Content/Songs/dev song"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: plugin.appending(path: "plugin.json"))
    try Data("so".utf8).write(to: plugin.appending(path: "VST/dubstemmix-arm32.so"))

    let card = folder.appending(path: "card")
    let export = MPCExport(setlist: set, at: document, to: card, bundledPlugin: plugin)
    #expect(!export.hasExisting)
    let report = try export.run()
    #expect(report == MPCExport.Report(songs: 2, written: 2, reused: 0, removed: 0, missing: []))

    let installed = card.appending(path: "VST2 Plugins/\(MPCExport.pluginFolderName)")
    #expect(listing(installed) == ["Content", "VST", "plugin.json"])
    #expect(listing(installed.appending(path: "Content/Songs")) == ["01 ZION GATE", "02 ROCKERS"])
    let first = installed.appending(path: "Content/Songs/01 ZION GATE")
    #expect(listing(first) == ["1 - DRUMS.wav", "2 - BASS.wav", "4 - VOX.wav", "song.json"])

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: first.appending(path: "song.json"))) as! [String: Any]
    #expect(json["title"] as? String == "ZION GATE")
    #expect(json["bpm"] as? Double == 72)
    #expect(json["strips"] as? [String] == ["DRUMS", "BASS", "", "VOX", "", ""])

    // 44.1 kHz stereo, a second long (the 48 kHz stems converted), the two bass stems summed on both sides.
    let bass = try AVAudioFile(forReading: first.appending(path: "2 - BASS.wav"))
    #expect(bass.fileFormat.sampleRate == 44_100 && bass.fileFormat.channelCount == 2)
    #expect(abs(bass.length - 44_100) < 64)
    let buffer = AVAudioPCMBuffer(pcmFormat: bass.processingFormat, frameCapacity: AVAudioFrameCount(bass.length))!
    try bass.read(into: buffer)
    #expect(abs(buffer.floatChannelData![0][20_000] - 0.6) < 0.001)
    #expect(abs(buffer.floatChannelData![1][20_000] - 0.6) < 0.001)

    // Again: nothing to write.
    let again = try MPCExport(setlist: set, at: document, to: card, bundledPlugin: plugin).run()
    #expect(again.written == 0 && again.reused == 2)
}

@Test func theCardFollowsTheSetlistOrderAndLosesTheSongsLeft() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try song(folder, "Alpha", bpm: 80, stems: [("drums.wav", 0, 0.2, 44_100, 2)])
    let b = try song(folder, "Beta", bpm: 90, stems: [("bass.wav", 1, 0.2, 44_100, 2)])
    let c = try song(folder, "Gamma", bpm: 100, stems: [("keys.wav", 2, 0.2, 44_100, 2)])
    let card = folder.appending(path: "card")
    let songs = card.appending(path: "VST2 Plugins/\(MPCExport.pluginFolderName)/Content/Songs")

    var (set, document) = try setlist(folder, [a, b, c])
    _ = try MPCExport(setlist: set, at: document, to: card, bundledPlugin: nil).run()
    // A song copied by hand on the card goes too: the card is the setlist.
    try FileManager.default.createDirectory(at: songs.appending(path: "9 By Hand"), withIntermediateDirectories: true)

    (set, document) = try setlist(folder, [c, a])
    let export = MPCExport(setlist: set, at: document, to: card, bundledPlugin: nil)
    #expect(export.hasExisting)
    let backup = folder.appending(path: "backups/DubStemMix 2026-11-16")
    try export.backUp(to: backup)
    #expect(listing(backup.appending(path: "Content/Songs")) == ["01 ALPHA", "02 BETA", "03 GAMMA", "9 By Hand"])

    let report = try export.run()
    #expect(report.written == 0 && report.reused == 2 && report.removed == 2)
    #expect(listing(songs) == ["01 GAMMA", "02 ALPHA"])
    #expect(listing(songs.appending(path: "01 GAMMA")) == ["3 - KEYS.wav", "song.json"])
}

@Test func aSongWhoseStemChangedIsWrittenAgain() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try song(folder, "Alpha", bpm: 80, stems: [("drums.wav", 0, 0.2, 44_100, 2)])
    let (set, document) = try setlist(folder, [a])
    let card = folder.appending(path: "card")
    _ = try MPCExport(setlist: set, at: document, to: card, bundledPlugin: nil).run()

    var project = try Project.load(from: a)
    project.stripNames = ["0": "KICK"]
    try project.save(to: a)
    let report = try MPCExport(setlist: set, at: document, to: card, bundledPlugin: nil).run()
    #expect(report.written == 1 && report.reused == 0 && report.removed == 1)
    let songs = card.appending(path: "VST2 Plugins/\(MPCExport.pluginFolderName)/Content/Songs")
    #expect(listing(songs.appending(path: "01 ALPHA")) == ["1 - KICK.wav", "song.json"])
}

@Test func missingSongsAndStemsAreReported() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try song(folder, "Alpha", bpm: 80, stems: [("drums.wav", 0, 0.2, 44_100, 2), ("bass.wav", 1, 0.2, 44_100, 2)])
    try FileManager.default.removeItem(at: folder.appending(path: "Alpha stems/bass.wav"))
    let (set, document) = try setlist(folder, [a, folder.appending(path: "Gone.dubstem")])
    let report = try MPCExport(setlist: set, at: document, to: folder.appending(path: "card"), bundledPlugin: nil).run()
    #expect(report.songs == 1 && report.written == 1)
    #expect(report.missing == ["ALPHA: bass.wav", "Gone"])
}

@Test func folderNamesAreSafeOnAnyCard() {
    #expect(MPCExport.folderName(index: 6, title: "Zion: Gate / Dub?") == "07 Zion  Gate   Dub")
    #expect(MPCExport.folderName(index: 0, title: "") == "01 Song")
}
