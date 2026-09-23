import AVFoundation
import AppKit
import DubStemMixCore
import Foundation

/// Auto-contrôle sans interface ni son : déroule le cycle projet + setlist sur trois petits stems générés
/// dans un dossier temporaire.
@MainActor
enum DocumentsCheck {
    /// Une seconde de sinus, en WAV.
    private static func writeStem(_ url: URL, frequency: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for n in 0..<48_000 { buffer.floatChannelData![channel][n] = Float(0.3 * sin(2 * Double.pi * frequency * Double(n) / 48_000)) }
        }
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
    }

    /// Laisse tourner la boucle principale (les plugins se chargent en tâche de fond) jusqu'à la condition, 5 s max.
    private static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ✅ \(label)" : "  ❌ \(label)")
            if !condition { failures += 1 }
        }
        do {
            let work = FileManager.default.temporaryDirectory.appending(path: "dsm-check-\(UUID().uuidString)")
            let stemsCopy = work.appending(path: "song/stems")
            try FileManager.default.createDirectory(at: stemsCopy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            for (name, frequency) in [("Song (Bass)", 55.0), ("Song (Drums)", 110.0), ("Song (Full mix)", 220.0)] {
                try writeStem(stemsCopy.appending(path: "\(name).wav"), frequency: frequency)
            }
            let files = StemImporter.audioFiles(in: [stemsCopy])

            print("Projet")
            let model = try AppModel(preview: true, demoData: false)
            model.addToPool([stemsCopy])
            check(model.pool.count == 3 && model.engine.stems.isEmpty, "import : 3 fichiers dans la réserve, rien d'affecté automatiquement")
            model.assign([files[0]], toStrip: 4)
            model.assign([files[1]], toStrip: 4)
            model.renameStrip(4, " riddim ")
            check(model.mix.strips[4].name == "RIDDIM", "tranche renommée à la main")
            model.toggleKeep(strip: 4)
            model.mix.setFX(.killBass, 0.25)
            model.setReverbModel(.spring)
            model.setThrowTarget(.both)
            model.setBus3Model(.flanger)
            model.setBusSend(from: .delay, to: .bus3)
            model.setBusSend(from: .reverb, to: .delay)
            check(model.engine.busRouting.target(of: .reverb) == .delay, "renvoi de la reverb vers le delay")
            model.setInsert(strip: 4, .sub)
            model.setInsertValue(strip: 4, index: 0, 0.9)
            check(model.engine.inserts[4] == .sub && model.mix.strips[4].insert == .sub, "insert intégré posé sur la tranche 5")
            model.mix.setFX(.delayFeedback, 0.83)
            model.toggleLoop()
            model.mix.setTempo(72.5)
            model.mix.setDelaySync(true)
            let document = work.appending(path: "song/song.dubstem")
            model.projectURL = document
            model.saveProject()
            check(FileManager.default.fileExists(atPath: document.path) && !model.hasUnsavedChanges, "enregistrement du projet")

            model.newSession()
            check(model.engine.stems.isEmpty && model.pool.isEmpty && model.projectURL == nil, "nouvelle session vide")
            model.openProject(document)
            check(model.engine.stems.map(\.strip) == [4, 4], "réouverture : les 2 stems reviennent sur la tranche 5")
            check(model.pool.map(\.url.lastPathComponent) == [files[2].lastPathComponent], "réouverture : le 3e fichier revient dans la réserve")
            check(model.mix.fx[.delayFeedback] == 0.83 && model.looping == false, "réouverture : réglages d'effets et boucle restaurés")
            check(model.mix.bpm == 72.5 && model.mix.delaySync, "réouverture : tempo et calage du delay restaurés")
            check(model.mix.strips[4].name == "RIDDIM", "réouverture : nom de tranche restauré")
            check(model.mix.strips[4].keep && !model.mix.strips[3].keep, "réouverture : marque KEEP restaurée")
            check(model.mix.fx[.killBass] == 0.25, "réouverture : réglage de la chaîne master restauré")
            check(model.reverbModel == .spring && model.engine.reverbModel == .spring, "réouverture : reverb à ressort restaurée")
            check(model.throwTarget == .both && model.engine.throwTarget == .both, "réouverture : cible du throw restaurée")
            check(model.bus3Model == .flanger && model.engine.bus3Model == .flanger, "réouverture : flanger sur le bus 3 restauré")
            check(model.busRouting.target(of: .delay) == .bus3 && model.engine.busRouting.target(of: .reverb) == .delay,
                  "réouverture : renvois de bus à bus restaurés")
            check(model.engine.inserts[4] == .sub && model.mix.strips[4].insertValues.first == 0.9, "réouverture : insert intégré et réglage restaurés")
            model.renameStrip(4, "")
            check(model.mix.strips[4].name == "BASS", "nom vidé : retour au nom du fichier")
            model.renameStrip(4, "riddim")
            check(!model.engine.isPlaying && model.engine.position == 0, "morceau chargé à l'arrêt, au début")
            check(!model.hasUnsavedChanges, "aucun changement en attente juste après l'ouverture")

            print("Dossier déplacé, puis stem manquant")
            let moved = work.appending(path: "moved")
            try FileManager.default.moveItem(at: work.appending(path: "song"), to: moved)
            let movedDocument = moved.appending(path: "song.dubstem")
            model.projectURL = nil
            model.openProject(movedDocument)
            check(model.engine.stems.count == 2 && model.unresolvedStems.isEmpty, "dossier entier déplacé : stems retrouvés par chemin relatif")

            let hidden = work.appending(path: "elsewhere")
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            let lost = moved.appending(path: "stems/\(files[0].lastPathComponent)")
            model.projectURL = nil
            model.clear()
            try FileManager.default.moveItem(at: lost, to: hidden.appending(path: lost.lastPathComponent))
            model.openProject(movedDocument)
            check(model.engine.stems.count == 1 && model.unresolvedStems.count == 1, "stem introuvable : signalé, les autres sont chargés")
            for _ in 0..<40 { model.autosaveIfNeeded() }
            check((try? Project.load(from: movedDocument))?.stems.count == 2, "la sauvegarde automatique ne fait pas disparaître le stem manquant du projet")

            print("Plugin Audio Unit dans un projet")
            if let appleDelay = model.installedPlugins.first(where: { $0.id == "aufx-dely-appl" }) {
                let memoryKey = "macros." + appleDelay.id
                UserDefaults.standard.removeObject(forKey: memoryKey)
                model.loadPlugin(appleDelay, on: .delay)
                wait { model.engine.plugins[.delay] != nil }
                check(model.engine.plugins[.delay] != nil && model.mix.hostedBuses == [.delay], "plugin chargé sur le bus delay")
                check(model.macroTarget(bus: .delay, index: 0) == nil, "première fois : aucune macro affectée")
                if let parameter = model.engine.plugins[.delay]?.parameters.first {
                    model.assignMacro(parameter, bus: .delay, index: 0)
                    model.mix.setMacro(bus: .delay, index: 0, 0.3)
                    model.refreshPluginStates()
                    model.saveProject()
                    model.newSession()
                    check(model.engine.plugins.isEmpty && model.mix.hostedBuses.isEmpty, "nouvelle session : retour aux effets intégrés")
                    model.openProject(movedDocument)
                    wait { model.engine.plugins[.delay] != nil }
                    check(model.engine.plugins[.delay]?.info.id == appleDelay.id, "réouverture : le plugin revient sur son bus")
                    check(model.macroTarget(bus: .delay, index: 0) == parameter, "réouverture : la macro est toujours affectée")
                    let restored = model.engine.plugins[.delay]?.normalizedValue(parameter.address) ?? -1
                    check(abs(restored - 0.3) < 0.02, "réouverture : l'état du plugin est restauré")

                    model.useBuiltInEffect(on: .delay)
                    model.loadPlugin(appleDelay, on: .reverb) // autre bus, autre morceau : les macros sont mémorisées par plugin
                    wait { model.engine.plugins[.reverb] != nil }
                    check(model.macroTarget(bus: .reverb, index: 0) == parameter, "macros mémorisées par plugin et reproposées")
                    model.useBuiltInEffect(on: .reverb)

                    print("Plugin Audio Unit en insert de tranche")
                    UserDefaults.standard.removeObject(forKey: "insertmacros." + appleDelay.id)
                    model.loadInsertPlugin(appleDelay, strip: 2)
                    wait { model.engine.insertPlugins[2] != nil }
                    check(model.engine.insertPlugins[2] != nil && model.mix.strips[2].insertHosted, "plugin chargé en insert de la tranche 3")
                    model.assignInsertMacro(parameter, strip: 2, index: 1)
                    model.mix.setInsertMacro(strip: 2, index: 1, 0.4)
                    model.followInsertPlugins(refreshStates: true)
                    model.saveProject()
                    model.newSession()
                    check(model.engine.insertPlugins.isEmpty && !model.mix.strips[2].insertHosted, "nouvelle session : plus d'insert")
                    model.openProject(movedDocument)
                    wait { model.engine.insertPlugins[2] != nil }
                    check(model.engine.insertPlugins[2]?.info.id == appleDelay.id, "réouverture : le plugin revient en insert")
                    check(model.insertMacroTarget(strip: 2, index: 1) == parameter, "réouverture : la macro d'insert est toujours affectée")
                    let restoredInsert = model.engine.insertPlugins[2]?.normalizedValue(parameter.address) ?? -1
                    check(abs(restoredInsert - 0.4) < 0.02, "réouverture : l'état du plugin d'insert est restauré")
                    model.setInsert(strip: 2, nil)
                    UserDefaults.standard.removeObject(forKey: "insertmacros." + appleDelay.id)
                }
                UserDefaults.standard.removeObject(forKey: memoryKey)

                var withGhost = try Project.load(from: movedDocument)
                let ghost = PluginInfo(name: "Ghost Verb", manufacturer: "Nobody", type: appleDelay.type, subType: 0x67686F73, manufacturerCode: 0x6E6F6E65)
                withGhost.slots = ["reverb": .init(plugin: ghost, state: nil, macros: [])]
                try withGhost.save(to: movedDocument)
                model.openProject(movedDocument)
                check(model.engine.plugins.isEmpty && model.errorMessage?.contains("Ghost Verb") == true, "plugin absent : effet intégré + avertissement")
                for _ in 0..<40 { model.autosaveIfNeeded() }
                check((try? Project.load(from: movedDocument))?.slots?["reverb"]?.plugin.name == "Ghost Verb", "plugin absent : il reste inscrit dans le projet")
                model.useBuiltInEffect(on: .reverb)
            }

            print("Setlist")
            let second = moved.appending(path: "second.dubstem")
            try FileManager.default.copyItem(at: movedDocument, to: second)
            let setlistFile = moved.appending(path: "set.dubset")
            var setlist = Setlist(name: "CHECK")
            setlist.projects = [movedDocument, second].map { FileReference($0, relativeTo: setlistFile) }
            try setlist.save(to: setlistFile)
            model.open([setlistFile])
            check(model.setlistEntries.count == 2 && model.setlistIndex == 0, "setlist ouverte, morceau courant repéré")
            model.openNextInSetlist()
            check(model.projectURL?.lastPathComponent == "second.dubstem" && model.setlistIndex == 1, "N : morceau suivant chargé")
            model.openNextInSetlist()
            check(model.setlistIndex == 1, "N sur le dernier morceau : on reste dessus")
            model.openNextInSetlist(offset: -1)
            check(model.setlistIndex == 0, "P : morceau précédent")
            model.moveInSetlist(model.setlistEntries[0], onto: model.setlistEntries[1])
            check(model.setlistEntries.map(\.title) == ["second", "song"] || model.setlistIndex == 1, "glisser-déposer : morceau courant passé en 2e position")
            model.renameSetlist(" friday ")
            check((try? Setlist.load(from: setlistFile))?.name == "FRIDAY", "setlist renommée et enregistrée")
        } catch {
            print("  ❌ erreur inattendue : \(error)")
            failures += 1
        }
        print(failures == 0 ? "\nTout est bon." : "\n\(failures) contrôle(s) en échec.")
        exit(failures == 0 ? 0 : 1)
    }
}
