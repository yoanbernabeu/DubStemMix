import AppKit
import CoreAudioKit
import DubStemMixCore

extension AppModel {
    // MARK: Charger / retirer un plugin sur un bus

    func loadPlugin(_ info: PluginInfo, on bus: SendBus, saved entry: Project.SlotEntry? = nil) {
        guard !loadingPlugin.contains(bus) else { return }
        loadingPlugin.insert(bus)
        pluginWindows.close(bus.key)
        Task {
            defer { loadingPlugin.remove(bus) }
            do {
                let plugin = try await engine.loadPlugin(info, on: bus, state: entry?.state)
                unresolvedSlots[bus.key] = nil
                mix.setHosted(bus, true)
                // Macros : celles du projet, sinon celles mémorisées pour ce plugin.
                let available = Set(plugin.parameters.map(\.address))
                let macros = entry?.macros ?? Self.rememberedMacros(for: info)
                for (index, target) in macros.prefix(AudioEngine.macroCount).enumerated() {
                    if let target, available.contains(target.address) { engine.setMacroTarget(target, bus: bus, index: index) }
                }
                pluginStates[bus] = plugin.state
                errorMessage = nil
            } catch {
                errorMessage = "Can't load \(info.name): \(error.localizedDescription)"
            }
        }
    }

    /// Retour à l'effet intégré.
    func unloadPlugin(on bus: SendBus) {
        guard engine.plugins[bus] != nil else { return }
        pluginWindows.close(bus.key)
        engine.unloadPlugin(on: bus)
        mix.setHosted(bus, false)
        pluginStates[bus] = nil
    }

    // MARK: Plugin crash (out-of-process extension gone)

    /// The system tells us when the connection to an extension process (AUv3) is lost. Plugins bridged out of
    /// process (v2) get no such notification: `checkPluginLiveness` polls them instead.
    func watchPluginCrashes() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(kAudioComponentInstanceInvalidationNotification as String), object: nil, queue: .main
        ) { [weak self] note in
            // Identities only cross into the main actor: the objects themselves stay where they are.
            let unit = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let pointer = ((note.userInfo?["audioUnit"] as? NSValue)?.pointerValue).map { UInt(bitPattern: $0) }
            MainActor.assumeIsolated { self?.pluginInvalidated(auAudioUnit: unit, audioUnit: pointer) }
        }
    }

    private func pluginInvalidated(auAudioUnit: ObjectIdentifier?, audioUnit: UInt?) {
        for (bus, plugin) in engine.plugins {
            let sameObject = auAudioUnit == ObjectIdentifier(plugin.unit.auAudioUnit)
            let samePointer = audioUnit != nil && audioUnit == UInt(bitPattern: plugin.unit.audioUnit)
            if sameObject || samePointer { pluginCrashed(on: bus) }
        }
    }

    /// Once a second: a plugin whose process died no longer answers.
    func checkPluginLiveness() {
        for (bus, plugin) in engine.plugins where !plugin.isAlive { pluginCrashed(on: bus) }
        checkInsertLiveness()
    }

    /// Back to the built-in effect, with a warning. The slot stays in the project (state and macros as last
    /// known) so the song is not silently changed; picking the plugin again in the slot menu reloads it.
    private func pluginCrashed(on bus: SendBus) {
        guard let plugin = engine.plugins[bus] else { return }
        let entry = Project.SlotEntry(plugin: plugin.info, state: pluginStates[bus], macros: engine.macroTargets[bus] ?? [])
        unloadPlugin(on: bus)
        unresolvedSlots[bus.key] = entry
        errorMessage = "\(plugin.info.name) crashed — built-in effect used instead (pick it again in the slot menu to reload)"
    }

    func useBuiltInEffect(on bus: SendBus) {
        unresolvedSlots[bus.key] = nil
        unloadPlugin(on: bus)
    }

    func openPluginWindow(on bus: SendBus) {
        guard let plugin = engine.plugins[bus] else { return }
        pluginWindows.open(plugin, key: bus.key)
    }

    // MARK: Potards macros

    func macroTarget(bus: SendBus, index: Int) -> PluginParameter? {
        engine.macroTargets[bus]?[index]
    }

    /// Affectation faite par l'utilisateur : mémorisée pour ce plugin, et reproposée dans tous les morceaux.
    func assignMacro(_ parameter: PluginParameter?, bus: SendBus, index: Int) {
        guard let plugin = engine.plugins[bus] else { return }
        engine.setMacroTarget(parameter, bus: bus, index: index)
        if let targets = engine.macroTargets[bus], let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: Self.macrosKey(plugin.info))
        }
    }

    func macroDisplay(bus: SendBus, index: Int) -> String {
        guard let target = macroTarget(bus: bus, index: index), let plugin = engine.plugins[bus] else { return "" }
        return plugin.displayValue(target.address)
    }

    private static func macrosKey(_ info: PluginInfo) -> String { "macros." + info.id }

    private static func rememberedMacros(for info: PluginInfo) -> [PluginParameter?] {
        guard let data = UserDefaults.standard.data(forKey: macrosKey(info)),
              let macros = try? JSONDecoder().decode([PluginParameter?].self, from: data)
        else { return [] }
        return macros
    }

    /// Appelé 30 fois par seconde : les potards macros suivent ce qui change dans la fenêtre du plugin,
    /// et l'état des plugins est relevé de temps en temps pour la sauvegarde automatique.
    func followPlugins() {
        for (bus, plugin) in engine.plugins {
            for (index, target) in (engine.macroTargets[bus] ?? []).enumerated() {
                if let target, let value = plugin.normalizedValue(target.address) { mix.syncMacro(bus: bus, index: index, value) }
            }
        }
        pluginStateCountdown -= 1
        if pluginStateCountdown % 30 == 0 { checkPluginLiveness() }
        followInsertPlugins(refreshStates: pluginStateCountdown <= 0)
        if pluginStateCountdown <= 0 {
            pluginStateCountdown = 150 // toutes les 5 s : demander son état complet à un plugin n'est pas gratuit
            refreshPluginStates()
        }
    }

    func refreshPluginStates() {
        for (bus, plugin) in engine.plugins { pluginStates[bus] = plugin.state }
    }

    // MARK: Projet

    func currentSlots() -> [String: Project.SlotEntry] {
        var slots = unresolvedSlots
        for (bus, plugin) in engine.plugins {
            slots[bus.key] = Project.SlotEntry(plugin: plugin.info, state: pluginStates[bus], macros: engine.macroTargets[bus] ?? [])
        }
        return slots
    }

    /// À l'ouverture d'un projet. Plugin absent de ce Mac : l'effet intégré reste en place, le slot reste
    /// inscrit dans le projet, et on prévient.
    /// - Returns: les noms des plugins du projet qui ne sont pas installés sur ce Mac.
    @discardableResult
    func restoreSlots() -> [String] {
        var missing: [String] = []
        for bus in SendBus.allCases {
            guard let entry = unresolvedSlots[bus.key] else { continue }
            if installedPlugins.contains(where: { $0.id == entry.plugin.id }) {
                loadPlugin(entry.plugin, on: bus, saved: entry)
            } else {
                missing.append(entry.plugin.name)
            }
        }
        return missing
    }
}

/// Plugin windows: the plugin's own interface, or Apple's generic parameter view when it has none.
/// Keyed by bus key (send slots) or "insert-N" (strip inserts).
@MainActor
final class PluginWindows {
    private var windows: [String: NSWindow] = [:]

    func open(_ plugin: HostedPlugin, key: String) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        plugin.unit.auAudioUnit.requestViewController { controller in
            // The plugin may answer on any thread: the window is created on the main thread.
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let window = controller.map(NSWindow.init(contentViewController:))
                    ?? Self.genericWindow(for: plugin)
                window.title = plugin.info.name + (controller == nil ? " (generic view)" : "")
                window.styleMask = [.titled, .closable, .miniaturizable]
                window.isReleasedWhenClosed = false
                self.windows[key] = window
                window.makeKeyAndOrderFront(nil)
            } }
        }
    }

    /// Apple's generic view lists every parameter as a slider; scrolls when the plugin has many.
    static func genericView(for plugin: HostedPlugin) -> AUGenericView {
        let view = AUGenericView(audioUnit: plugin.unit.audioUnit)
        view.showsExpertParameters = true
        return view
    }

    private static func genericWindow(for plugin: HostedPlugin) -> NSWindow {
        let view = genericView(for: plugin)
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let size = NSSize(width: max(360, view.frame.width), height: min(640, max(120, view.frame.height)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.center()
        return window
    }

    func close(_ key: String) {
        windows[key]?.close()
        windows[key] = nil
    }
}
