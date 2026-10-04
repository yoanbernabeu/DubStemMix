import Foundation
import Testing
@testable import DubStemMixCore

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dsm-workshop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func song(_ title: String, in folder: URL, bpm: Double = 70, duration: Double = 200) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var project = Project()
    project.title = title
    project.bpm = bpm
    project.duration = duration
    let url = folder.appending(path: "\(title).dubstem")
    try project.save(to: url)
    return url
}

// MARK: - Colour and tag per line

@Test func colourAndTagAreStoredBesideTheSongAndOldSetlistsStillOpen() throws {
    let old = #"{"version": 1, "name": "OLD", "projects": [{"path": "/a.dubstem", "relativePath": "a.dubstem"}]}"#
    let setlist = try JSONDecoder().decode(Setlist.self, from: Data(old.utf8))
    #expect(setlist.projects.first?.path == "/a.dubstem" && setlist.projects.first?.color == nil)

    var marked = setlist
    marked.projects[0].color = 3
    marked.projects[0].tag = "Opener"
    let data = try JSONEncoder().encode(marked)
    #expect(try JSONDecoder().decode(Setlist.self, from: data) == marked)
    // An older app reads the line as a plain file reference.
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let line = try #require((json["projects"] as? [[String: Any]])?.first)
    #expect(line["path"] as? String == "/a.dubstem" && line["color"] as? Int == 3 && line["tag"] as? String == "Opener")
}

@Test func aSongIsNeverTwiceInTheSameSet() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let location = folder.appending(path: "sets/Sunday.dubset")
    let a = try song("Roots Steppa", in: folder.appending(path: "songs"))
    let b = try song("Zion Gate", in: folder.appending(path: "songs"))
    var setlist = Setlist(name: "SUNDAY")
    let addedA = setlist.insert(a, location: location)
    let addedB = setlist.insert(b, at: 0, location: location)
    let addedAgain = setlist.insert(URL(fileURLWithPath: folder.path + "/songs/../songs/Roots Steppa.dubstem"), location: location)
    #expect(addedA && addedB && !addedAgain)
    #expect(setlist.projects.compactMap { $0.resolve(relativeTo: location) } == [b, a].map(\.standardizedFileURL))
    #expect(setlist.index(of: a, at: location) == 1)
}

@Test func aMovedSetlistKeepsItsSongsColoursAndTags() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = try song("Roots Steppa", in: folder.appending(path: "songs"))
    let old = folder.appending(path: "Desktop/Sunday.dubset")
    var setlist = Setlist(name: "SUNDAY")
    setlist.insert(a, location: old)
    setlist.projects[0].color = 1
    setlist.projects[0].tag = "Encore"
    let new = folder.appending(path: "Setlists/Sunday.dubset")
    let moved = setlist.moved(from: old, to: new)
    #expect(moved.projects[0].relativePath == "../songs/Roots Steppa.dubstem")
    #expect(moved.projects[0].color == 1 && moved.projects[0].tag == "Encore")
}

// MARK: - Library

@Test func theLibraryFindsEverySongOnceSortedByTitle() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let music = root.appending(path: "Music/DubStemMix")
    _ = try song("Zion Gate", in: music.appending(path: "Stems/Zion Gate [12ab]"), bpm: 140, duration: 303)
    _ = try song("roots steppa", in: music.appending(path: "Projects"))
    let elsewhere = try song("Électrique Dub", in: root.appending(path: "Desktop"))
    try Data("{".utf8).write(to: music.appending(path: "Broken.dubstem"))

    // The stems folder is inside the music folder here: its songs are not listed twice.
    let songs = SongLibrary.scan(folders: [music, music.appending(path: "Stems")],
                                 extra: [elsewhere, root.appending(path: "gone.dubstem")])
    #expect(songs.map(\.title) == ["Électrique Dub", "roots steppa", "Zion Gate"])
    #expect(songs.last?.bpm == 140 && songs.last?.duration == 303)
    #expect(SongLibrary.search(songs, "electrique").map(\.title) == ["Électrique Dub"])
    #expect(SongLibrary.search(songs, "GATE zion").map(\.title) == ["Zion Gate"])
    #expect(SongLibrary.search(songs, "  ").count == 3)
}
