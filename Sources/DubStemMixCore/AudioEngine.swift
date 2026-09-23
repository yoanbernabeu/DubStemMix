import AVFoundation
import DubDSP
import Synchronization

/// Built-in reverb on the REVERB bus (PRD § 11.4). Raw values are stored in projects.
public enum ReverbModel: String, CaseIterable, Sendable {
    case plate, spring

    public var label: String { self == .plate ? "Plate" : "Spring" }
    var kind: BuiltInEffect.Kind { self == .plate ? .plate : .spring }
}

/// Where the dub throw goes (PRD § 11.4). Raw values are stored in projects.
public enum ThrowTarget: String, CaseIterable, Sendable {
    case delay, reverb, both

    public var label: String {
        switch self {
        case .delay: "Delay"
        case .reverb: "Reverb"
        case .both: "Delay + reverb"
        }
    }

    func includes(_ bus: SendBus) -> Bool {
        switch self {
        case .delay: bus == .delay
        case .reverb: bus == .reverb
        case .both: bus == .delay || bus == .reverb
        }
    }
}

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
    /// Strip insert (PRD § 11.5): a built-in insert's parameter, or a macro of a plugin insert (0…1).
    func setInsertParameter(strip: Int, index: Int, _ normalized: Double)
    func setInsertMacro(strip: Int, index: Int, _ normalized: Double)
}

/// Graphe validé au jalon M0 :
///
///   lecteur ─▶ somme de tranche ─▶ insert ─▶ prise pré ─┬─▶ fader/mute ─┬─▶ master ─▶ chaîne master ─▶ varispeed ─▶ gain ─▶ limiteur ─▶ sortie
///                                                       │               └─▶ 3 bus d'envoi (post-fader) ─▶ effet ─▶ retour ─▶ master
///                                                       └─▶ 3 send buses (before fader and mute: pre-fader sends, dub throw)
///                                                                       retour d'un bus ─▶ un autre bus (renvoi, issue #1)
///
/// Bus-to-bus sends: each return may also feed one other bus, chosen by the user (`BusRouting`, DLY→REV by
/// default). The routing is always loop-free; changing a target rewires the graph, engine stopped.
///
/// Per strip (PRD § 11.5): the stems sum in a mixer, go through the insert (between two fixed neutral nodes,
/// so swapping it never touches a mixer), then a unity "pre" mixer takes the pre-fader sends and the throw,
/// and the fader mixer applies fader and mute and feeds the master and the post-fader sends.
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
        /// Input bus used on the strip's sum mixer.
        var inputBus = 0
    }

    public let meters = MeterStore(count: stripCount + 1)
    public let recorder = MasterRecorder()
    /// Audio thread load and dropouts (real time only).
    public let load = RenderLoad()
    private var overloadListener: AudioDevices.OverloadListener?
    /// Per bus: the send is taken before the fader and mute (otherwise after, as on a console).
    public private(set) var preFader = [Bool](repeating: false, count: SendBus.allCases.count)
    public private(set) var reverbModel = ReverbModel.plate
    public private(set) var bus3Model = Bus3Model.phaser
    public private(set) var throwTarget = ThrowTarget.delay
    /// Last value applied per parameter, so a kernel created later (the spring) starts from the current knobs.
    private var lastFX: [FXParameter: Float] = [:]
    public private(set) var stems: [Stem] = []
    public private(set) var isPlaying = false
    public var loop = true {
        didSet { if loop != oldValue, isPlaying { restart(at: position) } }
    }

    let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let offline: Bool
    /// Per strip: sum of its stems → insert (between `insertInlets` and `insertOutlets`) → `preMixers` → `faderMixers`.
    private let stripMixers: [AVAudioMixerNode]
    private let insertInlets: [AVAudioUnitEQ] = (0..<AudioEngine.stripCount).map { _ in AudioEngine.neutralNode() }
    private let insertOutlets: [AVAudioUnitEQ] = (0..<AudioEngine.stripCount).map { _ in AudioEngine.neutralNode() }
    private let preMixers: [AVAudioMixerNode]
    private let faderMixers: [AVAudioMixerNode]
    /// The node currently in each strip's insert (nil = straight through).
    private var insertNodes: [AVAudioNode?] = Array(repeating: nil, count: AudioEngine.stripCount)
    public private(set) var inserts: [InsertKind?] = Array(repeating: nil, count: AudioEngine.stripCount)
    private var insertEffects: [Int: BuiltInEffect] = [:]
    public private(set) var insertPlugins: [Int: HostedPlugin] = [:]
    public private(set) var insertMacroTargets: [Int: [PluginParameter?]] = [:]
    public static let insertMacroCount = 3
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
        preMixers = (0..<Self.stripCount).map { _ in AVAudioMixerNode() }
        faderMixers = (0..<Self.stripCount).map { _ in AVAudioMixerNode() }
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

    /// Input of a send bus taking strip `strip` before its fader (post-fader sends use inputs 0…7).
    private func preBus(_ bus: SendBus, strip: Int) -> Int { Self.stripCount + strip }

    /// Input of any send bus taking the return of `source` (strips use 0…15).
    private func sendInput(from source: SendBus) -> Int { Self.stripCount * 2 + source.rawValue }

    /// Where each bus's return is sent besides the master (issue #1).
    public private(set) var busRouting = BusRouting.standard

    private func buildGraph(withEffects: Bool) {
        let main = engine.mainMixerNode
        for node in stripMixers + preMixers + faderMixers + busInputs + returnMixers { engine.attach(node) }
        for node in insertInlets + insertOutlets { engine.attach(node) }

        for i in 0..<Self.stripCount {
            engine.connect(stripMixers[i], to: insertInlets[i], format: format)
            engine.connect(insertInlets[i], to: insertOutlets[i], format: format) // no insert yet: straight through
            engine.connect(insertOutlets[i], to: preMixers[i], format: format)
            let preTakes = SendBus.allCases.map { AVAudioConnectionPoint(node: busInputs[$0.rawValue], bus: preBus($0, strip: i)) }
            engine.connect(preMixers[i], to: [AVAudioConnectionPoint(node: faderMixers[i], bus: 0)] + preTakes, fromBus: 0, format: format)
            let postSends = busInputs.map { AVAudioConnectionPoint(node: $0, bus: i) }
            engine.connect(faderMixers[i], to: [AVAudioConnectionPoint(node: main, bus: i)] + postSends, fromBus: 0, format: format)
            faderMixers[i].outputVolume = Self.headroom
            for bus in SendBus.allCases { applySend(bus, strip: i) } // new connections open at full volume
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
        // Each return goes to the master and, if routed, to one other bus (closed until its knob is set).
        for source in SendBus.allCases { connectReturn(of: source) }

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
        for (i, strip) in faderMixers.enumerated() {
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
        let usedInputs = Set(stems.filter { $0.strip == stem.strip }.map(\.inputBus))
        stem.inputBus = (0...).first { !usedInputs.contains($0) }!
        engine.connect(stem.player, to: stripMixers[stem.strip], fromBus: 0, toBus: stem.inputBus, format: stem.file.processingFormat)
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
        faderMixers[strip].outputVolume = min(1, gain * Self.headroom)
    }

    public func setSendGain(_ bus: SendBus, strip: Int, _ gain: Float) {
        sendGains[strip][bus.rawValue] = gain
        applySend(bus, strip: strip)
    }

    public func setThrow(strip: Int, _ on: Bool) {
        throwing[strip] = on
        for bus in [SendBus.delay, .reverb] { applySend(bus, strip: strip) } // whichever the throw targets
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
        lastFX[parameter] = value
        if let (kind, index) = parameter.kernelParameter {
            effects[kind]?.set(index, value)
            if kind == .plate { effects[.spring]?.set(index, value) } // the spring shares the plate's knobs
            if kind == .phaser { effects[.flanger]?.set(index, value) } // so does the flanger with the phaser's
            return
        }
        // Returns and sends are per destination: a return at zero never closes the bus's send, and back.
        if parameter.isBusSend, let source = parameter.bus {
            if let target = busRouting.target(of: source) {
                returnMixers[source.rawValue].destination(forMixer: busInputs[target.rawValue], bus: sendInput(from: source))?.volume = value
            }
            return
        }
        let source: SendBus
        switch parameter {
        case .delayReturn: source = .delay
        case .reverbReturn: source = .reverb
        case .phaserReturn: source = .bus3
        default: return
        }
        returnMixers[source.rawValue].destination(forMixer: engine.mainMixerNode, bus: returnBusBase + source.rawValue)?.volume = value
    }

    // MARK: Bus-to-bus sends (issue #1)

    /// Sends a bus's return to another bus (nil = none). Refused when it would close a loop.
    /// Rewiring needs the engine stopped for a moment, like swapping an effect: effect tails are cut.
    @discardableResult
    public func setBusSend(from source: SendBus, to target: SendBus?) -> Bool {
        guard let routing = busRouting.setting(source, to: target) else { return false }
        setBusRouting(routing)
        return true
    }

    /// Applies a whole routing at once (a project being opened); ignored if it has a loop.
    public func setBusRouting(_ routing: BusRouting) {
        guard routing != busRouting, routing.isLoopFree else { return }
        let changed = SendBus.allCases.filter { routing.target(of: $0) != busRouting.target(of: $0) }
        restructure {
            engine.stop()
            busRouting = routing
            for source in changed { connectReturn(of: source) }
            try? engine.start()
        }
    }

    /// Wires a return to the master and to its routed bus, with the current return and send levels.
    private func connectReturn(of source: SendBus) {
        let b = source.rawValue
        var points = [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: returnBusBase + b)]
        if let target = busRouting.target(of: source) {
            points.append(AVAudioConnectionPoint(node: busInputs[target.rawValue], bus: sendInput(from: source)))
        }
        engine.connect(returnMixers[b], to: points, fromBus: 0, format: format)
        let returnParameter: FXParameter = [.delayReturn, .reverbReturn, .phaserReturn][b]
        let send = FXParameter.busSend(from: source)
        // New connections open at full volume: restore the levels (a never-set send stays closed).
        setFX(returnParameter, lastFX[returnParameter] ?? 1)
        setFX(send, lastFX[send] ?? 0)
    }

    // MARK: Delay and reverb gestures (PRD § 11.4)

    /// HOLD: the delay loop closes on itself while held.
    public func setHold(_ on: Bool) {
        effects[.delay]?.set(DUB_DELAY_HOLD, on ? 1 : 0)
    }

    /// CRASH: hits the spring. Does nothing on the plate (the caller tells the user).
    public func crash() {
        guard reverbModel == .spring else { return }
        effects[.spring]?.set(DUB_SPRING_CRASH, 1)
    }

    /// Plate or spring on the REVERB bus. With a plugin on the bus, the choice waits for the built-in effect.
    public func setReverbModel(_ model: ReverbModel) {
        guard model != reverbModel, effectNodes[SendBus.reverb.rawValue] != nil else { return }
        reverbModel = model
        if effects[.spring] == nil {
            let spring = BuiltInEffect(.spring)
            effects[.spring] = spring
            // Same knobs as the plate: start from its current settings.
            for parameter in FXParameter.allCases {
                if let (kind, index) = parameter.kernelParameter, kind == .plate { spring.set(index, lastFX[parameter] ?? parameter.value(parameter.defaultValue)) }
            }
        }
        guard plugins[.reverb] == nil, let node = effects[model.kind]?.node else { return }
        swapEffectNode(node, on: .reverb)
    }

    public func setThrowTarget(_ target: ThrowTarget) {
        throwTarget = target
        for strip in 0..<Self.stripCount {
            applySend(.delay, strip: strip)
            applySend(.reverb, strip: strip)
        }
    }

    /// Bi-Phaser or tape flanger on BUS 3. With a plugin on the bus, the choice waits for the built-in effect.
    public func setBus3Model(_ model: Bus3Model) {
        guard model != bus3Model, effectNodes[SendBus.bus3.rawValue] != nil else { return }
        bus3Model = model
        if effects[.flanger] == nil {
            let flanger = BuiltInEffect(.flanger)
            effects[.flanger] = flanger
            for parameter in FXParameter.allCases {
                if let (kind, index) = parameter.kernelParameter, kind == .phaser { flanger.set(index, lastFX[parameter] ?? parameter.value(parameter.defaultValue)) }
            }
        }
        guard plugins[.bus3] == nil, let node = effects[model.kind]?.node else { return }
        swapEffectNode(node, on: .bus3)
    }

    // MARK: Strip inserts (PRD § 11.5)

    /// A built-in insert on a strip (nil = straight through). Replaces a plugin insert if any.
    public func setInsert(strip: Int, _ kind: InsertKind?) {
        guard !stripInsertUnavailable, kind != nil || insertNodes[strip] != nil else { return } // nothing to swap
        if let kind {
            let effect = BuiltInEffect(kind.effectKind)
            insertEffects[strip] = effect
            swapInsertNode(effect.node, strip: strip)
        } else {
            insertEffects[strip] = nil
            swapInsertNode(nil, strip: strip)
        }
        inserts[strip] = kind
        insertPlugins[strip] = nil
        insertMacroTargets[strip] = nil
    }

    /// Insert parameter, normalized 0…1 (see `InsertKind.parameters`).
    public func setInsertParameter(strip: Int, index: Int, _ normalized: Double) {
        guard let kind = inserts[strip], kind.parameters.indices.contains(index) else { return }
        let parameter = kind.parameters[index]
        insertEffects[strip]?.set(parameter.kernelIndex, parameter.value(normalized))
    }

    /// An Audio Unit in a strip's insert. Set its mix as wanted: it sits in the direct path.
    @discardableResult
    public func loadInsertPlugin(_ info: PluginInfo, strip: Int, state: Data? = nil) async throws -> HostedPlugin {
        guard !stripInsertUnavailable else { throw PluginError.noEffectChain }
        let plugin = try await HostedPlugin.load(info, format: format)
        if let state { plugin.restore(state) }
        swapInsertNode(plugin.unit, strip: strip)
        inserts[strip] = nil
        insertEffects[strip] = nil
        insertPlugins[strip] = plugin
        insertMacroTargets[strip] = Array(repeating: nil, count: Self.insertMacroCount)
        return plugin
    }

    public func setInsertMacroTarget(_ parameter: PluginParameter?, strip: Int, index: Int) {
        guard insertMacroTargets[strip]?.indices.contains(index) == true else { return }
        insertMacroTargets[strip]?[index] = parameter
    }

    public func setInsertMacro(strip: Int, index: Int, _ normalized: Double) {
        guard let target = insertMacroTargets[strip]?[index], let plugin = insertPlugins[strip] else { return }
        plugin.setNormalizedValue(target.address, normalized)
    }

    /// Engines built without effects (some tests) have no insert chain to swap.
    private var stripInsertUnavailable: Bool { effects.isEmpty }

    private func swapInsertNode(_ node: AVAudioNode?, strip: Int) {
        let inlet = insertInlets[strip], outlet = insertOutlets[strip]
        restructure {
            engine.stop()
            engine.disconnectNodeOutput(inlet)
            if let old = insertNodes[strip] {
                engine.disconnectNodeOutput(old)
                engine.detach(old)
            }
            if let node {
                engine.attach(node)
                engine.connect(inlet, to: node, format: format)
                engine.connect(node, to: outlet, format: format)
            } else {
                engine.connect(inlet, to: outlet, format: format)
            }
            insertNodes[strip] = node
            try? engine.start()
        }
    }

    // MARK: Slots d'effets (effet intégré ou plugin Audio Unit)

    private static let builtInKinds: [BuiltInEffect.Kind] = [.delay, .plate, .phaser]

    /// The built-in effect a bus falls back to (reverb and bus 3 follow their chosen model).
    private func builtInKind(for bus: SendBus) -> BuiltInEffect.Kind {
        switch bus {
        case .delay: .delay
        case .reverb: reverbModel.kind
        case .bus3: bus3Model.kind
        }
    }

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
        guard plugins[bus] != nil, let builtIn = effects[builtInKind(for: bus)] else { return }
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

    /// Post-fader send from the fader mixer, and pre-fader take from the pre mixer: the send when the bus is
    /// pre-fader, and the dub throw (worth a send at full) on the buses it targets. The pre take compensates
    /// the strip headroom so its level matches a post-fader send.
    private func applySend(_ bus: SendBus, strip: Int) {
        let post = preFader[bus.rawValue] ? 0 : sendGains[strip][bus.rawValue]
        faderMixers[strip].destination(forMixer: busInputs[bus.rawValue], bus: strip)?.volume = post
        var pre: Float = preFader[bus.rawValue] ? sendGains[strip][bus.rawValue] * Self.headroom : 0
        if throwing[strip], throwTarget.includes(bus) { pre = Self.headroom }
        preMixers[strip].destination(forMixer: busInputs[bus.rawValue], bus: preBus(bus, strip: strip))?.volume = pre
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
