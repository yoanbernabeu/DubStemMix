import DubStemMixCore
import SwiftUI

/// Export to MPC (PRD § 16.2 quater): pick the card (or a folder), back up what is on it, write.
struct MPCExportView: View {
    var model: AppModel
    @State private var destinations: [MPCDestination] = []
    @State private var selected: MPCDestination?
    @State private var backUp = true
    @State private var plan: MPCExport?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EXPORT TO MPC")
                .font(Fonts.label(20, weight: 850, width: 118))
                .foregroundStyle(Theme.text)
            Text("Writes the DubStemMix plugin and this setlist's songs for an Akai MPC (MPC OS 3.10.1 or later). The card becomes this setlist: songs already there and unchanged are not copied again.")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(destinations) { destination in row(destination) }
                if destinations.isEmpty {
                    Text("No card or drive plugged in")
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SmallButton(title: "CHOOSE A FOLDER…", color: Theme.textDim) {
                    if let folder = model.chooseMPCFolder() { select(folder) }
                }
                .help("To copy onto the card yourself later")
            }

            if let plan, let selected {
                let bytes = plan.bytesNeeded()
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary(plan, bytes: bytes.write))
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(enoughRoom(selected, bytes) ? Theme.text : Theme.rec)
                    if plan.hasExisting {
                        Toggle(isOn: $backUp) {
                            Text("Back up the DubStemMix folder already there to Music ▸ DubStemMix ▸ MPC Backups first")
                                .font(Fonts.mono(10.5))
                                .foregroundStyle(Theme.text)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if plan.bundledPlugin == nil {
                        Text("⚠ This build has no MPC plugin inside: only the songs are written")
                            .font(Fonts.mono(10)).foregroundStyle(Theme.rec)
                    }
                    if !plan.missing.isEmpty {
                        Text("⚠ \(plan.missing.count) not found, not exported")
                            .font(Fonts.mono(10)).foregroundStyle(Theme.rec)
                            .help(plan.missing.joined(separator: "\n"))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.showMPCExport = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    if let selected { model.exportToMPC(selected, backUp: backUp) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || plan?.songs.isEmpty != false)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.bg)
        .onAppear {
            destinations = model.mpcVolumes()
            if let first = destinations.first { select(first) }
        }
    }

    private func row(_ destination: MPCDestination) -> some View {
        let on = selected == destination
        return Button { select(destination) } label: {
            HStack {
                Text(destination.name.uppercased())
                    .font(Fonts.label(12, weight: 800))
                    .foregroundStyle(on ? Theme.bg : Theme.text)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: destination.free, countStyle: .file) + " free")
                    .font(Fonts.mono(10))
                    .foregroundStyle(on ? Theme.bg : Theme.textDim)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.text : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Theme.text : Theme.border, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ destination: MPCDestination) {
        if !destinations.contains(destination) { destinations.append(destination) }
        selected = destination
        plan = model.planMPCExport(to: destination)
        backUp = true
    }

    private func summary(_ plan: MPCExport, bytes: Int64) -> String {
        let songs = plan.songs.count
        return "\(songs) song\(songs == 1 ? "" : "s") · about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) to write"
    }

    private func enoughRoom(_ destination: MPCDestination, _ bytes: (write: Int64, freed: Int64)) -> Bool {
        destination.free == 0 || destination.free + bytes.freed >= bytes.write
    }
}

/// Under the setlist: the export's progress, then what was written, with Eject for a card.
struct MPCExportStatus: View {
    var model: AppModel

    var body: some View {
        switch model.mpcExport {
        case .idle:
            EmptyView()
        case let .exporting(fraction):
            Text("MPC: WRITING… \(Int(fraction * 100)) %")
                .font(Fonts.mono(9.5, weight: 700))
                .foregroundStyle(Theme.delay)
        case let .done(root, report, volume, backup):
            VStack(alignment: .leading, spacing: 4) {
                Text("MPC: \(report.songs) SONG\(report.songs == 1 ? "" : "S") · \(report.written) WRITTEN · \(report.reused) ALREADY THERE")
                    .font(Fonts.mono(9.5, weight: 700))
                    .foregroundStyle(Theme.reverb)
                    .help(backup.map { "Backup: \($0.path)" } ?? "")
                if !report.missing.isEmpty {
                    Text("⚠ \(report.missing.count) NOT FOUND, NOT EXPORTED")
                        .font(Fonts.mono(9))
                        .foregroundStyle(Theme.rec)
                        .help(report.missing.joined(separator: "\n"))
                }
                if volume {
                    SmallButton(title: "EJECT THE CARD", color: Theme.reverb) { model.ejectMPC(root) }
                } else {
                    SmallButton(title: "SHOW IN FINDER", color: Theme.reverb) {
                        NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: "VST2 Plugins")])
                    }
                }
            }
        case let .failed(message):
            Text("MPC EXPORT FAILED: \(message)")
                .font(Fonts.mono(9))
                .foregroundStyle(Theme.rec)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
