import AppKit
import DubStemMixCore
import StemSplit
import SwiftUI

/// The preparation mode's screen (PRD § 12.6): the queue of songs being split, in place of the console.
struct PreparationView: View {
    var model: AppModel

    @State private var dropTargeted = false

    private var queue: SplitQueue { model.prepQueue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)
            if queue.items.isEmpty {
                Spacer()
            } else if model.isPreview {
                rows
                Spacer(minLength: 0)
            } else {
                ScrollView { rows }
            }
            dropHint
                .padding(.top, 14)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.text, lineWidth: dropTargeted ? 3 : 0))
        .stemDrop(enabled: !model.isPreview, isTargeted: $dropTargeted) { model.prepareSongs($0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Text("DUB").foregroundStyle(Theme.delay))\(Text("STEM").foregroundStyle(Theme.reverb))\(Text("MIX").foregroundStyle(Theme.bus3))")
                    .font(Fonts.label(15, weight: 900, width: 122))
                    .tracking(0.5)
                Text("PREPARE SONGS")
                    .font(Fonts.label(30, weight: 900, width: 110))
                    .tracking(1.5)
                    .foregroundStyle(Theme.text)
                Text("Each song → drums, bass, instruments, vocals and a ready project next to them · playback is off")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                Text(summary)
                    .font(Fonts.mono(11, weight: 700))
                    .foregroundStyle(model.prepBusy ? Theme.delay : Theme.reverb)
                    .padding(.top, 8)
                if let error = model.errorMessage {
                    Text(error)
                        .font(Fonts.mono(10))
                        .foregroundStyle(Theme.rec)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                SmallButton(title: "ADD SONGS…", color: Theme.text) { model.chooseSongsToPrepare() }
                    .frame(width: 190)
                if model.prepBusy {
                    SmallButton(title: "CANCEL ALL", color: Theme.rec) { model.cancelPreparation() }
                        .frame(width: 190)
                        .help("Stops the song being split and empties the list; prepared songs stay")
                } else {
                    if queue.waitingCount > 0 {
                        SmallButton(title: "START", color: Theme.delay) { model.startPreparing() }
                            .frame(width: 190)
                    }
                    SmallButton(title: "BACK TO THE CONSOLE", color: Theme.reverb) { model.leavePreparation() }
                        .frame(width: 190)
                }
            }
        }
    }

    /// "3 / 10 PREPARED · 1 FAILED · ABOUT 42 MIN LEFT"
    private var summary: String {
        if case let .downloading(received, total) = model.separation {
            return "DOWNLOADING THE ENGINE… \(received / 1_000_000) / \(total / 1_000_000) MB"
        }
        let finished = queue.doneCount + queue.failedCount
        var parts = ["\(queue.doneCount) / \(queue.items.count) PREPARED"]
        if queue.failedCount > 0 { parts.append("\(queue.failedCount) FAILED") }
        if model.prepBusy {
            parts.append(model.prepTimeLeft.map { "ABOUT \(Self.duration($0)) LEFT" } ?? "ESTIMATING TIME LEFT…")
        } else if finished == queue.items.count, finished > 0 {
            parts.append("ALL DONE")
        } else if queue.waitingCount > 0 {
            parts.append("WAITING")
        }
        return parts.joined(separator: " · ")
    }

    /// "1 H 05", "42 MIN", "< 1 MIN"
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "< 1 MIN" }
        return minutes >= 60 ? "\(minutes / 60) H \(String(format: "%02d", minutes % 60))" : "\(minutes) MIN"
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                PrepRow(model: model, item: item, number: index + 1)
            }
        }
    }

    private var dropHint: some View {
        Text(queue.items.isEmpty ? "Drop songs or a folder here" : "Drop more songs here to add them at the end")
            .font(Fonts.mono(10))
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.textDim.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Rectangle())
            .onTapGesture { model.chooseSongsToPrepare() }
    }
}

/// One song of the queue: waiting (drag to reorder, right-click), running (progress), prepared or failed.
private struct PrepRow: View {
    var model: AppModel
    var item: SplitQueue.Item
    var number: Int

    private var running: Bool { item.status == .running }

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", number))
                .font(Fonts.mono(11))
                .foregroundStyle(Theme.textDim)
            VStack(alignment: .leading, spacing: 3) {
                Text(StemImporter.songTitle(for: item.source))
                    .font(Fonts.label(14, weight: 800, width: 104))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(item.source.lastPathComponent + (item.duration.map { " · " + Self.length($0) } ?? ""))
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if running, case let .splitting(_, _, fraction, _) = model.separation {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border).frame(height: 4)
                        GeometryReader { geo in
                            Capsule().fill(Theme.delay).frame(width: geo.size.width * min(1, max(0, fraction)), height: 4)
                        }
                        .frame(height: 4)
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 12)
            status
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(running ? Theme.delay : Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .prepDrag(item, model: model)
        .contextMenu {
            if item.isWaiting {
                Button("Move up") { model.movePrepSong(item.id, by: -1) }
                Button("Move down") { model.movePrepSong(item.id, by: 1) }
                Button("Remove", role: .destructive) { model.removeFromPrepQueue(item.id) }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .waiting:
            HStack(spacing: 12) {
                Text("WAITING").font(Fonts.mono(10, weight: 700)).foregroundStyle(Theme.textDim)
                Button("×") { model.removeFromPrepQueue(item.id) }
                    .buttonStyle(.plain)
                    .font(Fonts.mono(14, weight: 700))
                    .foregroundStyle(Theme.textDim)
                    .help("Remove from the list")
            }
        case .running:
            Text(runningDetail).font(Fonts.mono(10, weight: 700)).foregroundStyle(Theme.delay)
        case let .done(project, reused):
            HStack(spacing: 12) {
                Text(reused ? "ALREADY PREPARED" : "READY").font(Fonts.mono(10, weight: 700)).foregroundStyle(Theme.reverb)
                Button("SHOW IN FINDER") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                    .buttonStyle(.plain)
                    .font(Fonts.mono(9.5, weight: 700))
                    .foregroundStyle(Theme.text)
            }
            .help(project.path)
        case let .failed(message):
            Text("FAILED").font(Fonts.mono(10, weight: 700)).foregroundStyle(Theme.rec).help(message)
        }
    }

    private var runningDetail: String {
        guard case let .splitting(_, stem, fraction, started) = model.separation else { return "STARTING…" }
        var text = "\(stem.rawValue.uppercased())… \(Int(fraction * 100)) %"
        if fraction > 0.02 {
            let remaining = Date().timeIntervalSince(started) * (1 - fraction) / fraction
            text += " · " + Self.length(remaining) + " LEFT"
        }
        return text
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

extension View {
    /// Waiting songs can be dragged onto one another to change the order (disabled for PNG captures).
    @ViewBuilder
    fileprivate func prepDrag(_ item: SplitQueue.Item, model: AppModel) -> some View {
        if model.isPreview || !item.isWaiting {
            self
        } else {
            draggable(item.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first.flatMap(UUID.init(uuidString:)) else {
                        // Songs dragged from the Finder can arrive here as text.
                        let urls = ids.compactMap(URL.init(string:)).filter(\.isFileURL)
                        model.prepareSongs(urls)
                        return !urls.isEmpty
                    }
                    model.movePrepSong(id, onto: item.id)
                    return true
                }
        }
    }
}
