import CoreAudio
import Foundation

/// An audio device (sound card or built-in output) that can play.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    /// Stable across launches (the CoreAudio `id` is not).
    public let uid: String
    public let name: String
}

/// CoreAudio (HAL) access to audio devices: listing, buffer size, sample rate, dropouts.
public enum AudioDevices {
    public static let bufferChoices = [64, 128, 256, 512, 1024]

    // MARK: Property access

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type) -> T? {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func readString(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        read(selector, of: object, as: Unmanaged<CFString>?.self)?.map { $0.takeRetainedValue() as String }
    }

    private static func readArray<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }

    @discardableResult
    private static func write<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, _ value: T) -> Bool {
        var address = address(selector)
        return withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer) == noErr
        }
    }

    // MARK: Devices

    public static func info(for id: AudioDeviceID) -> AudioDeviceInfo? {
        guard id != kAudioObjectUnknown, let uid = readString(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
        return AudioDeviceInfo(id: id, uid: uid, name: readString(kAudioObjectPropertyName, of: id) ?? uid)
    }

    /// Every available output, in system order.
    public static func outputDevices() -> [AudioDeviceInfo] {
        readArray(kAudioHardwarePropertyDevices, of: AudioObjectID(kAudioObjectSystemObject), as: AudioDeviceID.self)
            .filter { hasOutput($0) }
            .compactMap(info(for:))
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    public static func defaultOutputDevice() -> AudioDeviceInfo? {
        read(kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject), as: AudioDeviceID.self)
            .flatMap(info(for:))
    }

    public static func device(uid: String) -> AudioDeviceInfo? {
        outputDevices().first { $0.uid == uid }
    }

    // MARK: Buffer size and sample rate

    public static func sampleRate(of id: AudioDeviceID) -> Double? {
        read(kAudioDevicePropertyNominalSampleRate, of: id, as: Float64.self)
    }

    /// The device's buffer size in frames. It belongs to the device and is shared by every app using it.
    public static func bufferFrames(of id: AudioDeviceID) -> Int? {
        read(kAudioDevicePropertyBufferFrameSize, of: id, as: UInt32.self).map(Int.init)
    }

    public static func bufferFrameRange(of id: AudioDeviceID) -> ClosedRange<Int>? {
        read(kAudioDevicePropertyBufferFrameSizeRange, of: id, as: AudioValueRange.self).map { Int($0.mMinimum)...Int($0.mMaximum) }
    }

    /// - Returns: the size actually applied (the device may round it), or nil if it refused.
    @discardableResult
    public static func setBufferFrames(_ frames: Int, of id: AudioDeviceID) -> Int? {
        guard write(kAudioDevicePropertyBufferFrameSize, of: id, UInt32(frames)) else { return nil }
        return bufferFrames(of: id)
    }

    // MARK: Dropouts

    /// Listens for a device's "processor overload" events. Keep the token for as long as you want to listen.
    public final class OverloadListener {
        private let device: AudioDeviceID
        private let block: AudioObjectPropertyListenerBlock
        private var address = AudioDevices.address(kAudioDeviceProcessorOverload)

        fileprivate init(device: AudioDeviceID, block: @escaping AudioObjectPropertyListenerBlock) {
            self.device = device
            self.block = block
            AudioObjectAddPropertyListenerBlock(device, &address, nil, block)
        }

        deinit { AudioObjectRemovePropertyListenerBlock(device, &address, nil, block) }
    }

    public static func listenForOverloads(on id: AudioDeviceID, _ onOverload: @escaping @Sendable () -> Void) -> OverloadListener {
        OverloadListener(device: id) { _, _ in onOverload() }
    }
}
