import Foundation
import Testing
@testable import DubStemMixCore

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dsm-project-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func relativePathsClimbAndDescend() {
    let folder = URL(fileURLWithPath: "/music/live/song")
    #expect(FileReference.relativePath(from: folder, to: URL(fileURLWithPath: "/music/live/song/stems/bass.wav")) == "stems/bass.wav")
    #expect(FileReference.relativePath(from: folder, to: URL(fileURLWithPath: "/music/live/other/bass.wav")) == "../other/bass.wav")
    #expect(FileReference.relativePath(from: folder, to: URL(fileURLWithPath: "/samples/bass.wav")) == "../../../samples/bass.wav")
}

@Test func projectRoundTrips() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let document = folder.appending(path: "song.dubstem")

    var project = Project()
    project.title = "MIDNIGHT VERSION"
    project.duration = 252
    project.bpm = 72
    project.delaySync = true
    project.loop = false
    project.stems = [.init(file: FileReference(folder.appending(path: "stems/bass.wav"), relativeTo: document), strip: 1)]
    project.pool = [FileReference(folder.appending(path: "stems/full mix.wav"), relativeTo: document)]
    project.fx = Dictionary(uniqueKeysWithValues: FXParameter.allCases.map { ($0.rawValue, $0.defaultValue) })
    project.stripNames = ["1": "RIDDIM"]
    project.keep = [0, 1]
    try project.save(to: document)

    let loaded = try Project.load(from: document)
    #expect(loaded == project)
    #expect(loaded.stripNames?["1"] == "RIDDIM")
    #expect(loaded.stems[0].file.relativePath == "stems/bass.wav")
    #expect(FXParameter(rawValue: "delayTime") == .delayTime) // noms enregistrés dans les projets
}

@Test func stemsAreFoundAgainAfterTheWholeFolderMoved() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appending(path: "before")
    try FileManager.default.createDirectory(at: original.appending(path: "stems"), withIntermediateDirectories: true)
    let stem = original.appending(path: "stems/bass.wav")
    try Data("x".utf8).write(to: stem)
    let document = original.appending(path: "song.dubstem")
    let reference = FileReference(stem, relativeTo: document)
    #expect(reference.resolve(relativeTo: document)?.standardizedFileURL == stem.standardizedFileURL)

    // Tout le dossier déménage : le chemin absolu est mort, le chemin relatif au projet tient.
    let moved = root.appending(path: "after")
    try FileManager.default.moveItem(at: original, to: moved)
    let movedDocument = moved.appending(path: "song.dubstem")
    #expect(reference.resolve(relativeTo: movedDocument)?.path == moved.appending(path: "stems/bass.wav").standardizedFileURL.path)

    // Fichier réellement disparu : pas de résolution.
    try FileManager.default.removeItem(at: moved.appending(path: "stems/bass.wav"))
    #expect(reference.resolve(relativeTo: movedDocument) == nil)
}

@Test func setlistRoundTrips() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let document = folder.appending(path: "sunday.dubset")
    var setlist = Setlist(name: "SUNDAY SESSION")
    setlist.projects = ["a", "b"].map { FileReference(folder.appending(path: "\($0).dubstem"), relativeTo: document) }
    try setlist.save(to: document)
    #expect(try Setlist.load(from: document) == setlist)
}

// MARK: - Setlist rack (live use)

@Test func aSetlistSavedBeforeTheRackStillOpens() throws {
    let json = #"{"version": 1, "name": "OLD", "projects": []}"#
    let setlist = try JSONDecoder().decode(Setlist.self, from: Data(json.utf8))
    #expect(setlist.name == "OLD" && setlist.rack == nil)
}

@Test func setlistRackRoundTripsAndComparesByWiring() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let document = folder.appending(path: "sunday.dubset")
    let dubFilter = PluginInfo(name: "Dub Filter", manufacturer: "Acme", type: 1, subType: 2, manufacturerCode: 3)
    var setlist = Setlist(name: "SUNDAY SESSION")
    setlist.rack = Rack(reverbModel: "spring", busSends: ["delay": "reverb"],
                        slots: ["bus3": .init(plugin: dubFilter, state: Data([1]), macros: [])])
    try setlist.save(to: document)
    #expect(try Setlist.load(from: document) == setlist)

    // A plugin whose settings moved is still the same rack; another effect or another patch is not.
    var tweaked = setlist.rack!
    tweaked.slots?["bus3"]?.state = Data([2])
    #expect(tweaked.isWiredLike(setlist.rack!))
    #expect(!Rack(busSends: ["delay": "reverb"]).isWiredLike(setlist.rack!))
    // Defaults written out or left absent are the same rack.
    #expect(Rack(reverbModel: "plate", bus3Model: "phaser", busSends: [:]).isWiredLike(Rack(busSends: [:])))
}

@Test func projectRackReadsAndWritesTheSongsOwnFields() {
    var project = Project()
    project.reverbModel = "spring"
    project.busSends = ["bus3": "delay"]
    #expect(project.rack == Rack(reverbModel: "spring", busSends: ["bus3": "delay"]))
    project.rack = Rack()
    #expect(project.reverbModel == nil && project.busSends == nil && project.slots == nil)
}

@Test func missingStemsAreFoundByNameWithoutGuessing() {
    let document = URL(fileURLWithPath: "/old/set/tune.dubstem")
    let bass = FileReference(URL(fileURLWithPath: "/old/set/Rockers Rise/bass.wav"), relativeTo: document)
    let melodica = FileReference(URL(fileURLWithPath: "/old/set/Rockers Rise/melodica.wav"), relativeTo: document)
    let found: [String: [URL]] = [
        "bass.wav": [URL(fileURLWithPath: "/new/Zion Gate/bass.wav"), URL(fileURLWithPath: "/new/Rockers Rise/bass.wav")],
        "melodica.wav": [URL(fileURLWithPath: "/new/misc/melodica.wav")],
        "drums.wav": [URL(fileURLWithPath: "/new/a/drums.wav"), URL(fileURLWithPath: "/new/b/drums.wav")],
    ]
    #expect(bass.bestMatch(in: found)?.path == "/new/Rockers Rise/bass.wav") // two of them: the one in its folder
    #expect(melodica.bestMatch(in: found)?.path == "/new/misc/melodica.wav") // the only one
    let drums = FileReference(URL(fileURLWithPath: "/old/set/Roots/drums.wav"), relativeTo: document)
    #expect(drums.bestMatch(in: found) == nil) // two, neither in a "Roots" folder: no guess
}

@Test func setlistExportCopiesEverySongWithItsFiles() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default
    // Two songs in different folders, both with a "bass.wav"; the second has a stem that no longer exists.
    func song(_ name: String, stems: [String], missing: String? = nil) throws -> URL {
        let folder = root.appending(path: "library/\(name)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appending(path: "\(name).dubstem")
        var project = Project()
        project.title = name.uppercased()
        for (strip, stem) in stems.enumerated() {
            try Data(stem.utf8).write(to: folder.appending(path: stem))
            project.stems.append(.init(file: FileReference(folder.appending(path: stem), relativeTo: document), strip: strip))
        }
        project.stems.append(.init(file: FileReference(folder.appending(path: stems[0]), relativeTo: document), strip: 7)) // same file twice
        if let missing { project.pool = [FileReference(folder.appending(path: missing), relativeTo: document)] }
        try project.save(to: document)
        return document
    }
    let first = try song("Roots Steppa", stems: ["bass.wav", "drums.wav"])
    let second = try song("Zion Gate", stems: ["bass.wav"], missing: "gone.wav")
    var withInsert = try Project.load(from: second)
    let plugin = PluginInfo(name: "Dub Filter", manufacturer: "AudioThing", type: 0x61756678, subType: 1, manufacturerCode: 2)
    withInsert.inserts = ["2": .init(plugin: plugin, state: nil, macros: [])]
    try withInsert.save(to: second)

    let setlistURL = root.appending(path: "sets/Sunday.dubset")
    try files.createDirectory(at: setlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var setlist = Setlist(name: "SUNDAY")
    setlist.projects = [first, second, root.appending(path: "nowhere.dubstem")].map { FileReference($0, relativeTo: setlistURL) }
    setlist.rack = Rack(reverbModel: "spring")
    try setlist.save(to: setlistURL)

    let target = root.appending(path: "usb/SUNDAY")
    let export = SetlistExport(setlist: setlist, at: setlistURL, to: target)
    #expect(export.report.songs == 2)
    #expect(export.report.files == 3)
    #expect(export.report.missing == ["Zion Gate: gone.wav", "nowhere.dubstem"])
    #expect(export.report.plugins == ["Dub Filter (AudioThing) — used by: ZION GATE (insert, strip 3)"])
    try export.run()
    #expect(throws: SetlistExport.ExportError.self) { try export.run() } // never over an existing folder

    // On the other Mac: the folder has moved, nothing of the original library exists.
    try files.removeItem(at: root.appending(path: "library"))
    let moved = root.appending(path: "elsewhere")
    try files.moveItem(at: target, to: moved)
    let exported = try Setlist.load(from: moved.appending(path: "Sunday.dubset"))
    #expect(exported.name == "SUNDAY" && exported.rack == setlist.rack)
    let songs = exported.projects.compactMap { $0.resolve(relativeTo: moved.appending(path: "Sunday.dubset")) }
    #expect(songs.map { $0.lastPathComponent } == ["Roots Steppa.dubstem", "Zion Gate.dubstem"])
    for document in songs {
        let project = try Project.load(from: document)
        #expect(project.stems.allSatisfy { $0.file.resolve(relativeTo: document) != nil })
    }
    let zion = try Project.load(from: songs[1])
    #expect(zion.pool.first?.fileName == "gone.wav" && zion.pool.first?.resolve(relativeTo: songs[1]) == nil) // still listed as missing
    #expect(zion.inserts?["2"]?.plugin == plugin)
    #expect(try String(contentsOf: moved.appending(path: "PLUGINS.txt"), encoding: .utf8).contains("Dub Filter (AudioThing)"))
}
