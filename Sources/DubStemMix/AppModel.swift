import DubStemMixCore
import StemSplit
import SwiftUI

/// Relie le moteur audio, la MIDImix et la logique de mix à l'interface.
@MainActor
@Observable
final class AppModel {
    let mix: MixController
    let isPreview: Bool
    @ObservationIgnored let engine: AudioEngine
    @ObservationIgnored private let midi = MidiMix()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keys: KeyGestures?
    @ObservationIgnored var peaksByStem: [UUID: [Float]] = [:]

    var title = ""
    var waveform: [Float] = []
    var midiConnected = false
    /// First message received that the factory mapping does not know (the console was reconfigured).
    var midiWarning: String?
    /// Output device name, then its sample rate and buffer size, as shown in the status bar.
    var audioDevice = ""
    var audioFormat = ""
    /// Worst audio-thread load over the last moments (1 = no headroom left), and dropouts since launch.
    var dspLoad: Float = 0
    var dropouts = 0
    @ObservationIgnored private var audioStatusCountdown = 0
    var errorMessage: String?
    var pool: [PoolItem] = []
    /// Strip names typed by the user; a strip without one is named after its first stem.
    var stripNames: [Int: String] = [:]
    // Documents : projet (.dubstem) et setlist (.dubset). Voir AppModel+Documents.swift.
    var projectURL: URL?
    /// Dernier état écrit sur le disque, pour savoir s'il reste des changements à enregistrer.
    var savedProject: Project?
    /// Stems du projet dont le fichier est introuvable : conservés tels quels jusqu'à ce qu'on les relocalise.
    var unresolvedStems: [Project.StemEntry] = []
    var setlist: Setlist?
    var setlistURL: URL?
    var setlistEntries: [SetlistEntry] = []
    /// File ▸ Open Recent and the Dock menu: the recent projects and setlists still on disk. See AppModel+Recent.swift.
    var recentFiles: [URL] = []
    @ObservationIgnored var recentDocuments = AppModel.storedRecentDocuments()
    @ObservationIgnored var autosaveCountdown = 0

    // Plugins Audio Unit. Voir AppModel+Plugins.swift.
    var installedPlugins: [PluginInfo] = []
    /// Bus en cours de chargement d'un plugin.
    var loadingPlugin: Set<SendBus> = []
    /// Slots du projet pas (encore) chargés — plugin absent de ce Mac, ou chargement en cours. Conservés dans le projet.
    var unresolvedSlots: [String: Project.SlotEntry] = [:]
    @ObservationIgnored var pluginStates: [SendBus: Data] = [:]
    @ObservationIgnored var pluginStateCountdown = 0
    /// First launch: the welcome panel, until dismissed once (Help ▸ Welcome reopens it).
    var showWelcome = !UserDefaults.standard.bool(forKey: Preference.welcomeShown)

    // Stem separation (PRD § 12). See AppModel+Separation.swift.
    var separation = SeparationState.idle
    var modelStatus = ModelStore.Status.missing
    var stemsFolder = AppModel.storedStemsFolder()
    @ObservationIgnored var separationTask: Task<Void, Never>?
    @ObservationIgnored var pendingSong: URL?
    // Setlist workshop (PRD § 13). See AppModel+Workshop.swift.
    var editingSetlists = false
    var workshopSetlists: [WorkshopSetlist] = []
    var workshopURL: URL?
    var workshopSetlist: Setlist?
    var workshopEntries: [SetlistEntry] = []
    /// Tags already used in the setlists folder, offered when tagging a line.
    var workshopTags: [String] = []
    var library: [LibrarySong] = []
    var libraryScanning = false
    /// A song refused because it is already in the set: its line blinks.
    var workshopBlink: URL?
    /// When the setlist being edited was last written (every change is), shown as "SAVED · 18:42".
    var workshopSavedAt: Date?
    /// Songs played at least 30 s this session: greyed with ✓ in the setlist, forgotten when the app quits.
    var playedSongs: Set<URL> = []
    @ObservationIgnored var playedSeconds: [URL: Double] = [:]
    /// The song being listened to in the workshop (its project), its progress and its waveform.
    var previewing: URL?
    var previewPosition = 0.0
    var previewDuration = 0.0
    var previewPeaks: [Float] = []
    @ObservationIgnored let previewPlayer = PreviewPlayer()
    @ObservationIgnored var previewTicker: Task<Void, Never>?
    /// Music ▸ DubStemMix ▸ Setlists and Music ▸ DubStemMix; elsewhere for the self-checks.
    @ObservationIgnored var setlistsFolder = AppModel.defaultSetlistsFolder
    @ObservationIgnored var libraryFolder = AppModel.defaultLibraryFolder
    // Preparation mode (PRD § 12.6). See AppModel+Preparation.swift.
    var preparing = false
    var prepQueue = SplitQueue()
    @ObservationIgnored var prepTask: Task<Void, Never>?
    var splitSpeed = AppModel.storedSplitSpeed()
    /// Session title set by a split (the stems are named drums, bass… and would give no title).
    var titleOverride: String?

    // Strip inserts. See AppModel+Inserts.swift.
    var loadingInsert: Set<Int> = []
    var unresolvedInserts: [String: Project.InsertEntry] = [:]
    @ObservationIgnored var insertStates: [Int: Data] = [:]
    var bus3Model = Bus3Model.phaser
    @ObservationIgnored let pluginWindows = PluginWindows()

    var detectingTempo = false
    @ObservationIgnored private var taps: [Date] = []

    // Delay and reverb (PRD § 11.4): mirrors of the engine's state, for the interface and the project.
    var reverbModel = ReverbModel.plate
    var throwTarget = ThrowTarget.delay
    /// Where each bus's return is sent besides the master (issue #1).
    var busRouting = BusRouting.standard
    /// HOLD held (H, or MUTE of strip 7): the delay loops on itself.
    var holding: Bool { mix.holding }

    // Preferences. See AppModel+Settings.swift.
    /// Per bus (`SendBus.rawValue`): send taken before the fader and mute.
    var sendPreFader = AppModel.storedSendPreFader()
    var recordingsFolder = AppModel.storedRecordingsFolder()
    /// Output devices offered in Settings, and the one in use (its UID) with its buffer size.
    var outputDevices: [AudioDeviceInfo] = []
    var outputDeviceUID = ""
    var bufferFrames = 0

    // Live use. See AppModel+Live.swift.
    /// A word in the top bar for a few seconds ("FX cleared", "Stop playback to…").
    var notice: String?
    @ObservationIgnored var noticeCountdown = 0
    /// Last PANIC, for the bus cards' flash.
    var panicFlash: Date?
    /// The setlist song armed while the current one plays (N / P, or a click on its row): Space launches it.
    var armedSong: FileReference?
    /// Why launching the armed song will still cut the effect tails, if it will.
    var armWarning: String?
    /// The open song's own rack while it plays through the setlist's: written back to its file untouched.
    @ObservationIgnored var songRack: Rack?
    /// Setlist export to another Mac, see AppModel+Documents.swift.
    var setlistExport = SetlistExportState.idle
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var screenActivity: NSObjectProtocol?
    @ObservationIgnored var activationObserver: NSObjectProtocol?

    var isRecording = false
    var recordingTime = 0.0
    /// Folder of the last finished session (to find it in the Finder).
    var lastRecording: URL?
    /// The session being recorded and its folder (AppModel+Recording).
    @ObservationIgnored var recordingSession: RecordingSession?
    @ObservationIgnored var recordingFolder: URL?
    /// Bumped each time a song is loaded: the first play of a new load enters the tracklist.
    @ObservationIgnored var songLoads = 0
    @ObservationIgnored var loggedSongLoad: Int?
    /// The Recorded Sessions window: sessions found in the recordings folder, MP3 exports in progress (0…1) and
    /// the last export error, by session folder.
    var recordedSessions: [RecordingSession.Entry] = []
    var sessionExports: [URL: Double] = [:]
    var sessionExportErrors: [URL: String] = [:]
    @ObservationIgnored var sessionExportTasks: [URL: Task<Void, Never>] = [:]

    /// A newer release found on GitHub, and where installing it stands (AppModel+Updates).
    var availableUpdate: ReleaseInfo?
    var updateStatus = UpdateStatus.idle
    var automaticUpdateChecks = UserDefaults.standard.object(forKey: Preference.automaticUpdateChecks) as? Bool ?? true
    var limiterOn = UserDefaults.standard.object(forKey: Preference.limiterOn) as? Bool ?? true
    /// dB the limiter takes off (limiter on) or the output goes over full scale (limiter off), held 1.5 s.
    var limiterAmount: Float = 0
    /// Highest `limiterAmount` since the last reset (click on the readout).
    var limiterAmountMax: Float = 0
    private var limiterHoldTicks = 0
    /// Pire charge DSP récente, suivie à chaque tick ; `dspLoad` n'en est que l'affichage, publié deux fois par seconde.
    @ObservationIgnored private var dspPeak: Float = 0
    @ObservationIgnored private var dspDisplayTicks = 0

    // Rafraîchis 30 fois par seconde.
    var isPlaying = false
    var looping = true
    var position = 0.0
    var duration = 0.0
    var levels = [Float](repeating: 0, count: AudioEngine.meterCount)

    /// - Parameter preview: données de démonstration, sans carte son ni console (rendu PNG de l'interface).
    /// - Parameter demoData: faux → modèle hors ligne vide (auto-contrôle des documents).
    init(preview: Bool = false, demoData: Bool = true) throws {
        isPreview = preview
        engine = try AudioEngine(offline: preview, effects: true)
        mix = MixController(engine: engine, surface: preview ? nil : midi)
        installedPlugins = PluginInfo.installed()
        for bus in SendBus.allCases { engine.setSendPreFader(bus, sendPreFader[bus.rawValue]) }
        watchPluginCrashes()
        if preview {
            if demoData { loadPreviewData() }
            return
        }
        applyStoredAudioPreferences()
        refreshAudioStatus()
        refreshModelStatus()
        midi.onEvent = { [weak self] in self?.mix.handle($0) }
        mix.onPanic = { [weak self] in self?.panic() }
        watchActivation()
        refreshRecentFiles()
        midi.onConnectionChange = { [weak self] connected in
            self?.midiConnected = connected
            self?.midiWarning = nil // a console plugged back in gets a fresh chance
            if connected { self?.mix.refreshSurface() }
        }
        midi.onUnmappedMessage = { [weak self] description in
            if self?.midiWarning == nil { self?.midiWarning = description }
        }
        midi.start()
        keys = KeyGestures { [weak self] key, down in self?.handleGestureKey(key, down: down) ?? false }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutDown() {
        if isRecording { toggleRecording() }
        engine.stop()
        midi.allLedsOff()
    }

    /// Limiter on: what it took off since the last tick, as it reports it. Off: how far what reaches it goes
    /// over full scale, which is what clips.
    private func trackLimiter(input: Float) {
        let reduction = engine.takeLimiterReduction()
        let amount: Float = limiterOn ? reduction : (input > 1 ? 20 * log10(input) : 0)
        let now = amount < 0.1 ? 0 : amount
        if now >= limiterAmount {
            update(\.limiterAmount, now)
            limiterHoldTicks = 45
        } else if limiterHoldTicks > 0 {
            limiterHoldTicks -= 1
        } else {
            update(\.limiterAmount, now)
        }
        update(\.limiterAmountMax, max(limiterAmountMax, now))
    }

    func resetLimiterMax() { limiterAmountMax = 0 }

    /// @Observable signale chaque assignation, même d'une valeur identique : à 30 Hz, ça relançait sans fin la
    /// mise en page de la fenêtre sur le MainActor — celui qui reçoit aussi le MIDI, qui arrivait alors en retard.
    /// Le tick n'écrit donc que ce qui a changé.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func tick() {
        engine.tick()
        update(\.isPlaying, engine.isPlaying)
        keepScreenAwake(isPlaying)
        tickNotice()
        update(\.position, engine.position)
        update(\.duration, engine.duration)
        countPlayedTime()
        var peaks = levels
        var decayed = levels
        for index in levels.indices {
            peaks[index] = engine.meters.take(index)
            let level = max(peaks[index], levels[index] * 0.85)
            decayed[index] = level < 0.001 ? 0 : level // la décroissance s'arrête à zéro au lieu de changer sans fin
        }
        update(\.levels, decayed)
        trackLimiter(input: peaks[AudioEngine.limiterInputMeter])
        // La charge bouge à chaque tick : la publier 30 fois par seconde redessinait sans fin pour un pourcentage.
        dspPeak = max(engine.load.takePeak(), dspPeak * 0.9)
        dspDisplayTicks += 1
        if dspDisplayTicks >= 15 {
            dspDisplayTicks = 0
            update(\.dspLoad, (dspPeak * 100).rounded() / 100)
        }
        update(\.dropouts, engine.load.overloadCount)
        audioStatusCountdown -= 1
        if audioStatusCountdown <= 0 { // once a second: the device may have changed under us
            audioStatusCountdown = 30
            refreshAudioStatus()
        }
        followPlugins()
        autosaveIfNeeded()
        if isRecording {
            update(\.recordingTime, engine.recorder.duration)
            if !engine.recorder.isRecording { // l'écriture a échoué (disque plein, volume éjecté…)
                finishRecordingSession()
                errorMessage = "Recording stopped: can't write to disk"
            } else {
                followRecordedSong()
            }
        }
    }

    // MARK: Stems — c'est l'utilisateur qui décide quel stem va sur quelle tranche

    /// Un fichier importé, pas encore posé sur une tranche.
    struct PoolItem: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        var name: String
    }

    /// Fichiers déposés dans la fenêtre : ils attendent dans la réserve, rien n'est affecté automatiquement.
    func addToPool(_ urls: [URL]) {
        let known = Set(pool.map(\.url) + engine.stems.map(\.url))
        let files = StemImporter.audioFiles(in: urls).filter { !known.contains($0) }
        guard !files.isEmpty else { return }
        pool += files.map { PoolItem(url: $0, name: "") }
        refreshNames()
    }

    /// Fichiers déposés sur une tranche (depuis le Finder, la réserve ou une autre tranche).
    func assign(_ urls: [URL], toStrip strip: Int) {
        for file in StemImporter.audioFiles(in: urls) {
            if let stem = engine.stems.first(where: { $0.url == file }) {
                engine.moveStem(id: stem.id, toStrip: strip)
                continue
            }
            do {
                let stem = try engine.addStem(url: file, name: "", strip: strip)
                pool.removeAll { $0.url == file }
                Task {
                    peaksByStem[stem.id] = await Waveform.peaks(of: file)
                    refreshWaveform()
                }
            } catch {
                errorMessage = "Can't read \(file.lastPathComponent)"
            }
        }
        refreshNames()
        if mix.bpm == nil { detectTempo() }
    }

    // MARK: Tempo

    /// Estime le BPM à partir des stems posés sur les tranches. Ne remplace jamais un tempo déjà connu,
    /// sauf demande explicite (bouton AUTO).
    func detectTempo(replacing: Bool = false) {
        let urls = engine.stems.map(\.url)
        guard !urls.isEmpty, !detectingTempo, !isPreview else { return }
        detectingTempo = true
        Task {
            let detected = await TempoDetector.detect(urls: urls)
            detectingTempo = false
            if let detected, replacing || mix.bpm == nil { mix.setTempo(detected) }
        }
    }

    /// Tap tempo : moyenne des derniers intervalles ; une pause de plus de 2 s repart de zéro.
    func tapTempo() {
        let now = Date.now
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps = (taps + [now]).suffix(8)
        guard taps.count >= 3, let first = taps.first else { return }
        let interval = now.timeIntervalSince(first) / Double(taps.count - 1)
        mix.setTempo((60 / interval * 10).rounded() / 10)
    }

    func scaleTempo(by factor: Double) {
        if let bpm = mix.bpm { mix.setTempo(bpm * factor) }
    }

    /// Retire le stem de sa tranche et le remet dans la réserve.
    func unassign(_ id: UUID) {
        guard let stem = engine.stems.first(where: { $0.id == id }) else { return }
        dropStem(id)
        pool.append(PoolItem(url: stem.url, name: ""))
        refreshNames()
    }

    func removeStem(_ id: UUID) {
        dropStem(id)
        refreshNames()
    }

    func removeFromPool(_ url: URL) {
        pool.removeAll { $0.url == url }
        refreshNames()
    }

    /// Vide la session (sans toucher aux fichiers) : le projet ouvert est simplement refermé.
    /// - Parameter keepingRack: a song of the setlist is coming: the rack (reverb and bus 3 effects, bus-to-bus
    ///   sends, plugins on the buses) stays as it is, so nothing is rewired.
    /// - Parameter keepingInserts: strips whose plugin insert the coming song uses too: it stays plugged in.
    func clear(keepingRack: Bool = false, keepingInserts: Set<Int> = []) {
        songLoads += 1
        for stem in engine.stems { dropStem(stem.id) }
        pool = []
        stripNames = [:]
        mix.setDrop(false)
        for strip in 0..<AudioEngine.stripCount { mix.setKeep(strip: strip, false) }
        setHold(false)
        setThrowTarget(.delay)
        for strip in 0..<AudioEngine.stripCount where !keepingInserts.contains(strip) { setInsert(strip: strip, nil) }
        unresolvedInserts = [:]
        titleOverride = nil
        unresolvedStems = []
        if !keepingRack {
            setReverbModel(.plate)
            setBus3Model(.phaser)
            unresolvedSlots = [:]
            for bus in SendBus.allCases { unloadPlugin(on: bus) }
        }
        projectURL = nil
        savedProject = nil
        mix.setTempo(nil)
        mix.setDelaySync(false)
        refreshNames()
    }

    /// A new session starts like a fresh launch: effect settings and bus routing back to their defaults, no strip
    /// muted or soloed. Faders and sends stay where the hardware holds them.
    /// Not part of `clear()`, which also runs when a project opens: rewiring the buses there would cut the tails.
    func resetToLaunchState() {
        setBusRouting(.standard)
        for parameter in FXParameter.allCases { mix.setFX(parameter, parameter.defaultValue) }
        for strip in mix.strips.indices {
            if mix.strips[strip].mute { mix.toggleMute(strip: strip) }
            if mix.strips[strip].solo { mix.toggleSolo(strip: strip) }
        }
    }

    func dropStem(_ id: UUID) {
        engine.removeStem(id: id)
        peaksByStem[id] = nil
        refreshWaveform()
    }

    /// Noms lisibles (préfixe et suffixe communs retirés), calculés sur tous les fichiers de la session.
    func refreshNames() {
        let urls = engine.stems.map(\.url) + pool.map(\.url)
        let cleaned = StemImporter.stripNames(for: urls.map { $0.deletingPathExtension().lastPathComponent })
        let names = Dictionary(uniqueKeysWithValues: zip(urls, cleaned))
        title = urls.isEmpty ? "" : (titleOverride ?? StemImporter.sessionTitle(for: urls))
        for index in pool.indices { pool[index].name = names[pool[index].url] ?? "" }
        for strip in 0..<AudioEngine.stripCount {
            let stems = engine.stems.filter { $0.strip == strip }
            mix.setStems(
                strip: strip,
                name: stripNames[strip] ?? stems.first.flatMap { names[$0.url] } ?? "",
                stems: stems.map { MixController.StemInfo(id: $0.id, name: $0.url.lastPathComponent) }
            )
        }
        duration = engine.duration
    }

    /// Empty name: back to the name derived from the file.
    func renameStrip(_ strip: Int, _ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        stripNames[strip] = cleaned.isEmpty ? nil : cleaned
        refreshNames()
    }

    func url(ofStem id: UUID) -> URL? {
        engine.stems.first { $0.id == id }?.url
    }

    func refreshWaveform() {
        waveform = Waveform.combine(engine.stems.compactMap { peaksByStem[$0.id] })
    }

    // MARK: Gestures (PRD § 11.6)

    /// - Returns: true when the key is a gesture (the event is consumed).
    private func handleGestureKey(_ key: String, down: Bool) -> Bool {
        guard !preparing, !editingSetlists else { return false }
        switch key {
        case "d":
            mix.setDrop(down)
        case "r":
            if down { pullUp() }
        case "h":
            setHold(down)
        case "c":
            if down { crash() }
        case "\u{1b}": // Esc: PANIC (not in a sheet, where Esc closes it)
            guard NSApp.keyWindow?.isSheet != true else { return false }
            if down { panic() }
        default:
            return false
        }
        return true
    }

    /// With a song armed, the pull-up lands on it instead of the top of the current one.
    func pullUp() {
        if armedIndex != nil, engine.isPlaying, !engine.isPullingUp {
            engine.pullUpLanding = { [weak self] in self?.launchArmed() }
        }
        engine.pullUp()
    }

    func setHold(_ on: Bool) {
        mix.setGesture(.hold, on)
    }

    /// CRASH hits the spring; on the plate the gesture does nothing and says so.
    func crash() {
        guard reverbModel == .spring else {
            errorMessage = "CRASH needs the Spring reverb (slot menu of the REVERB bus)"
            return
        }
        engine.crash()
    }

    func setReverbModel(_ model: ReverbModel) {
        reverbModel = model
        engine.setReverbModel(model)
        if model == .spring, errorMessage?.hasPrefix("CRASH needs") == true { errorMessage = nil }
    }

    func setThrowTarget(_ target: ThrowTarget) {
        throwTarget = target
        engine.setThrowTarget(target)
    }

    func setBusSend(from source: SendBus, to target: SendBus?) {
        guard engine.setBusSend(from: source, to: target) else { return }
        busRouting = engine.busRouting
    }

    func setBusRouting(_ routing: BusRouting) {
        engine.setBusRouting(routing)
        busRouting = engine.busRouting
    }

    /// Bus name on screen. Bus 3 has no fixed role, so its name follows the effect it holds.
    func busLabel(_ bus: SendBus) -> String {
        switch bus {
        case .delay: "DELAY"
        case .reverb: "REVERB"
        case .bus3: engine.plugins[.bus3] != nil ? "FX 3" : bus3Model == .phaser ? "PHASER" : "FLANGER"
        }
    }

    /// Bus name in menus ("Phaser", "FX 3").
    func busMenuName(_ bus: SendBus) -> String {
        engine.plugins[bus] != nil && bus == .bus3 ? "FX 3" : busLabel(bus).capitalized
    }

    /// Short bus name for knob labels ("PHS RETURN", "DLY→FLG").
    func busShortName(_ bus: SendBus) -> String {
        switch bus {
        case .delay, .reverb: bus.shortName
        case .bus3: engine.plugins[.bus3] != nil ? "FX3" : bus3Model == .phaser ? "PHS" : "FLG"
        }
    }

    /// How lit a bus looks, 0…1, from a meter's peak on a 48 dB scale: echo and reverb tails stay visible as they fade.
    func activity(_ meter: Int) -> Double {
        let peak = Double(levels[meter])
        guard peak > 0.000_01 else { return 0 }
        return min(1, max(0, 1 + 20 * log10(peak) / 48))
    }

    /// FX-page knob label; bus-send knobs name their target, and bus 3's return follows its effect.
    func fxLabel(_ parameter: FXParameter) -> String {
        if parameter == .phaserReturn { return busShortName(.bus3) + " RETURN" }
        guard parameter.isBusSend, let source = parameter.bus else { return parameter.label }
        return parameter.label(sendingTo: busRouting.target(of: source), names: busShortName)
    }

    func dismissWelcome() {
        showWelcome = false
        UserDefaults.standard.set(true, forKey: Preference.welcomeShown)
    }

    func toggleKeep(strip: Int) {
        mix.setKeep(strip: strip, !mix.strips[strip].keep)
    }

    // MARK: Transport

    /// With a song armed, Space launches it (the selector's drop); otherwise play / pause.
    func togglePlay() {
        guard !preparing, !editingSetlists else { return }
        if armedIndex != nil {
            launchArmed()
            return
        }
        if engine.isPlaying { engine.pause() } else { engine.play() }
        isPlaying = engine.isPlaying
    }

    func returnToStart() {
        engine.seek(to: 0)
        position = 0
    }

    func toggleLoop() {
        looping.toggle()
        engine.loop = looping
    }

    func seek(fraction: Double) {
        engine.seek(to: fraction * engine.duration)
        position = engine.position
    }

    // MARK: Démonstration

    private func loadPreviewData() {
        title = "MIDNIGHT VERSION"
        audioDevice = "MacBook Pro Speakers"
        audioFormat = "48 kHz · buffer 128"
        outputDevices = [AudioDeviceInfo(id: 1, uid: "built-in", name: "MacBook Pro Speakers"),
                         AudioDeviceInfo(id: 2, uid: "scarlett", name: "Scarlett 2i2 USB")]
        outputDeviceUID = "built-in"
        bufferFrames = 128
        dspLoad = 0.23
        let demo: [(String, [String], [Double], Double, Float)] = [
            ("DRUMS", ["kick.wav", "snare.wav", "hats.wav"], [0, 0.18, 0], 0.80, 0.82),
            ("BASS", ["bass.wav"], [0, 0, 0], 0.84, 0.74),
            ("SKANK", ["guitar.wav"], [0.62, 0.30, 0], 0.72, 0.55),
            ("KEYS", ["organ.wav", "piano.wav"], [0.25, 0.40, 0.55], 0.66, 0.48),
        ]
        for (strip, (name, stems, sends, fader, level)) in demo.enumerated() {
            mix.setStems(strip: strip, name: name, stems: stems.map { .init(id: UUID(), name: $0) })
            for (row, send) in sends.enumerated() { mix.setSend(strip: strip, row: row, send) }
            mix.setFader(strip: strip, fader)
            levels[strip] = level
            levels[AudioEngine.stripPreMeter(strip)] = level > 0 ? min(1, level * 1.1) : 0.6 // muted strips still play
        }
        // A split song leaves strips 5 and 6 empty: the siren sounds, through the delay and a touch of reverb.
        mix.setFader(strip: 4, 0.7)
        mix.setFader(strip: 5, 0.62)
        mix.setInstrumentGesture(.siren, true)
        mix.setFX(.sirenReverb, 0.35)
        levels[4] = 0.62
        levels[AudioEngine.stripPreMeter(4)] = 0.7
        mix.setThrow(strip: 2, true)
        mix.setKeep(strip: 0, true)
        mix.setKeep(strip: 1, true)
        setInsert(strip: 1, .sub)
        setInsert(strip: 2, .autoWah)
        mix.handle(.knob(strip: 3, row: 2, value: 0.2)) // potard « fantôme »
        mix.setSend(strip: 3, row: 2, 0.55)
        levels[AudioEngine.masterMeter] = 0.78
        // The delay patched into the reverb, both sounding: the cable and the lit cards show on the screenshots.
        setBusSend(from: .delay, to: .reverb)
        mix.setFX(.delayToReverb, 0.5)
        for (bus, input, output) in [(SendBus.delay, 0.4, 0.3), (.reverb, 0.12, 0.05), (.bus3, 0.002, 0.0005)] {
            levels[AudioEngine.busInputMeter(bus)] = Float(input)
            levels[AudioEngine.busReturnMeter(bus)] = Float(output)
        }
        pool = [
            PoolItem(url: URL(fileURLWithPath: "/demo/Midnight Version (Melodica).wav"), name: "MELODICA"),
            PoolItem(url: URL(fileURLWithPath: "/demo/Midnight Version (Full mix).wav"), name: "FULL MIX"),
        ]
        mix.setTempo(72)
        mix.setDelaySync(true)
        projectURL = URL(fileURLWithPath: "/demo/Midnight Version.dubstem")
        savedProject = currentProject(for: projectURL!)
        setlist = Setlist(name: "SUNDAY SESSION")
        let songs: [(String, Double, Double)] = [("Roots Steppa", 68, 238), ("Midnight Version", 72, 252),
                                                 ("Zion Gate Dub", 140, 303), ("Rockers Rise", 76, 221)]
        let marks: [String: (Int, String)] = ["Roots Steppa": (0, "Opener"), "Zion Gate Dub": (2, "Peak")]
        setlistEntries = songs.map { title, bpm, duration in
            let url = URL(fileURLWithPath: "/demo/\(title).dubstem")
            let song = SetlistSong(FileReference(url, relativeTo: url), color: marks[title]?.0, tag: marks[title]?.1)
            return SetlistEntry(song: song, url: url, title: title, bpm: bpm, duration: duration)
        }
        playedSongs = [URL(fileURLWithPath: "/demo/Roots Steppa.dubstem")]
        isPlaying = true
        duration = 252
        position = 85.6
        waveform = (0..<1000).map { i in
            let x = Double(i)
            let envelope = 0.55 + 0.35 * sin(x / 160) * sin(x / 37)
            let grain = abs(sin(x * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
            return Float(max(0.06, min(1, envelope * (0.45 + 0.55 * grain) * ((420..<510).contains(i) ? 0.35 : 1))))
        }
    }
}
