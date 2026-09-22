import AVFoundation
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

        // A third-party plugin (out of process) on a bus: the device switch must not lose it.
        var plugin: HostedPlugin?
        if let info = PluginInfo.installed().first(where: { $0.manufacturer != "Apple" }) {
            var done = false
            Task {
                plugin = try? await engine.loadPlugin(info, on: .reverb)
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(plugin != nil, "plugin \(info.name) loaded on the reverb bus" + (plugin?.isOutOfProcess == true ? " (out of process)" : ""))
        }

        // Hot switch to another device (if any), then back.
        if let other = devices.first(where: { $0.id != engine.outputDeviceID }), let current = device {
            do {
                try engine.setOutputDevice(other)
                check(engine.outputDeviceID == other.id, "switched to \(other.name)")
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                check(engine.load.takePeak() > 0, "render load still measured after the switch")
                if let plugin {
                    check(engine.plugins[.reverb] === plugin && plugin.isAlive, "plugin still on its bus and answering after the switch")
                }
                try engine.setOutputDevice(current)
                check(engine.outputDeviceID == current.id, "back to \(current.name)")
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                if let plugin { check(plugin.isAlive, "plugin still answering after switching back") }
            } catch {
                check(false, "device switch: \(error.localizedDescription)")
            }
        }
        // Pull-up: a short stem, brake, restart from the top.
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: "dsm-pullup-\(UUID().uuidString).wav")
            // Written in its own scope: the file is only complete once its AVAudioFile is released.
            try {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 4)!
                buffer.frameLength = buffer.frameCapacity
                for n in 0..<Int(buffer.frameLength) {
                    let v = Float(0.2 * sin(2 * Double.pi * 220 * Double(n) / 48_000))
                    buffer.floatChannelData![0][n] = v
                    buffer.floatChannelData![1][n] = v
                }
                try file.write(from: buffer)
            }()
            defer { try? FileManager.default.removeItem(at: url) }
            try engine.addStem(url: url, name: "tone", strip: 0)
            engine.setFaderGain(strip: 0, 1)
            engine.setMasterGain(0.2)
            engine.play()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            let before = engine.position
            engine.pullUp()
            check(engine.isPullingUp, "pull-up started at \(String(format: "%.2f", before)) s")
            var ticks = 0
            while engine.isPullingUp, ticks < 200 {
                engine.tick()
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30))
                ticks += 1
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            check(!engine.isPullingUp && engine.isPlaying && engine.position < 1, "restarted from the top after \(ticks) ticks (position \(String(format: "%.2f", engine.position)) s)")
            check(engine.load.overloadCount == 0, "no dropout during the pull-up")
            engine.stop()
        } catch {
            check(false, "pull-up: \(error.localizedDescription)")
        }
        print(failures == 0 ? "\nAll good." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
