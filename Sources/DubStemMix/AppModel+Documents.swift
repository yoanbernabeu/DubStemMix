import AppKit
import DubStemMixCore
import UniformTypeIdentifiers

/// Une ligne de la setlist, avec ce qu'il faut pour l'afficher sans charger le morceau.
struct SetlistEntry: Identifiable, Equatable {
    let id = UUID()
    var reference: FileReference
    var url: URL?
    var title: String
    var bpm: Double?
    var duration: Double

    static func == (a: SetlistEntry, b: SetlistEntry) -> Bool { a.id == b.id }
}

extension AppModel {
    // MARK: Ouverture (projet, setlist, stems : un seul point d'entrée pour le sélecteur et le glisser-déposer)

    func open(_ urls: [URL]) {
        if let setlistFile = urls.first(where: { $0.pathExtension == Setlist.fileExtension }) {
            openSetlist(setlistFile)
        } else if let projectFile = urls.first(where: { $0.pathExtension == Project.fileExtension }) {
            openProject(projectFile)
        } else {
            addToPool(urls)
        }
    }

    func chooseFilesToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Open a project, a setlist, a folder of stems or audio files"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    // MARK: Projet

    var hasUnsavedChanges: Bool {
        guard let projectURL else { return !engine.stems.isEmpty || !pool.isEmpty }
        return currentProject(for: projectURL) != savedProject
    }

    func currentProject(for document: URL) -> Project {
        var project = Project()
        project.title = title
        project.duration = engine.duration
        project.loop = looping
        project.bpm = mix.bpm
        project.delaySync = mix.delaySync
        project.stems = engine.stems.map { .init(file: FileReference($0.url, relativeTo: document), strip: $0.strip) } + unresolvedStems
        project.pool = pool.map { FileReference($0.url, relativeTo: document) }
        project.fx = Dictionary(uniqueKeysWithValues: mix.fx.map { ($0.key.rawValue, $0.value) })
        let slots = currentSlots()
        project.slots = slots.isEmpty ? nil : slots
        project.stripNames = stripNames.isEmpty ? nil : Dictionary(uniqueKeysWithValues: stripNames.map { ("\($0.key)", $0.value) })
        let kept = mix.strips.indices.filter { mix.strips[$0].keep }
        project.keep = kept.isEmpty ? nil : kept
        project.reverbModel = reverbModel == .plate ? nil : reverbModel.rawValue
        project.throwTarget = throwTarget == .delay ? nil : throwTarget.rawValue
        project.bus3Model = bus3Model == .phaser ? nil : bus3Model.rawValue
        let inserts = currentInserts()
        project.inserts = inserts.isEmpty ? nil : inserts
        return project
    }

    /// Enregistre dans le fichier du projet ; la première fois (ou pour « Save As »), demande où.
    func saveProject(askLocation: Bool = false) {
        var destination = askLocation ? nil : projectURL
        if destination == nil {
            guard !isPreview else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: Project.fileExtension) ?? .json]
            panel.nameFieldStringValue = (title.isEmpty ? "Untitled" : title.capitalized) + "." + Project.fileExtension
            panel.directoryURL = projectURL?.deletingLastPathComponent() ?? engine.stems.first?.url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            destination = chosen
        }
        guard let destination else { return }
        write(to: destination)
    }

    private func write(to document: URL) {
        let project = currentProject(for: document)
        do {
            try project.save(to: document)
            projectURL = document
            savedProject = project
            errorMessage = nil
            refreshSetlistEntries() // titre ou durée ont pu changer
        } catch {
            errorMessage = "Can't save the project: \(error.localizedDescription)"
        }
    }

    /// Une fois le projet enregistré quelque part, les changements suivants sont écrits tout seuls.
    func autosaveIfNeeded() {
        autosaveCountdown -= 1
        guard autosaveCountdown <= 0 else { return }
        autosaveCountdown = 15 // toutes les demi-secondes
        if let projectURL, currentProject(for: projectURL) != savedProject { write(to: projectURL) }
    }

    /// Le morceau est chargé à l'arrêt, au début. Les queues d'écho et de reverb du précédent continuent.
    func openProject(_ document: URL) {
        guard confirmDiscardingUnsavedSession() else { return }
        let project: Project
        do { project = try Project.load(from: document) } catch {
            errorMessage = "Can't open \(document.lastPathComponent)"
            return
        }
        engine.stop()
        clear()
        mix.setTempo(project.bpm) // avant de poser les stems : un tempo enregistré n'est pas re-détecté
        mix.setDelaySync(project.delaySync)
        stripNames = Dictionary(uniqueKeysWithValues: (project.stripNames ?? [:]).compactMap { key, name in Int(key).map { ($0, name) } })
        for strip in project.keep ?? [] where mix.strips.indices.contains(strip) { mix.setKeep(strip: strip, true) }
        setReverbModel(project.reverbModel.flatMap(ReverbModel.init) ?? .plate)
        setThrowTarget(project.throwTarget.flatMap(ThrowTarget.init) ?? .delay)
        setBus3Model(project.bus3Model.flatMap(Bus3Model.init) ?? .phaser)
        unresolvedInserts = project.inserts ?? [:]
        for entry in project.stems {
            if let url = entry.file.resolve(relativeTo: document) {
                assign([url], toStrip: min(max(0, entry.strip), AudioEngine.stripCount - 1))
            } else {
                unresolvedStems.append(entry)
            }
        }
        addToPool(project.pool.compactMap { $0.resolve(relativeTo: document) })
        for (name, value) in project.fx {
            if let parameter = FXParameter(rawValue: name) { mix.setFX(parameter, value) }
        }
        looping = project.loop
        engine.loop = project.loop
        unresolvedSlots = project.slots ?? [:] // chargés en tâche de fond ; d'ici là ils restent inscrits dans le projet
        projectURL = document
        savedProject = currentProject(for: document)
        var warnings = restoreSlots().map { "\($0) is not installed (built-in effect used instead)" }
        warnings += restoreInserts().map { "\($0) is not installed (insert bypassed)" }
        if !unresolvedStems.isEmpty { warnings.insert("\(unresolvedStems.count) stem(s) not found", at: 0) }
        errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    /// Cherche les stems introuvables, par nom de fichier, dans un dossier choisi par l'utilisateur.
    func locateMissingStems() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder that contains: " + unresolvedStems.map(\.file.fileName).joined(separator: ", ")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for entry in unresolvedStems {
            let candidate = folder.appending(path: entry.file.fileName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            unresolvedStems.removeAll { $0 == entry }
            assign([candidate], toStrip: entry.strip)
        }
        errorMessage = unresolvedStems.isEmpty ? nil : "\(unresolvedStems.count) stem(s) still not found"
    }

    func newSession() {
        guard confirmDiscardingUnsavedSession() else { return }
        engine.stop()
        clear()
    }

    /// Seule une session jamais enregistrée peut se perdre : un projet enregistré se sauvegarde tout seul.
    func confirmDiscardingUnsavedSession() -> Bool {
        guard !isPreview, projectURL == nil, hasUnsavedChanges else { return true } // pas de dialogue sans interface
        let alert = NSAlert()
        alert.messageText = "This session has never been saved"
        alert.informativeText = "Your strip assignments and effect settings will be lost."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject()
            return projectURL != nil
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Setlist

    var setlistIndex: Int? {
        guard let projectURL else { return nil }
        return setlistEntries.firstIndex { $0.url?.standardizedFileURL == projectURL.standardizedFileURL }
    }

    func openSetlist(_ document: URL) {
        do {
            setlist = try Setlist.load(from: document)
            setlistURL = document
            refreshSetlistEntries()
        } catch {
            errorMessage = "Can't open \(document.lastPathComponent)"
        }
    }

    /// Ajoute le morceau ouvert à la setlist (créée au besoin). Le morceau doit exister sur le disque.
    func addCurrentProjectToSetlist() {
        if projectURL == nil { saveProject() }
        guard let projectURL, setlistIndex == nil else { return }
        if setlist == nil { setlist = Setlist(name: "SETLIST") }
        let anchor = setlistURL ?? projectURL
        setlist?.projects.append(FileReference(projectURL, relativeTo: anchor))
        refreshSetlistEntries()
        saveSetlist()
    }

    func removeFromSetlist(_ entry: SetlistEntry) {
        setlist?.projects.removeAll { $0 == entry.reference }
        refreshSetlistEntries()
        saveSetlist()
    }

    func moveInSetlist(_ entry: SetlistEntry, by offset: Int) {
        guard var projects = setlist?.projects, let index = projects.firstIndex(of: entry.reference) else { return }
        let target = index + offset
        guard projects.indices.contains(target) else { return }
        projects.swapAt(index, target)
        setlist?.projects = projects
        refreshSetlistEntries()
        saveSetlist()
    }

    /// Drag and drop: puts `entry` where `target` is (before it when moving up, after it when moving down).
    func moveInSetlist(_ entry: SetlistEntry, onto target: SetlistEntry) {
        guard var projects = setlist?.projects, entry != target,
              let from = projects.firstIndex(of: entry.reference), let to = projects.firstIndex(of: target.reference)
        else { return }
        let moved = projects.remove(at: from)
        projects.insert(moved, at: to)
        setlist?.projects = projects
        refreshSetlistEntries()
        saveSetlist()
    }

    func renameSetlist(_ name: String) {
        guard setlist != nil else { return }
        setlist?.name = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        saveSetlist()
    }

    func closeSetlist() {
        setlist = nil
        setlistURL = nil
        setlistEntries = []
    }

    /// Enregistre la setlist ; la première fois, demande où.
    func saveSetlist() {
        guard var setlist else { return }
        if setlistURL == nil {
            guard !isPreview else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: Setlist.fileExtension) ?? .json]
            panel.nameFieldStringValue = "Setlist." + Setlist.fileExtension
            panel.directoryURL = projectURL?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            // Les chemins relatifs se calculent par rapport à l'emplacement définitif de la setlist.
            setlist.projects = setlistEntries.map { entry in
                entry.url.map { FileReference($0, relativeTo: chosen) } ?? entry.reference
            }
            setlist.name = chosen.deletingPathExtension().lastPathComponent.uppercased()
            setlistURL = chosen
            self.setlist = setlist
        }
        guard let setlistURL else { return }
        do { try setlist.save(to: setlistURL) } catch {
            errorMessage = "Can't save the setlist: \(error.localizedDescription)"
        }
        refreshSetlistEntries()
    }

    func refreshSetlistEntries() {
        guard let setlist else { return }
        let anchor = setlistURL ?? projectURL ?? URL(fileURLWithPath: "/")
        setlistEntries = setlist.projects.map { reference in
            let url = reference.resolve(relativeTo: anchor)
            let project = url.flatMap { try? Project.load(from: $0) }
            let fallback = URL(fileURLWithPath: reference.path).deletingPathExtension().lastPathComponent
            return SetlistEntry(
                reference: reference, url: url,
                title: project.map { $0.title.isEmpty ? fallback : $0.title } ?? fallback,
                bpm: project?.bpm, duration: project?.duration ?? 0
            )
        }
    }

    func openSetlistEntry(at index: Int) {
        guard setlistEntries.indices.contains(index), let url = setlistEntries[index].url else { return }
        openProject(url)
    }

    func openNextInSetlist(offset: Int = 1) {
        guard !setlistEntries.isEmpty else { return }
        openSetlistEntry(at: (setlistIndex ?? (offset > 0 ? -1 : setlistEntries.count)) + offset)
    }
}
