import DubStemMixCore
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
    @ObservationIgnored var autosaveCountdown = 0

    // Plugins Audio Unit. Voir AppModel+Plugins.swift.
    var installedPlugins: [PluginInfo] = []
    /// Bus en cours de chargement d'un plugin.
    var loadingPlugin: Set<SendBus> = []
    /// Slots du projet pas (encore) chargés — plugin absent de ce Mac, ou chargement en cours. Conservés dans le projet.
    var unresolvedSlots: [String: Project.SlotEntry] = [:]
    @ObservationIgnored var pluginStates: [SendBus: Data] = [:]
    @ObservationIgnored var pluginStateCountdown = 0
    @ObservationIgnored let pluginWindows = PluginWindows()

    var detectingTempo = false
    @ObservationIgnored private var taps: [Date] = []

    // Delay and reverb (PRD § 11.4): mirrors of the engine's state, for the interface and the project.
    var reverbModel = ReverbModel.plate
    var throwTarget = ThrowTarget.delay
    /// HOLD held (H): the delay loops on itself.
    var holding = false

    // Preferences. See AppModel+Settings.swift.
    /// Per bus (`SendBus.rawValue`): send taken before the fader and mute.
    var sendPreFader = AppModel.storedSendPreFader()
    var recordingsFolder = AppModel.storedRecordingsFolder()
    /// Output devices offered in Settings, and the one in use (its UID) with its buffer size.
    var outputDevices: [AudioDeviceInfo] = []
    var outputDeviceUID = ""
    var bufferFrames = 0

    var isRecording = false
    var recordingTime = 0.0
    /// Dernier enregistrement terminé (pour le retrouver dans le Finder).
    var lastRecording: URL?

    // Rafraîchis 30 fois par seconde.
    var isPlaying = false
    var looping = true
    var position = 0.0
    var duration = 0.0
    var levels = [Float](repeating: 0, count: AudioEngine.stripCount + 1)

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
        midi.onEvent = { [weak self] in self?.mix.handle($0) }
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

    private func tick() {
        engine.tick()
        isPlaying = engine.isPlaying
        position = engine.position
        duration = engine.duration
        for index in levels.indices {
            levels[index] = max(engine.meters.take(index), levels[index] * 0.85)
        }
        dspLoad = max(engine.load.takePeak(), dspLoad * 0.9)
        dropouts = engine.load.overloadCount
        audioStatusCountdown -= 1
        if audioStatusCountdown <= 0 { // once a second: the device may have changed under us
            audioStatusCountdown = 30
            refreshAudioStatus()
        }
        followPlugins()
        autosaveIfNeeded()
        if isRecording {
            recordingTime = engine.recorder.duration
            if !engine.recorder.isRecording { // l'écriture a échoué (disque plein, volume éjecté…)
                isRecording = false
                errorMessage = "Recording stopped: can't write to disk"
            }
        }
    }

    // MARK: Enregistrement du master

    func toggleRecording() {
        if isRecording {
            lastRecording = engine.stopRecording()
            isRecording = false
            return
        }
        do {
            try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss" // heure locale
            let stamp = formatter.string(from: .now)
            let name = (title.isEmpty ? "Untitled" : title.capitalized).replacingOccurrences(of: "/", with: "-")
            try engine.startRecording(to: recordingsFolder.appending(path: "\(name) \(stamp).wav"))
            errorMessage = nil
            recordingTime = 0
            isRecording = true
        } catch {
            errorMessage = "Can't start recording: \(error.localizedDescription)"
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
    func clear() {
        for stem in engine.stems { dropStem(stem.id) }
        pool = []
        stripNames = [:]
        mix.setDrop(false)
        for strip in 0..<AudioEngine.stripCount { mix.setKeep(strip: strip, false) }
        setHold(false)
        setReverbModel(.plate)
        setThrowTarget(.delay)
        unresolvedStems = []
        unresolvedSlots = [:]
        for bus in SendBus.allCases { unloadPlugin(on: bus) }
        projectURL = nil
        savedProject = nil
        mix.setTempo(nil)
        mix.setDelaySync(false)
        refreshNames()
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
        title = urls.isEmpty ? "" : StemImporter.sessionTitle(for: urls)
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
        switch key {
        case "d":
            mix.setDrop(down)
        case "r":
            if down { pullUp() }
        case "h":
            setHold(down)
        case "c":
            if down { crash() }
        default:
            return false
        }
        return true
    }

    func pullUp() {
        engine.pullUp()
    }

    func setHold(_ on: Bool) {
        holding = on
        engine.setHold(on)
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

    func toggleKeep(strip: Int) {
        mix.setKeep(strip: strip, !mix.strips[strip].keep)
    }

    // MARK: Transport

    func togglePlay() {
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
            ("HORNS", ["horns.wav"], [0.45, 0.52, 0], 0.70, 0),
            ("PERC", ["percussion.wav"], [0.10, 0.35, 0.30], 0.60, 0.40),
            ("VOX", ["lead vocal.wav", "backing.wav"], [0.70, 0.45, 0], 0.76, 0),
        ]
        for (strip, (name, stems, sends, fader, level)) in demo.enumerated() {
            mix.setStems(strip: strip, name: name, stems: stems.map { .init(id: UUID(), name: $0) })
            for (row, send) in sends.enumerated() { mix.setSend(strip: strip, row: row, send) }
            mix.setFader(strip: strip, fader)
            levels[strip] = level
        }
        mix.toggleMute(strip: 4)
        mix.toggleMute(strip: 6)
        mix.setThrow(strip: 2, true)
        mix.setKeep(strip: 0, true)
        mix.setKeep(strip: 1, true)
        mix.handle(.knob(strip: 3, row: 2, value: 0.2)) // potard « fantôme »
        mix.setSend(strip: 3, row: 2, 0.55)
        levels[AudioEngine.masterMeter] = 0.78
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
        setlistEntries = songs.map { title, bpm, duration in
            let url = URL(fileURLWithPath: "/demo/\(title).dubstem")
            return SetlistEntry(reference: FileReference(url, relativeTo: url), url: url, title: title, bpm: bpm, duration: duration)
        }
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
