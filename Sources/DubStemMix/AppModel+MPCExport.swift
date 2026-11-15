import AppKit
import DubStemMixCore
import Foundation

/// Where Export to MPC writes: a card or drive plugged in, or a folder chosen by hand.
struct MPCDestination: Identifiable, Equatable {
    let url: URL
    let name: String
    let free: Int64
    let isVolume: Bool
    var id: URL { url }
}

enum MPCExportState: Equatable {
    case idle
    case exporting(fraction: Double)
    case done(root: URL, report: MPCExport.Report, volume: Bool, backup: URL?)
    case failed(String)
}

extension AppModel {
    // MARK: Export to MPC (PRD § 16.2 quater)

    /// The plugin shipped inside the app (tools/make-app.sh), or the one built in the repository when run from it.
    var bundledMPCPlugin: URL? {
        let name = MPCExport.pluginFolderName
        var candidates = [Bundle.main.resourceURL?.appending(path: "MPC/\(name)")]
        let repository = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repository?.appending(path: "mpc/DubStemMix/build/\(name)"))
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appending(path: "plugin.json").path) }
    }

    /// The setlist as it is now, then the window that picks the card.
    func chooseMPCExport() {
        if setlistURL == nil { saveSetlist() }
        guard !isPreview, setlistURL != nil, setlist != nil, exportTask == nil else { return }
        autosaveCountdown = 0
        autosaveIfNeeded()
        showMPCExport = true
    }

    /// Cards and drives plugged in (removable or ejectable), with their free room.
    func mpcVolumes() -> [MPCDestination] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsReadOnlyKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsReadOnly != true,
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false
            else { return nil }
            return MPCDestination(url: url, name: values.volumeName ?? url.lastPathComponent,
                                  free: Int64(values.volumeAvailableCapacityForImportantUsage ?? 0), isVolume: true)
        }
    }

    func chooseMPCFolder() -> MPCDestination? {
        let panel = NSOpenPanel()
        panel.title = "Export to MPC"
        panel.message = "A folder to write the MPC plugin and the songs in (VST2 Plugins/…), to copy onto the card yourself"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        return MPCDestination(url: url, name: url.lastPathComponent, free: Int64(free ?? 0), isVolume: false)
    }

    /// The export planned for a destination (the songs are read, nothing is written).
    func planMPCExport(to destination: MPCDestination) -> MPCExport? {
        guard let setlist, let setlistURL else { return nil }
        return MPCExport(setlist: setlist, at: setlistURL, to: destination.url, bundledPlugin: bundledMPCPlugin)
    }

    /// Backups go to ~/Music/DubStemMix/MPC Backups/DubStemMix 2026-11-16 21.40.
    static func mpcBackupFolder() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Music/DubStemMix/MPC Backups/DubStemMix \(formatter.string(from: .now))", directoryHint: .isDirectory)
    }

    func exportToMPC(_ destination: MPCDestination, backUp: Bool) {
        guard let export = planMPCExport(to: destination), exportTask == nil else { return }
        showMPCExport = false
        mpcExport = .exporting(fraction: 0)
        let backupFolder = backUp && export.hasExisting ? Self.mpcBackupFolder() : nil
        exportTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<MPCExport.Report, Error> in
                Result {
                    if let backupFolder { try export.backUp(to: backupFolder) }
                    return try export.run { fraction in
                        Task { @MainActor in
                            if case .exporting = self?.mpcExport { self?.mpcExport = .exporting(fraction: fraction) }
                        }
                    }
                }
            }.value
            guard let self else { return }
            exportTask = nil
            switch result {
            case let .success(report):
                mpcExport = .done(root: destination.url, report: report, volume: destination.isVolume, backup: backupFolder)
            case let .failure(error):
                mpcExport = .failed(error.localizedDescription)
            }
        }
    }

    func ejectMPC(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            mpcExport = .idle
        } catch {
            mpcExport = .failed("Could not eject: \(error.localizedDescription)")
        }
    }
}
