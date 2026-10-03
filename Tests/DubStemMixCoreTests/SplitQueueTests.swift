import Foundation
import Testing
@testable import DubStemMixCore

private func song(_ name: String, _ duration: Double? = 200) -> (source: URL, duration: Double?) {
    (URL(fileURLWithPath: "/music/\(name).mp3"), duration)
}

@Test func queueRunsSongsInOrderOneAtATime() {
    var queue = SplitQueue()
    #expect(queue.add([song("a"), song("b")]) == 2)
    let first = queue.startNext()
    #expect(first?.source.lastPathComponent == "a.mp3")
    #expect(queue.startNext() == nil) // one at a time
    queue.finish(first!.id, .done(project: URL(fileURLWithPath: "/stems/a/A.dubstem"), reused: false))
    #expect(queue.startNext()?.source.lastPathComponent == "b.mp3")
    #expect(queue.hasWork)
    queue.finish(queue.running!.id, .failed("unreadable"))
    #expect(!queue.hasWork && queue.doneCount == 1 && queue.failedCount == 1)
}

@Test func queueSkipsSongsAlreadyWaitingButTakesFinishedOnesAgain() {
    var queue = SplitQueue()
    queue.add([song("a")])
    #expect(queue.add([song("a"), song("b")]) == 1)
    let a = queue.startNext()!
    #expect(queue.add([song("a")]) == 0) // running
    queue.finish(a.id, .done(project: URL(fileURLWithPath: "/x.dubstem"), reused: false))
    #expect(queue.add([song("a")]) == 1)
}

@Test func onlyWaitingSongsMoveOrLeave() {
    var queue = SplitQueue()
    queue.add([song("a"), song("b"), song("c"), song("d")])
    let a = queue.startNext()!
    let ids = queue.items.map(\.id)
    queue.remove(a.id)
    queue.move(a.id, by: 1)
    #expect(queue.items.map(\.id) == ids)
    queue.move(ids[3], onto: ids[1]) // d before b
    #expect(queue.items.map(\.source.lastPathComponent) == ["a.mp3", "d.mp3", "b.mp3", "c.mp3"])
    queue.move(ids[3], by: -1) // d can't go above the running song
    #expect(queue.items.map(\.source.lastPathComponent) == ["a.mp3", "d.mp3", "b.mp3", "c.mp3"])
    queue.move(ids[2], by: 1) // c after… it is already last
    queue.move(ids[1], by: 1) // b after c
    #expect(queue.items.map(\.source.lastPathComponent) == ["a.mp3", "d.mp3", "c.mp3", "b.mp3"])
    queue.remove(ids[2])
    #expect(queue.waitingCount == 2)
}

@Test func cancellingKeepsFinishedSongs() {
    var queue = SplitQueue()
    queue.add([song("a"), song("b"), song("c")])
    queue.finish(queue.startNext()!.id, .done(project: URL(fileURLWithPath: "/a.dubstem"), reused: true))
    _ = queue.startNext()
    queue.cancelAll()
    #expect(queue.items.count == 1 && queue.doneCount == 1 && !queue.hasWork)
}

@Test func remainingTimeAddsTheRunningSongAndTheWaitingOnes() {
    var queue = SplitQueue()
    queue.add([song("a", 300), song("b", 200), song("c", 100)])
    #expect(queue.remainingTime(secondsPerAudioSecond: nil, runningRemaining: nil) == nil)
    #expect(queue.remainingTime(secondsPerAudioSecond: 1.2, runningRemaining: nil) == 720)
    _ = queue.startNext()
    #expect(queue.remainingTime(secondsPerAudioSecond: 1.2, runningRemaining: 50) == 410)
    queue.add([song("d", nil)])
    #expect(queue.remainingTime(secondsPerAudioSecond: 1.2, runningRemaining: 50) == nil)
}

@Test func separatedProjectOpensLikeAFreshSplit() throws {
    let folder = URL(fileURLWithPath: "/music/Stems/Song [abcd1234]")
    let document = folder.appending(path: "Song.dubstem")
    let stems = ["drums", "bass", "instruments", "vocals"].map { (url: folder.appending(path: "\($0).wav"), name: $0.uppercased()) }
    let original = URL(fileURLWithPath: "/music/Song.mp3")
    let project = Project.separated(title: "SONG", stems: stems, original: original, duration: 245, bpm: 74, document: document)
    #expect(project.stems.map(\.strip) == [0, 1, 2, 3])
    #expect(project.stems[3].file.relativePath == "vocals.wav")
    #expect(project.stripNames == ["0": "DRUMS", "1": "BASS", "2": "INSTRUMENTS", "3": "VOCALS"])
    #expect(project.pool.first?.resolve(relativeTo: document) == nil) // not on disk here, but referenced
    #expect(project.pool.first?.path == "/music/Song.mp3")
    #expect(project.fx.count == FXParameter.allCases.count)
    #expect(BusRouting(projectValue: project.busSends) == .standard)
    #expect(project.title == "SONG" && project.bpm == 74 && project.duration == 245)
}

@Test func songTitleIsTheFileNameNotTheFolder() {
    #expect(StemImporter.songTitle(for: URL(fileURLWithPath: "/Users/me/Downloads/Akae Beka - Dont Feel No Way.mp3"))
        == "AKAE BEKA - DONT FEEL NO WAY")
}
