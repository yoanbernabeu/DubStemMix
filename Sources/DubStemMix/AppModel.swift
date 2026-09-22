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
    @ObservationIgnored var peaksByStem: [UUID: [Float]] = [:]

    var title = ""
    var waveform: [Float] = []
    var midiConnected = false
    var audioOutput = ""
    var errorMessage: String?
    var pool: [PoolItem] = []
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

    // Preferences. See AppModel+Settings.swift.
    /// Per bus (`SendBus.rawValue`): send taken before the fader and mute.
    var sendPreFader = AppModel.storedSendPreFader()

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
        if preview {
            if demoData { loadPreviewData() }
            return
        }
        audioOutput = engine.outputDescription
        midi.onEvent = { [weak self] in self?.mix.handle($0) }
        midi.onConnectionChange = { [weak self] connected in
            self?.midiConnected = connected
            if connected { self?.mix.refreshSurface() }
        }
        midi.start()
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

    static let recordingsFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "DubStemMix")

    func toggleRecording() {
        if isRecording {
            lastRecording = engine.stopRecording()
            isRecording = false
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss" // heure locale
            let stamp = formatter.string(from: .now)
            let name = (title.isEmpty ? "Untitled" : title.capitalized).replacingOccurrences(of: "/", with: "-")
            try engine.startRecording(to: Self.recordingsFolder.appending(path: "\(name) \(stamp).wav"))
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
                name: stems.first.flatMap { names[$0.url] } ?? "",
                stems: stems.map { MixController.StemInfo(id: $0.id, name: $0.url.lastPathComponent) }
            )
        }
        duration = engine.duration
    }

    func url(ofStem id: UUID) -> URL? {
        engine.stems.first { $0.id == id }?.url
    }

    func refreshWaveform() {
        waveform = Waveform.combine(engine.stems.compactMap { peaksByStem[$0.id] })
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
