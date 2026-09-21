import AppKit
import CoreAudioKit
import DubStemMixCore

/// Auto-contrôle sans son : charge chaque plugin AU tiers installé sur un bus du moteur (hors ligne)
/// et rapporte ce qui marche — processus séparé, paramètres, état, fenêtre.
@MainActor
enum PluginCheck {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared // la fenêtre d'un plugin hors processus exige une application initialisée
        NSApp.setActivationPolicy(.accessory)
        var finished = false
        Task {
            await check()
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        exit(0)
    }

    private static func check() async {
        let plugins = PluginInfo.installed()
        print("\(plugins.count) effets AU installés, dont \(plugins.filter { $0.manufacturer != "Apple" }.count) hors Apple\n")
        guard let engine = try? AudioEngine(offline: true, effects: true) else { return print("moteur indisponible") }
        for info in plugins where info.manufacturer != "Apple" {
            print("• \(info.manufacturer) — \(info.name)  [\(info.id)]")
            do {
                let plugin = try await engine.loadPlugin(info, on: .reverb)
                let parameters = plugin.parameters
                print("    chargé \(plugin.isOutOfProcess ? "dans un processus séparé" : "dans l'app (in-process)") · stéréo 48 kHz accepté")
                print("    \(parameters.count) paramètres : " + parameters.prefix(6).map(\.name).joined(separator: ", ") + (parameters.count > 6 ? "…" : ""))
                print("    état sauvegardable : \(plugin.state.map { "\($0.count) octets" } ?? "non")")
                let hasWindow = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    plugin.unit.auAudioUnit.requestViewController { continuation.resume(returning: $0 != nil) }
                }
                print("    fenêtre propre : \(hasWindow ? "oui" : "non")")
                _ = try? engine.renderOffline(frames: 4800)
                engine.unloadPlugin(on: .reverb)
            } catch {
                print("    ❌ \(error.localizedDescription)")
            }
        }
    }
}
