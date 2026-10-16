import AVFoundation
import DubDSP

/// The instruments of strips 5 and 6 (PRD § 15): an empty strip 5 plays a dub siren, an empty strip 6 a Syndrum.
/// A stem dropped on the strip makes it a stem strip again; taking off its last stem brings the instrument back.
/// The instrument goes through the strip like a stem would: insert, fader, sends.
public enum Instrument: Int, CaseIterable, Sendable {
    case siren, syndrum

    public static let strips = 4..<6

    public init?(strip: Int) {
        guard Self.strips.contains(strip) else { return nil }
        self.init(rawValue: strip - Self.strips.lowerBound)
    }

    public var strip: Int { Self.strips.lowerBound + rawValue }

    public var title: String { self == .siren ? "SIREN" : "SYNDRUM" }

    /// Knobs on the MIX page, top to bottom.
    public var knobs: [FXParameter] { FXParameter.instrumentLayout[rawValue] }

    /// Send levels to the delay, reverb and bus 3 (indexed like `SendBus`).
    public var sends: [FXParameter] { FXParameter.instrumentSends[rawValue] }

    var kind: BuiltInEffect.Kind { self == .siren ? .siren : .syndrum }
    var dspKind: DubEffectKind { self == .siren ? DUB_EFFECT_SIREN : DUB_EFFECT_SYNDRUM }
}

/// An instrument's kernel played by a source node, summed into its strip with the stems: an effect node with
/// nothing playing upstream would never be pulled by the engine.
@MainActor
final class InstrumentVoice {
    let node: AVAudioSourceNode
    private nonisolated(unsafe) let kernel: OpaquePointer

    init(_ instrument: Instrument, format: AVAudioFormat) {
        guard let kernel = dub_effect_create(instrument.dspKind) else { fatalError("No memory for the \(instrument)") }
        dub_effect_prepare(kernel, format.sampleRate)
        self.kernel = kernel
        node = AVAudioSourceNode(format: format, renderBlock: Self.render(kernel))
    }

    deinit { dub_effect_destroy(kernel) }

    func set(_ parameter: Int, _ value: Float) {
        dub_effect_set(kernel, Int32(parameter), value)
    }

    /// Built outside the main actor: the block runs on the audio thread. Silence in, the instrument out.
    private nonisolated static func render(_ kernel: OpaquePointer) -> AVAudioSourceNodeRenderBlock {
        nonisolated(unsafe) let kernel = kernel
        return { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            dub_effect_process(kernel, left, right, left, right, Int32(frames))
            return noErr
        }
    }
}

/// What the buttons of an instrument strip play (PRD § 15). The LED stays lit while held.
public enum InstrumentGesture: Sendable, CaseIterable {
    /// Siren: MUTE held sounds it, REC ARM held makes it rise.
    case siren, rise
    /// Syndrum: MUTE hits once per press, REC ARM held rolls on the tempo.
    case hit, roll

    public var instrument: Instrument { self == .siren || self == .rise ? .siren : .syndrum }

    /// On the MUTE button (otherwise REC ARM).
    public var onMute: Bool { self == .siren || self == .hit }

    public static func on(_ instrument: Instrument, mute: Bool) -> InstrumentGesture {
        switch instrument {
        case .siren: mute ? .siren : .rise
        case .syndrum: mute ? .hit : .roll
        }
    }

    public var label: String {
        switch self {
        case .siren: "HOLD"
        case .rise: "RISE"
        case .hit: "HIT"
        case .roll: "ROLL"
        }
    }

    /// The kernel parameter it drives.
    var kernelParameter: Int {
        switch self {
        case .siren: Int(DUB_SIREN_GATE)
        case .rise: Int(DUB_SIREN_RISE)
        case .hit: Int(DUB_SYNDRUM_HIT)
        case .roll: Int(DUB_SYNDRUM_ROLLING)
        }
    }
}
