import Foundation
import Testing
@testable import DubStemMixCore

private func file(_ name: String) -> URL { URL(fileURLWithPath: "/Sets/\(name)") }

@Test func recentDocumentsKeepTheLastTenNewestFirst() {
    var recent = RecentDocuments()
    for i in 1...12 { recent.note(file("song\(i).dubstem")) }
    #expect(recent.urls.count == RecentDocuments.limit)
    #expect(recent.urls.first == file("song12.dubstem"))
    #expect(recent.urls.last == file("song3.dubstem"))
}

@Test func reopeningAFileMovesItToTheTopOnce() {
    var recent = RecentDocuments(urls: [file("a.dubstem"), file("set.dubset"), file("b.dubstem")])
    recent.note(URL(fileURLWithPath: "/Sets/./set.dubset")) // same file, other spelling
    #expect(recent.urls == [file("set.dubset"), file("a.dubstem"), file("b.dubstem")])
}

@Test func missingFilesAreHiddenNotForgotten() {
    var recent = RecentDocuments(urls: [file("a.dubstem"), file("gone.dubstem")])
    #expect(recent.existing { $0 != file("gone.dubstem") } == [file("a.dubstem")])
    #expect(recent.urls.count == 2) // its disk may come back
    recent.clear()
    #expect(recent.urls.isEmpty)
}
