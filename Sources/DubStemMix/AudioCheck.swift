import DubStemMixCore
import Foundation

/// Self-check on the real-time engine, without UI: lists output devices, reports the one in use with its
/// sample rate and buffer size, then lets the engine run for a second to read the render load and dropouts.
@MainActor
enum AudioCheck {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ✅ \(label)" : "  ❌ \(label)")
            if !condition { failures += 1 }
        }
        let devices = AudioDevices.outputDevices()
        print("Output devices")
        for device in devices { print("  • \(device.name)  [\(device.uid)]") }
        check(!devices.isEmpty, "at least one output device")

        guard let engine = try? AudioEngine() else {
            print("  ❌ the engine could not start")
            exit(1)
        }
        let device = engine.outputDevice
        print("\nEngine")
        print("  device: \(device?.name ?? "none") · \(Int(engine.outputSampleRate)) Hz · buffer \(engine.bufferFrames.map(String.init) ?? "?")")
        check(device != nil, "engine bound to a device")
        if let range = AudioDevices.bufferFrameRange(of: engine.outputDeviceID) {
            print("  buffer range: \(range.lowerBound)…\(range.upperBound)")
        }

        // Buffer size round trip: set, read back, restore.
        if let before = engine.bufferFrames {
            let target = before == 256 ? 512 : 256
            let applied = engine.setBufferFrames(target)
            check(applied == target, "buffer size set to \(target) (device reports \(applied.map(String.init) ?? "refused"))")
            engine.setBufferFrames(before)
        }

        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let load = engine.load.takePeak()
        print("  render load over 1 s: \(Int((load * 100).rounded()))% · dropouts: \(engine.load.overloadCount)")
        check(load > 0, "render load is measured (the render notify fired)")
        check(load < 0.5, "idle graph stays far from overload")

        // Hot switch to another device (if any), then back.
        if let other = devices.first(where: { $0.id != engine.outputDeviceID }), let current = device {
            do {
                try engine.setOutputDevice(other)
                check(engine.outputDeviceID == other.id, "switched to \(other.name)")
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                check(engine.load.takePeak() > 0, "render load still measured after the switch")
                try engine.setOutputDevice(current)
                check(engine.outputDeviceID == current.id, "back to \(current.name)")
            } catch {
                check(false, "device switch: \(error.localizedDescription)")
            }
        }
        print(failures == 0 ? "\nAll good." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
