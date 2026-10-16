import DubDSP
import Foundation
import Testing
@testable import DubStemMixCore

// Siren and Syndrum on empty strips 5 and 6 (PRD § 15).

/// Runs a kernel on `input` (mono, doubled to stereo), in blocks of 512 like the engine; `before` runs before each block.
private func play(_ kernel: OpaquePointer, _ input: [Float], before: (Int) -> Void = { _ in }) -> [Float] {
    var left = input, right = input
    var offset = 0, block = 0
    while offset < input.count {
        before(block)
        let frames = min(512, input.count - offset)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                dub_effect_process(kernel, l.baseAddress! + offset, r.baseAddress! + offset,
                                   l.baseAddress! + offset, r.baseAddress! + offset, Int32(frames))
            }
        }
        offset += frames
        block += 1
    }
    return left
}

private func noise(_ count: Int) -> [Float] {
    var seed: UInt32 = 1
    return (0..<count).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / 16_777_216 - 0.5
    }
}

private func energy(_ samples: ArraySlice<Float>) -> Float { samples.reduce(0) { $0 + $1 * $1 } }

/// Rising zero crossings per second: the fundamental of a plain tone.
private func pitch(_ samples: ArraySlice<Float>, rate: Double = 48_000) -> Double {
    var crossings = 0
    var previous = samples.first ?? 0
    for sample in samples.dropFirst() {
        if previous <= 0, sample > 0 { crossings += 1 }
        previous = sample
    }
    return Double(crossings) * rate / Double(samples.count)
}

@Test func sirenIsAnExactPassthroughUntilPlayedAndAfterItDies() {
    let siren = dub_effect_create(DUB_EFFECT_SIREN)!
    defer { dub_effect_destroy(siren) }
    dub_effect_prepare(siren, 48_000)
    let input = noise(72_000)
    #expect(play(siren, input) == input)

    // Played for a quarter second, then let go: the siren is heard, then the strip is exact again.
    let output = play(siren, input) { block in
        dub_effect_set(siren, Int32(DUB_SIREN_GATE), block < 24 ? 1 : 0)
    }
    #expect(energy(zip(output, input).map { $0 - $1 }[0..<12_000]) > 10)
    #expect(Array(output[48_000...]) == Array(input[48_000...]))
}

@Test func sirenRiseClimbsTwoOctaves() {
    func tone(rising: Bool) -> Double {
        let siren = dub_effect_create(DUB_EFFECT_SIREN)!
        defer { dub_effect_destroy(siren) }
        dub_effect_set(siren, Int32(DUB_SIREN_PITCH), 300)
        dub_effect_set(siren, Int32(DUB_SIREN_RATE), 0.05) // a sweep slow enough to read a pitch
        dub_effect_set(siren, Int32(DUB_SIREN_WAVE), 1) // triangle: plain zero crossings
        dub_effect_set(siren, Int32(DUB_SIREN_GATE), 1)
        dub_effect_set(siren, Int32(DUB_SIREN_RISE), rising ? 1 : 0)
        dub_effect_prepare(siren, 48_000)
        let output = play(siren, [Float](repeating: 0, count: 120_000))
        return pitch(output[110_000...])
    }
    let low = tone(rising: false), high = tone(rising: true)
    #expect((212...260).contains(low), "low in the sweep: \(low) Hz") // starts at the bottom, 300 Hz × 2^−0.5
    #expect((3.6...4.1).contains(high / low), "rise: ×\(high / low)")
}

@Test func syndrumHitDiesAwayFallingInPitch() {
    let drum = dub_effect_create(DUB_EFFECT_SYNDRUM)!
    defer { dub_effect_destroy(drum) }
    dub_effect_set(drum, Int32(DUB_SYNDRUM_PITCH), 600)
    dub_effect_set(drum, Int32(DUB_SYNDRUM_DECAY), 0.5)
    dub_effect_prepare(drum, 48_000)
    let input = noise(48_000)
    #expect(play(drum, input) == input)

    dub_effect_set(drum, Int32(DUB_SYNDRUM_HIT), 1)
    let output = play(drum, [Float](repeating: 0, count: 48_000))
    #expect(dub_effect_get(drum, Int32(DUB_SYNDRUM_HIT)) == 0) // the hit was taken
    let early = output[480..<4800], late = output[9600..<14_400]
    #expect(energy(early) / Float(early.count) > 5 * energy(late) / Float(late.count))
    #expect(pitch(early) > 1.4 * pitch(late), "piou: \(pitch(early)) → \(pitch(late)) Hz")
    #expect(play(drum, input) == input) // silent again: exact
}

@Test func syndrumRollHitsAtItsInterval() {
    let drum = dub_effect_create(DUB_EFFECT_SYNDRUM)!
    defer { dub_effect_destroy(drum) }
    dub_effect_set(drum, Int32(DUB_SYNDRUM_DECAY), 0.02)
    dub_effect_set(drum, Int32(DUB_SYNDRUM_ROLL), 0.1)
    dub_effect_set(drum, Int32(DUB_SYNDRUM_ROLLING), 1)
    dub_effect_prepare(drum, 48_000)
    let output = play(drum, [Float](repeating: 0, count: 26_000))
    for hit in 0..<5 {
        let start = hit * 4800
        #expect(energy(output[start..<(start + 480)]) > 100 * energy(output[(start + 2400)..<(start + 2880)]), "hit \(hit)")
    }
}

// MARK: - Console

@MainActor @Test func emptyStripsFiveAndSixPlayTheirInstruments() {
    let engine = FakeEngine(), surface = FakeSurface()
    let mix = MixController(engine: engine, surface: surface)
    #expect(mix.instrument(strip: 4) == .siren && mix.instrument(strip: 5) == .syndrum && mix.instrument(strip: 3) == nil)

    mix.handle(.button(.mute, strip: 4, pressed: true))
    #expect(engine.instruments[.siren] == true && surface.muteLeds[4] && !mix.strips[4].mute)
    mix.handle(.button(.recArm, strip: 4, pressed: true))
    #expect(engine.instruments[.rise] == true && surface.recLeds[4] && engine.throwing[4] == false)
    mix.handle(.button(.recArm, strip: 4, pressed: false))
    mix.handle(.button(.mute, strip: 4, pressed: false))
    #expect(engine.instruments[.siren] == false && engine.instruments[.rise] == false && !surface.muteLeds[4])

    mix.handle(.button(.mute, strip: 5, pressed: true))
    #expect(engine.instruments[.hit] == true)
    mix.handle(.button(.recArm, strip: 5, pressed: true))
    #expect(engine.instruments[.roll] == true)

    // Knobs: the sound, then the delay send; they catch up first, like the effect strips'.
    mix.handle(.knob(strip: 4, row: 0, value: 0.9))
    #expect(mix.fx[.sirenPitch] == FXParameter.sirenPitch.defaultValue)
    mix.handle(.knob(strip: 4, row: 0, value: 0.5))
    mix.handle(.knob(strip: 4, row: 0, value: 0.7))
    #expect(mix.fx[.sirenPitch] == 0.7 && mix.strips[4].sends[0] == 0)
    mix.handle(.knob(strip: 4, row: 2, value: 0.5))
    mix.handle(.knob(strip: 4, row: 2, value: 0.8))
    #expect(mix.fx[.sirenDelay] == 0.8 && engine.sends[4][0] == MixController.sendGain(0.8))
    mix.setFX(.sirenReverb, 0.6) // with the mouse
    #expect(engine.sends[4][1] == MixController.sendGain(0.6))
}

@MainActor @Test func aStemDroppedOnTheStripTakesItBack() {
    let engine = FakeEngine(), surface = FakeSurface()
    let mix = MixController(engine: engine, surface: surface)
    mix.setSend(strip: 4, row: 1, 0.3)
    mix.setFX(.sirenReverb, 0.6)
    mix.handle(.button(.mute, strip: 4, pressed: true))

    mix.setStems(strip: 4, name: "HORNS", stems: [.init(id: UUID(), name: "horns.wav")])
    #expect(mix.instrument(strip: 4) == nil)
    #expect(engine.instruments[.siren] == false && !surface.muteLeds[4]) // the held siren let go
    #expect(engine.sends[4][1] == MixController.sendGain(0.3)) // the stem's own send, not the siren's
    mix.handle(.button(.mute, strip: 4, pressed: false))
    mix.handle(.button(.mute, strip: 4, pressed: true))
    #expect(mix.strips[4].mute && surface.muteLeds[4] && engine.instruments[.siren] == false)

    // Its last stem gone, the siren is back, unmuted.
    mix.setStems(strip: 4, name: "", stems: [])
    #expect(mix.instrument(strip: 4) == .siren && !mix.strips[4].mute && !surface.muteLeds[4])
    #expect(engine.sends[4][1] == MixController.sendGain(0.6) && engine.faders[4] > 0)
}

@MainActor @Test func instrumentsStayThroughDropAndStopOnPanic() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    mix.setStems(strip: 0, name: "DRUMS", stems: [.init(id: UUID(), name: "drums.wav")])
    mix.setDrop(true)
    #expect(engine.faders[0] == 0 && engine.faders[4] > 0 && engine.faders[5] > 0)

    mix.handle(.button(.mute, strip: 4, pressed: true))
    mix.handle(.button(.recArm, strip: 5, pressed: true))
    mix.releaseInstruments()
    #expect(engine.instruments[.siren] == false && engine.instruments[.roll] == false)
}

@MainActor @Test func syndrumRollFollowsTheTempo() {
    let engine = FakeEngine()
    let mix = MixController(engine: engine)
    #expect(engine.fx[.syndrumRoll] == Float(60.0 / 120 * 0.25)) // sixteenths, 120 BPM without a tempo
    mix.setTempo(100)
    #expect(engine.fx[.syndrumRoll] == Float(60.0 / 100 * 0.25))
    mix.setFX(.syndrumRoll, FXParameter.step(0, of: FXParameter.rollDivisions.count))
    #expect(engine.fx[.syndrumRoll] == Float(60.0 / 100 * 0.5))
}

// MARK: - Engine

@MainActor @Test func sirenSoundsThroughStripFiveAndItsDelay() throws {
    let engine = try AudioEngine(offline: true, effects: true)
    let mix = MixController(engine: engine)
    mix.setMaster(1)
    mix.setFader(strip: 4, 1)
    let silent = try engine.renderOffline(frames: 9600)
    #expect(silent.allSatisfy { $0 == 0 })
    mix.handle(.button(.mute, strip: 4, pressed: true))
    let blowing = try engine.renderOffline(frames: 9600)
    #expect(energy(blowing[4800...]) > 10)
    mix.handle(.button(.mute, strip: 4, pressed: false))
    mix.setFader(strip: 4, 0) // the dry siren gone: what is left comes back through the delay
    _ = try engine.renderOffline(frames: 4800)
    let echoes = try engine.renderOffline(frames: 48_000)
    #expect(energy(echoes[...]) > 1)
}
