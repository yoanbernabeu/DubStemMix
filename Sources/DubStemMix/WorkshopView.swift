import AppKit
import DubStemMixCore
import SwiftUI

/// The setlist workshop (PRD § 13): my setlists, the library, the setlist being built. In place of the console.
struct WorkshopView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)
            HStack(alignment: .top, spacing: 18) {
                SetlistsColumn(model: model)
                    .frame(width: 230)
                LibraryColumn(model: model)
                    .frame(width: 330)
                SetlistColumn(model: model)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text("DUB").foregroundStyle(Theme.delay))\(Text("STEM").foregroundStyle(Theme.reverb))\(Text("MIX").foregroundStyle(Theme.bus3))")
                    .font(Fonts.label(15, weight: 900, width: 122))
                    .tracking(0.5)
                Text("SETLISTS")
                    .font(Fonts.label(30, weight: 900, width: 110))
                    .tracking(1.5)
                    .foregroundStyle(Theme.text)
                Text("Drag songs from the library into the set · every change is saved · playback is off")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                if let error = model.errorMessage {
                    Text(error)
                        .font(Fonts.mono(10))
                        .foregroundStyle(Theme.rec)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            Spacer()
            SmallButton(title: "BACK TO THE CONSOLE", color: Theme.reverb) { model.leaveWorkshop() }
                .frame(width: 190)
        }
    }
}

/// Column title: "MY SETLISTS", with an optional detail on the right.
private struct ColumnTitle: View {
    var title: String
    var detail = ""

    var body: some View {
        HStack {
            Text(title).font(Fonts.mono(10, weight: 700)).foregroundStyle(Theme.textDim)
            Spacer()
            Text(detail).font(Fonts.mono(9.5)).foregroundStyle(Theme.textDim)
        }
        .padding(.bottom, 8)
    }
}

/// "4:12", "1:02:40"
private func length(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - My setlists

private struct SetlistsColumn: View {
    var model: AppModel

    @State private var renaming: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnTitle(title: "MY SETLISTS")
            scroll {
                VStack(spacing: 3) {
                    ForEach(model.workshopSetlists) { item in row(item) }
                }
            }
            SmallButton(title: "+ NEW SETLIST", color: Theme.text) {
                if let url = model.newWorkshopSetlist() { renaming = url }
            }
            .padding(.top, 10)
            Text("Kept in Music ▸ DubStemMix ▸ Setlists")
                .font(Fonts.mono(9))
                .foregroundStyle(Theme.textDim)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func scroll(@ViewBuilder _ content: () -> some View) -> some View {
        if model.isPreview { content() } else { ScrollView { content() } }
    }

    private func row(_ item: WorkshopSetlist) -> some View {
        let selected = item.url == model.workshopURL
        let playing = item.url == model.setlistURL?.standardizedFileURL
        return VStack(alignment: .leading, spacing: 2) {
            EditableTitle(text: item.name, editing: Binding(get: { renaming == item.url }, set: { renaming = $0 ? item.url : nil }),
                          onCommit: { model.renameWorkshopSetlist(item.url, to: $0) }) {
                Text(item.name).lineLimit(1)
            }
            .font(Fonts.label(12.5, weight: selected ? 800 : 600, width: 104))
            .foregroundStyle(selected ? Theme.bg : Theme.text)
            Text(details(item, playing: playing))
                .font(Fonts.mono(9))
                .foregroundStyle(selected ? Theme.bg.opacity(0.6) : Theme.textDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.text : Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture { model.selectWorkshopSetlist(item.url) }
        .help(item.elsewhere ? item.url.path(percentEncoded: false) : "Double-click to rename")
        .contextMenu {
            Button("Rename…") { renaming = item.url }
            Button("Duplicate") { model.duplicateWorkshopSetlist(item.url) }
            if item.elsewhere { Button("Move to the Setlists Folder") { model.moveToSetlistsFolder(item.url) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Delete…", role: .destructive) { model.deleteWorkshopSetlist(item.url) }
        }
    }

    private func details(_ item: WorkshopSetlist, playing: Bool) -> String {
        var parts = ["\(item.songs) SONG\(item.songs == 1 ? "" : "S")"]
        if playing { parts.append("ON THE CONSOLE") }
        if item.elsewhere { parts.append("ELSEWHERE") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Library

private struct LibraryColumn: View {
    var model: AppModel

    @State private var query = ""
    @State private var dropTargeted = false

    private var songs: [LibrarySong] { SongLibrary.search(model.library, query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnTitle(title: "LIBRARY", detail: model.libraryScanning ? "LOOKING…" : "\(model.library.count) SONGS")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                if model.isPreview { // ImageRenderer can't draw a text field
                    Text("Search by title").font(Fonts.mono(11)).foregroundStyle(Theme.textDim)
                    Spacer()
                } else {
                    TextField("Search by title", text: $query)
                        .textFieldStyle(.plain)
                        .font(Fonts.mono(11))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .padding(.bottom, 8)
            list
            Text("Every project in Music ▸ DubStemMix and the stems folder. Drop a .dubstem here to add one from elsewhere.")
                .font(Fonts.mono(9))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).stroke(dropTargeted ? Theme.reverb : .clear, lineWidth: 1.5))
        .padding(-4)
        .stemDrop(enabled: !model.isPreview, isTargeted: $dropTargeted) { model.addToLibrary($0) }
    }

    @ViewBuilder
    private var list: some View {
        let rows = VStack(spacing: 3) {
            ForEach(songs) { song in row(song) }
        }
        if model.isPreview { rows } else { ScrollView { rows } }
    }

    private func row(_ song: LibrarySong) -> some View {
        let inSet = model.isInWorkshopSetlist(song)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(Fonts.label(12, weight: 650, width: 104))
                    .foregroundStyle(inSet ? Theme.textDim : Theme.text)
                    .lineLimit(1)
                Text(([song.bpm.map { "\(Int($0.rounded())) BPM" }, song.duration > 0 ? length(song.duration) : nil].compactMap { $0 }).joined(separator: " · "))
                    .font(Fonts.mono(9))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            if inSet {
                Text("IN SET").font(Fonts.mono(8.5, weight: 700)).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.addToWorkshopSetlist([song.url]) }
        .help("Drag into the set, or double-click to add it at the end")
        .libraryDrag(song.url, enabled: !model.isPreview)
        .contextMenu {
            Button("Add to the Setlist") { model.addToWorkshopSetlist([song.url]) }.disabled(model.workshopSetlist == nil)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.url]) }
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func libraryDrag(_ url: URL, enabled: Bool) -> some View {
        if enabled { draggable(url.absoluteString) } else { self }
    }
}

// MARK: - The setlist

private struct SetlistColumn: View {
    var model: AppModel

    @State private var renaming = false
    @State private var selected: UUID?
    @State private var tagging: UUID?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var entries: [SetlistEntry] { model.workshopEntries }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let setlist = model.workshopSetlist {
                head(setlist)
                list
                endZone
            } else {
                ColumnTitle(title: "SETLIST")
                Text("Choose a setlist on the left, or make a new one.")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).stroke(dropTargeted ? Theme.reverb : .clear, lineWidth: 1.5))
        .padding(-4)
        .stemDrop(enabled: !model.isPreview && model.workshopSetlist != nil, isTargeted: $dropTargeted) {
            model.addToWorkshopSetlist($0)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let selected, let entry = entries.first(where: { $0.id == selected }) else { return .ignored }
            model.removeFromWorkshop(entry)
            self.selected = nil
            return .handled
        }
    }

    private func head(_ setlist: Setlist) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ColumnTitle(title: "SETLIST", detail: model.workshopURL == model.setlistURL?.standardizedFileURL ? "ON THE CONSOLE" : "")
            EditableTitle(text: setlist.name, editing: $renaming, onCommit: { model.renameWorkshopSetlistTitle($0) }) {
                Text(setlist.name.isEmpty ? "SETLIST" : setlist.name).lineLimit(1)
            }
            .font(Fonts.label(22, weight: 900, width: 110))
            .tracking(1)
            .foregroundStyle(Theme.text)
            .help("Double-click to rename")
            let total = entries.map(\.duration).reduce(0, +)
            Text("\(entries.count) SONG\(entries.count == 1 ? "" : "S") · \(length(total))")
                .font(Fonts.mono(10, weight: 700))
                .foregroundStyle(Theme.delay)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var list: some View {
        let rows = VStack(spacing: 3) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(entry, number: index + 1)
            }
        }
        if model.isPreview { rows } else { ScrollView { rows } }
    }

    /// Drop here to add at the end.
    private var endZone: some View {
        Text(entries.isEmpty ? "Drag songs from the library here" : "Drop here to add at the end")
            .font(Fonts.mono(10))
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.textDim.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .padding(.top, 8)
            .workshopDrop(model: model, at: nil)
    }

    private func row(_ entry: SetlistEntry, number: Int) -> some View {
        let missing = entry.url == nil
        let isSelected = selected == entry.id
        let blinking = entry.url != nil && entry.url?.standardizedFileURL == model.workshopBlink
        let color = Theme.lineColor(entry.song.color)
        return HStack(spacing: 10) {
            Text(String(format: "%02d", number))
                .font(Fonts.mono(10.5))
                .foregroundStyle(Theme.textDim)
                .frame(width: 20, alignment: .leading)
            colorMenu(entry, color: color)
            Text((missing ? "⚠ " : "") + entry.title)
                .font(Fonts.label(13, weight: 700, width: 104))
                .foregroundStyle(missing ? Theme.rec : Theme.text)
                .lineLimit(1)
            if let tag = entry.song.tag {
                Text(tag.uppercased())
                    .font(Fonts.mono(9, weight: 700))
                    .foregroundStyle(color ?? Theme.textDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke((color ?? Theme.textDim).opacity(0.7), lineWidth: 1))
                    .onTapGesture { tagging = entry.id }
            }
            Spacer(minLength: 8)
            Text(missing ? "PROJECT NOT FOUND" : ([entry.bpm.map { "\(Int($0.rounded())) BPM" }, length(entry.duration)].compactMap { $0 }).joined(separator: " · "))
                .font(Fonts.mono(9.5))
                .foregroundStyle(missing ? Theme.rec : Theme.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(blinking ? Theme.delay.opacity(0.35) : Theme.surface))
        .overlay(alignment: .leading) {
            if let color { UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(color).frame(width: 4) }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.text : (missing ? Theme.rec.opacity(0.6) : Theme.border), lineWidth: 1))
        .animation(.easeInOut(duration: 0.25).repeatCount(3, autoreverses: true), value: blinking)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = entry.id
            focused = true
        }
        .help(missing ? "Project not found: " + entry.reference.path : entry.problems.joined(separator: "\n"))
        .popover(isPresented: Binding(get: { tagging == entry.id }, set: { if !$0 { tagging = nil } })) {
            TagEditor(tag: entry.song.tag ?? "", suggestions: model.workshopTags) { model.setTag($0, of: entry) }
        }
        .entryDrag(entry, model: model)
        .contextMenu {
            Menu("Colour") {
                ForEach(Theme.lineColors.indices, id: \.self) { index in
                    Button(Theme.lineColors[index].name) { model.setColor(index, of: entry) }
                }
                Divider()
                Button("None") { model.setColor(nil, of: entry) }
            }
            Button(entry.song.tag == nil ? "Add a Tag…" : "Edit the Tag…") { tagging = entry.id }
            Divider()
            Button("Move Up") { model.moveInWorkshop(entry, by: -1) }
            Button("Move Down") { model.moveInWorkshop(entry, by: 1) }
            Divider()
            Button("Remove from the Setlist", role: .destructive) { model.removeFromWorkshop(entry) }
        }
    }

    /// The line's colour: a dot, a click opens the palette.
    private func colorMenu(_ entry: SetlistEntry, color: Color?) -> some View {
        Menu {
            ForEach(Theme.lineColors.indices, id: \.self) { index in
                Button(Theme.lineColors[index].name) { model.setColor(index, of: entry) }
            }
            Divider()
            Button("None") { model.setColor(nil, of: entry) }
        } label: {
            Circle()
                .fill(color ?? .clear)
                .overlay(Circle().stroke(color ?? Theme.textDim.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: color == nil ? [2, 2] : [])))
                .frame(width: 12, height: 12)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Colour of this line")
    }
}

/// The tag of a setlist line: a short free text, with the tags already used offered.
private struct TagEditor: View {
    @State var tag: String
    var suggestions: [String]
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TAG").font(Fonts.mono(9.5, weight: 700)).foregroundStyle(Theme.textDim)
            TextField("Opener, Encore…", text: $tag)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commit(tag) }
            if !suggestions.isEmpty {
                FlowTags(tags: suggestions.filter { $0 != tag }) { commit($0) }
            }
            HStack {
                Button("Remove") { commit("") }
                Spacer()
                Button("OK") { commit(tag) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func commit(_ value: String) {
        onCommit(value)
        dismiss()
    }
}

/// Tags already used, as buttons, wrapped on several lines.
private struct FlowTags: View {
    var tags: [String]
    var onPick: (String) -> Void

    var body: some View {
        let rows = stride(from: 0, to: tags.count, by: 3).map { Array(tags[$0..<min($0 + 3, tags.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { tag in
                        Button(tag) { onPick(tag) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

extension View {
    /// A setlist line: dragged onto another to reorder; songs from the library dropped on it are added at its place.
    @ViewBuilder
    fileprivate func entryDrag(_ entry: SetlistEntry, model: AppModel) -> some View {
        if model.isPreview {
            self
        } else {
            draggable(entry.id.uuidString)
                .workshopDrop(model: model, at: entry)
        }
    }

    /// Drop on a line (`at`: before it) or on the end zone (nil): reorders a line, or adds songs from the library
    /// or the Finder.
    @ViewBuilder
    fileprivate func workshopDrop(model: AppModel, at target: SetlistEntry?) -> some View {
        if model.isPreview {
            self
        } else {
            dropDestination(for: String.self) { items, _ in
                if let id = items.first, let dragged = model.workshopEntries.first(where: { $0.id.uuidString == id }) {
                    if let target { model.moveInWorkshop(dragged, onto: target) } else { model.moveToEndOfWorkshop(dragged) }
                    return true
                }
                let urls = items.compactMap(URL.init(string:)).filter(\.isFileURL)
                guard !urls.isEmpty else { return false }
                model.addToWorkshopSetlist(urls, at: target.flatMap { model.workshopEntries.firstIndex(of: $0) })
                return true
            }
        }
    }
}
