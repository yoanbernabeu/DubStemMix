import AppKit
import DubStemMixCore

extension AppModel {
    // MARK: Open Recent (PRD § 5.8)

    static func storedRecentDocuments() -> RecentDocuments {
        RecentDocuments(urls: (UserDefaults.standard.stringArray(forKey: Preference.recentDocuments) ?? []).map { URL(fileURLWithPath: $0) })
    }

    /// A project or a setlist just became the open one. Songs opened from the open setlist are left out:
    /// the setlist is the way back to them, and a set would push everything else out of the list.
    func noteRecentDocument(_ url: URL) {
        guard !isPreview else { return }
        recentDocuments.note(url)
        UserDefaults.standard.set(recentDocuments.urls.map { $0.path(percentEncoded: false) }, forKey: Preference.recentDocuments)
        refreshRecentFiles()
    }

    func clearRecentDocuments() {
        recentDocuments.clear()
        UserDefaults.standard.removeObject(forKey: Preference.recentDocuments)
        refreshRecentFiles()
    }

    /// The menus show the files still there; also called when coming back to the app (a disk may be back).
    func refreshRecentFiles() {
        let files = recentDocuments.existing()
        if files != recentFiles { recentFiles = files }
    }

    func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            refreshRecentFiles()
            errorMessage = "\(url.lastPathComponent) is no longer there"
            return
        }
        open([url])
    }

    /// Menu label: the file's name; a setlist says so.
    static func recentLabel(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return url.pathExtension == Setlist.fileExtension ? "\(name) (setlist)" : name
    }
}
