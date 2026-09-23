import Foundation

/// A dotted version ("0.3.0", "v0.3.0"), compared number by number.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The latest GitHub release: its version, the app zip the release pipeline attached, and its page.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let zipURL: URL
    public let pageURL: URL

    public static func == (lhs: ReleaseInfo, rhs: ReleaseInfo) -> Bool {
        lhs.version == rhs.version && lhs.zipURL == rhs.zipURL && lhs.pageURL == rhs.pageURL
    }

    /// Reads the GitHub API answer for a release; nil when it has no DubStemMix zip (build still running).
    public init?(githubJSON data: Data) {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name),
              let zip = release.assets.first(where: { $0.name.hasPrefix("DubStemMix-") && $0.name.hasSuffix(".zip") })
        else { return nil }
        self.version = version
        zipURL = zip.browser_download_url
        pageURL = release.html_url
    }
}

/// Asks GitHub for the latest release (issue: automatic, opt-out update check). Nothing else is sent.
public enum UpdateCheck {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/yoanbernabeu/DubStemMix/releases/latest")!
    /// At most one automatic check per day.
    public static let interval: TimeInterval = 24 * 3600

    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now // a clock set back: check again
    }

    /// The latest release, or nil when there is none with an app zip yet.
    public static func latestRelease(session: URLSession = .shared) async throws -> ReleaseInfo? {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ReleaseInfo(githubJSON: data)
    }

    /// The release when it is newer than the running version.
    public static func newer(_ release: ReleaseInfo?, than current: AppVersion) -> ReleaseInfo? {
        guard let release, current < release.version else { return nil }
        return release
    }
}
