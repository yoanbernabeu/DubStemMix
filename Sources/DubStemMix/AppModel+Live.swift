import AppKit
import DubStemMixCore

/// Live use: the screen stays on while playing, nothing done by mistake cuts the sound, PANIC, the next song of
/// the setlist armed while the current one plays, and the setlist's rack.
extension AppModel {
    // MARK: Screen

    /// The console is played, not the Mac: macOS would think it idle and put the screen to sleep mid-set.
    /// Held only while playing, so a Mac left stopped sleeps as usual. Also keeps App Nap away.
    func keepScreenAwake(_ playing: Bool) {
        guard !isPreview else { return }
        if playing, screenActivity == nil {
            screenActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing a version"
            )
        } else if !playing, let activity = screenActivity {
            ProcessInfo.processInfo.endActivity(activity)
            screenActivity = nil
        }
    }

    // MARK: Notices

    /// A word in the top bar for three seconds.
    func showNotice(_ text: String) {
        notice = text
        noticeCountdown = 90
    }

    func tickNotice() {
        guard notice != nil else { return }
        noticeCountdown -= 1
        if noticeCountdown <= 0 { notice = nil }
    }

    // MARK: Nothing cuts the sound by mistake

    /// While playing, what would cut the sound (rewiring the graph, a stem put on or taken off) is refused.
    /// - Returns: true when refused (the reason shows in the top bar).
    func refusedWhilePlaying(_ action: String) -> Bool {
        guard engine.isPlaying else { return false }
        showNotice("Stop playback to \(action)")
        return true
    }

    /// Quitting, a new session, another project: asked first while playing. The safe answer is the default.
    func confirmWhilePlaying(_ action: String) -> Bool {
        guard engine.isPlaying, !isPreview else { return true }
        let alert = NSAlert()
        alert.messageText = "Playback is running"
        alert.informativeText = "\(action) stops the music."
        alert.addButton(withTitle: "Keep Playing")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // What the screen offers: the same actions as before, refused while playing when they would cut.

    func pickPlugin(_ info: PluginInfo, on bus: SendBus) {
        guard !refusedWhilePlaying("change a bus plugin") else { return }
        loadPlugin(info, on: bus)
    }

    /// The bus's built-in effect: plate / spring and phaser / flanger change while playing, a plugin can't go.
    func pickBuiltInEffect(on bus: SendBus, reverb: ReverbModel? = nil, bus3: Bus3Model? = nil) {
        if engine.plugins[bus] != nil, refusedWhilePlaying("remove a bus plugin") { return }
        if let reverb { setReverbModel(reverb) }
        if let bus3 { setBus3Model(bus3) }
        useBuiltInEffect(on: bus)
    }

    /// Patching goes through memory, not the graph: allowed while playing, nothing is cut.
    func pickBusSend(from source: SendBus, to target: SendBus?) {
        setBusSend(from: source, to: target)
    }

    /// Built-in inserts change while playing (crossfaded); taking a plugin insert out rewires.
    func pickInsert(strip: Int, _ kind: InsertKind?) {
        if engine.insertPlugins[strip] != nil, refusedWhilePlaying("remove a plugin insert") { return }
        setInsert(strip: strip, kind)
    }

    func pickInsertPlugin(_ info: PluginInfo, strip: Int) {
        guard !refusedWhilePlaying("load a plugin insert") else { return }
        loadInsertPlugin(info, strip: strip)
    }

    func placeStems(_ urls: [URL], onStrip strip: Int) {
        guard !refusedWhilePlaying("place stems") else { return }
        assign(urls, toStrip: strip)
    }

    func takeOffStrip(_ id: UUID, remove: Bool) {
        guard !refusedWhilePlaying("take a stem off its strip") else { return }
        if remove { removeStem(id) } else { unassign(id) }
    }

    /// Double-click or ⌥-click on the waveform while playing; a plain click only when stopped.
    func seekFromWaveform(fraction: Double, deliberate: Bool) {
        guard duration > 0 else { return }
        guard !engine.isPlaying || deliberate else {
            showNotice("Double-click (or ⌥-click) the waveform to move while playing")
            return
        }
        seek(fraction: fraction)
    }

    // MARK: PANIC

    /// Esc, or BANK LEFT + BANK RIGHT on the console: the three buses emptied at once, the tune plays on.
    func panic() {
        guard !isPreview else { return }
        engine.clearEffects()
        holding = false
        panicFlash = .now
        showNotice("FX cleared")
    }

    // MARK: The next song, armed while this one plays

    var armedIndex: Int? {
        guard let armedSong else { return nil }
        return setlistEntries.firstIndex { $0.reference == armedSong }
    }

    /// N / P while playing: the song after (or before) the armed one, or the current one.
    func armSong(offset: Int) {
        guard !setlistEntries.isEmpty else { return }
        let base = armedIndex ?? setlistIndex ?? (offset > 0 ? -1 : setlistEntries.count)
        arm(at: base + offset)
    }

    /// Arms a song of the setlist; the current one disarms. Nothing is cut: the song loads when launched.
    func arm(at index: Int) {
        guard setlistEntries.indices.contains(index), setlistEntries[index].url != nil else { return }
        guard index != setlistIndex else {
            disarm()
            return
        }
        armedSong = setlistEntries[index].reference
        armWarning = tailsCutWarning(for: setlistEntries[index])
    }

    func disarm() {
        armedSong = nil
        armWarning = nil
    }

    /// With the setlist's rack, only plugin inserts still rewire the graph between two songs (built-in inserts
    /// switch, the buses stay as they are).
    private func tailsCutWarning(for entry: SetlistEntry) -> String? {
        let next = entry.url.flatMap { try? Project.load(from: $0) }
        let nextHasPluginInserts = next?.inserts?.values.contains { $0.plugin != nil } ?? false
        guard nextHasPluginInserts || !engine.insertPlugins.isEmpty else { return nil }
        return "plugin inserts: tails will be cut"
    }

    /// The selector's drop: the current song stops dead, the armed one starts from the top, the tails go on.
    func launchArmed() {
        guard let index = armedIndex, let url = setlistEntries[index].url else {
            disarm()
            return
        }
        disarm()
        openProject(url)
        engine.play()
        isPlaying = engine.isPlaying
    }

    // MARK: The setlist's rack

    /// What is patched on the buses right now, in the project's encoding.
    var currentRack: Rack {
        let slots = currentSlots()
        return Rack(
            reverbModel: reverbModel == .plate ? nil : reverbModel.rawValue,
            bus3Model: bus3Model == .phaser ? nil : bus3Model.rawValue,
            busSends: busRouting.projectValue,
            slots: slots.isEmpty ? nil : slots
        )
    }

    func isInSetlist(_ document: URL) -> Bool {
        setlistEntries.contains { $0.url?.standardizedFileURL == document.standardizedFileURL }
    }

    /// Puts a rack in place. What is already there stays as it is: the same rack twice rewires nothing.
    /// - Returns: the rack's plugins missing on this Mac (kept in the rack, built-in effect used instead).
    func applyRack(_ rack: Rack) -> [String] {
        setReverbModel(rack.reverbModel.flatMap(ReverbModel.init) ?? .plate)
        setBus3Model(rack.bus3Model.flatMap(Bus3Model.init) ?? .phaser)
        setBusRouting(BusRouting(projectValue: rack.busSends))
        var toLoad: [String: Project.SlotEntry] = [:]
        for bus in SendBus.allCases {
            let loaded = engine.plugins[bus]?.info.id
            if let wanted = rack.slots?[bus.key] {
                if loaded != wanted.plugin.id { toLoad[bus.key] = wanted }
            } else if loaded != nil {
                unloadPlugin(on: bus)
            }
        }
        unresolvedSlots = toLoad
        return restoreSlots()
    }

    /// Called with the autosave: the rack as played is the setlist's (plugin settings included).
    func saveSetlistRackIfNeeded() {
        guard setlistIndex != nil, var setlist, setlist.rack != currentRack else { return }
        let rewired = !(setlist.rack.map { $0.isWiredLike(currentRack) } ?? false)
        setlist.rack = currentRack
        self.setlist = setlist
        if let setlistURL { try? setlist.save(to: setlistURL) }
        if rewired { refreshSetlistEntries() } // the "own rack" marks follow
    }

    // MARK: Setlist check

    /// Keeps an eye on the setlist when coming back to the app: a disk may have been plugged in meanwhile.
    func watchActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSetlistEntries() }
        }
    }

    /// What would go wrong when opening a song, found before the set: stems not found, plugins not installed.
    /// The songs' own bus plugins are not checked in a setlist: the setlist's rack is played instead.
    func problems(of project: Project, at url: URL) -> [String] {
        var problems: [String] = []
        let missing = project.stems.filter { $0.file.resolve(relativeTo: url) == nil }.count
        if missing > 0 { problems.append("\(missing) stem\(missing == 1 ? "" : "s") not found") }
        let installed = Set(installedPlugins.map(\.id))
        for plugin in (project.inserts ?? [:]).values.compactMap(\.plugin) where !installed.contains(plugin.id) {
            problems.append("\(plugin.name) not installed")
        }
        return problems
    }

    var setlistHasMissingStems: Bool { setlistEntries.contains { $0.missingStems } }

    /// One folder for the whole setlist: every missing stem is looked for by name in it and its subfolders, and
    /// the songs are saved with the files found.
    func locateMissingStemsInSetlist() {
        guard !refusedWhilePlaying("relink stems") else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder holding the missing stems (its subfolders are searched too)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        relinkMissingStems(in: folder)
    }

    func relinkMissingStems(in folder: URL) {
        var byName: [String: [URL]] = [:]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let file = files?.nextObject() as? URL { byName[file.lastPathComponent, default: []].append(file) }

        var found = 0, still = 0, reopen = false
        for entry in setlistEntries {
            guard let url = entry.url, var project = try? Project.load(from: url) else { continue }
            var changed = false
            for index in project.stems.indices where project.stems[index].file.resolve(relativeTo: url) == nil {
                if let file = project.stems[index].file.bestMatch(in: byName) {
                    project.stems[index].file = FileReference(file, relativeTo: url)
                    changed = true
                    found += 1
                } else {
                    still += 1
                }
            }
            guard changed else { continue }
            try? project.save(to: url)
            if url.standardizedFileURL == projectURL?.standardizedFileURL { reopen = true }
        }
        if reopen, let projectURL { openProject(projectURL) } // stopped: the open song gets its stems now
        refreshSetlistEntries()
        showNotice(still == 0 ? "\(found) stem\(found == 1 ? "" : "s") found" : "\(found) found · \(still) still missing")
    }
}

/// Closing the window quits the app: while playing, the red button and ⌘W ask first. Stands in front of the
/// window's own delegate (SwiftUI's) and hands it everything else.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { shouldClose() } && (original?.windowShouldClose?(sender) ?? true)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }
}
