import AppKit
import DubStemMixCore

/// Strip inserts (PRD § 11.5): a built-in insert or an Audio Unit in each strip, between the stem sum and
/// the fader. Same mechanics as the bus slots: out-of-process loading, macros remembered per plugin,
/// state saved in the project, a missing plugin kept in the project and reported.
extension AppModel {
    static func insertKey(_ strip: Int) -> String { "\(strip)" }
    private static func windowKey(_ strip: Int) -> String { "insert-\(strip)" }

    // MARK: Built-in insert, or none

    func setInsert(strip: Int, _ kind: InsertKind?) {
        pluginWindows.close(Self.windowKey(strip))
        unresolvedInserts[Self.insertKey(strip)] = nil
        insertStates[strip] = nil
        engine.setInsert(strip: strip, kind)
        mix.setInsert(strip: strip, kind)
    }

    /// Auto-wah "down" mode and other screen-only parameters live after the three knobs.
    func setInsertValue(strip: Int, index: Int, _ value: Double) {
        mix.setInsertValue(strip: strip, index: index, value)
    }

    // MARK: Plugin insert

    func loadInsertPlugin(_ info: PluginInfo, strip: Int, saved entry: Project.InsertEntry? = nil) {
        guard !loadingInsert.contains(strip) else { return }
        loadingInsert.insert(strip)
        pluginWindows.close(Self.windowKey(strip))
        Task {
            defer { loadingInsert.remove(strip) }
            do {
                let plugin = try await engine.loadInsertPlugin(info, strip: strip, state: entry?.state)
                unresolvedInserts[Self.insertKey(strip)] = nil
                mix.setInsertHosted(strip: strip, true)
                let available = Set(plugin.parameters.map(\.address))
                let macros = entry?.macros ?? Self.rememberedInsertMacros(for: info)
                for (index, target) in macros.prefix(AudioEngine.insertMacroCount).enumerated() {
                    if let target, available.contains(target.address) { engine.setInsertMacroTarget(target, strip: strip, index: index) }
                }
                insertStates[strip] = plugin.state
                errorMessage = nil
            } catch {
                errorMessage = "Can't load \(info.name): \(error.localizedDescription)"
            }
        }
    }

    /// The same plugin on the same strip in the song coming: it stays plugged in, only its settings change,
    /// so the graph is not rewired and the tails go on.
    private func reuseInsertPlugin(strip: Int, saved entry: Project.InsertEntry) {
        guard let plugin = engine.insertPlugins[strip] else { return }
        if let state = entry.state { plugin.restore(state) }
        unresolvedInserts[Self.insertKey(strip)] = nil
        let available = Set(plugin.parameters.map(\.address))
        let macros = entry.macros ?? Self.rememberedInsertMacros(for: plugin.info)
        for index in 0..<AudioEngine.insertMacroCount {
            let target = macros.indices.contains(index) ? macros[index] : nil
            engine.setInsertMacroTarget(target.flatMap { available.contains($0.address) ? $0 : nil }, strip: strip, index: index)
        }
        insertStates[strip] = plugin.state
    }

    /// Strips whose plugin insert is the same in this project: kept plugged in when it opens.
    func sharedInsertPlugins(with project: Project) -> Set<Int> {
        Set((0..<AudioEngine.stripCount).filter { strip in
            guard let loaded = engine.insertPlugins[strip]?.info.id else { return false }
            return project.inserts?[Self.insertKey(strip)]?.plugin?.id == loaded
        })
    }

    func openInsertWindow(strip: Int) {
        guard let plugin = engine.insertPlugins[strip] else { return }
        pluginWindows.open(plugin, key: Self.windowKey(strip))
    }

    func insertMacroTarget(strip: Int, index: Int) -> PluginParameter? {
        engine.insertMacroTargets[strip]?[index]
    }

    /// Remembered per plugin, like the bus macros, and offered again in every song.
    func assignInsertMacro(_ parameter: PluginParameter?, strip: Int, index: Int) {
        guard let plugin = engine.insertPlugins[strip] else { return }
        engine.setInsertMacroTarget(parameter, strip: strip, index: index)
        if let targets = engine.insertMacroTargets[strip], let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: Self.insertMacrosKey(plugin.info))
        }
    }

    func insertMacroDisplay(strip: Int, index: Int) -> String {
        guard let target = insertMacroTarget(strip: strip, index: index), let plugin = engine.insertPlugins[strip] else { return "" }
        return plugin.displayValue(target.address)
    }

    private static func insertMacrosKey(_ info: PluginInfo) -> String { "insertmacros." + info.id }

    private static func rememberedInsertMacros(for info: PluginInfo) -> [PluginParameter?] {
        guard let data = UserDefaults.standard.data(forKey: insertMacrosKey(info)),
              let macros = try? JSONDecoder().decode([PluginParameter?].self, from: data)
        else { return [] }
        return macros
    }

    /// Called with `followPlugins`: macros follow the plugin's window, states are refreshed for saving.
    func followInsertPlugins(refreshStates: Bool) {
        for (strip, plugin) in engine.insertPlugins {
            for (index, target) in (engine.insertMacroTargets[strip] ?? []).enumerated() {
                if let target, let value = plugin.normalizedValue(target.address) { mix.syncInsertMacro(strip: strip, index: index, value) }
            }
            if refreshStates { insertStates[strip] = plugin.state }
        }
    }

    /// A plugin insert whose process died: the strip goes straight through, the slot stays in the project.
    func checkInsertLiveness() {
        for (strip, plugin) in engine.insertPlugins where !plugin.isAlive {
            let entry = Project.InsertEntry(plugin: plugin.info, state: insertStates[strip], macros: engine.insertMacroTargets[strip] ?? [])
            setInsert(strip: strip, nil)
            unresolvedInserts[Self.insertKey(strip)] = entry
            errorMessage = "\(plugin.info.name) crashed on strip \(strip + 1) — insert bypassed (pick it again to reload)"
        }
    }

    // MARK: Project

    func currentInserts() -> [String: Project.InsertEntry] {
        var inserts = unresolvedInserts
        for strip in 0..<AudioEngine.stripCount {
            if let plugin = engine.insertPlugins[strip] {
                inserts[Self.insertKey(strip)] = Project.InsertEntry(plugin: plugin.info, state: insertStates[strip], macros: engine.insertMacroTargets[strip] ?? [])
            } else if let kind = mix.strips[strip].insert {
                inserts[Self.insertKey(strip)] = Project.InsertEntry(kind: kind.rawValue, values: mix.strips[strip].insertValues)
            }
        }
        return inserts
    }

    /// At project opening. Built-in inserts come back at once; plugins load in the background, and a
    /// plugin missing from this Mac stays in the project.
    /// - Returns: the names of the missing plugins.
    @discardableResult
    func restoreInserts() -> [String] {
        var missing: [String] = []
        for strip in 0..<AudioEngine.stripCount {
            guard let entry = unresolvedInserts[Self.insertKey(strip)] else { continue }
            if let plugin = entry.plugin {
                if engine.insertPlugins[strip]?.info.id == plugin.id {
                    reuseInsertPlugin(strip: strip, saved: entry)
                } else if installedPlugins.contains(where: { $0.id == plugin.id }) {
                    loadInsertPlugin(plugin, strip: strip, saved: entry)
                } else {
                    missing.append(plugin.name)
                }
            } else if let kind = entry.kind.flatMap(InsertKind.init) {
                setInsert(strip: strip, kind)
                for (index, value) in (entry.values ?? []).enumerated() { mix.setInsertValue(strip: strip, index: index, value) }
            } else {
                unresolvedInserts[Self.insertKey(strip)] = nil
            }
        }
        return missing
    }

    // MARK: Bus 3 model

    func setBus3Model(_ model: Bus3Model) {
        bus3Model = model
        engine.setBus3Model(model)
    }
}
