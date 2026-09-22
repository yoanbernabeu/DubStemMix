import AudioToolbox
import Synchronization

/// Audio thread load: time spent rendering one buffer relative to that buffer's duration
/// (1.0 = no headroom left), plus the number of dropouts reported by the audio device.
/// Fed from the real-time thread: atomics only, no allocation, no lock.
public final class RenderLoad: Sendable {
    private let started = Atomic<UInt64>(0)
    private let peakBits = Atomic<UInt32>(0)
    private let sampleRateBits = Atomic<UInt64>(48_000.0.bitPattern)
    private let overloads = Atomic<Int>(0)
    /// Nanoseconds per `mach_absolute_time` tick.
    private let nanosecondsPerTick: Double

    init() {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        nanosecondsPerTick = Double(info.numer) / Double(info.denom)
    }

    func setSampleRate(_ rate: Double) { sampleRateBits.store(rate.bitPattern, ordering: .relaxed) }

    func begin() { started.store(mach_absolute_time(), ordering: .relaxed) }

    func end(frames: UInt32) {
        let elapsed = Double(mach_absolute_time() &- started.load(ordering: .relaxed)) * nanosecondsPerTick
        let budget = Double(frames) / Double(bitPattern: sampleRateBits.load(ordering: .relaxed)) * 1e9
        let load = Float(elapsed / budget)
        // Positive floats compare like their bit patterns: lock-free atomic max.
        var current = peakBits.load(ordering: .relaxed)
        while current < load.bitPattern {
            let (exchanged, original) = peakBits.compareExchange(expected: current, desired: load.bitPattern, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    func reportOverload() { overloads.wrappingAdd(1, ordering: .relaxed) }

    /// Worst load since the last read (then reset).
    public func takePeak() -> Float { Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)) }

    /// Dropouts since launch.
    public var overloadCount: Int { overloads.load(ordering: .relaxed) }

    // MARK: Hooking the engine's output unit (Audio Unit v2 API: C callback, no capture)

    /// Render notification of the output unit: PreRender fires right before the whole graph is pulled,
    /// PostRender right after, so the difference is the render time of one full buffer.
    private static let renderNotify: AURenderCallback = { refCon, flags, _, _, frames, _ in
        let load = Unmanaged<RenderLoad>.fromOpaque(refCon).takeUnretainedValue()
        if flags.pointee.contains(.unitRenderAction_PreRender) {
            load.begin()
        } else if flags.pointee.contains(.unitRenderAction_PostRender) {
            load.end(frames: frames)
        }
        return noErr
    }

    func attach(to unit: AudioUnit) {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        AudioUnitRemoveRenderNotify(unit, Self.renderNotify, refCon) // never twice on the same unit
        AudioUnitAddRenderNotify(unit, Self.renderNotify, refCon)
    }

    func detach(from unit: AudioUnit) {
        AudioUnitRemoveRenderNotify(unit, Self.renderNotify, Unmanaged.passUnretained(self).toOpaque())
    }
}
