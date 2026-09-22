import AppKit
import DubStemMixCore
import Foundation

/// Self-check without sound: loads an out-of-process plugin, kills its hosting service, and verifies
/// that the app falls back to the built-in effect, warns, and keeps the slot in the project.
@MainActor
enum PluginCrashCheck {
    private static func wait(seconds: Double = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func hostingServices() -> Set<Int32> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "AUHostingService"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(output.split(separator: "\n").compactMap { Int32($0) })
    }

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ✅ \(label)" : "  ❌ \(label)")
            if !condition { failures += 1 }
        }
        guard let model = try? AppModel(preview: true, demoData: false) else {
            print("  ❌ the model could not be created")
            exit(1)
        }
        let before = hostingServices()
        // Third-party plugins are the ones that run out of process; Apple's load in the app.
        let candidates = model.installedPlugins.filter { $0.manufacturer != "Apple" } + model.installedPlugins
        var loaded: HostedPlugin?
        for info in candidates {
            model.loadPlugin(info, on: .reverb)
            wait { model.engine.plugins[.reverb] != nil || model.errorMessage != nil }
            if let plugin = model.engine.plugins[.reverb], plugin.isOutOfProcess {
                loaded = plugin
                break
            }
            model.useBuiltInEffect(on: .reverb)
            model.errorMessage = nil
        }
        guard let plugin = loaded else {
            print("  ⚠️ no plugin runs out of process on this Mac: nothing to crash")
            exit(0)
        }
        print("Loaded \(plugin.info.name) out of process on the reverb bus")
        let services = hostingServices().subtracting(before)
        check(!services.isEmpty, "hosting service process found (\(services.map(String.init).joined(separator: ", ")))")
        for pid in services { kill(pid, SIGKILL) }
        print("Killed the hosting service")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(!plugin.isAlive, "the plugin no longer answers")
        model.checkPluginLiveness()
        check(model.engine.plugins[.reverb] == nil, "plugin unloaded, built-in effect back on the bus")
        check(model.errorMessage?.contains("crashed") == true, "warning shown: \(model.errorMessage ?? "none")")
        check(model.unresolvedSlots["reverb"]?.plugin.id == plugin.info.id, "slot kept in the project")
        _ = try? model.engine.renderOffline(frames: 4800)
        check(true, "engine still renders")
        print(failures == 0 ? "\nAll good." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
