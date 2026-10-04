import Foundation

/// The projects and setlists opened lately, newest first, for File ▸ Open Recent and the Dock menu (PRD § 5.8).
/// A file that is gone is hidden, not forgotten: it comes back when its disk is plugged in again.
public struct RecentDocuments: Equatable, Sendable {
    public static let limit = 10
    public private(set) var urls: [URL]

    public init(urls: [URL] = []) {
        self.urls = []
        for url in urls.reversed() { note(url) }
    }

    /// `url` was just opened: it goes to the top, once.
    public mutating func note(_ url: URL) {
        let url = url.standardizedFileURL
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > Self.limit { urls.removeLast(urls.count - Self.limit) }
    }

    public mutating func clear() { urls = [] }

    /// What the menus show: the files still there.
    public func existing(_ fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> [URL] {
        urls.filter(fileExists)
    }
}
