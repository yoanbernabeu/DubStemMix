import AppKit
import DubStemMixCore
import Foundation

/// Where a one-click update stands.
enum UpdateStatus: Equatable {
    case idle
    case downloading
    case failed(String)
}

/// Update check (automatic, at most once a day, opt-out in Settings) and one-click update: the app downloads
/// the release zip, checks it, quits, and a small script swaps the bundle in place and reopens it.
extension AppModel {
    /// The running version; nil when launched with `swift run` (no bundle), unless `DUBSTEMMIX_PRETEND_VERSION`
    /// is set to try the update flow from a development build.
    var currentVersion: AppVersion? {
        if let pretend = ProcessInfo.processInfo.environment["DUBSTEMMIX_PRETEND_VERSION"] { return AppVersion(pretend) }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    /// Only a real .app bundle can replace itself; a development build opens the release page instead.
    private var installedBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    func setAutomaticUpdateChecks(_ on: Bool) {
        automaticUpdateChecks = on
        UserDefaults.standard.set(on, forKey: Preference.automaticUpdateChecks)
        if on { checkForUpdatesIfDue() }
    }

    /// At launch: asks GitHub at most once a day, unless turned off in Settings.
    func checkForUpdatesIfDue() {
        guard !isPreview, automaticUpdateChecks, currentVersion != nil else { return }
        let last = UserDefaults.standard.object(forKey: Preference.lastUpdateCheck) as? Date
        guard UpdateCheck.isDue(lastCheck: last) else { return }
        checkForUpdates(manual: false)
    }

    /// Help ▸ Check for Updates… answers in a dialog either way; the automatic check stays silent unless
    /// there is something new.
    func checkForUpdates(manual: Bool) {
        guard let current = currentVersion else {
            if manual { inform("Development build", "Update checks need the installed app (or DUBSTEMMIX_PRETEND_VERSION).") }
            return
        }
        Task { @MainActor in
            do {
                let latest = try await UpdateCheck.latestRelease()
                UserDefaults.standard.set(Date(), forKey: Preference.lastUpdateCheck)
                availableUpdate = UpdateCheck.newer(latest, than: current)
                if manual, availableUpdate == nil { inform("DubStemMix is up to date", "You have version \(current), the latest.") }
            } catch {
                if manual { inform("Can't check for updates", error.localizedDescription) }
            }
        }
    }

    /// One click: download, check, then quit and let the swap script reopen the new version.
    func installUpdate() {
        guard let release = availableUpdate, updateStatus != .downloading else { return }
        guard let bundle = installedBundle else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard !isPlaying, !isRecording else { return } // the banner is hidden while playing anyway
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            updateStatus = .failed("Can't write to \(bundle.deletingLastPathComponent().path)")
            return
        }
        guard confirmDiscardingUnsavedSession() else { return }
        updateStatus = .downloading
        Task { @MainActor in
            do {
                let fresh = try await Self.downloadApp(release)
                try Self.launchSwap(replacing: bundle, with: fresh)
                NSApp.terminate(nil)
            } catch {
                updateStatus = .failed(error.localizedDescription)
            }
        }
    }

    func dismissUpdate() {
        availableUpdate = nil
        updateStatus = .idle
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Download and swap

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Downloads and unzips the release; returns the new DubStemMix.app after checking it is the same app
    /// at the announced version.
    nonisolated static func downloadApp(_ release: ReleaseInfo) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "DubStemMix-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (download, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
        let zip = work.appending(path: "DubStemMix.zip")
        try FileManager.default.moveItem(at: download, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appending(path: "unzipped").path])
        let app = work.appending(path: "unzipped/DubStemMix.app")
        guard let info = Bundle(url: app)?.infoDictionary,
              Bundle.main.bundleURL.pathExtension != "app" || info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == release.version
        else { throw UpdateError("The downloaded archive is not DubStemMix \(release.version)") }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        return app
    }

    /// `--check-update [version]`: asks GitHub, downloads and checks the release as the running app would,
    /// without replacing anything. The bundle-id check is skipped when not run from an .app.
    static func runCheck(pretending version: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                guard let current = AppVersion(version) else { print("❌ version illisible : \(version)"); return }
                guard let latest = try await UpdateCheck.latestRelease() else { print("❌ aucune release avec un zip"); return }
                print("  ✅ dernière release : \(latest.version) (\(latest.zipURL.lastPathComponent))")
                guard UpdateCheck.newer(latest, than: current) != nil else { print("  ✅ \(current) est à jour : aucun bandeau"); return }
                print("  ✅ \(current) < \(latest.version) : le bandeau s'afficherait")
                let app = try await downloadApp(latest)
                print("  ✅ téléchargé, décompressé et vérifié (version, signature)")
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent())
            } catch {
                print("❌ \(error.localizedDescription)")
            }
        }
        semaphore.wait()
    }

    /// Starts a detached script that waits for this process to quit, swaps the bundles (the old one is kept
    /// until the copy succeeds), clears the quarantine flag like install.sh, and reopens the app.
    private static func launchSwap(replacing bundle: URL, with fresh: URL) throws {
        let work = fresh.deletingLastPathComponent().deletingLastPathComponent()
        let script = work.appending(path: "swap.sh")
        try """
        #!/bin/sh
        PID="$1"; DEST="$2"; NEW="$3"; WORK="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        mv "$DEST" "$WORK/previous.app" || exit 1
        if ditto "$NEW" "$DEST"; then
            xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            open "$DEST"
            rm -rf "$WORK"
        else
            rm -rf "$DEST"; mv "$WORK/previous.app" "$DEST"; open "$DEST"
        fi
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), bundle.path, fresh.path, work.path]
        try process.run() // not waited for: it outlives the app
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }
}
