import AppKit
import DubStemMixCore
import StemSplit
import UniformTypeIdentifiers

/// What the separation is doing, for the sidebar (PRD § 12.4).
enum SeparationState: Equatable {
    case idle
    case downloading(received: Int64, total: Int64)
    case splitting(song: String, stem: Stem, fraction: Double, started: Date)

    var isActive: Bool { self != .idle }
}

/// A full song dropped in the split zone → four stems on strips 1 to 4 (PRD § 12).
extension AppModel {
    static let modelStore = ModelStore(directory: ModelStore.defaultDirectory)

    static let defaultStemsFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "DubStemMix/Stems")

    static func storedStemsFolder() -> URL {
        UserDefaults.standard.string(forKey: Preference.stemsFolder).map { URL(fileURLWithPath: $0) } ?? defaultStemsFolder
    }

    func refreshModelStatus() {
        modelStatus = Self.modelStore.status
    }

    // MARK: Entry points

    func chooseSongToSplit() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a full song to split into drums, bass, instruments and vocals"
        if panel.runModal() == .OK, let url = panel.url { splitSong(url) }
    }

    /// Checks, consent and warnings happen here; the work itself starts in `startSplit`.
    func splitSong(_ url: URL) {
        guard !isPreview else { return }
        guard !separation.isActive else {
            errorMessage = "A separation is already running"
            return
        }
        guard StemImporter.audioFiles(in: [url]).count == 1 else {
            errorMessage = "Drop one audio file (WAV, MP3, AIFF, FLAC, M4A…)"
            return
        }
        if isPlaying {
            let alert = NSAlert()
            alert.messageText = "Split while playing?"
            alert.informativeText = "Splitting a song takes several minutes of heavy CPU work and may cause audio dropouts. Stop playback first if you are performing."
            alert.addButton(withTitle: "Split anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard confirmDiscardingUnsavedSession() else { return }
        if Self.modelStore.isReady {
            startSplit(url)
        } else if consentToDownload() {
            pendingSong = url
            startDownload()
        }
    }

    /// Never a silent download (PRD § 12.2): size, source and license status are on the screen.
    private func consentToDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the separation engine?"
        let megabytes = Int(Double(ModelCatalog.totalBytes) / 1e6)
        alert.informativeText = """
            Splitting songs needs the \(ModelCatalog.name) model: four files, \(megabytes) MB in total, downloaded once from \
            Hugging Face (\(ModelCatalog.repository)) into ~/Library/Application Support/DubStemMix.

            \(ModelCatalog.licenseNotice)
            """
        alert.addButton(withTitle: "Download \(megabytes) MB")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Models

    func startDownload() {
        guard !separation.isActive else { return }
        separation = .downloading(received: 0, total: ModelCatalog.totalBytes)
        errorMessage = nil
        separationTask = Task { [weak self] in
            do {
                try await Self.modelStore.download { received, total in
                    Task { @MainActor in
                        guard let self, case .downloading = self.separation else { return }
                        self.separation = .downloading(received: received, total: total)
                    }
                }
                guard let self else { return }
                separation = .idle
                refreshModelStatus()
                if let song = pendingSong {
                    pendingSong = nil
                    startSplit(song)
                }
            } catch is CancellationError {
                self?.separation = .idle
                self?.pendingSong = nil
            } catch {
                self?.separation = .idle
                self?.pendingSong = nil
                self?.errorMessage = "Download failed: \(error.localizedDescription)"
            }
            self?.refreshModelStatus()
        }
    }

    func deleteModels() {
        guard !separation.isActive else { return }
        do {
            try Self.modelStore.delete()
            errorMessage = nil
        } catch {
            errorMessage = "Can't delete the models: \(error.localizedDescription)"
        }
        refreshModelStatus()
    }

    // MARK: The split itself

    private func startSplit(_ url: URL) {
        let song = url.deletingPathExtension().lastPathComponent
        separation = .splitting(song: song, stem: .drums, fraction: 0, started: .now)
        errorMessage = nil
        let root = stemsFolder
        let store = Self.modelStore
        separationTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let result = try await SeparationJob.run(source: url, outputRoot: root, separator: { OnnxStemSeparator(store: store) }) { progress in
                    Task { @MainActor in
                        guard let self, case let .splitting(song, _, _, started) = self.separation else { return }
                        self.separation = .splitting(song: song, stem: progress.stem, fraction: progress.fraction, started: started)
                    }
                }
                guard let self else { return }
                separation = .idle
                loadSeparated(result, source: url)
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            } catch is CancellationError {
                self?.separation = .idle
            } catch {
                self?.separation = .idle
                self?.errorMessage = "Split failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelSeparation() {
        separationTask?.cancel()
        separationTask = nil
        pendingSong = nil
    }

    /// New session: the four stems in order on strips 1 to 4, the original in the pool for A/B listening.
    private func loadSeparated(_ result: SeparationResult, source: URL) {
        engine.stop()
        clear()
        resetEffects()
        titleOverride = StemImporter.sessionTitle(for: [source])
        for (strip, stem) in Stem.allCases.enumerated() {
            guard let url = result.stems[stem] else { continue }
            stripNames[strip] = stem.label
            assign([url], toStrip: strip)
        }
        addToPool([source])
        refreshNames()
    }

    // MARK: Stems folder (Settings)

    func chooseStemsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = stemsFolder
        panel.message = "Choose where separated stems are written"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        stemsFolder = folder
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: Preference.stemsFolder)
    }

    func resetStemsFolder() {
        stemsFolder = Self.defaultStemsFolder
        UserDefaults.standard.removeObject(forKey: Preference.stemsFolder)
    }
}
