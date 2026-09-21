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
    try project.save(to: document)

    let loaded = try Project.load(from: document)
    #expect(loaded == project)
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
