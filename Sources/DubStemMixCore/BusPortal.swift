import AVFoundation
import DubDSP

/// Bus-to-bus sends through memory (dub_portal.c): each bus return writes itself there on its way to the master,
/// each bus input reads what the others send it. The buses are never wired to one another, so patching them is a
/// gain change, while playing, without a cut, and any loop-free patch is possible.
final class BusPortal: @unchecked Sendable {
    let pointer: OpaquePointer

    init() {
        guard let pointer = dub_portal_create() else { fatalError("Bus portal: out of memory") }
        self.pointer = pointer
    }

    deinit { dub_portal_destroy(pointer) }

    func setGain(from source: SendBus, to target: SendBus, _ gain: Float) {
        dub_portal_set_gain(pointer, Int32(source.rawValue), Int32(target.rawValue), gain)
    }

    /// Pass-through unit on a bus return: what comes out of the bus's effect goes on unchanged, and into the portal.
    @MainActor
    func sender(for source: SendBus) -> AVAudioUnitEffect {
        _ = Self.registered
        let node = AVAudioUnitEffect(audioComponentDescription: Self.senderDescription)
        guard let unit = node.auAudioUnit as? PortalSendAudioUnit else { fatalError("Bus portal: sender unit not available") }
        unit.connect(self, source: source)
        return node
    }

    /// Source node on a bus input: what the other buses send to `target`.
    func receiver(for target: SendBus, format: AVAudioFormat) -> AVAudioSourceNode {
        let portal = self // held by the node: the portal outlives the audio thread's use of it
        let bus = Int32(target.rawValue)
        return AVAudioSourceNode(format: format) { _, timestamp, frameCount, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            dub_portal_read(portal.pointer, bus, timestamp.pointee.mSampleTime, left, right, Int32(frameCount))
            return noErr
        }
    }

    private static let senderDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: "dpsd".utf8.reduce(0) { ($0 << 8) | OSType($1) },
        componentManufacturer: "DbSM".utf8.reduce(0) { ($0 << 8) | OSType($1) },
        componentFlags: 0, componentFlagsMask: 0
    )

    private static let registered: Void = {
        AUAudioUnit.registerSubclass(PortalSendAudioUnit.self, as: senderDescription, name: "DubStemMix: bus send", version: 1)
    }()
}

/// The sender's Audio Unit. Its render block only touches a fixed C-side context: no Swift object on the audio thread.
final class PortalSendAudioUnit: AUAudioUnit, @unchecked Sendable {
    private struct Context {
        var portal: OpaquePointer?
        var source: Int32 = 0
    }

    private let context = UnsafeMutablePointer<Context>.allocate(capacity: 1)
    private var portal: BusPortal? // keeps the portal alive as long as the unit
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private let scratch: UnsafeMutablePointer<Float>
    private static let maxFrames = 4096

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        context.initialize(to: Context())
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
        context.deallocate()
        scratch.deallocate()
    }

    /// Before the unit renders (it is attached right after).
    func connect(_ portal: BusPortal, source: SendBus) {
        self.portal = portal
        context.pointee = Context(portal: portal.pointer, source: Int32(source.rawValue))
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        let context = context
        let scratch = scratch
        let maxFrames = Self.maxFrames
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard frames <= maxFrames, output.count == 2 else { return kAudioUnitErr_TooManyFramesToProcess }
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            for channel in 0..<2 where output[channel].mData == nil {
                output[channel].mData = UnsafeMutableRawPointer(scratch + channel * maxFrames)
            }
            for channel in 0..<2 { output[channel].mDataByteSize = byteSize }
            var flags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            guard let left = output[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = output[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            if let portal = context.pointee.portal {
                dub_portal_write(portal, context.pointee.source, timestamp.pointee.mSampleTime, left, right, Int32(frames))
            }
            return noErr
        }
    }
}
