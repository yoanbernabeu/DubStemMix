import AppKit
import AVFoundation
import DubStemMixCore
import StemSplit
import UserNotifications

/// Several songs dropped at once, split one after the other into ready projects (PRD § 12.6). A mode of its own:
/// the console is hidden and playback is off while it lasts.
extension AppModel {
    /// Seconds of work per second of audio, measured on the last song split on this Mac.
    static func storedSplitSpeed() -> Double? {
        let speed = UserDefaults.standard.double(forKey: Preference.splitSpeed)
        return speed > 0 ? speed : nil
    }

    /// A song is being split, or the engine is being downloaded for the queue.
    var prepBusy: Bool { prepTask != nil || separation.isActive }

    // MARK: Entry points

    func chooseSongsToPrepare() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = "Choose the songs to prepare (each one gets its stems and a ready project)"
        if panel.runModal() == .OK { prepareSongs(panel.urls) }
    }

    /// From the sidebar zone (enters the mode) or from the preparation screen (adds to the queue).
    func prepareSongs(_ urls: [URL]) {
        guard !isPreview else { return }
        let files = StemImporter.audioFiles(in: urls)
        if !preparing {
            guard !separation.isActive else {
                errorMessage = "A separation is already running"
                return
            }
            guard !files.isEmpty else {
                errorMessage = "Drop audio files (WAV, MP3, AIFF, FLAC, M4A…) or a folder of songs"
                return
            }
            if engine.isPlaying {
                let alert = NSAlert()
                alert.messageText = "Stop playback and prepare songs?"
                alert.informativeText = "Playback stays off while songs are being prepared. Your session stays open: you find it again when you go back to the console."
                alert.addButton(withTitle: "Stop and Prepare")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            disarm()
            engine.pause()
            isPlaying = false
            preparing = true
            errorMessage = nil
            askNotificationPermission()
        }
        prepQueue.add(files.map { ($0, Self.audioDuration(of: $0)) })
        startPreparing()
    }

    /// Runs the queue, after the engine's download if it is not there yet (never without consent, PRD § 12.2).
    func startPreparing() {
        guard !prepBusy, prepQueue.waitingCount > 0 else { return }
        if Self.modelStore.isReady {
            runPrepQueue()
        } else if consentToDownload() {
            startDownload() // runs the queue once done
        }
    }

    /// Back to the console; only when nothing runs. Songs still waiting (engine not downloaded) are dropped.
    func leavePreparation() {
        guard !prepBusy else { return }
        prepQueue.removeAll()
        preparing = false
        errorMessage = nil
    }

    /// Stops the running song (its half-made stems are removed) and empties the queue; finished songs stay.
    func cancelPreparation() {
        prepTask?.cancel()
        prepTask = nil
        cancelSeparation()
        separation = .idle
        prepQueue.cancelAll()
    }

    func removeFromPrepQueue(_ id: UUID) { prepQueue.remove(id) }
    func movePrepSong(_ id: UUID, onto target: UUID) { prepQueue.move(id, onto: target) }
    func movePrepSong(_ id: UUID, by offset: Int) { prepQueue.move(id, by: offset) }

    /// ⌘Q and the window's close button: songs waiting are lost, the finished ones stay on disk.
    func confirmQuit() -> Bool {
        guard prepQueue.hasWork, !isPreview else { return confirmWhilePlaying("Quit") }
        let alert = NSAlert()
        alert.messageText = "Songs are being prepared"
        let left = prepQueue.waitingCount + (prepQueue.running == nil ? 0 : 1)
        alert.informativeText = "Quitting drops the \(left) song\(left == 1 ? "" : "s") not prepared yet. Songs already prepared stay on disk."
        alert.addButton(withTitle: "Keep Preparing")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The console's actions (open, new session, split one song) wait until the preparation screen is left.
    func refusedWhilePreparing() -> Bool {
        guard preparing else { return false }
        errorMessage = "Go back to the console first (when the songs are prepared)"
        return true
    }

    // MARK: Time left

    /// Seconds left for the whole queue: the running song from its own progress, the waiting ones at the speed
    /// measured on this Mac (or, the first time, on the running song).
    var prepTimeLeft: Double? {
        var runningRemaining: Double?
        var liveSpeed: Double?
        if case let .splitting(_, _, fraction, started) = separation, fraction > 0.02 {
            let elapsed = Date().timeIntervalSince(started)
            runningRemaining = elapsed * (1 - fraction) / fraction
            if let duration = prepQueue.running?.duration, duration > 0 { liveSpeed = elapsed / fraction / duration }
        }
        return prepQueue.remainingTime(secondsPerAudioSecond: splitSpeed ?? liveSpeed, runningRemaining: runningRemaining)
    }

    // MARK: The queue itself

    private func runPrepQueue() {
        guard prepTask == nil else { return }
        prepTask = Task { [weak self] in
            while let self, let item = prepQueue.startNext() {
                let status = await prepare(item)
                if Task.isCancelled { return } // cancelPreparation has already cleaned up
                prepQueue.finish(item.id, status)
            }
            guard let self else { return }
            prepTask = nil
            separation = .idle
            announcePrepared()
        }
    }

    /// One song: its stems (or the ones already there), then its project next to them, unless one is already there.
    private func prepare(_ item: SplitQueue.Item) async -> SplitQueue.Status {
        let title = StemImporter.songTitle(for: item.source)
        let started = Date.now
        separation = .splitting(song: title, stem: .drums, fraction: 0, started: started)
        let root = stemsFolder
        let store = Self.modelStore
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let result = try await SeparationJob.run(source: item.source, outputRoot: root, separator: { OnnxStemSeparator(store: store) }) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case let .splitting(song, _, _, started) = separation, song == title else { return }
                    separation = .splitting(song: song, stem: progress.stem, fraction: progress.fraction, started: started)
                }
            }
            if Task.isCancelled { return .failed("cancelled") } // the state belongs to whatever comes next
            if !result.reused, let duration = item.duration, duration > 0 {
                splitSpeed = Date().timeIntervalSince(started) / duration
                UserDefaults.standard.set(splitSpeed, forKey: Preference.splitSpeed)
            }
            separation = .idle
            let (document, reused) = try await Self.writePreparedProject(result, source: item.source, duration: item.duration)
            return .done(project: document, reused: reused)
        } catch {
            if !Task.isCancelled { separation = .idle }
            return .failed(item.duration == nil ? "Can't read this audio file" : error.localizedDescription)
        }
    }

    /// The song's project next to its stems, as a split would leave the session; an existing one is left untouched.
    nonisolated static func writePreparedProject(_ result: SeparationResult, source: URL, duration: Double?) async throws -> (URL, reused: Bool) {
        let title = StemImporter.songTitle(for: source)
        let name = (title.isEmpty ? "Untitled" : title.capitalized).replacingOccurrences(of: "/", with: "-")
        let document = result.folder.appending(path: name + "." + Project.fileExtension)
        if FileManager.default.fileExists(atPath: document.path) { return (document, true) }
        let stems = Stem.allCases.compactMap { stem in result.stems[stem].map { (url: $0, name: stem.label) } }
        let bpm = await TempoDetector.detect(urls: stems.map(\.url))
        let length = stems.compactMap { audioDuration(of: $0.url) }.max() ?? duration ?? 0
        let project = Project.separated(title: title, stems: stems, original: source, duration: length, bpm: bpm, document: document)
        try project.save(to: document)
        return (document, false)
    }

    // MARK: End of the queue

    private func askNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return } // `swift run`: no bundle, no notifications
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func announcePrepared() {
        let done = prepQueue.doneCount
        let failed = prepQueue.failedCount
        guard done + failed > 0 else { return }
        if NSApp?.isActive == false { NSApp.requestUserAttention(.informationalRequest) } // no NSApp in command-line checks
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Songs ready"
        content.body = "\(done) song\(done == 1 ? "" : "s") prepared" + (failed > 0 ? " · \(failed) failed" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Length in seconds, nil when the file can't be read.
    nonisolated static func audioDuration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

extension AppModel {
    /// Demo queue for the PNG capture (`--snapshot out.png --prepare`).
    func loadPreviewPreparation() {
        preparing = true
        let songs = ["Akae Beka - Dont Feel No Way", "Midnite - Ras To The Bone", "Jah Sun - Lion Heart",
                     "Vaughn Benjamin - Iyanola", "Danny Red - Riddimwise", "Kiddus I - Graceful Dub"]
        prepQueue.add(songs.enumerated().map { (URL(fileURLWithPath: "/Music/Set/\($0.element).mp3"), Double(200 + $0.offset * 37)) })
        let ids = prepQueue.items.map(\.id)
        prepQueue.finish(ids[0], .done(project: URL(fileURLWithPath: "/Music/Stems/A.dubstem"), reused: false))
        prepQueue.finish(ids[1], .failed("The file couldn't be read"))
        _ = prepQueue.startNext()
        separation = .splitting(song: "JAH SUN - LION HEART", stem: .bass, fraction: 0.38, started: Date().addingTimeInterval(-100))
        splitSpeed = 1.17
        prepTask = Task {}
    }
}
