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

            model.mix.toggleMute(strip: 2)
            model.mix.toggleSolo(strip: 3)
            model.newSession()
            check(model.engine.stems.isEmpty && model.pool.isEmpty && model.projectURL == nil, "nouvelle session vide")
            check(model.mix.strips.allSatisfy { !$0.mute && !$0.solo }, "nouvelle session : ni mute ni solo")
            check(model.busRouting == .standard && model.engine.busRouting == .standard, "nouvelle session : bus isolés")
            check(FXParameter.allCases.allSatisfy { model.mix.fx[$0] == $0.defaultValue }, "nouvelle session : effets aux réglages d'usine")
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

                    print("Même plugin d'insert dans le morceau suivant")
                    let sibling = moved.appending(path: "sibling.dubstem")
                    model.mix.setInsertMacro(strip: 2, index: 1, 0.7)
                    model.followInsertPlugins(refreshStates: true)
                    try model.currentProject(for: sibling).save(to: sibling)
                    let kept = model.engine.insertPlugins[2]
                    model.openProject(movedDocument)
                    check(model.engine.insertPlugins[2] === kept, "même plugin sur la même tranche : il reste branché")
                    let switched = model.engine.insertPlugins[2]?.normalizedValue(parameter.address) ?? -1
                    check(abs(switched - 0.4) < 0.02, "même plugin : les réglages du morceau ouvert sont appliqués")
                    check(model.insertMacroTarget(strip: 2, index: 1) == parameter, "même plugin : la macro reste affectée")
                    model.openProject(sibling)
                    let back = model.engine.insertPlugins[2]?.normalizedValue(parameter.address) ?? -1
                    check(model.engine.insertPlugins[2] === kept && abs(back - 0.7) < 0.02, "et dans l'autre sens")
                    try FileManager.default.removeItem(at: sibling)
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
            if let other = model.setlistEntries.first(where: { $0.url?.standardizedFileURL != model.projectURL?.standardizedFileURL }),
               let otherURL = other.url, let openURL = model.projectURL {
                model.renameSetlistEntry(other, to: " dub version ")
                check((try? Project.load(from: otherURL))?.title == "DUB VERSION"
                      && model.setlistEntries.contains { $0.title == "DUB VERSION" }, "morceau de la setlist renommé dans son fichier")
                model.renameSong("riddim")
                model.autosaveCountdown = 0
                model.autosaveIfNeeded()
                check((try? Project.load(from: openURL))?.title == "RIDDIM", "morceau ouvert renommé et enregistré")
                model.openProject(otherURL)
                model.openProject(openURL)
                check(model.title == "RIDDIM", "le titre saisi revient à la réouverture")
            }

            print("Usage live : rack de setlist")
            check(model.setlist?.rack != nil, "la setlist a pris le rack du morceau ouvert")
            let songURL = model.projectURL!
            model.pickBuiltInEffect(on: .reverb, reverb: .spring) // à l'arrêt, sur le premier morceau
            model.autosaveCountdown = 0
            model.autosaveIfNeeded()
            check((try? Setlist.load(from: setlistFile))?.rack?.reverbModel == "spring", "un changement du rack est enregistré dans la setlist")
            var own = try Project.load(from: second)
            own.rack = Rack(busSends: [:]) // le second morceau a été préparé avec la plate, sans renvoi
            try own.save(to: second)
            model.refreshSetlistEntries()
            let secondIndex = model.setlistEntries.firstIndex { $0.url?.lastPathComponent == "second.dubstem" }!
            check(model.setlistEntries[secondIndex].ownRack, "marque ≠ RACK sur le morceau préparé avec un autre rack")
            model.openSetlistEntry(at: secondIndex)
            check(model.reverbModel == .spring && model.engine.reverbModel == .spring, "morceau suivant joué avec le rack de la setlist")
            model.autosaveCountdown = 0
            model.autosaveIfNeeded()
            check((try? Project.load(from: second))?.rack == Rack(busSends: [:]), "le morceau garde son propre rack dans son fichier")

            print("Usage live : armement et protections pendant la lecture")
            let songIndex = model.setlistEntries.firstIndex { $0.url?.standardizedFileURL == songURL.standardizedFileURL }!
            model.openSetlistEntry(at: songIndex)
            model.togglePlay()
            check(model.engine.isPlaying, "lecture lancée")
            model.openNextInSetlist(offset: secondIndex > songIndex ? 1 : -1)
            check(model.armedIndex == secondIndex && model.projectURL == songURL, "N / P en lecture : morceau armé, rien de chargé")
            model.openSetlistEntry(at: songIndex)
            check(model.armedIndex == nil && model.projectURL == songURL, "clic sur le morceau en cours : désarmé")
            model.openSetlistEntry(at: secondIndex)
            model.togglePlay()
            check(model.projectURL?.lastPathComponent == "second.dubstem" && model.engine.isPlaying && model.armedIndex == nil,
                  "Espace : le morceau armé part tout de suite")
            let stemsBefore = model.engine.stems.count
            model.placeStems([files[2]], onStrip: 7)
            check(model.engine.stems.count == stemsBefore && model.notice?.hasPrefix("Stop playback") == true, "en lecture : poser un stem est refusé")
            let routing = model.busRouting
            let wanted: SendBus? = routing.target(of: .bus3) == nil && routing.allows(.bus3, to: .delay) ? .delay : nil
            model.pickBusSend(from: .bus3, to: wanted)
            check(model.busRouting.target(of: .bus3) == wanted && model.engine.isPlaying, "en lecture : re-patcher les bus est permis, la lecture continue")
            model.pickBuiltInEffect(on: .reverb, reverb: .plate)
            check(model.reverbModel == .plate && model.engine.reverbModel == .plate, "en lecture : plate ↔ ressort permis")
            model.pickInsert(strip: 0, .sub)
            check(model.mix.strips[0].insert == .sub && model.engine.inserts[0] == .sub, "en lecture : insert intégré permis")
            model.seekFromWaveform(fraction: 0.5, deliberate: false)
            check(model.engine.position < 0.25, "en lecture : un simple clic sur la forme d'onde ne déplace pas")
            model.seekFromWaveform(fraction: 0.5, deliberate: true)
            check(abs(model.engine.position - model.engine.duration / 2) < 0.25, "en lecture : double-clic ou ⌥-clic déplace")
            model.togglePlay()
            check(!model.engine.isPlaying, "Espace sans morceau armé : pause")

            print("Usage live : vérification de la setlist")
            // Plus haut, un stem du premier morceau a été rangé dans « elsewhere » : il manque encore.
            check(model.setlistHasMissingStems && model.setlistEntries.contains { $0.problems.contains { $0.contains("not found") } },
                  "stem introuvable : signalé sur la ligne avant d'ouvrir le morceau")
            model.relinkMissingStems(in: work)
            check(!model.setlistHasMissingStems, "stems retrouvés pour toute la setlist dans un dossier et ses sous-dossiers")
            check((try? Project.load(from: movedDocument))?.stems.allSatisfy { $0.file.resolve(relativeTo: movedDocument) != nil } == true,
                  "le morceau est enregistré avec le fichier retrouvé")

            print("Setlist : Save As")
            let copyFolder = moved.appending(path: "copies")
            try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
            let copyFile = copyFolder.appending(path: "Short Set.dubset")
            let songsBefore = model.setlistEntries.compactMap(\.url)
            model.move(setlistTo: copyFile)
            model.saveSetlist()
            let copy = try? Setlist.load(from: copyFile)
            check(model.setlistURL == copyFile && copy?.name == "SHORT SET", "copie enregistrée, nommée d'après son fichier, devenue la setlist ouverte")
            check(copy?.projects.map { $0.resolve(relativeTo: copyFile) } == songsBefore && copy?.projects.first?.relativePath.hasPrefix("../") == true,
                  "copie : les morceaux sont retrouvés depuis son nouvel emplacement")
            check(copy?.rack != nil && (try? Setlist.load(from: setlistFile))?.name == "FRIDAY", "copie : rack gardé, l'originale n'a pas bougé")

            print("Setlist : projets glissés depuis le Finder")
            let third = moved.appending(path: "third.dubstem")
            try FileManager.default.copyItem(at: second, to: third)
            let openBefore = model.projectURL
            model.addToSetlist([third, second, moved.appending(path: "bass.wav")])
            let saved = try? Setlist.load(from: copyFile)
            check(model.setlistEntries.count == 3 && model.setlistEntries.last?.url?.lastPathComponent == "third.dubstem",
                  "ajouté à la fin, une seule fois (déjà présent et non-projet ignorés)")
            check(saved?.projects.count == 3 && model.projectURL == openBefore, "setlist enregistrée, morceau ouvert inchangé")

            print("Setlist : export pour un autre Mac")
            let exportFolder = work.appending(path: "export/SHORT SET")
            model.export(model.setlist!, at: copyFile, to: exportFolder)
            wait { model.exportTask == nil }
            let exportedSet = exportFolder.appending(path: "Short Set.dubset")
            if case let .done(_, songs, missing, _) = model.setlistExport {
                check(songs == 3 && missing.isEmpty, "3 morceaux exportés, rien d'introuvable")
            } else {
                check(false, "export terminé")
            }
            let exportedSongs = (try? Setlist.load(from: exportedSet))?.projects.compactMap { $0.resolve(relativeTo: exportedSet) } ?? []
            check(exportedSongs.count == 3 && exportedSongs.allSatisfy { $0.path.hasPrefix(exportFolder.path) },
                  "la setlist exportée pointe sur les morceaux copiés")
            model.open([exportedSet])
            model.openSetlistEntry(at: 0)
            check(model.projectURL?.path.hasPrefix(exportFolder.path) == true && model.unresolvedStems.isEmpty
                  && model.engine.stems.allSatisfy { $0.url.path.hasPrefix(exportFolder.path) }, "morceau exporté ouvert avec ses propres stems")
            model.export(model.setlist!, at: exportedSet, to: exportFolder)
            wait { model.exportTask == nil }
            check(model.setlistExport == .failed("\"SHORT SET\" already exists, choose another name"), "jamais d'export par-dessus un dossier existant")
        } catch {
            print("  ❌ erreur inattendue : \(error)")
            failures += 1
        }
        print(failures == 0 ? "\nTout est bon." : "\n\(failures) contrôle(s) en échec.")
        exit(failures == 0 ? 0 : 1)
    }
}
