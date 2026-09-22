import AVFoundation
import Synchronization

public enum SendBus: Int, CaseIterable, Sendable {
    case delay, reverb, bus3

    /// Nom enregistré dans les projets : ne pas le changer.
    public var key: String {
        switch self {
        case .delay: "delay"
        case .reverb: "reverb"
        case .bus3: "bus3"
        }
    }
}

/// Crêtes mesurées sur le thread audio, lues (et remises à zéro) par l'interface.
public final class MeterStore: Sendable {
    private let peaks: Mutex<[Float]>

    init(count: Int) { peaks = Mutex(Array(repeating: 0, count: count)) }

    func report(_ index: Int, _ peak: Float) {
        peaks.withLock { $0[index] = max($0[index], peak) }
    }

    /// Crête depuis la dernière lecture.
    public func take(_ index: Int) -> Float {
        peaks.withLock { values in
            defer { values[index] = 0 }
            return values[index]
        }
    }
}

/// Ce que la logique de mix demande au moteur (permet de tester le contrôleur sans audio).
@MainActor
public protocol MixEngineControl: AnyObject {
    func setFaderGain(strip: Int, _ gain: Float)
    func setSendGain(_ bus: SendBus, strip: Int, _ gain: Float)
    func setThrow(strip: Int, _ on: Bool)
    func setMasterGain(_ gain: Float)
    /// Paramètre d'effet, déjà converti en unités réelles (voir `FXParameter.value`).
    func setFX(_ parameter: FXParameter, _ value: Float)
    /// Potard macro d'un bus qui héberge un plugin (valeur normalisée 0…1).
    func setMacro(bus: SendBus, index: Int, _ normalized: Double)
}

/// Graphe validé au jalon M0 :
///
///   lecteur ─┬─▶ mixeur de tranche (fader/mute) ─┬─▶ master ─▶ chaîne master ─▶ varispeed ─▶ gain ─▶ limiteur ─▶ sortie
///            │                                   └─▶ 3 bus d'envoi (post-fader) ─▶ effet ─▶ retour ─▶ master
///            └─▶ 3 send buses (taken before fader and mute: pre-fader sends, dub throw)
///                                                                       retour delay ─▶ bus reverb (DLY→REV)
///
/// AVAudioMixerNode lisse lui-même les changements de volume (~25 ms) mais plafonne à 1,0 :
/// tranches et master travaillent donc 6 dB sous l'unité, rattrapés par l'étage de gain final.
@MainActor
public final class AudioEngine: MixEngineControl {
    public static let stripCount = 8
    public static let masterMeter = stripCount
    /// Hors ligne, la lecture démarre ce nombre d'échantillons après l'appel à `play()`.
    public static let offlineStartDelay = 2048
    private static let headroom: Float = 0.5
    private static let loopIterations = 64

    public struct Stem: Identifiable {
        public let id = UUID()
        public let url: URL
        public let name: String
        public internal(set) var strip: Int
        public var duration: Double { Double(file.length) / file.processingFormat.sampleRate }

        let file: AVAudioFile
        let player = AVAudioPlayerNode()
        /// Input buses used on the strip mixer and, for the pre-fader take, on each send bus.
        var inputBus = 0
        var preBuses = [Int](repeating: 0, count: SendBus.allCases.count)
    }

    public let meters = MeterStore(count: stripCount + 1)
    public let recorder = MasterRecorder()
    /// Audio thread load and dropouts (real time only).
    public let load = RenderLoad()
    private var overloadListener: AudioDevices.OverloadListener?
    /// Per bus: the send is taken before the fader and mute (otherwise after, as on a console).
    public private(set) var preFader = [Bool](repeating: false, count: SendBus.allCases.count)
    public private(set) var stems: [Stem] = []
    public private(set) var isPlaying = false
    public var loop = true {
        didSet { if loop != oldValue, isPlaying { restart(at: position) } }
    }

    let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let offline: Bool
    private let stripMixers: [AVAudioMixerNode]
    private let busInputs: [AVAudioMixerNode]
    private let returnMixers: [AVAudioMixerNode]
    private var effects: [BuiltInEffect.Kind: BuiltInEffect] = [:]
    /// Le nœud d'effet actuellement branché sur chaque bus (effet intégré ou plugin).
    private var effectNodes: [AVAudioNode?] = [nil, nil, nil]
    /// Nœuds neutres fixes de part et d'autre de chaque effet : changer d'effet à chaud ne touche ainsi jamais
    /// aux mixeurs (AVAudioEngine plante si on rebranche un mixeur alimenté par des connexions en éventail).
    private let effectInlets: [AVAudioUnitEQ] = SendBus.allCases.map { _ in AudioEngine.neutralNode() }
    private let effectOutlets: [AVAudioUnitEQ] = SendBus.allCases.map { _ in AudioEngine.neutralNode() }

    private static func neutralNode() -> AVAudioUnitEQ {
        let node = AVAudioUnitEQ(numberOfBands: 1)
        node.bands[0].bypass = true
        return node
    }
    /// Plugins AU chargés à la place de l'effet intégré, et les paramètres affectés à leurs potards macros.
    public private(set) var plugins: [SendBus: HostedPlugin] = [:]
    public private(set) var macroTargets: [SendBus: [PluginParameter?]] = [:]
    public static let macroCount = 6
    private var sendGains = [[Float]](repeating: [0, 0, 0], count: stripCount)
    private var throwing = [Bool](repeating: false, count: stripCount)
    private var switchingDevice = false
    /// Pull-up (PRD § 11.3): tape brake on the master, real time only.
    private var varispeed: AVAudioUnitVarispeed?
    private var pullUpStart: Date?
    private var masterVolume: Float = headroom
    public var isPullingUp: Bool { pullUpStart != nil }
    private static let pullUpDuration = 1.3
    private var basePosition = 0.0

    /// - Parameter offline: rendu manuel sans carte son ni limiteur (tests au sample près).
    /// - Parameter effects: faux → les bus reviennent secs au master. Par défaut : effets en temps réel seulement.
    public init(offline: Bool = false, effects: Bool? = nil) throws {
        self.offline = offline
        stripMixers = (0..<Self.stripCount).map { _ in AVAudioMixerNode() }
        busInputs = SendBus.allCases.map { _ in AVAudioMixerNode() }
        returnMixers = SendBus.allCases.map { _ in AVAudioMixerNode() }
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        }
        buildGraph(withEffects: effects ?? !offline)
        if !offline {
            installTaps()
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
            }
        }
        try engine.start()
        if !offline { watchHealth() }
    }

    // MARK: Graphe

    private var returnBusBase: Int { Self.stripCount }
    private var masterOutput: AVAudioNode?

    /// Entrée du bus reverb réservée au renvoi du delay (les tranches occupent 0…7).
    private var delayToReverbBus: Int { Self.stripCount }

    /// First input of a send bus available for pre-fader takes.
    private func preBusBase(_ bus: SendBus) -> Int { bus == .reverb ? delayToReverbBus + 1 : Self.stripCount }

    private func buildGraph(withEffects: Bool) {
        let main = engine.mainMixerNode
        for node in stripMixers + busInputs + returnMixers { engine.attach(node) }

        for (i, strip) in stripMixers.enumerated() {
            let points = [AVAudioConnectionPoint(node: main, bus: i)]
                + busInputs.map { AVAudioConnectionPoint(node: $0, bus: i) }
            engine.connect(strip, to: points, fromBus: 0, format: format)
            strip.outputVolume = Self.headroom
        }

        // Bus d'envoi ─▶ effet intégré ─▶ mixeur de retour ─▶ master.
        let kinds: [BuiltInEffect.Kind] = [.delay, .plate, .phaser]
        for (b, input) in busInputs.enumerated() {
            if withEffects {
                let effect = BuiltInEffect(kinds[b])
                effects[kinds[b]] = effect
                effectNodes[b] = effect.node
                for node in [effectInlets[b], effect.node, effectOutlets[b]] { engine.attach(node) }
                engine.connect(input, to: effectInlets[b], format: format)
                engine.connect(effectInlets[b], to: effect.node, format: format)
                engine.connect(effect.node, to: effectOutlets[b], format: format)
                engine.connect(effectOutlets[b], to: returnMixers[b], format: format)
            } else {
                engine.connect(input, to: returnMixers[b], format: format)
            }
        }
        // Le retour du delay part aussi dans la reverb (DLY→REV), fermé par défaut.
        engine.connect(returnMixers[0], to: [
            AVAudioConnectionPoint(node: main, bus: returnBusBase),
            AVAudioConnectionPoint(node: busInputs[SendBus.reverb.rawValue], bus: delayToReverbBus),
        ], fromBus: 0, format: format)
        returnMixers[0].destination(forMixer: busInputs[SendBus.reverb.rawValue], bus: delayToReverbBus)?.volume = 0
        for b in 1..<returnMixers.count {
            engine.connect(returnMixers[b], to: main, fromBus: 0, toBus: returnBusBase + b, format: format)
        }

        // Master chain (PRD § 11.3): big knob → kills → dubplate, exact passthrough until touched.
        var tail: AVAudioNode = main
        if withEffects {
            let master = BuiltInEffect(.master)
            effects[.master] = master
            engine.attach(master.node)
            engine.connect(tail, to: master.node, format: format)
            tail = master.node
        }
        if offline {
            // The main mixer was wired to the output on its own; the master chain now sits in between.
            if tail !== main { engine.connect(tail, to: engine.outputNode, format: format) }
            masterOutput = tail
        } else {
            // Pull-up: a varispeed, bypassed until the gesture (rate 1 = plain passthrough).
            let varispeed = AVAudioUnitVarispeed()
            varispeed.auAudioUnit.shouldBypassEffect = true
            self.varispeed = varispeed
            // Master : rattrapage des 12 dB de marge (tranche + master), puis limiteur de sécurité.
            let makeup = AVAudioUnitEQ(numberOfBands: 1)
            makeup.bands[0].bypass = true
            makeup.globalGain = 12.04
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0
            ))
            for node in [varispeed, makeup, limiter] { engine.attach(node) }
            engine.connect(tail, to: varispeed, format: format)
            engine.connect(varispeed, to: makeup, format: format)
            engine.connect(makeup, to: limiter, format: format)
            engine.connect(limiter, to: engine.outputNode, format: format)
            masterOutput = limiter
        }
        main.outputVolume = Self.headroom
    }

    /// Un seul tap par sortie de nœud : celui du master sert à la fois au vu-mètre et à l'enregistrement.
    /// Temps réel uniquement : en rendu manuel hors ligne, un tap rend le rendu instable (blocs vides) —
    /// l'enregistreur y est alimenté directement par `renderOffline`.
    private func installTaps() {
        for (i, strip) in stripMixers.enumerated() {
            strip.installTap(onBus: 0, bufferSize: 1024, format: nil,
                             block: Self.tap(meters, index: i, scale: 1 / Self.headroom, recorder: nil))
        }
        masterOutput?.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                 block: Self.tap(meters, index: Self.masterMeter, scale: 1, recorder: recorder))
    }

    /// Construit hors du MainActor : le bloc s'exécute sur un thread audio (non temps réel).
    private nonisolated static func tap(_ meters: MeterStore, index: Int, scale: Float, recorder: MasterRecorder?) -> AVAudioNodeTapBlock {
        { buffer, _ in
            recorder?.write(buffer)
            guard let channels = buffer.floatChannelData else { return }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in stride(from: 0, to: Int(buffer.frameLength), by: 2) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
            meters.report(index, peak * scale)
        }
    }

    // MARK: Enregistrement du master (après limiteur : exactement ce qu'on entend)

    public func startRecording(to url: URL) throws {
        guard let masterOutput else { return }
        try recorder.start(to: url, format: masterOutput.outputFormat(forBus: 0))
    }

    @discardableResult
    public func stopRecording() -> URL? { recorder.stop() }

    private func recoverFromConfigurationChange() {
        guard !switchingDevice else { return } // we are switching devices ourselves: already handled
        // Carte son changée ou débranchée : on relance le moteur et on reprend où on en était.
        let wasPlaying = isPlaying
        let resumeAt = position
        if wasPlaying { haltPlayers() }
        basePosition = resumeAt
        try? engine.start()
        if wasPlaying { play() }
        watchHealth()
    }

    // MARK: Output device, buffer size, load

    /// Load measurement on the output unit, and dropout listening on the device in use.
    private func watchHealth() {
        if let unit = engine.outputNode.audioUnit { load.attach(to: unit) }
        load.setSampleRate(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        let load = load
        overloadListener = AudioDevices.listenForOverloads(on: outputDeviceID) { load.reportOverload() }
    }

    public var outputDeviceID: AudioDeviceID { engine.outputNode.auAudioUnit.deviceID }
    public var outputDevice: AudioDeviceInfo? { AudioDevices.info(for: outputDeviceID) }
    public var outputSampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }
    public var bufferFrames: Int? { AudioDevices.bufferFrames(of: outputDeviceID) }

    /// Hot-switches the output device: the engine stops for the switch, playback resumes at the same position.
    public func setOutputDevice(_ device: AudioDeviceInfo) throws {
        guard !offline, device.id != outputDeviceID else { return }
        switchingDevice = true
        defer { switchingDevice = false }
        var failure: Error?
        restructure {
            engine.stop()
            do { try engine.outputNode.auAudioUnit.setDeviceID(device.id) } catch { failure = error }
            try? engine.start()
        }
        watchHealth()
        if let failure { throw failure }
    }

    /// - Returns: the size the device actually applied.
    @discardableResult
    public func setBufferFrames(_ frames: Int) -> Int? {
        guard !offline else { return nil }
        return AudioDevices.setBufferFrames(frames, of: outputDeviceID)
    }

    // MARK: Stems

    @discardableResult
    public func addStem(url: URL, name: String, strip: Int) throws -> Stem {
        var stem = Stem(url: url, name: name, strip: strip, file: try AVAudioFile(forReading: url))
        restructure {
            engine.attach(stem.player)
            connect(&stem)
            stems.append(stem)
        }
        return stem
    }

    public func removeStem(id: Stem.ID) {
        guard let index = stems.firstIndex(where: { $0.id == id }) else { return }
        restructure {
            let stem = stems.remove(at: index)
            stem.player.stop()
            engine.disconnectNodeOutput(stem.player)
            engine.detach(stem.player)
        }
        if stems.isEmpty { stop() }
    }

    public func moveStem(id: Stem.ID, toStrip strip: Int) {
        guard let index = stems.firstIndex(where: { $0.id == id }), stems[index].strip != strip else { return }
        restructure {
            var stem = stems.remove(at: index)
            stem.strip = strip
            engine.disconnectNodeOutput(stem.player)
            connect(&stem)
            stems.insert(stem, at: index)
        }
    }

    /// Les bus sont attribués ici : `nextAvailableInputBus` ignore les connexions en éventail
    /// et propose des bus déjà pris. `stem` ne doit pas figurer dans `stems` pendant l'appel.
    private func connect(_ stem: inout Stem) {
        let strip = stem.strip
        let usedInputs = Set(stems.filter { $0.strip == strip }.map(\.inputBus))
        stem.inputBus = (0...).first { !usedInputs.contains($0) }!
        for bus in SendBus.allCases {
            let used = Set(stems.map { $0.preBuses[bus.rawValue] })
            stem.preBuses[bus.rawValue] = (preBusBase(bus)...).first { !used.contains($0) }!
        }
        let preTakes = SendBus.allCases.map { AVAudioConnectionPoint(node: busInputs[$0.rawValue], bus: stem.preBuses[$0.rawValue]) }
        engine.connect(stem.player, to: [AVAudioConnectionPoint(node: stripMixers[strip], bus: stem.inputBus)] + preTakes,
                       fromBus: 0, format: stem.file.processingFormat)
        // A new connection opens at full volume: apply the intended levels right away.
        for bus in SendBus.allCases {
            applySend(bus, strip: strip)
            applyPreTake(stem, bus)
        }
    }

    /// Toute modification du graphe se fait lecteurs arrêtés, puis la lecture reprend au même endroit.
    private func restructure(_ change: () -> Void) {
        let wasPlaying = isPlaying
        let resumeAt = position
        if wasPlaying { haltPlayers() }
        change()
        basePosition = min(resumeAt, duration)
        if wasPlaying { play() }
    }

    // MARK: Niveaux (MixEngineControl)

    public func setFaderGain(strip: Int, _ gain: Float) {
        stripMixers[strip].outputVolume = min(1, gain * Self.headroom)
    }

    public func setSendGain(_ bus: SendBus, strip: Int, _ gain: Float) {
        sendGains[strip][bus.rawValue] = gain
        applySend(bus, strip: strip)
    }

    public func setThrow(strip: Int, _ on: Bool) {
        throwing[strip] = on
        applySend(.delay, strip: strip)
    }

    /// Send taken before the fader and mute (pre) or after (post), for the whole bus.
    public func setSendPreFader(_ bus: SendBus, _ pre: Bool) {
        preFader[bus.rawValue] = pre
        for strip in 0..<Self.stripCount { applySend(bus, strip: strip) }
    }

    public func setMasterGain(_ gain: Float) {
        masterVolume = min(1, gain * Self.headroom)
        if !isPullingUp { engine.mainMixerNode.outputVolume = masterVolume }
    }

    // MARK: Pull-up (PRD § 11.3)

    /// The selector's rewind: the whole master brakes like a tape (pitch falls with the speed), fades out
    /// at the bottom, then the song restarts from the top at once. Driven by `tick()`.
    public func pullUp() {
        guard isPlaying, varispeed != nil, !isPullingUp else { return }
        varispeed?.rate = 1
        varispeed?.auAudioUnit.shouldBypassEffect = false
        pullUpStart = .now
    }

    private func advancePullUp() {
        guard let start = pullUpStart, let varispeed else { return }
        let t = min(1, Date.now.timeIntervalSince(start) / Self.pullUpDuration)
        // Speed: 1 → 0.25 (two octaves down, the varispeed's floor), accelerating like a real brake.
        varispeed.rate = Float(1 - 0.75 * t * t)
        // The last stretch fades to silence: the tape never quite stops but the ear hears it stop.
        let fade: Float = t < 0.55 ? 1 : Float(pow(1 - (t - 0.55) / 0.45, 2))
        engine.mainMixerNode.outputVolume = masterVolume * fade
        guard t >= 1 else { return }
        pullUpStart = nil
        stop()
        varispeed.rate = 1
        varispeed.auAudioUnit.shouldBypassEffect = true
        engine.mainMixerNode.outputVolume = masterVolume
        play()
    }

    public func setFX(_ parameter: FXParameter, _ value: Float) {
        if let (kind, index) = parameter.kernelParameter {
            effects[kind]?.set(index, value)
            return
        }
        let reverbInput = busInputs[SendBus.reverb.rawValue]
        switch parameter {
        case .delayToReverb:
            returnMixers[0].destination(forMixer: reverbInput, bus: delayToReverbBus)?.volume = value
        case .delayReturn:
            returnMixers[0].destination(forMixer: engine.mainMixerNode, bus: returnBusBase)?.volume = value
        case .reverbReturn:
            returnMixers[1].outputVolume = value
        case .phaserReturn:
            returnMixers[2].outputVolume = value
        default:
            break
        }
    }

    // MARK: Slots d'effets (effet intégré ou plugin Audio Unit)

    private static let builtInKinds: [BuiltInEffect.Kind] = [.delay, .plate, .phaser]

    /// Charge un plugin AU sur un bus, à la place de l'effet intégré (ou du plugin précédent). À chaud.
    @discardableResult
    public func loadPlugin(_ info: PluginInfo, on bus: SendBus, state: Data? = nil) async throws -> HostedPlugin {
        guard effectNodes[bus.rawValue] != nil else { throw PluginError.noEffectChain }
        let plugin = try await HostedPlugin.load(info, format: format)
        if let state { plugin.restore(state) }
        swapEffectNode(plugin.unit, on: bus)
        plugins[bus] = plugin
        macroTargets[bus] = Array(repeating: nil, count: Self.macroCount)
        return plugin
    }

    /// Revient à l'effet intégré du bus.
    public func unloadPlugin(on bus: SendBus) {
        guard plugins[bus] != nil, let builtIn = effects[Self.builtInKinds[bus.rawValue]] else { return }
        swapEffectNode(builtIn.node, on: bus)
        plugins[bus] = nil
        macroTargets[bus] = nil
    }

    private func swapEffectNode(_ node: AVAudioNode, on bus: SendBus) {
        let b = bus.rawValue
        // Moteur arrêté le temps du recâblage : moteur en marche, AVAudioEngine lève une exception interne
        // dès le troisième changement d'effet sur un même bus. La lecture reprend ensuite au même endroit.
        restructure {
            engine.stop()
            if let old = effectNodes[b], old !== node {
                engine.disconnectNodeOutput(effectInlets[b])
                engine.disconnectNodeOutput(old)
                engine.detach(old)
            }
            engine.attach(node)
            engine.connect(effectInlets[b], to: node, format: format)
            engine.connect(node, to: effectOutlets[b], format: format)
            effectNodes[b] = node
            try? engine.start()
        }
    }

    public func setMacroTarget(_ parameter: PluginParameter?, bus: SendBus, index: Int) {
        guard macroTargets[bus]?.indices.contains(index) == true else { return }
        macroTargets[bus]?[index] = parameter
    }

    public func setMacro(bus: SendBus, index: Int, _ normalized: Double) {
        guard let target = macroTargets[bus]?[index], let plugin = plugins[bus] else { return }
        plugin.setNormalizedValue(target.address, normalized)
    }

    /// Une tranche sans stem n'a pas de destination d'envoi (AVAudioEngine l'écarte du graphe actif) :
    /// les niveaux sont mémorisés et réappliqués dès qu'un stem y est branché.
    private func applySend(_ bus: SendBus, strip: Int) {
        let post = preFader[bus.rawValue] ? 0 : sendGains[strip][bus.rawValue]
        stripMixers[strip].destination(forMixer: busInputs[bus.rawValue], bus: strip)?.volume = post
        for stem in stems where stem.strip == strip { applyPreTake(stem, bus) }
    }

    /// Pre-fader take from a player into a bus: the send when the bus is pre-fader, and on the delay the dub throw
    /// (worth a send at full). The strip headroom is compensated so the level matches a post-fader send.
    private func applyPreTake(_ stem: Stem, _ bus: SendBus) {
        var volume: Float = preFader[bus.rawValue] ? sendGains[stem.strip][bus.rawValue] * Self.headroom : 0
        if bus == .delay, throwing[stem.strip] { volume = Self.headroom }
        stem.player.destination(forMixer: busInputs[bus.rawValue], bus: stem.preBuses[bus.rawValue])?.volume = volume
    }

    public var outputDescription: String {
        let format = engine.outputNode.outputFormat(forBus: 0)
        return "\(Int(format.sampleRate / 1000)) kHz · \(format.channelCount) ch"
    }

    // MARK: Transport

    public var duration: Double { stems.map(\.duration).max() ?? 0 }

    public var position: Double {
        guard isPlaying, let player = stems.first?.player,
              let renderTime = player.lastRenderTime, renderTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return basePosition }
        let elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        let position = basePosition + elapsed
        guard duration > 0 else { return 0 }
        return loop ? position.truncatingRemainder(dividingBy: duration) : min(position, duration)
    }

    public func play() {
        guard !isPlaying, !stems.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        if basePosition >= duration { basePosition = 0 }
        for stem in stems { schedule(stem, from: basePosition) }
        if offline {
            // Comme en temps réel, le départ est programmé dans le futur : un lecteur démarré « tout de suite »
            // peut perdre son premier tampon.
            // A player reads the sample time in its own rate, whatever the AVAudioTime says: the start is
            // converted for a stem whose file is not at the engine's rate.
            let startSeconds = Double(engine.manualRenderingSampleTime + AVAudioFramePosition(Self.offlineStartDelay)) / format.sampleRate
            for stem in stems {
                let rate = stem.file.processingFormat.sampleRate
                stem.player.play(at: AVAudioTime(sampleTime: AVAudioFramePosition((startSeconds * rate).rounded()), atRate: rate))
            }
        } else {
            // Même instant hôte pour tous les lecteurs → départ calé à l'échantillon.
            // La marge laisse aussi le temps à la lecture anticipée des fichiers d'arriver.
            let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1))
            for stem in stems { stem.player.play(at: start) }
        }
        isPlaying = true
    }

    /// Les queues d'effets continuent : seuls les lecteurs s'arrêtent.
    public func pause() {
        guard isPlaying else { return }
        let resumeAt = position
        haltPlayers()
        basePosition = resumeAt
    }

    public func stop() {
        haltPlayers()
        basePosition = 0
    }

    public func seek(to seconds: Double) {
        restart(at: min(max(0, seconds), duration))
    }

    /// À appeler régulièrement : arrête la lecture en fin de morceau quand la boucle est coupée.
    public func tick() {
        advancePullUp()
        if isPlaying, !loop, position >= duration - 0.01 { stop() }
    }

    private func restart(at seconds: Double) {
        let wasPlaying = isPlaying
        haltPlayers()
        basePosition = seconds
        if wasPlaying { play() }
    }

    private func haltPlayers() {
        for stem in stems { stem.player.stop() }
        isPlaying = false
    }

    /// Les stems n'ont pas tous la même longueur : chaque tour de boucle est donc programmé
    /// à un instant absolu du lecteur, jamais « à la suite » du précédent.
    private func schedule(_ stem: Stem, from seconds: Double) {
        let rate = stem.file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((seconds * rate).rounded())
        let loopFrames = AVAudioFramePosition((duration * rate).rounded())
        if startFrame < stem.file.length {
            enqueue(stem, from: startFrame, at: 0)
        }
        guard loop else { return }
        for iteration in 1..<(offline ? 8 : Self.loopIterations) {
            enqueue(stem, from: 0, at: AVAudioFramePosition(iteration) * loopFrames - startFrame)
        }
    }

    private func enqueue(_ stem: Stem, from startFrame: AVAudioFramePosition, at playerSample: AVAudioFramePosition) {
        let file = stem.file
        let time = AVAudioTime(sampleTime: playerSample, atRate: file.processingFormat.sampleRate)
        let count = AVAudioFrameCount(file.length - startFrame)
        guard offline else {
            // Temps réel : lecture en streaming depuis le disque.
            stem.player.scheduleSegment(file, startingFrame: startFrame, frameCount: count, at: time)
            return
        }
        // Hors ligne, le rendu va plus vite que la lecture anticipée du disque et un segment peut
        // manquer son horaire : on programme des tampons en mémoire (même logique d'horaires).
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return }
        file.framePosition = startFrame
        try? file.read(into: buffer, frameCount: count)
        stem.player.scheduleBuffer(buffer, at: time)
    }

    // MARK: Rendu hors ligne (tests)

    public func renderOffline(frames: Int, beforeBlock: (Int) -> Void = { _ in }) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var samples: [Float] = []
        var block = 0
        while samples.count < frames {
            beforeBlock(block)
            guard try engine.renderOffline(512, to: buffer) == .success else { break }
            recorder.write(buffer)
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            block += 1
        }
        return samples
    }
}
