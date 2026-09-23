import AVFoundation
import DubDSP
import Foundation
import Testing
@testable import DubStemMixCore

// MARK: - Noyaux DSP (C), testés directement

/// Fait passer `input` (mono, dupliqué en stéréo) dans un noyau, par blocs de 512 comme le moteur.
private func run(_ effect: OpaquePointer, input: [Float]) -> (left: [Float], right: [Float]) {
    var left = input, right = input
    var offset = 0
    while offset < input.count {
        let frames = min(512, input.count - offset)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                dub_effect_process(effect, l.baseAddress! + offset, r.baseAddress! + offset,
                                   l.baseAddress! + offset, r.baseAddress! + offset, Int32(frames))
            }
        }
        offset += frames
    }
    return (left, right)
}

private func impulse(_ count: Int) -> [Float] {
    var signal = [Float](repeating: 0, count: count)
    signal[0] = 1
    return signal
}

private func energy(_ samples: ArraySlice<Float>) -> Float { samples.reduce(0) { $0 + $1 * $1 } }

@Test func delayEchoArrivesOnTime() {
    let delay = dub_effect_create(DUB_EFFECT_DELAY)!
    defer { dub_effect_destroy(delay) }
    dub_effect_set(delay, Int32(DUB_DELAY_TIME), 0.25)
    dub_effect_set(delay, Int32(DUB_DELAY_FEEDBACK), 0)
    dub_effect_set(delay, Int32(DUB_DELAY_WOW), 0)
    dub_effect_set(delay, Int32(DUB_DELAY_LOW_CUT), 10)
    dub_effect_set(delay, Int32(DUB_DELAY_HIGH_CUT), 20_000)
    dub_effect_prepare(delay, 48_000)

    let output = run(delay, input: impulse(24_000)).left
    let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) }!
    #expect(abs(peak - 12_000) <= 3, "écho au sample \(peak)")
    #expect(output[..<11_900].allSatisfy { abs($0) < 0.001 }) // 100 % wet : rien avant l'écho
}

@Test func delayRepeatsDecayAndGetDarker() {
    let delay = dub_effect_create(DUB_EFFECT_DELAY)!
    defer { dub_effect_destroy(delay) }
    dub_effect_set(delay, Int32(DUB_DELAY_TIME), 0.1)
    dub_effect_set(delay, Int32(DUB_DELAY_FEEDBACK), 0.6)
    dub_effect_set(delay, Int32(DUB_DELAY_WOW), 0)
    dub_effect_prepare(delay, 48_000)
    let output = run(delay, input: impulse(48_000)).left
    let first = energy(output[4700..<5300]), second = energy(output[9500..<10_100]), third = energy(output[14_300..<14_900])
    #expect(first > second && second > third && third > 0)
}

@Test func delaySelfOscillationStaysBounded() {
    let delay = dub_effect_create(DUB_EFFECT_DELAY)!
    defer { dub_effect_destroy(delay) }
    dub_effect_set(delay, Int32(DUB_DELAY_TIME), 0.12)
    dub_effect_set(delay, Int32(DUB_DELAY_FEEDBACK), 1.15)
    dub_effect_prepare(delay, 48_000)
    var generator = SystemRandomNumberGenerator()
    let burst = (0..<480_000).map { $0 < 24_000 ? Float.random(in: -0.8...0.8, using: &generator) : 0 }
    let output = run(delay, input: burst).left
    #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1.01 }) // la saturation borne la boucle
    #expect(energy(output[430_000...]) > 1) // …et la boucle tient toute seule
}

@Test func plateTailDecaysAndIsStereo() {
    let plate = dub_effect_create(DUB_EFFECT_PLATE)!
    defer { dub_effect_destroy(plate) }
    dub_effect_set(plate, Int32(DUB_PLATE_DECAY), 0.8)
    dub_effect_prepare(plate, 48_000)
    let (left, right) = run(plate, input: impulse(192_000))
    #expect(left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite))
    let early = energy(left[12_000..<36_000]), late = energy(left[150_000..<174_000])
    #expect(early > 0 && late > 0 && late < early * 0.2)
    #expect(zip(left, right).contains { abs($0 - $1) > 0.001 })
}

@Test func phaserStaysBoundedAtFullResonance() {
    let phaser = dub_effect_create(DUB_EFFECT_PHASER)!
    defer { dub_effect_destroy(phaser) }
    dub_effect_set(phaser, Int32(DUB_PHASER_FEEDBACK), 0.95)
    dub_effect_set(phaser, Int32(DUB_PHASER_DEPTH), 1)
    dub_effect_set(phaser, Int32(DUB_PHASER_RATE), 2)
    dub_effect_prepare(phaser, 48_000)
    var generator = SystemRandomNumberGenerator()
    let noise = (0..<192_000).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
    let (left, right) = run(phaser, input: noise)
    #expect(left.allSatisfy { $0.isFinite && abs($0) < 6 })
    #expect(zip(left, right).contains { abs($0 - $1) > 0.01 }) // LFO déphasé entre les canaux
}

/// Le phaser vit sur un bus d'envoi : c'est la somme « direct + sortie du phaser » qui doit creuser
/// des encoches profondes. 12 étages : encoche là où chaque étage déphase de 45° (f = fc · tan 22,5°).
@Test func phaserCarvesDeepNotchesAgainstTheDrySignal() {
    let phaser = dub_effect_create(DUB_EFFECT_PHASER)!
    defer { dub_effect_destroy(phaser) }
    dub_effect_set(phaser, Int32(DUB_PHASER_DEPTH), 0) // balayage figé
    dub_effect_set(phaser, Int32(DUB_PHASER_FEEDBACK), 0)
    dub_effect_set(phaser, Int32(DUB_PHASER_CENTER), 1000)
    dub_effect_prepare(phaser, 48_000)

    func residual(at frequency: Double) -> Float {
        dub_effect_prepare(phaser, 48_000)
        let dry = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
        let wet = run(phaser, input: dry).left
        let sum = zip(dry, wet).map { $0 + $1 }
        return energy(sum[24_000...]) / energy(dry[24_000...])
    }
    #expect(residual(at: 1000 * tan(Double.pi / 8)) < 0.01) // encoche : plus de 20 dB d'atténuation
    #expect(residual(at: 1000) > 3.5)                        // entre deux encoches : +6 dB
}

// MARK: - Dans le moteur (rendu hors ligne, à travers l'Audio Unit interne)

@MainActor @Test func throwGoesThroughTheBuiltInDelay() throws {
    let engine = try AudioEngine(offline: true, effects: true)
    let url = FileManager.default.temporaryDirectory.appending(path: "dsm-fx-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for channel in 0..<2 { buffer.floatChannelData![channel][1000] = 1 }
    try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)

    try engine.addStem(url: url, name: "impulse", strip: 0)
    engine.setFaderGain(strip: 0, 0) // tranche coupée : seul le throw (pré-fader) atteint le delay
    engine.setMasterGain(1)
    engine.setThrow(strip: 0, true)
    engine.setFX(.delayTime, 0.1)
    engine.setFX(.delayFeedback, 0)
    engine.setFX(.delayWow, 0)
    engine.setFX(.delayLowCut, 10)
    engine.setFX(.delayHighCut, 20_000)
    engine.setFX(.delayReturn, 1)
    engine.loop = false
    _ = try engine.renderOffline(frames: 96_000) // le temps de retard glisse jusqu'à sa cible
    engine.play()

    let output = try engine.renderOffline(frames: 24_000)
    let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) }!
    #expect(abs(peak - (AudioEngine.offlineStartDelay + 1000 + 4800)) <= 3, "écho au sample \(peak)")
    #expect(abs(output[peak]) > 0.05)
}

/// Energy reaching the master when a thrown impulse can only get out through `exit` (issue #1):
/// the other returns are closed, so anything heard came through a bus-to-bus send.
@MainActor private func energyThrough(
    _ exit: SendBus, throwTo target: ThrowTarget, configure: (AudioEngine) -> Void
) throws -> Float {
    let engine = try AudioEngine(offline: true, effects: true)
    let url = FileManager.default.temporaryDirectory.appending(path: "dsm-route-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for channel in 0..<2 { buffer.floatChannelData![channel][1000] = 1 }
    try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)

    try engine.addStem(url: url, name: "impulse", strip: 0)
    engine.setFaderGain(strip: 0, 0) // no direct signal: only the throw reaches the buses
    engine.setMasterGain(1)
    engine.setThrowTarget(target)
    engine.setThrow(strip: 0, true)
    engine.setFX(.delayFeedback, 0)
    engine.setFX(.delayToReverb, 0)
    for (bus, parameter) in zip(SendBus.allCases, [FXParameter.delayReturn, .reverbReturn, .phaserReturn]) {
        engine.setFX(parameter, bus == exit ? 1 : 0)
    }
    configure(engine)
    engine.loop = false
    engine.play()
    let output = try engine.renderOffline(frames: 48_000)
    return energy(output[...])
}

@MainActor @Test func delayCanBeSentToBus3Instead() throws {
    let closed = try energyThrough(.bus3, throwTo: .delay) { _ in }
    let open = try energyThrough(.bus3, throwTo: .delay) {
        #expect($0.setBusSend(from: .delay, to: .bus3))
        $0.setFX(.delayToReverb, 1)
    }
    #expect(closed < 1e-6, "no send to bus 3 by default: \(closed)")
    #expect(open > 1e-3, "delay sent to bus 3: \(open)")
}

@MainActor @Test func reverbCanBeSentBackToTheDelay() throws {
    let open = try energyThrough(.delay, throwTo: .reverb) {
        #expect(!$0.setBusSend(from: .reverb, to: .delay)) // DLY→REV exists: that would close a loop
        #expect($0.setBusSend(from: .delay, to: nil))
        #expect($0.setBusSend(from: .reverb, to: .delay))
        $0.setFX(.reverbSend, 1)
    }
    #expect(open > 1e-3, "reverb sent to the delay: \(open)")
}

@MainActor @Test func rewiringSendsRepeatedlyWhilePlayingKeepsTheEngineAlive() throws {
    let engine = try AudioEngine(offline: true, effects: true)
    engine.play()
    let targets: [SendBus?] = [.bus3, nil, .reverb, .bus3, nil, .reverb]
    for target in targets {
        #expect(engine.setBusSend(from: .delay, to: target))
        _ = try engine.renderOffline(frames: 1024)
    }
    #expect(engine.busRouting == .standard)
}

@Test func busRoutingNeverClosesALoop() {
    var routing = BusRouting.standard // delay → reverb
    #expect(!routing.allows(.reverb, to: .delay))
    #expect(!routing.allows(.delay, to: .delay))
    routing = routing.setting(.reverb, to: .bus3)! // delay → reverb → bus 3
    #expect(!routing.allows(.bus3, to: .delay) && !routing.allows(.bus3, to: .reverb))
    #expect(routing.allows(.delay, to: .bus3)) // replacing the delay's own target is fine
    #expect(BusRouting(projectValue: ["delay": "reverb", "reverb": "delay"]) == .standard) // a looped file falls back
    #expect(BusRouting(projectValue: routing.projectValue) == routing)
    #expect(BusRouting.standard.projectValue == nil)
}

@MainActor @Test func busSendsStayOnTheirKnobsWhenBusesHostPlugins() {
    let mix = MixController(engine: FakeEngine())
    for bus in SendBus.allCases { mix.setHosted(bus, true) }
    #expect(mix.cell(strip: 1, row: 2) == .parameter(.delayToReverb))
    #expect(mix.cell(strip: 7, row: 0) == .parameter(.reverbSend))
    #expect(mix.cell(strip: 7, row: 1) == .parameter(.bus3Send))
    #expect(mix.cell(strip: 3, row: 2) == .macro(.reverb, 5)) // the reverb keeps its 6 macros
    #expect(mix.cell(strip: 5, row: 2) == .macro(.bus3, 5)) // and so does bus 3
    #expect(FXParameter.delayToReverb.label(sendingTo: .reverb) == "DLY→REV")
    #expect(FXParameter.reverbSend.label(sendingTo: nil) == "REV→—")
}

// MARK: - Page FX

@MainActor @Test func fxPageRemapsKnobsWithPickup() {
    let engine = FakeEngine(), surface = FakeSurface()
    let mix = MixController(engine: engine, surface: surface)
    #expect(engine.fx[.delayTime] == FXParameter.delayTime.value(FXParameter.delayTime.defaultValue))

    mix.handle(.knob(strip: 0, row: 0, value: 0.9)) // page MIX : envoi delay de la tranche 1
    #expect(mix.strips[0].sends[0] == 0.9)

    mix.handle(.button(.bankRight, strip: 0, pressed: true))
    #expect(mix.page == .fx && surface.bankLeds.right && !surface.bankLeds.left)
    #expect(mix.fxGhost(.delayTime) == 0.9) // le potard est à 0,9, TIME vaut 0,62 : il doit rattraper

    mix.handle(.knob(strip: 0, row: 0, value: 0.85)) // encore au-dessus : ignoré
    #expect(mix.fx[.delayTime] == FXParameter.delayTime.defaultValue)
    mix.handle(.knob(strip: 0, row: 0, value: 0.6)) // a croisé 0,62 : rattrapé
    #expect(mix.fx[.delayTime] == 0.6)
    #expect(engine.fx[.delayTime] == FXParameter.delayTime.value(0.6))
    #expect(mix.strips[0].sends[0] == 0.9) // l'envoi de la page MIX n'a pas bougé

    mix.handle(.fader(strip: 0, value: 0.3)) // les faders restent des volumes sur la page FX
    #expect(mix.strips[0].fader == 0.3)

    mix.handle(.button(.bankLeft, strip: 0, pressed: true))
    #expect(mix.page == .mix && mix.knobGhost(strip: 0, row: 0) == 0.6)
}

@MainActor @Test func untouchedKnobDoesNotJumpAnEffectParameter() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    mix.handle(.button(.bankRight, strip: 0, pressed: true))
    mix.handle(.knob(strip: 0, row: 1, value: 0.05)) // jamais vu avant, loin de FEEDBACK (0,5)
    #expect(mix.fx[.delayFeedback] == FXParameter.delayFeedback.defaultValue)
}

@Test func fxParameterDisplaysRealUnits() {
    #expect(FXParameter.delayTime.display(0) == "40 ms")
    #expect(FXParameter.delayTime.display(1) == "1500 ms")
    #expect(FXParameter.delayHighCut.display(1) == "14.0 kHz")
    #expect(FXParameter.delayReturn.display(1) == "+0 dB")
    #expect(FXParameter.delayReturn.display(0) == "−∞ dB")
    #expect(FXParameter.layout.count == 8 && FXParameter.layout.allSatisfy { $0.count == 3 })
    let onPages = Set((FXParameter.layout + FXParameter.masterLayout).flatMap { $0 }.compactMap { $0 })
    #expect(onPages.count == FXParameter.allCases.count) // every parameter has a knob on one page
}

// MARK: - Tempo

/// Enveloppe d'attaques synthétique : un coup par temps, un coup plus faible sur le contretemps.
private func clickEnvelope(bpm: Double, seconds: Double, framesPerSecond: Double) -> [Float] {
    var envelope = [Float](repeating: 0, count: Int(seconds * framesPerSecond))
    let period = 60 / bpm * framesPerSecond
    var beat = 0.0
    while Int(beat) < envelope.count {
        envelope[Int(beat)] = 1
        let offbeat = Int(beat + period / 2)
        if offbeat < envelope.count { envelope[offbeat] = 0.4 }
        beat += period
    }
    return envelope
}

/// Un morceau à 140 BPM est rendu à 70 : toujours dans la plage 58–125, l'utilisateur a ×2.
@Test(arguments: [(68.0, 68.0), (72.0, 72.0), (90.5, 90.5), (118.0, 118.0), (140.0, 70.0)])
func tempoIsDetected(played: Double, expected: Double) {
    let detected = TempoDetector.estimate(envelope: clickEnvelope(bpm: played, seconds: 60, framesPerSecond: 187.5), framesPerSecond: 187.5)
    #expect(abs((detected ?? 0) - expected) <= 0.3, "détecté : \(String(describing: detected))")
}

@Test func silenceHasNoTempo() {
    #expect(TempoDetector.estimate(envelope: [Float](repeating: 0, count: 12_000), framesPerSecond: 187.5) == nil)
}

@MainActor @Test func syncedDelayFollowsTempoAndDivision() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    mix.setFX(.delayTime, 0.45) // 3e division sur 6 : croche pointée
    #expect(mix.fxDisplay(.delayTime).hasSuffix("ms") && !mix.fxDisplay(.delayTime).contains("/"))

    mix.setTempo(72)
    mix.setDelaySync(true)
    #expect(abs((engine.fx[.delayTime] ?? 0) - Float(60.0 / 72 * 0.75)) < 0.0001)
    #expect(mix.fxDisplay(.delayTime) == "1/8. · 625 ms")

    mix.setTempo(144) // ×2 : le delay suit
    #expect(abs((engine.fx[.delayTime] ?? 0) - Float(60.0 / 144 * 0.75)) < 0.0001)

    mix.setFX(.delayTime, 1) // potard à fond : blanche
    #expect(mix.fxDisplay(.delayTime).hasPrefix("1/2"))

    mix.setDelaySync(false) // retour au temps libre, en millisecondes
    #expect(engine.fx[.delayTime] == FXParameter.delayTime.value(1))
}

// MARK: - Plugins Audio Unit (testés avec l'AUDelay d'Apple, présent sur tous les Mac)

@MainActor @Test func pluginReplacesTheBuiltInEffectAndComesBack() async throws {
    let appleDelay = try #require(PluginInfo.installed().first { $0.id == "aufx-dely-appl" })
    let engine = try AudioEngine(offline: true, effects: true)
    let url = FileManager.default.temporaryDirectory.appending(path: "dsm-au-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
    buffer.frameLength = 96_000
    // 440 Hz et non un signal continu : le delay intégré a un coupe-bas dans sa boucle.
    for channel in 0..<2 { for n in 0..<96_000 { buffer.floatChannelData![channel][n] = Float(0.8 * sin(2 * Double.pi * 440 * Double(n) / 48_000)) } }
    try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
    try engine.addStem(url: url, name: "sine", strip: 0)
    engine.setFaderGain(strip: 0, 0) // seul le throw atteint le bus delay
    engine.setMasterGain(1)
    engine.setFX(.delayReturn, 1)
    engine.setThrow(strip: 0, true)

    let plugin = try await engine.loadPlugin(appleDelay, on: .delay)
    #expect(engine.plugins[.delay] != nil)
    let parameters = plugin.parameters
    #expect(parameters.count >= 3, "\(parameters.map(\.name))")

    // Potard macro → paramètre du plugin.
    let target = try #require(parameters.first)
    engine.setMacroTarget(target, bus: .delay, index: 0)
    engine.setMacro(bus: .delay, index: 0, 1)
    #expect(abs((plugin.normalizedValue(target.address) ?? 0) - 1) < 0.001)
    engine.setMacro(bus: .delay, index: 0, 0.25)
    #expect(abs((plugin.normalizedValue(target.address) ?? 0) - 0.25) < 0.001)
    #expect(!plugin.displayValue(target.address).isEmpty)

    // L'état du plugin se sauvegarde et se restaure.
    let saved = try #require(plugin.state)
    engine.setMacro(bus: .delay, index: 0, 0.9)
    plugin.restore(saved)
    #expect(abs((plugin.normalizedValue(target.address) ?? 0) - 0.25) < 0.01)

    // Le son traverse le plugin…
    try warmUpEngine(engine)
    engine.play()
    let throughPlugin = try engine.renderOffline(frames: 48_000)
    #expect(throughPlugin.contains { abs($0) > 0.01 })

    // …puis l'effet intégré reprend sa place, à chaud.
    engine.unloadPlugin(on: .delay)
    #expect(engine.plugins[.delay] == nil)
    let throughBuiltIn = try engine.renderOffline(frames: 96_000)
    #expect(throughBuiltIn.suffix(24_000).contains { abs($0) > 0.01 })
}

/// Changer plusieurs fois d'effet sur un même bus, à chaud (c'est ce que fait un utilisateur qui essaie des plugins).
@MainActor @Test func effectsCanBeSwappedRepeatedly() async throws {
    let plugins = PluginInfo.installed()
    let delay = try #require(plugins.first { $0.id == "aufx-dely-appl" })
    let reverb = try #require(plugins.first { $0.id == "aufx-mrev-appl" })
    let engine = try AudioEngine(offline: true, effects: true)
    for round in 0..<3 {
        try await engine.loadPlugin(delay, on: .reverb)
        _ = try engine.renderOffline(frames: 2048)
        try await engine.loadPlugin(reverb, on: .reverb) // plugin → plugin, sans repasser par l'effet intégré
        _ = try engine.renderOffline(frames: 2048)
        engine.unloadPlugin(on: .reverb)
        _ = try engine.renderOffline(frames: 2048)
        #expect(engine.plugins[.reverb] == nil, "tour \(round)")
    }
}

@MainActor private func warmUpEngine(_ engine: AudioEngine) throws { _ = try engine.renderOffline(frames: 9600) }

@MainActor @Test func hostedBusTurnsItsKnobsIntoMacros() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    #expect(mix.cell(strip: 2, row: 0) == .parameter(.reverbDecay))

    mix.setHosted(.reverb, true)
    #expect(mix.cell(strip: 2, row: 0) == .macro(.reverb, 0))
    #expect(mix.cell(strip: 3, row: 2) == .macro(.reverb, 5))
    #expect(mix.cell(strip: 0, row: 0) == .parameter(.delayTime)) // les autres bus ne bougent pas
    #expect(mix.cell(strip: 6, row: 1) == .parameter(.reverbReturn)) // le retour reste un niveau du moteur

    mix.handle(.button(.bankRight, strip: 0, pressed: true))
    mix.handle(.knob(strip: 3, row: 1, value: 0.02)) // proche de 0 : le potard tient la macro
    mix.handle(.knob(strip: 3, row: 1, value: 0.6))
    #expect(mix.macros[.reverb]?[4] == 0.6 && engine.macros["reverb-4"] == 0.6)

    // Le delay garde DLY→REV sur son 6e potard, même avec un plugin.
    mix.setHosted(.delay, true)
    #expect(mix.cell(strip: 1, row: 2) == .parameter(.delayToReverb))
    #expect(mix.cell(strip: 1, row: 1) == .macro(.delay, 4))

    mix.syncMacro(bus: .reverb, index: 4, 0.1) // changé dans la fenêtre du plugin
    #expect(mix.macros[.reverb]?[4] == 0.1 && mix.macroGhost(bus: .reverb, index: 4) == 0.6)

    mix.setHosted(.reverb, false)
    #expect(mix.cell(strip: 2, row: 0) == .parameter(.reverbDecay) && mix.macros[.reverb] == nil)
}

// MARK: - Master chain (big knob, kills, dubplate)

private func sine(_ hz: Double, count: Int, rate: Double = 48_000) -> [Float] {
    (0..<count).map { Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

/// RMS of the last part of a signal, once filters have settled.
private func rms(_ samples: ArraySlice<Float>) -> Float { (energy(samples) / Float(samples.count)).squareRoot() }

private func decibels(_ output: [Float], reference: [Float]) -> Float {
    20 * log10(rms(output[24_000...]) / rms(reference[24_000...]))
}

private func makeMaster() -> OpaquePointer {
    let master = dub_effect_create(DUB_EFFECT_MASTER)!
    dub_effect_prepare(master, 48_000)
    return master
}

@Test func masterChainIsAnExactPassthroughByDefault() {
    let master = makeMaster()
    defer { dub_effect_destroy(master) }
    let input = sine(440, count: 4800)
    let output = run(master, input: input)
    #expect(output.left == input && output.right == input)
}

@Test func bigKnobCutsBelowItsStepAndLeavesTheRest() {
    let master = makeMaster()
    defer { dub_effect_destroy(master) }
    dub_effect_set(master, Int32(DUB_MASTER_HIGH_PASS), 300)
    let low = run(master, input: sine(50, count: 48_000)).left
    dub_effect_prepare(master, 48_000)
    let high = run(master, input: sine(2000, count: 48_000)).left
    #expect(decibels(low, reference: sine(50, count: 48_000)) < -25)
    #expect(abs(decibels(high, reference: sine(2000, count: 48_000))) < 1)
}

@Test func killsRemoveOneBandAndSumFlatWhenOpen() {
    let master = makeMaster()
    defer { dub_effect_destroy(master) }
    dub_effect_set(master, Int32(DUB_MASTER_BASS), 0)
    let bass = run(master, input: sine(60, count: 48_000)).left
    dub_effect_prepare(master, 48_000)
    let mid = run(master, input: sine(1000, count: 48_000)).left
    #expect(decibels(bass, reference: sine(60, count: 48_000)) < -30)
    #expect(abs(decibels(mid, reference: sine(1000, count: 48_000))) < 1)

    // Bands nearly open (so the crossovers are in the path): the sum stays flat across the spectrum.
    dub_effect_set(master, Int32(DUB_MASTER_BASS), 0.999)
    for hz in [80.0, 200.0, 1000.0, 2500.0, 8000.0] {
        dub_effect_prepare(master, 48_000)
        let out = run(master, input: sine(hz, count: 48_000)).left
        #expect(abs(decibels(out, reference: sine(hz, count: 48_000))) < 1, "\(hz) Hz")
    }
}

@Test func dubplateNarrowsTheBandwidthAndStaysBounded() {
    let master = makeMaster()
    defer { dub_effect_destroy(master) }
    dub_effect_set(master, Int32(DUB_MASTER_DUBPLATE), 1)
    let high = run(master, input: sine(14_000, count: 48_000)).left
    #expect(decibels(high, reference: sine(14_000, count: 48_000)) < -6)
    dub_effect_prepare(master, 48_000)
    let loud = run(master, input: sine(200, count: 48_000).map { $0 * 1.5 }).left
    #expect(loud.allSatisfy { abs($0) < 1.2 })
    #expect(rms(loud[24_000...]) > 0.3)
}

// MARK: - Delay heads, ping-pong, HOLD (PRD § 11.4)

private func makeDelay(time: Float = 0.1) -> OpaquePointer {
    let delay = dub_effect_create(DUB_EFFECT_DELAY)!
    dub_effect_set(delay, Int32(DUB_DELAY_TIME), time)
    dub_effect_set(delay, Int32(DUB_DELAY_FEEDBACK), 0)
    dub_effect_set(delay, Int32(DUB_DELAY_WOW), 0)
    dub_effect_set(delay, Int32(DUB_DELAY_LOW_CUT), 10)
    dub_effect_set(delay, Int32(DUB_DELAY_HIGH_CUT), 20_000)
    dub_effect_prepare(delay, 48_000)
    return delay
}

@Test func headPatternsPlaceEchoesAtMultiplesOfTheTime() {
    let delay = makeDelay()
    defer { dub_effect_destroy(delay) }
    dub_effect_set(delay, Int32(DUB_DELAY_HEADS), 5) // heads 1 + 3
    let output = run(delay, input: impulse(24_000)).left
    let loud = output.indices.filter { abs(output[$0]) > 0.2 }
    #expect(loud.contains { abs($0 - 4800) <= 3 } && loud.contains { abs($0 - 14_400) <= 3 }, "\(loud)")
    #expect(!loud.contains { abs($0 - 9600) <= 3 }) // head 2 is off
}

@Test func pingPongAlternatesSides() {
    let delay = makeDelay()
    defer { dub_effect_destroy(delay) }
    dub_effect_set(delay, Int32(DUB_DELAY_FEEDBACK), 0.7)
    dub_effect_set(delay, Int32(DUB_DELAY_PINGPONG), 1)
    dub_effect_prepare(delay, 48_000) // the width is smoothed: start from it, not from zero
    let output = run(delay, input: impulse(24_000))
    let firstL = energy(output.left[4700..<4900]), firstR = energy(output.right[4700..<4900])
    let secondL = energy(output.left[9500..<9700]), secondR = energy(output.right[9500..<9700])
    #expect(firstL > 10 * firstR, "first repeat on the left")
    #expect(secondR > 10 * secondL, "second repeat on the right")
}

@Test func holdKeepsTheLoopGoingWithoutInput() {
    let delay = makeDelay()
    defer { dub_effect_destroy(delay) }
    dub_effect_set(delay, Int32(DUB_DELAY_FEEDBACK), 0.3)
    var signal = [Float](repeating: 0, count: 96_000)
    for n in 0..<4800 { signal[n] = 0.5 * sin(Float(n) * 0.05) } // 100 ms of tone, then nothing
    _ = run(delay, input: Array(signal[..<9600]))
    dub_effect_set(delay, Int32(DUB_DELAY_HOLD), 1)
    let held = run(delay, input: Array(signal[9600..<72_000])).left
    // Ten loops later the level is still there (unity feedback), and bounded.
    #expect(energy(held[48_000..<52_800]) > 0.5 * energy(held[0..<4800]), "\(energy(held[48_000..<52_800])) vs \(energy(held[0..<4800]))")
    #expect(held.allSatisfy { abs($0) <= 1 })
    dub_effect_set(delay, Int32(DUB_DELAY_HOLD), 0)
    let released = run(delay, input: Array(signal[72_000...])).left
    #expect(energy(released[19_200..<24_000]) < 0.2 * energy(held[0..<4800])) // decays again at 30 %
}

// MARK: - Spring reverb and CRASH (PRD § 11.4)

@Test func springTailDecaysAndCrashIsLoud() {
    let spring = dub_effect_create(DUB_EFFECT_SPRING)!
    defer { dub_effect_destroy(spring) }
    dub_effect_set(spring, Int32(DUB_PLATE_DECAY), 0.8)
    dub_effect_prepare(spring, 48_000)
    let tail = run(spring, input: impulse(96_000))
    let early = energy(tail.left[0..<9600]), late = energy(tail.left[48_000..<57_600]), end = energy(tail.left[86_400..<96_000])
    #expect(early > late && late > end && end > 0, "\(early) \(late) \(end)")
    #expect(tail.left != tail.right) // two springs, a stereo pair
    let quiet = energy(run(spring, input: [Float](repeating: 0, count: 48_000)).left[38_400..<48_000])
    dub_effect_set(spring, Int32(DUB_SPRING_CRASH), 1)
    let crash = run(spring, input: [Float](repeating: 0, count: 48_000))
    #expect(energy(crash.left[0..<9600]) > 100 * quiet)
    #expect(crash.left.allSatisfy { abs($0) < 2 })
    #expect(dub_effect_get(spring, Int32(DUB_SPRING_CRASH)) == 0) // consumed
}

// MARK: - Strip inserts and flanger (PRD § 11.5)

/// Correlation of a signal with a sine at `hz`, over its last part: how much of that frequency is there.
private func level(of samples: [Float], at hz: Double) -> Float {
    let tail = samples[24_000...]
    var re: Float = 0, im: Float = 0
    for (i, x) in tail.enumerated() {
        let phase = 2 * Double.pi * hz * Double(i) / 48_000
        re += x * Float(cos(phase))
        im += x * Float(sin(phase))
    }
    return 2 * (re * re + im * im).squareRoot() / Float(tail.count)
}

@Test func subGeneratorAddsAnOctaveBelowTheBass() {
    let sub = dub_effect_create(DUB_EFFECT_SUB)!
    defer { dub_effect_destroy(sub) }
    dub_effect_prepare(sub, 48_000)
    let bass = sine(80, count: 48_000).map { $0 * 0.5 }
    let dry = run(sub, input: bass).left
    #expect(dry == bass) // amount 0: exact passthrough

    dub_effect_set(sub, Int32(DUB_SUB_AMOUNT), 1)
    dub_effect_set(sub, Int32(DUB_SUB_CUTOFF), 100)
    dub_effect_prepare(sub, 48_000)
    let boosted = run(sub, input: bass).left
    #expect(level(of: boosted, at: 40) > 0.15, "sub at 40 Hz: \(level(of: boosted, at: 40))")
    #expect(abs(level(of: boosted, at: 80) - 0.5) < 0.1) // the bass itself is untouched
    #expect(level(of: boosted, at: 120) < 0.25 * level(of: boosted, at: 40), "harmonic \(level(of: boosted, at: 120)) vs sub \(level(of: boosted, at: 40))")
}

@Test func autoWahOpensWithLevel() {
    let wah = dub_effect_create(DUB_EFFECT_WAH)!
    defer { dub_effect_destroy(wah) }
    dub_effect_set(wah, Int32(DUB_WAH_RANGE), 1)
    dub_effect_set(wah, Int32(DUB_WAH_RESONANCE), 0.2)
    dub_effect_prepare(wah, 48_000)
    let quiet = run(wah, input: sine(1500, count: 48_000).map { $0 * 0.02 }).left
    dub_effect_prepare(wah, 48_000)
    let loud = run(wah, input: sine(1500, count: 48_000).map { $0 * 0.5 }).left
    let quietGain = level(of: quiet, at: 1500) / 0.02, loudGain = level(of: loud, at: 1500) / 0.5
    #expect(loudGain > 4 * quietGain, "quiet \(quietGain) loud \(loudGain)") // the filter opened

    dub_effect_set(wah, Int32(DUB_WAH_DIRECTION), 1)
    dub_effect_prepare(wah, 48_000)
    let loudDown = run(wah, input: sine(1500, count: 48_000).map { $0 * 0.5 }).left
    #expect(level(of: loudDown, at: 1500) / 0.5 < loudGain / 4) // down mode: louder closes it
    #expect(loud.allSatisfy { abs($0) < 3 })
}

@Test func flangerIsAShortDelayWithFeedback() {
    let flanger = dub_effect_create(DUB_EFFECT_FLANGER)!
    defer { dub_effect_destroy(flanger) }
    dub_effect_set(flanger, Int32(DUB_PHASER_DEPTH), 0)
    dub_effect_set(flanger, Int32(DUB_PHASER_FEEDBACK), 0.5)
    dub_effect_set(flanger, Int32(DUB_PHASER_CENTER), 500) // 2 ms = 96 samples
    dub_effect_prepare(flanger, 48_000)
    let output = run(flanger, input: impulse(2400)).left
    let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) }!
    #expect(abs(peak - 96) <= 2, "first repeat at \(peak)")
    #expect(output[..<90].allSatisfy { abs($0) < 0.001 }) // wet only
    #expect(abs(output[min(2399, peak * 2)]) > 0.2 && abs(output[min(2399, peak * 2)]) < abs(output[peak])) // decaying repeats
}
