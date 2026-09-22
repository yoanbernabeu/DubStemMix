import AVFoundation
import Foundation
import Testing
@testable import DubStemMixCore

// MARK: - Import

@Test func stripNamesDropCommonPrefixAndSuffix() {
    let names = [
        "Akae Beka - Don't Feel No Way (Autre)_1",
        "Akae Beka - Don't Feel No Way (Basse)_1",
        "Akae Beka - Don't Feel No Way (Batteries)_1",
        "Akae Beka - Don't Feel No Way (Chant)_1",
    ]
    #expect(StemImporter.stripNames(for: names) == ["AUTRE", "BASSE", "BATTERIES", "CHANT"])
    #expect(StemImporter.stripNames(for: ["bass"]) == ["BASS"])
}

@Test func importIgnoresNonAudioFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dsm-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["b.wav", "a.WAV", "a.wav.asd", "notes.txt"] {
        try Data().write(to: folder.appending(path: name))
    }
    #expect(StemImporter.audioFiles(in: [folder]).map(\.lastPathComponent) == ["a.WAV", "b.wav"])
}

// MARK: - Mapping MIDImix

@Test func factoryMappingDecodes() {
    func decode(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> String {
        MidiMix.decode(status: status, data1: d1, data2: d2).map { "\($0)" } ?? "nil"
    }
    #expect(decode(0xB0, 16, 127) == "knob(strip: 0, row: 0, value: 1.0)")
    #expect(decode(0xB0, 60, 0) == "knob(strip: 7, row: 2, value: 0.0)")
    #expect(decode(0xB0, 49, 127) == "fader(strip: 4, value: 1.0)")
    #expect(decode(0xB0, 62, 127) == "master(value: 1.0)")
    #expect(decode(0x90, 1, 127).contains("mute, strip: 0, pressed: true"))
    #expect(decode(0x80, 24, 127).contains("recArm, strip: 7, pressed: false"))
    #expect(decode(0x90, 5, 127).contains("solo, strip: 1, pressed: true"))
    #expect(decode(0x90, 26, 127).contains("bankRight"))
    #expect(decode(0xB0, 99, 5) == "nil")
}

@Test func messagesOutsideTheFactoryMappingAreDescribed() {
    #expect(MidiMix.unmappedDescription(status: 0xB1, data1: 99) == "CC 99 on channel 2")
    #expect(MidiMix.unmappedDescription(status: 0x90, data1: 40) == "note 40 on channel 1")
    #expect(MidiMix.unmappedDescription(status: 0xF8, data1: 0) == nil) // MIDI clock: not a mapping issue
    // Everything the factory mapping sends decodes, so it never triggers the warning.
    for cc: UInt8 in [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
                      46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62] {
        #expect(MidiMix.decode(status: 0xB0, data1: cc, data2: 64) != nil, "CC \(cc)")
    }
    for note: UInt8 in 1...27 {
        #expect(MidiMix.decode(status: 0x90, data1: note, data2: 127) != nil, "note \(note)")
    }
}

// MARK: - Logique de mix

@MainActor
final class FakeEngine: MixEngineControl {
    var faders = [Float](repeating: -1, count: 8)
    var sends = [[Float]](repeating: [-1, -1, -1], count: 8)
    var throwing = [Bool](repeating: false, count: 8)
    var master: Float = -1

    func setFaderGain(strip: Int, _ gain: Float) { faders[strip] = gain }
    func setSendGain(_ bus: SendBus, strip: Int, _ gain: Float) { sends[strip][bus.rawValue] = gain }
    func setThrow(strip: Int, _ on: Bool) { throwing[strip] = on }
    func setMasterGain(_ gain: Float) { master = gain }
    var fx: [FXParameter: Float] = [:]
    func setFX(_ parameter: FXParameter, _ value: Float) { fx[parameter] = value }
    var macros: [String: Double] = [:]
    func setMacro(bus: SendBus, index: Int, _ normalized: Double) { macros["\(bus)-\(index)"] = normalized }
}

@MainActor
final class FakeSurface: ControlSurface {
    var muteLeds = [Bool](repeating: false, count: 8)
    var recLeds = [Bool](repeating: false, count: 8)
    var bankLeds = (left: false, right: false)

    func setMuteLed(strip: Int, _ on: Bool) { muteLeds[strip] = on }
    func setSoloLed(strip: Int, _ on: Bool) {}
    func setRecLed(strip: Int, _ on: Bool) { recLeds[strip] = on }
    func setBankLeds(left: Bool, right: Bool) { bankLeds = (left, right) }
}

@MainActor @Test func faderLawHasUnityAtEightyPercent() {
    #expect(abs(MixController.faderGain(0.8) - 1) < 0.0001)
    #expect(MixController.faderGain(0) == 0)
    #expect(MixController.faderGain(1) > 1.5)
}

@MainActor @Test func muteCutsTheStripAndLightsTheLed() {
    let engine = FakeEngine(), surface = FakeSurface()
    let mix = MixController(engine: engine, surface: surface)
    #expect(abs(engine.faders[2] - 1) < 0.0001)

    mix.handle(.button(.mute, strip: 2, pressed: true))
    mix.handle(.button(.mute, strip: 2, pressed: false))
    #expect(engine.faders[2] == 0)
    #expect(surface.muteLeds[2])

    // Bouger le fader d'une tranche coupée ne la rouvre pas.
    mix.handle(.fader(strip: 2, value: 1))
    #expect(engine.faders[2] == 0)

    mix.handle(.button(.mute, strip: 2, pressed: true))
    #expect(engine.faders[2] > 1.5)
    #expect(!surface.muteLeds[2])
}

@MainActor @Test func soloIsInPlaceAndOverridesMute() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    mix.handle(.button(.mute, strip: 0, pressed: true))
    mix.handle(.button(.solo, strip: 0, pressed: true))
    #expect(engine.faders[0] > 0)
    #expect(engine.faders[1] == 0)
    mix.handle(.button(.solo, strip: 0, pressed: true))
    #expect(engine.faders[0] == 0)
    #expect(engine.faders[1] > 0)
}

@MainActor @Test func throwIsMomentary() {
    let engine = FakeEngine(), surface = FakeSurface()
    let mix = MixController(engine: engine, surface: surface)
    mix.handle(.button(.recArm, strip: 3, pressed: true))
    #expect(engine.throwing[3] && surface.recLeds[3] && mix.strips[3].throwing)
    mix.handle(.button(.recArm, strip: 3, pressed: false))
    #expect(!engine.throwing[3] && !surface.recLeds[3])
}

@MainActor @Test func firstMessageAdoptsTheConsole() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    mix.handle(.knob(strip: 0, row: 0, value: 0.5)) // SEND ALL
    #expect(mix.strips[0].sends[0] == 0.5)
    #expect(engine.sends[0][0] == 0.25)
}

@MainActor @Test func screenChangeRequiresPickup() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    mix.handle(.knob(strip: 0, row: 1, value: 0.2))
    mix.setSend(strip: 0, row: 1, 0.7) // à la souris
    #expect(mix.knobGhost(strip: 0, row: 1) == 0.2)

    mix.handle(.knob(strip: 0, row: 1, value: 0.3)) // encore loin : ignoré
    #expect(mix.strips[0].sends[1] == 0.7)
    #expect(mix.knobGhost(strip: 0, row: 1) == 0.3)

    mix.handle(.knob(strip: 0, row: 1, value: 0.75)) // a croisé 0,7 : rattrapé
    #expect(mix.strips[0].sends[1] == 0.75)
    #expect(mix.knobGhost(strip: 0, row: 1) == nil)
}

// MARK: - Moteur audio (rendu hors ligne, au sample près)

/// Gain d'un stem à travers le moteur hors ligne : 6 dB de marge sur la tranche et sur le master.
private let pathGain: Float = 0.25

private func makeStem(frames: Int, sampleRate: Double = 48_000, fill: (Int) -> Float) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "dsm-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<2 {
        for n in 0..<frames { buffer.floatChannelData![channel][n] = fill(n) }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false) // format du buffer fourni
    try file.write(from: buffer)
    return url
}

/// Dans l'app le moteur tourne déjà quand on lance la lecture. Le mixeur ouvrant chaque nouvelle
/// entrée en fondu (~25 ms), les tests font de même avant de mesurer au sample près.
@MainActor private func warmUp(_ engine: AudioEngine) throws {
    _ = try engine.renderOffline(frames: 9600)
}

private func hits(_ samples: [Float]) -> [Int: Float] {
    Dictionary(uniqueKeysWithValues: samples.enumerated().filter { abs($0.element) > 0.01 }.map { ($0.offset, $0.element) })
}

@MainActor @Test func stemsStartOnTheSameSample() throws {
    let engine = try AudioEngine(offline: true)
    for strip in 0..<2 {
        try engine.addStem(url: makeStem(frames: 4800) { $0 == 100 ? 1 : 0 }, name: "s\(strip)", strip: strip)
        engine.setFaderGain(strip: strip, 1)
    }
    engine.setMasterGain(1)
    engine.loop = false
    try warmUp(engine)
    engine.play()
    let found = hits(try engine.renderOffline(frames: 9600))
    #expect(found.keys.sorted() == [AudioEngine.offlineStartDelay + 100], "\(found)")
    #expect(abs((found.values.first ?? 0) - 2 * pathGain) < 0.001, "\(found)")
}

/// A 44.1 kHz stem next to a 48 kHz one: the engine converts on the fly, both stay in time and in tune
/// with each other (the converter spreads an impulse over a few samples and may shift it slightly).
@MainActor @Test func stemsOfDifferentSampleRatesStayAligned() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 9600) { $0 == 4800 ? 1 : 0 }, name: "48k", strip: 0)
    try engine.addStem(url: makeStem(frames: 8820, sampleRate: 44_100) { $0 == 4410 ? 1 : 0 }, name: "44k", strip: 1)
    for strip in 0..<2 { engine.setFaderGain(strip: strip, 1) }
    engine.setMasterGain(1)
    engine.loop = false
    try warmUp(engine)
    engine.play()
    let samples = try engine.renderOffline(frames: 12_000)
    let expected = AudioEngine.offlineStartDelay + 4800
    // The 48 kHz impulse lands exactly; the converted one must add its energy within a few samples of it.
    #expect(abs(samples[expected] - pathGain) < 0.3, "\(samples[expected])")
    let window = samples[(expected - 64)...(expected + 64)]
    let energy = window.reduce(0) { $0 + abs($1) }
    #expect(energy > 1.5 * pathGain && energy < 4 * pathGain, "energy \(energy)")
    let outside = samples[..<(expected - 64)] + samples[(expected + 65)...]
    #expect(outside.allSatisfy { abs($0) < 0.02 }, "stray signal outside the impulse window")
    #expect(abs(engine.duration - 0.2) < 0.001)
}

@MainActor @Test func loopKeepsStemsOfDifferentLengthsAligned() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 3000) { $0 == 100 ? 1 : 0 }, name: "short", strip: 0)
    try engine.addStem(url: makeStem(frames: 5000) { $0 == 100 ? 1 : 0 }, name: "long", strip: 1)
    for strip in 0..<2 { engine.setFaderGain(strip: strip, 1) }
    engine.setMasterGain(1)
    try warmUp(engine)
    engine.play()
    let found = hits(try engine.renderOffline(frames: 12_000))
    let first = AudioEngine.offlineStartDelay + 100
    #expect(found.keys.sorted() == [first, first + 5000, first + 10_000], "\(found)")
    #expect(found.values.allSatisfy { abs($0 - 2 * pathGain) < 0.001 }, "\(found)")
}

@MainActor @Test func seekStartsFromTheRequestedPosition() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 9600) { $0 == 4800 ? 1 : 0 }, name: "s", strip: 0)
    engine.setFaderGain(strip: 0, 1)
    engine.setMasterGain(1)
    engine.loop = false
    engine.seek(to: 0.05) // 2400 échantillons
    try warmUp(engine)
    engine.play()
    let found = hits(try engine.renderOffline(frames: 9600))
    #expect(found.keys.sorted() == [AudioEngine.offlineStartDelay + 2400], "\(found)")
}

@MainActor @Test func sendsArePostFaderAndThrowIsPreFader() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 48_000) { _ in 0.8 }, name: "dc", strip: 0)
    engine.setMasterGain(1)
    engine.setFaderGain(strip: 0, 0) // tranche coupée
    engine.setSendGain(.delay, strip: 0, 1)
    try warmUp(engine)
    engine.play()

    // Envoi post-fader : tranche coupée → rien ne part dans le bus.
    let muted = try engine.renderOffline(frames: 9600)
    #expect(abs(muted.last ?? 1) < 0.001)

    // Dub throw : pris avant le fader → le signal part dans le bus malgré la tranche coupée.
    engine.setThrow(strip: 0, true)
    let thrown = try engine.renderOffline(frames: 9600)
    #expect(abs((thrown.last ?? 0) - 0.8 * pathGain) < 0.005)

    // Tranche rouverte, throw relâché : direct + envoi à fond.
    engine.setThrow(strip: 0, false)
    engine.setFaderGain(strip: 0, 1)
    let open = try engine.renderOffline(frames: 9600)
    #expect(abs((open.last ?? 0) - 2 * 0.8 * pathGain) < 0.005)
}

@MainActor @Test func volumeChangesAreRampedWithoutJump() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 48_000) { _ in 0.8 }, name: "dc", strip: 0)
    engine.setFaderGain(strip: 0, 1)
    engine.setMasterGain(1)
    try warmUp(engine)
    engine.play()
    let samples = try engine.renderOffline(frames: 24_000) { block in
        if block == 20 { engine.setFaderGain(strip: 0, 0) }
    }
    let settled = Array(samples[5000...])
    let biggestStep = zip(settled, settled.dropFirst()).map { abs($1 - $0) }.max() ?? 1
    #expect(abs(samples[10_000] - 0.8 * pathGain) < 0.001)
    #expect(abs(samples.last ?? 1) < 0.001)
    #expect(biggestStep < 0.001) // un saut franc vaudrait 0,2
}

// MARK: - Enregistrement

@MainActor @Test func masterRecordingIsA24BitWavOfWhatWasPlayed() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 96_000) { _ in 0.8 }, name: "dc", strip: 0)
    engine.setFaderGain(strip: 0, 1)
    engine.setMasterGain(1)
    try warmUp(engine)
    engine.play()
    _ = try engine.renderOffline(frames: 9600) // lecture établie avant d'enregistrer

    let url = FileManager.default.temporaryDirectory.appending(path: "dsm-rec-\(UUID().uuidString).wav")
    try engine.startRecording(to: url)
    #expect(engine.recorder.isRecording)
    _ = try engine.renderOffline(frames: 48_000)
    #expect(engine.stopRecording() == url)
    #expect(!engine.recorder.isRecording)
    _ = try engine.renderOffline(frames: 4800) // plus rien n'est écrit après l'arrêt

    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24)
    #expect(file.fileFormat.channelCount == 2 && file.fileFormat.sampleRate == 48_000)
    #expect(abs(Double(file.length) - 48_000) <= 1024, "\(file.length) frames")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let recorded = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    #expect(recorded.allSatisfy { abs($0 - 0.8 * pathGain) < 0.001 })
}

@MainActor @Test func preFaderSendIgnoresTheFaderAndDoesNotStackWithTheThrow() throws {
    let engine = try AudioEngine(offline: true)
    try engine.addStem(url: makeStem(frames: 96_000) { _ in 0.8 }, name: "dc", strip: 0)
    engine.setMasterGain(1)
    engine.setFaderGain(strip: 0, 0) // strip cut
    engine.setSendGain(.reverb, strip: 0, 1)
    engine.setSendGain(.delay, strip: 0, 1)
    try warmUp(engine)
    engine.play()
    _ = try engine.renderOffline(frames: 9600)

    // Pre-fader reverb send: the bus gets the signal even though the strip is cut.
    engine.setSendPreFader(.reverb, true)
    let pre = try engine.renderOffline(frames: 9600)
    #expect(abs((pre.last ?? 0) - 0.8 * pathGain) < 0.005)

    // Back to post-fader: nothing leaves the cut strip anymore.
    engine.setSendPreFader(.reverb, false)
    let post = try engine.renderOffline(frames: 9600)
    #expect(abs(post.last ?? 1) < 0.001)

    // Pre-fader delay send at full + dub throw: a single take, not twice the level.
    engine.setSendPreFader(.delay, true)
    engine.setThrow(strip: 0, true)
    let thrown = try engine.renderOffline(frames: 9600)
    #expect(abs((thrown.last ?? 0) - 0.8 * pathGain) < 0.005)

    // A stem added on a pre-fader bus picks up the strip's send level right away.
    try engine.addStem(url: makeStem(frames: 96_000) { _ in 0.8 }, name: "dc2", strip: 1)
    engine.setFaderGain(strip: 1, 0)
    engine.setSendGain(.delay, strip: 1, 1)
    engine.setThrow(strip: 0, false)
    _ = try engine.renderOffline(frames: 9600)
    let two = try engine.renderOffline(frames: 9600)
    #expect(abs((two.last ?? 0) - 2 * 0.8 * pathGain) < 0.01)
}
