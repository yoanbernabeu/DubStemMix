import AVFoundation
import DubDSP

/// Un effet intégré : un noyau DSP en C (cible DubDSP) enveloppé dans une Audio Unit interne à l'app,
/// pour s'insérer dans AVAudioEngine exactement comme le fera un plugin AU tiers (jalon M4).
@MainActor
public final class BuiltInEffect {
    public enum Kind: CaseIterable, Sendable {
        case delay, plate, phaser, master, spring

        var dspKind: DubEffectKind {
            switch self {
            case .delay: DUB_EFFECT_DELAY
            case .plate: DUB_EFFECT_PLATE
            case .phaser: DUB_EFFECT_PHASER
            case .master: DUB_EFFECT_MASTER
            case .spring: DUB_EFFECT_SPRING
            }
        }

        var description: AudioComponentDescription {
            let subType: String = switch self {
            case .delay: "ddly"
            case .plate: "dplt"
            case .phaser: "dphs"
            case .master: "dmst"
            case .spring: "dspr"
            }
            return AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: subType.utf8.reduce(0) { ($0 << 8) | OSType($1) },
                componentManufacturer: "DbSM".utf8.reduce(0) { ($0 << 8) | OSType($1) },
                componentFlags: 0, componentFlagsMask: 0
            )
        }
    }

    public let kind: Kind
    public let node: AVAudioUnitEffect
    private let unit: DubEffectAudioUnit

    private static let registered: Void = {
        for kind in Kind.allCases {
            AUAudioUnit.registerSubclass(DubEffectAudioUnit.self, as: kind.description, name: "DubStemMix: \(kind)", version: 1)
        }
    }()

    public init(_ kind: Kind) {
        _ = Self.registered
        self.kind = kind
        node = AVAudioUnitEffect(audioComponentDescription: kind.description)
        guard let unit = node.auAudioUnit as? DubEffectAudioUnit else {
            fatalError("L'Audio Unit interne \(kind) n'a pas pu être instanciée")
        }
        self.unit = unit
    }

    /// Paramètre du noyau (constantes DUB_* de DubDSP), en unités réelles. Lissé par le noyau.
    public func set(_ parameter: Int, _ value: Float) {
        dub_effect_set(unit.kernel, Int32(parameter), value)
    }
}

/// L'Audio Unit elle-même. Le bloc de rendu ne capture que des pointeurs : ni allocation, ni verrou,
/// ni objet Swift sur le thread audio.
final class DubEffectAudioUnit: AUAudioUnit, @unchecked Sendable {
    nonisolated(unsafe) let kernel: OpaquePointer
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private let scratch: UnsafeMutablePointer<Float>
    private static let maxFrames = 4096

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let kind = BuiltInEffect.Kind.allCases.first { $0.description.componentSubType == componentDescription.componentSubType } ?? .delay
        guard let kernel = dub_effect_create(kind.dspKind) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization)) }
        self.kernel = kernel
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        scratch = .allocate(capacity: Self.maxFrames * 2)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = AUAudioFrameCount(Self.maxFrames)
    }

    deinit {
        dub_effect_destroy(kernel)
        scratch.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        dub_effect_prepare(kernel, outputBus.format.sampleRate)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = kernel
        let scratch = scratch
        let maxFrames = Self.maxFrames
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard frames <= maxFrames, output.count == 2 else { return kAudioUnitErr_TooManyFramesToProcess }

            // L'hôte peut fournir des tampons de sortie vides : on lui prête alors les nôtres.
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            for channel in 0..<2 where output[channel].mData == nil {
                output[channel].mData = UnsafeMutableRawPointer(scratch + channel * maxFrames)
            }
            for channel in 0..<2 { output[channel].mDataByteSize = byteSize }

            // L'entrée est tirée directement dans les tampons de sortie, puis traitée en place.
            var flags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            guard let left = output[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = output[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            dub_effect_process(kernel, left, right, left, right, Int32(frames))
            return noErr
        }
    }
}
