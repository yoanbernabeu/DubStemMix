import Foundation
import Testing
@testable import DubStemMixCore

@Test func versionsCompareNumberByNumber() {
    #expect(AppVersion("0.3.0")! < AppVersion("0.10.0")!) // not alphabetical
    #expect(AppVersion("v0.3.0") == AppVersion("0.3")) // tag prefix and missing zeros
    #expect(AppVersion("0.3.1")! > AppVersion("0.3.0")!)
    #expect(AppVersion("0.3.0-beta") == nil && AppVersion("") == nil)
}

@Test func releaseIsReadFromTheGitHubAnswer() throws {
    let json = """
    {"tag_name": "v0.4.0", "html_url": "https://github.com/yoanbernabeu/DubStemMix/releases/tag/v0.4.0",
     "draft": false, "prerelease": false,
     "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                {"name": "DubStemMix-0.4.0.zip", "browser_download_url": "https://example.com/DubStemMix-0.4.0.zip"}]}
    """
    let release = try #require(ReleaseInfo(githubJSON: Data(json.utf8)))
    #expect(release.version == AppVersion("0.4.0"))
    #expect(release.zipURL.lastPathComponent == "DubStemMix-0.4.0.zip")
    #expect(UpdateCheck.newer(release, than: AppVersion("0.3.0")!) == release)
    #expect(UpdateCheck.newer(release, than: AppVersion("0.4.0")!) == nil)

    // No zip yet (the release pipeline is still building): nothing to offer.
    let building = json.replacingOccurrences(of: "DubStemMix-0.4.0.zip\"", with: "other.zip\"")
    #expect(ReleaseInfo(githubJSON: Data(building.utf8)) == nil)
    #expect(ReleaseInfo(githubJSON: Data(json.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true").utf8)) == nil)
}

@Test func automaticCheckRunsAtMostOnceADay() {
    let now = Date()
    #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
    #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
    #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now)) // clock set back
}
