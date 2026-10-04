import AppKit
import DubStemMixCore

/// A setlist of the workshop's first column: in the setlists folder, or elsewhere (opened, or recent).
struct WorkshopSetlist: Identifiable, Equatable {
    var url: URL
    var name: String
    var songs: Int
    /// Outside the setlists folder: can be moved into it.
    var elsewhere: Bool

    var id: URL { url }
}

/// The setlist workshop (PRD § 13): building sets in a screen of its own, in place of the console. Every change is
/// written at once; when the setlist being edited is the console's, the console follows.
extension AppModel {
    static let defaultSetlistsFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "DubStemMix/Setlists", directoryHint: .isDirectory)
    static let defaultLibraryFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appending(path: "DubStemMix", directoryHint: .isDirectory)

    // MARK: Entering and leaving

    func openWorkshop() {
        guard !isPreview, !editingSetlists, !refusedWhilePreparing() else { return }
        if engine.isPlaying {
            let alert = NSAlert()
            alert.messageText = "Stop playback and edit setlists?"
            alert.informativeText = "Your session stays open: you find it again when you go back to the console."
            alert.addButton(withTitle: "Stop and Edit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        disarm()
        engine.pause()
        isPlaying = false
        errorMessage = nil
        editingSetlists = true
        refreshWorkshopSetlists()
        selectWorkshopSetlist(setlistURL ?? workshopURL ?? workshopSetlists.first?.url)
        scanLibrary()
    }

    func leaveWorkshop() {
        editingSetlists = false
        errorMessage = nil
    }

    // MARK: First column: my setlists

    /// The setlists folder, plus the console's setlist and the recent ones when they live elsewhere.
    func refreshWorkshopSetlists() {
        let folder = setlistsFolder.standardizedFileURL
        let inFolder = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == Setlist.fileExtension }
            .map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var elsewhere: [URL] = []
        for url in [setlistURL, workshopURL].compactMap({ $0 }) + recentFiles.filter({ $0.pathExtension == Setlist.fileExtension }) {
            let url = url.standardizedFileURL
            if url.deletingLastPathComponent() != folder, !elsewhere.contains(url),
               FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                elsewhere.append(url)
            }
        }
        var tags = Set<String>()
        workshopSetlists = (inFolder + elsewhere).compactMap { url in
            guard let setlist = try? Setlist.load(from: url) else { return nil }
            setlist.projects.compactMap(\.tag).forEach { tags.insert($0) }
            let name = setlist.name.isEmpty ? url.deletingPathExtension().lastPathComponent.uppercased() : setlist.name
            return WorkshopSetlist(url: url, name: name, songs: setlist.projects.count, elsewhere: !inFolder.contains(url))
        }
        workshopTags = tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func selectWorkshopSetlist(_ url: URL?) {
        guard let url, let setlist = try? Setlist.load(from: url) else {
            workshopURL = nil
            workshopSetlist = nil
            workshopEntries = []
            return
        }
        workshopURL = url.standardizedFileURL
        workshopSetlist = setlist
        workshopEntries = entries(of: setlist, at: url)
    }

    /// A new, empty setlist in the setlists folder, selected.
    @discardableResult
    func newWorkshopSetlist() -> URL? {
        let url = freeSetlistLocation(named: "New Setlist")
        do {
            try FileManager.default.createDirectory(at: setlistsFolder, withIntermediateDirectories: true)
            try Setlist(name: url.deletingPathExtension().lastPathComponent.uppercased()).save(to: url)
        } catch {
            errorMessage = "Can't create the setlist: \(error.localizedDescription)"
            return nil
        }
        refreshWorkshopSetlists()
        selectWorkshopSetlist(url)
        return url
    }

    /// The name shown and the file's name change together; the file stays in its folder.
    func renameWorkshopSetlist(_ url: URL, to typed: String) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, var setlist = try? Setlist.load(from: url) else { return }
        setlist.name = name.uppercased()
        var destination = url
        if name.lowercased() != url.deletingPathExtension().lastPathComponent.lowercased() {
            destination = Self.freeLocation(in: url.deletingLastPathComponent(), named: name)
        }
        do {
            try setlist.save(to: url)
            if destination != url { try FileManager.default.moveItem(at: url, to: destination) }
        } catch {
            errorMessage = "Can't rename the setlist: \(error.localizedDescription)"
            return
        }
        followMove(of: url, to: destination, setlist: setlist)
    }

    /// A copy in the setlists folder, named "… copy", selected.
    func duplicateWorkshopSetlist(_ url: URL) {
        guard let setlist = try? Setlist.load(from: url) else { return }
        let destination = freeSetlistLocation(named: url.deletingPathExtension().lastPathComponent + " copy")
        var copy = setlist.moved(from: url, to: destination)
        copy.name = destination.deletingPathExtension().lastPathComponent.uppercased()
        do {
            try FileManager.default.createDirectory(at: setlistsFolder, withIntermediateDirectories: true)
            try copy.save(to: destination)
        } catch {
            errorMessage = "Can't duplicate the setlist: \(error.localizedDescription)"
            return
        }
        refreshWorkshopSetlists()
        selectWorkshopSetlist(destination)
    }

    /// Into the Trash (the songs are not touched), after asking. The console closes it if it was open there.
    func deleteWorkshopSetlist(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.deletingPathExtension().lastPathComponent)” to the Trash?"
        alert.informativeText = "Only the setlist goes: its songs stay where they are."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
            errorMessage = "Can't delete the setlist: \(error.localizedDescription)"
            return
        }
        if setlistURL?.standardizedFileURL == url.standardizedFileURL { closeSetlist() }
        refreshWorkshopSetlists()
        if workshopURL == url.standardizedFileURL { selectWorkshopSetlist(workshopSetlists.first?.url) }
    }

    /// A setlist living elsewhere joins the setlists folder; its songs stay where they are.
    func moveToSetlistsFolder(_ url: URL) {
        guard let setlist = try? Setlist.load(from: url) else { return }
        let destination = freeSetlistLocation(named: url.deletingPathExtension().lastPathComponent)
        let moved = setlist.moved(from: url, to: destination)
        do {
            try FileManager.default.createDirectory(at: setlistsFolder, withIntermediateDirectories: true)
            try moved.save(to: destination)
            try FileManager.default.removeItem(at: url)
        } catch {
            errorMessage = "Can't move the setlist: \(error.localizedDescription)"
            return
        }
        followMove(of: url, to: destination, setlist: moved)
    }

    /// After a rename or a move: the workshop, the console and the recent files point to the new place.
    private func followMove(of old: URL, to new: URL, setlist moved: Setlist) {
        let old = old.standardizedFileURL
        if setlistURL?.standardizedFileURL == old {
            setlistURL = new
            var console = moved
            console.rack = setlist?.rack ?? moved.rack
            setlist = console
            refreshSetlistEntries()
            noteRecentDocument(new)
        }
        refreshWorkshopSetlists()
        if workshopURL == old || workshopURL == nil { selectWorkshopSetlist(new) }
    }

    func freeSetlistLocation(named name: String) -> URL { Self.freeLocation(in: setlistsFolder, named: name) }

    /// "Name.dubset", or "Name 2.dubset"… when taken.
    static func freeLocation(in folder: URL, named name: String) -> URL {
        var candidate = folder.appending(path: name + "." + Setlist.fileExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(name) \(number)." + Setlist.fileExtension)
            number += 1
        }
        return candidate
    }

    // MARK: Third column: the setlist

    /// Songs dropped at `index` (at the end when nil). A song already in the set is refused and its line blinks.
    func addToWorkshopSetlist(_ documents: [URL], at index: Int? = nil) {
        guard let workshopURL, var setlist = workshopSetlist else { return }
        var position = index
        var refused: URL?
        for document in documents where document.pathExtension == Project.fileExtension {
            if setlist.insert(document, at: position, location: workshopURL) {
                position = position.map { $0 + 1 }
            } else {
                refused = document.standardizedFileURL
            }
        }
        if let refused { blink(refused) }
        commitWorkshop(setlist)
    }

    /// Drag and drop inside the setlist: `entry` takes `target`'s place.
    func moveInWorkshop(_ entry: SetlistEntry, onto target: SetlistEntry) {
        guard var setlist = workshopSetlist, entry != target,
              let from = workshopEntries.firstIndex(of: entry), let to = workshopEntries.firstIndex(of: target)
        else { return }
        setlist.projects.insert(setlist.projects.remove(at: from), at: to)
        commitWorkshop(setlist)
    }

    func moveInWorkshop(_ entry: SetlistEntry, by offset: Int) {
        guard var setlist = workshopSetlist, let from = workshopEntries.firstIndex(of: entry),
              setlist.projects.indices.contains(from + offset)
        else { return }
        setlist.projects.swapAt(from, from + offset)
        commitWorkshop(setlist)
    }

    func moveToEndOfWorkshop(_ entry: SetlistEntry) {
        guard var setlist = workshopSetlist, let from = workshopEntries.firstIndex(of: entry) else { return }
        setlist.projects.append(setlist.projects.remove(at: from))
        commitWorkshop(setlist)
    }

    func removeFromWorkshop(_ entry: SetlistEntry) {
        guard var setlist = workshopSetlist, let index = workshopEntries.firstIndex(of: entry) else { return }
        setlist.projects.remove(at: index)
        commitWorkshop(setlist)
    }

    /// `color`: an index in the fixed palette of 8, nil for none.
    func setColor(_ color: Int?, of entry: SetlistEntry) {
        guard var setlist = workshopSetlist, let index = workshopEntries.firstIndex(of: entry) else { return }
        setlist.projects[index].color = color
        commitWorkshop(setlist)
    }

    /// A short free text; empty removes the tag.
    func setTag(_ typed: String, of entry: SetlistEntry) {
        guard var setlist = workshopSetlist, let index = workshopEntries.firstIndex(of: entry) else { return }
        let tag = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        setlist.projects[index].tag = tag.isEmpty ? nil : tag
        commitWorkshop(setlist)
        refreshWorkshopSetlists()
    }

    func renameWorkshopSetlistTitle(_ typed: String) {
        guard let workshopURL else { return }
        renameWorkshopSetlist(workshopURL, to: typed)
    }

    /// Writes the edited setlist; the console follows when it is its setlist (keeping the rack it plays through).
    private func commitWorkshop(_ edited: Setlist) {
        guard let workshopURL else { return }
        var edited = edited
        let isConsoleSetlist = setlistURL?.standardizedFileURL == workshopURL
        if isConsoleSetlist { edited.rack = setlist?.rack ?? edited.rack }
        do { try edited.save(to: workshopURL) } catch {
            errorMessage = "Can't save the setlist: \(error.localizedDescription)"
            return
        }
        workshopSetlist = edited
        workshopEntries = entries(of: edited, at: workshopURL)
        if let index = workshopSetlists.firstIndex(where: { $0.url == workshopURL }) { workshopSetlists[index].songs = edited.projects.count }
        if isConsoleSetlist {
            setlist = edited
            refreshSetlistEntries()
            if armedSong != nil, armedIndex == nil { disarm() } // the armed song left the set
        }
    }

    private func blink(_ document: URL) {
        workshopBlink = document
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if self?.workshopBlink == document { self?.workshopBlink = nil }
        }
    }

    // MARK: Second column: the library

    static func storedLibraryExtra() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: Preference.libraryExtra) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Every project in the DubStemMix folder and the stems folder, plus the ones dropped from the Finder.
    func scanLibrary() {
        libraryScanning = true
        let folders = [libraryFolder, stemsFolder]
        let extra = Self.storedLibraryExtra()
        Task { [weak self] in
            let songs = await Task.detached(priority: .userInitiated) { SongLibrary.scan(folders: folders, extra: extra) }.value
            self?.library = songs
            self?.libraryScanning = false
        }
    }

    /// Projects dropped from the Finder onto the library: remembered from one launch to the next.
    func addToLibrary(_ urls: [URL]) {
        let documents = urls.filter { $0.pathExtension == Project.fileExtension }.map { $0.standardizedFileURL.path(percentEncoded: false) }
        guard !documents.isEmpty else { return }
        var stored = UserDefaults.standard.stringArray(forKey: Preference.libraryExtra) ?? []
        for path in documents where !stored.contains(path) { stored.append(path) }
        UserDefaults.standard.set(stored, forKey: Preference.libraryExtra)
        scanLibrary()
    }

    func isInWorkshopSetlist(_ song: LibrarySong) -> Bool {
        workshopEntries.contains { $0.url?.standardizedFileURL == song.url }
    }
}

extension AppModel {
    /// Demo workshop for the PNG capture (`--snapshot out.png --setlists`).
    func loadPreviewWorkshop() {
        editingSetlists = true
        let sets = [("SUNDAY SESSION", 6, false), ("KING ALPHA TRIBUTE", 9, false), ("OPEN AIR · JULY", 12, false),
                    ("WARM UP", 4, false), ("FESTIVAL DEMO", 7, true)]
        workshopSetlists = sets.map { name, songs, elsewhere in
            WorkshopSetlist(url: URL(fileURLWithPath: "/demo/Setlists/\(name).dubset"), name: name, songs: songs, elsewhere: elsewhere)
        }
        workshopURL = workshopSetlists[0].url
        setlistURL = workshopURL
        var set = Setlist(name: "SUNDAY SESSION")
        let lines: [(String, Double, Double, Int?, String?)] = [
            ("Roots Steppa", 68, 238, 0, "Opener"), ("Midnight Version", 72, 252, nil, nil), ("Zion Gate Dub", 140, 303, 2, nil),
            ("Rockers Rise", 76, 221, nil, nil), ("Lion Heart", 74, 274, 3, "Peak"), ("Graceful Dub", 66, 385, 5, "Encore"),
        ]
        workshopEntries = lines.map { title, bpm, duration, color, tag in
            let url = URL(fileURLWithPath: "/demo/\(title).dubstem")
            let song = SetlistSong(FileReference(url, relativeTo: url), color: color, tag: tag)
            set.projects.append(song)
            return SetlistEntry(song: song, url: url, title: title, bpm: bpm, duration: duration)
        }
        workshopEntries[3].url = nil
        workshopSetlist = set
        workshopTags = ["Encore", "Opener", "Peak"]
        let titles: [(String, Double, Double)] = [
            ("Bless Na Curse Riddim", 76, 212), ("Graceful Dub", 66, 385), ("Iyanola", 70, 311), ("King's Stone", 65.6, 213),
            ("Lion Heart", 74, 274), ("Marchin", 72, 244), ("Midnight Version", 72, 252), ("Ras To The Bone", 78, 237),
            ("Riddimwise", 69, 348), ("Roots Steppa", 68, 238), ("Zion Gate Dub", 140, 303),
        ]
        library = titles.map { LibrarySong(url: URL(fileURLWithPath: "/demo/\($0.0).dubstem"), title: $0.0, bpm: $0.1, duration: $0.2) }
    }
}
