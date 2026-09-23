import AppKit
import DubStemMixCore
import StemSplit
import SwiftUI

struct RootView: View {
    var model: AppModel

    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 232)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 14) {
                TopBar(model: model)
                WaveformOverview(model: model)
                    .frame(height: 78)
                FXRack(model: model)
                    .frame(height: 64)
                ConsoleView(model: model)
            }
            .padding(18)
        }
        .background(Theme.bg)
        .overlay(
            Rectangle().stroke(Theme.text, lineWidth: dropTargeted ? 3 : 0)
        )
        .stemDrop(enabled: !model.isPreview, isTargeted: $dropTargeted) { model.open($0) }
        .background(Shortcuts(model: model))
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: Binding(get: { model.showWelcome && !model.isPreview }, set: { if !$0 { model.dismissWelcome() } })) {
            WelcomeView(model: model) { model.dismissWelcome() }
        }
    }
}

extension View {
    /// Zone de dépôt de fichiers. Désactivée pour les captures PNG (ImageRenderer ne sait pas la dessiner).
    @ViewBuilder
    func stemDrop(enabled: Bool, isTargeted: Binding<Bool>, onDrop: @escaping ([URL]) -> Void) -> some View {
        if enabled {
            dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return true
            } isTargeted: { isTargeted.wrappedValue = $0 }
        } else {
            self
        }
    }
}

extension View {
    /// Rend un stem glissable vers une tranche (désactivé pour les captures PNG).
    @ViewBuilder
    func draggableStem(_ url: URL?, enabled: Bool) -> some View {
        if enabled, let url { draggable(url) } else { self }
    }
}

/// Raccourcis clavier : espace = lecture/pause, entrée = retour au début, L = boucle, N / P = morceau suivant / précédent.
private struct Shortcuts: View {
    var model: AppModel

    var body: some View {
        Group {
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.returnToStart() }.keyboardShortcut(.return, modifiers: [])
            Button("") { model.toggleLoop() }.keyboardShortcut("l", modifiers: [])
            Button("") { model.openNextInSetlist() }.keyboardShortcut("n", modifiers: [])
            Button("") { model.openNextInSetlist(offset: -1) }.keyboardShortcut("p", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

// MARK: - Barre du haut

private struct TopBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                TransportButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", active: model.isPlaying) {
                    model.togglePlay()
                }
                TransportButton(symbol: "backward.end.fill", active: false) { model.returnToStart() }
                TransportButton(symbol: "repeat", active: model.looping) { model.toggleLoop() }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(model.title.isEmpty ? "NO STEMS LOADED" : model.title)
                    .font(Fonts.label(17, weight: 850, width: 118))
                    .tracking(0.8)
                    .foregroundStyle(model.title.isEmpty ? Theme.textDim : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(timecode(model.position, tenths: true))
                        .font(Fonts.mono(13, weight: 700))
                        .foregroundStyle(Theme.text)
                    Text("/ " + timecode(model.duration, tenths: false))
                        .font(Fonts.mono(13))
                        .foregroundStyle(Theme.textDim)
                }
            }

            Spacer()

            if !model.title.isEmpty { TempoBlock(model: model).fixedSize().layoutPriority(1) }

            if let error = model.errorMessage {
                Text(error).font(Fonts.mono(11)).foregroundStyle(Theme.rec)
            }
            // Never while playing or recording: an update waits for the stop.
            if let update = model.availableUpdate, !model.isPlaying, !model.isRecording {
                UpdateBanner(model: model, update: update)
            }
            if let recording = model.lastRecording, !model.isRecording, model.errorMessage == nil {
                Button { NSWorkspace.shared.activateFileViewerSelecting([recording]) } label: {
                    Text("Saved \(recording.lastPathComponent) — show in Finder")
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 330)
                }
                .buttonStyle(.plain)
            }
            TextButton(title: "OPEN…") { model.chooseFilesToOpen() }
            if !model.title.isEmpty {
                TextButton(title: "SAVE", highlighted: model.hasUnsavedChanges) { model.saveProject() }
                TextButton(title: "NEW") { model.newSession() }
            }
            RecordButton(model: model)
        }
        .frame(height: 46)
    }

    private func timecode(_ seconds: Double, tenths: Bool) -> String {
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return tenths ? String(format: "%d:%04.1f", minutes, rest) : String(format: "%d:%02d", minutes, Int(rest))
    }
}

private struct TransportButton: View {
    var symbol: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(active ? Theme.bg : Theme.text)
                .frame(width: 44, height: 38)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.text : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Theme.text : Theme.border, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Tempo du morceau : détecté, tapé (T), glissé à la souris, ÷2 / ×2. SYNC cale le delay dessus.
private struct TempoBlock: View {
    var model: AppModel

    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(model.mix.bpm.map { String(format: "%.1f", $0) } ?? (model.detectingTempo ? "···" : "—"))
                    .font(Fonts.mono(22, weight: 700))
                    .foregroundStyle(model.mix.bpm == nil ? Theme.textDim : Theme.text)
                Text("BPM").font(Fonts.mono(9)).foregroundStyle(Theme.textDim)
            }
            .frame(minWidth: 74, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let start = dragStart ?? model.mix.bpm ?? 90
                        dragStart = start
                        let step = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1.0
                        model.mix.setTempo(((start - drag.translation.height / 6 * step) / step).rounded() * step)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Drag up or down to adjust (hold Shift for 0.1 BPM steps)")

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Chip(text: "TAP") { model.tapTempo() }.keyboardShortcut("t", modifiers: [])
                    Chip(text: "AUTO") { model.detectTempo(replacing: true) }
                }
                HStack(spacing: 4) {
                    Chip(text: "÷2") { model.scaleTempo(by: 0.5) }
                    Chip(text: "×2") { model.scaleTempo(by: 2) }
                    Chip(text: "SYNC", active: model.mix.delaySync) { model.mix.setDelaySync(!model.mix.delaySync) }
                        .help("Lock the delay time to the tempo: the TIME knob picks a note value")
                }
            }
        }
    }
}

private struct Chip: View {
    var text: String
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Fonts.mono(10, weight: 700))
                .foregroundStyle(active ? Theme.bg : Theme.textDim)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(minWidth: 28, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? Theme.delay : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? Theme.delay : Theme.border, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Enregistre le master (ce qu'on entend, après le limiteur) en WAV 24 bits dans le dossier des Réglages.
private struct RecordButton: View {
    var model: AppModel

    var body: some View {
        Button { model.toggleRecording() } label: {
            HStack(spacing: 8) {
                Circle().fill(model.isRecording ? Theme.bg : Theme.rec).frame(width: 10, height: 10)
                Text(model.isRecording ? "REC \(timecode)" : "REC")
                    .font(Fonts.mono(13, weight: 700))
                    .foregroundStyle(model.isRecording ? Theme.bg : Theme.rec)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.isRecording ? Theme.rec : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rec, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help("Record the master to \(model.recordingsFolder.path(percentEncoded: false)) (⌘R)")
    }

    private var timecode: String {
        let seconds = Int(model.recordingTime)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// A newer version is out: install it in one click, read its notes, or hide the banner until next launch.
private struct UpdateBanner: View {
    var model: AppModel
    var update: ReleaseInfo

    var body: some View {
        HStack(spacing: 8) {
            switch model.updateStatus {
            case .downloading:
                ProgressView().controlSize(.small)
                Text("Downloading \(update.version)…").font(Fonts.mono(10.5)).foregroundStyle(Theme.text)
            case let .failed(message):
                Text("Update failed: \(message)").font(Fonts.mono(10.5)).foregroundStyle(Theme.rec).lineLimit(1)
                Button("RETRY") { model.installUpdate() }.buttonStyle(.plain).font(Fonts.label(10.5, weight: 800)).foregroundStyle(Theme.text)
            case .idle:
                Text("\(update.version) available").font(Fonts.mono(10.5)).foregroundStyle(Theme.text)
                Button("UPDATE") { model.installUpdate() }
                    .buttonStyle(.plain)
                    .font(Fonts.label(10.5, weight: 800))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text))
                Button("NOTES") { NSWorkspace.shared.open(update.pageURL) }
                    .buttonStyle(.plain)
                    .font(Fonts.label(10.5, weight: 800))
                    .foregroundStyle(Theme.textDim)
            }
            if model.updateStatus != .downloading {
                Button { model.dismissUpdate() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textDim)
                    .help("Hide for now: the next daily check shows it again")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1.5))
        .fixedSize()
    }
}

private struct TextButton: View {
    var title: String
    var highlighted = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.label(12, weight: 800))
                .tracking(1)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(highlighted ? Theme.text : Theme.border, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Forme d'onde (clic ou glissé = déplacement)

private struct WaveformOverview: View {
    var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let progress = model.duration > 0 ? model.position / model.duration : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                if model.waveform.isEmpty {
                    Text("Drop a folder of stems (or a project) anywhere, then drag each stem onto the strip you want")
                        .font(Fonts.mono(11))
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                } else {
                    Canvas { context, size in
                        let peaks = model.waveform
                        let bars = max(1, Int(size.width / 3))
                        for bar in 0..<bars {
                            let from = bar * peaks.count / bars
                            let to = max(from + 1, (bar + 1) * peaks.count / bars)
                            let peak = CGFloat(peaks[from..<min(to, peaks.count)].max() ?? 0)
                            let height = max(2, (size.height - 16) * min(1, peak))
                            let rect = CGRect(x: CGFloat(bar) * 3, y: (size.height - height) / 2, width: 2, height: height)
                            let played = Double(bar) / Double(bars) < progress
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 1),
                                with: .color(played ? Theme.text : Theme.textDim.opacity(0.45))
                            )
                        }
                    }
                    Rectangle()
                        .fill(Theme.delay)
                        .frame(width: 2)
                        .offset(x: geo.size.width * progress)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { drag in
                    guard model.duration > 0 else { return }
                    model.seek(fraction: min(1, max(0, drag.location.x / geo.size.width)))
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Rack d'effets

/// Un bus = un slot d'effet : l'effet intégré, ou n'importe quel plugin Audio Unit installé.
private struct FXRack: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Bus.allCases, id: \.self) { bus in FXSlotCard(model: model, bus: bus) }
        }
    }
}

private struct FXSlotCard: View {
    var model: AppModel
    var bus: Bus

    private var sendBus: SendBus { SendBus(rawValue: bus.rawValue)! }
    private var plugin: HostedPlugin? { model.engine.plugins[sendBus] }
    private var builtInName: String { ["Dub Delay", model.reverbModel.label, model.bus3Model.label][bus.rawValue] }
    private var returnParameter: FXParameter { [.delayReturn, .reverbReturn, .phaserReturn][bus.rawValue] }

    private var summary: String {
        if model.loadingPlugin.contains(sendBus) { return "loading…" }
        if let plugin { return plugin.info.manufacturer + (plugin.isOutOfProcess ? "" : " · in-process") }
        func show(_ parameter: FXParameter) -> String { model.mix.fxDisplay(parameter) }
        switch bus {
        case .delay:
            let heads = (model.mix.fx[.delayHeads] ?? 0) > 0.01 ? " · heads \(show(.delayHeads))" : ""
            let target = model.throwTarget == .delay ? "" : " · throw → \(model.throwTarget.label.lowercased())"
            return (model.holding ? "HOLD · " : "") + "\(show(.delayTime)) · FB \(show(.delayFeedback))" + heads + target
        case .reverb: return "decay \(show(.reverbDecay))"
        case .bus3: return "\(show(.phaserRate)) · depth \(show(.phaserDepth))"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(bus.color).frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.busLabel(sendBus))
                        .font(Fonts.label(12, weight: 850))
                        .tracking(1.2)
                        .foregroundStyle(bus.color)
                        .fixedSize()
                    Tag(text: plugin == nil ? "BUILT-IN" : "AU")
                    Tag(text: model.sendPreFader[bus.rawValue] ? "PRE" : "POST")
                        .help(model.sendPreFader[bus.rawValue]
                              ? "Sends to this bus are taken before the fader and mute (Settings)"
                              : "Sends to this bus follow the fader and mute (Settings)")
                }
                slotMenu
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Text(summary)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border).frame(width: 110, height: 4)
                    Capsule().fill(bus.color).frame(width: 110 * (model.mix.fx[returnParameter] ?? 0), height: 4)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    /// Le nom de l'effet est un menu : effet intégré, ou un plugin AU (rangés par éditeur).
    private var slotMenu: some View {
        Menu {
            if bus == .reverb {
                ForEach(ReverbModel.allCases, id: \.self) { reverb in
                    Button((plugin == nil && reverb == model.reverbModel ? "✓ " : "") + "Built-in · \(reverb.label)") {
                        model.setReverbModel(reverb)
                        model.useBuiltInEffect(on: sendBus)
                    }
                }
            } else if bus == .bus3 {
                ForEach(Bus3Model.allCases, id: \.self) { effect in
                    Button((plugin == nil && effect == model.bus3Model ? "✓ " : "") + "Built-in · \(effect.label)") {
                        model.setBus3Model(effect)
                        model.useBuiltInEffect(on: sendBus)
                    }
                }
            } else {
                Button((plugin == nil ? "✓ " : "") + "Built-in · \(builtInName)") { model.useBuiltInEffect(on: sendBus) }
            }
            if plugin != nil {
                Button("Open plugin window") { model.openPluginWindow(on: sendBus) }
            }
            // Bus-to-bus send (issue #1): targets that would close a loop are disabled.
            Menu("Send to · \(model.busRouting.target(of: sendBus).map { model.busMenuName($0) } ?? "None")") {
                Button((model.busRouting.target(of: sendBus) == nil ? "✓ " : "") + "None") { model.setBusSend(from: sendBus, to: nil) }
                ForEach(SendBus.allCases.filter { $0 != sendBus }, id: \.self) { target in
                    Button((model.busRouting.target(of: sendBus) == target ? "✓ " : "") + model.busMenuName(target)) {
                        model.setBusSend(from: sendBus, to: target)
                    }
                    .disabled(!model.busRouting.allows(sendBus, to: target))
                }
            }
            if bus == .delay {
                // Where REC ARM / THROW sends the strip (PRD § 11.4).
                Menu("Dub throw goes to · \(model.throwTarget.label)") {
                    ForEach(ThrowTarget.allCases, id: \.self) { target in
                        Button((target == model.throwTarget ? "✓ " : "") + target.label) { model.setThrowTarget(target) }
                    }
                }
            }
            Divider()
            ForEach(manufacturers, id: \.self) { manufacturer in
                Menu(manufacturer) {
                    ForEach(model.installedPlugins.filter { $0.manufacturer == manufacturer }) { info in
                        Button((plugin?.info.id == info.id ? "✓ " : "") + info.name) { model.loadPlugin(info, on: sendBus) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(plugin?.info.name ?? builtInName)
                    .font(Fonts.label(14, weight: 700, width: 105))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isPreview)
    }

    private var manufacturers: [String] {
        var seen = Set<String>()
        return model.installedPlugins.map(\.manufacturer).filter { seen.insert($0).inserted }
    }
}

private struct Tag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Fonts.mono(8.5, weight: 700))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Barre latérale

private struct Sidebar: View {
    var model: AppModel

    private var stemCount: Int { model.mix.strips.reduce(0) { $0 + $1.stems.count } }

    private var projectState: String {
        guard let url = model.projectURL else { return "not saved yet" }
        return url.lastPathComponent + (model.hasUnsavedChanges ? " · saving…" : " · saved")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Text("DUB").foregroundStyle(Theme.delay))\(Text("STEM").foregroundStyle(Theme.reverb))\(Text("MIX").foregroundStyle(Theme.bus3))")
                .font(Fonts.label(21, weight: 900, width: 122))
                .tracking(0.5)
                .padding(.bottom, 22)

            Text("SESSION")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Theme.textDim)
            Text(model.title.isEmpty ? "—" : model.title)
                .font(Fonts.label(13, weight: 800))
                .tracking(1)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            if !model.title.isEmpty {
                Text(projectState)
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(model.projectURL == nil ? Theme.delay : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 2)
            }
            if !model.unresolvedStems.isEmpty {
                SmallButton(title: "LOCATE \(model.unresolvedStems.count) MISSING STEM(S)…", color: Theme.rec) {
                    model.locateMissingStems()
                }
                .padding(.top, 8)
            }

            SplitZone(model: model)
                .padding(.top, 20)

            if !model.pool.isEmpty || stemCount > 0 {
                StemPool(model: model)
                    .padding(.top, 20)
            }

            SetlistSection(model: model)
                .padding(.top, 20)

            if model.title.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Hint(key: "SEND ALL", text: "sync the app to the console")
                    Hint(key: "REC ARM", text: "hold = dub throw to the delay")
                    Hint(key: "BANK LEFT / RIGHT", text: "knobs = sends / effect settings")
                    Hint(key: "SOLO + MUTE", text: "solo a strip (⌥-click on screen)")
                    Hint(key: "SPACE · RETURN · L", text: "play / back to start / loop")
                    Hint(key: "D (hold) · R", text: "drop all but KEEP strips / pull-up rewind")
                    Hint(key: "H (hold) · C", text: "hold the echo / crash the spring")
                    Hint(key: "T", text: "tap tempo")
                    Hint(key: "N · P", text: "next / previous song of the setlist")
                    Hint(key: "⌘R", text: "record the master (24-bit WAV)")
                }
                .padding(.top, 22)
            }

            Spacer()

            if let warning = model.midiWarning {
                MappingWarning(message: warning)
                    .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 7) {
                StatusLine(
                    color: model.midiWarning != nil ? Theme.delay : (model.midiConnected ? Theme.reverb : Theme.rec),
                    title: "MIDIMIX",
                    detail: model.midiWarning != nil ? "custom mapping?" : (model.midiConnected ? "connected" : "not found")
                )
                StatusLine(color: Theme.reverb, title: "AUDIO", detail: model.audioDevice, sub: model.audioFormat)
                StatusLine(
                    color: model.dropouts > 0 ? Theme.rec : (model.dspLoad > 0.7 ? Theme.delay : Theme.reverb),
                    title: "DSP",
                    detail: "\(Int((model.dspLoad * 100).rounded()))% · \(model.dropouts) dropout\(model.dropouts == 1 ? "" : "s")"
                )
                .help("Worst audio-thread load over the last moments, and dropouts reported by the audio device since launch")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }
}

/// The one place where a dropped file is split into stems (PRD § 12.1); shows the job while it runs.
private struct SplitZone: View {
    var model: AppModel

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SPLIT A SONG")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Theme.textDim)
            switch model.separation {
            case .idle:
                dropTarget
            case let .downloading(received, total):
                progressBox(title: "DOWNLOADING THE ENGINE", detail: "\(received / 1_000_000) / \(total / 1_000_000) MB",
                            fraction: Double(received) / Double(max(1, total)))
            case let .splitting(song, stem, fraction, started):
                progressBox(title: song.uppercased(), detail: splitDetail(stem: stem, fraction: fraction, started: started), fraction: fraction)
            }
        }
    }

    private var dropTarget: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Drop a full mix here")
                .font(Fonts.label(12, weight: 800))
                .tracking(0.8)
                .foregroundStyle(targeted ? Theme.bg : Theme.text)
            Text(model.modelStatus == .ready ? "→ drums, bass, instruments, vocals on strips 1–4" : "engine not downloaded yet (asks first)")
                .font(Fonts.mono(9))
                .foregroundStyle(targeted ? Theme.bg.opacity(0.7) : Theme.textDim)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(targeted ? Theme.text : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(targeted ? Theme.text : Theme.textDim.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .contentShape(Rectangle())
        .stemDrop(enabled: !model.isPreview, isTargeted: $targeted) { urls in
            if let first = urls.first { model.splitSong(first) }
        }
        .onTapGesture { model.chooseSongToSplit() }
        .help("Drop one WAV, MP3, AIFF, FLAC or M4A file (or click to choose)")
    }

    private func progressBox(title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Fonts.label(12, weight: 800))
                .tracking(0.8)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border).frame(height: 4)
                GeometryReader { geo in
                    Capsule().fill(Theme.delay).frame(width: geo.size.width * min(1, max(0, fraction)), height: 4)
                }
                .frame(height: 4)
            }
            HStack {
                Text(detail).font(Fonts.mono(9)).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer()
                Button("CANCEL") { model.cancelSeparation() }
                    .buttonStyle(.plain)
                    .font(Fonts.mono(9, weight: 700))
                    .foregroundStyle(Theme.rec)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.delay, lineWidth: 1))
    }

    private func splitDetail(stem: Stem, fraction: Double, started: Date) -> String {
        let elapsed = Date().timeIntervalSince(started)
        var text = "\(stem.rawValue)… \(Int(fraction * 100)) %"
        if fraction > 0.02 {
            let remaining = Int(elapsed * (1 - fraction) / fraction)
            text += " · \(remaining / 60):\(String(format: "%02d", remaining % 60)) left"
        }
        return text
    }
}

/// Réserve : les fichiers importés attendent ici que l'utilisateur les pose sur une tranche.
private struct StemPool: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEMS TO PLACE")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Theme.textDim)
            if model.pool.isEmpty {
                Text("All stems are on a strip.")
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Theme.textDim)
            } else {
                Text("Drag onto a strip — or right-click")
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Theme.textDim)
                if model.isPreview { rows } else { ScrollView { rows }.frame(maxHeight: 180) }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(model.pool) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(Fonts.label(12, weight: 800))
                        .tracking(0.8)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(item.url.lastPathComponent)
                        .font(Fonts.mono(8.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
                .draggableStem(item.url, enabled: !model.isPreview)
                .contextMenu {
                    Menu("Place on strip") {
                        ForEach(0..<AudioEngine.stripCount, id: \.self) { strip in
                            Button("\(strip + 1)") { model.assign([item.url], toStrip: strip) }
                        }
                    }
                    Button("Remove", role: .destructive) { model.removeFromPool(item.url) }
                }
            }
        }
    }
}

/// Setlist : les morceaux (projets enregistrés) dans l'ordre du set. Un clic charge le morceau, à l'arrêt.
private struct SetlistSection: View {
    var model: AppModel

    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if renaming {
                    TextField("Setlist name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(Fonts.mono(9.5))
                        .foregroundStyle(Theme.text)
                        .onSubmit {
                            model.renameSetlist(draftName)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                        .onAppear { draftName = model.setlist?.name ?? "" }
                } else {
                    Text(model.setlist.map { $0.name.isEmpty ? "SETLIST" : "SETLIST · \($0.name)" } ?? "SETLIST")
                        .font(Fonts.mono(9.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if model.setlist != nil { renaming = true } }
                        .contextMenu { if model.setlist != nil { Button("Rename…") { renaming = true } } }
                        .help(model.setlist == nil ? "" : "Double-click to rename the setlist")
                }
                Spacer()
                if model.setlist != nil {
                    Button { model.closeSetlist() } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Close the setlist")
                }
            }
            if model.isPreview { rows } else { ScrollView { rows }.frame(maxHeight: 260) }
            if !model.title.isEmpty, model.setlistIndex == nil {
                SmallButton(title: "+ ADD THIS SONG", color: Theme.textDim) { model.addCurrentProjectToSetlist() }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 3) {
            ForEach(Array(model.setlistEntries.enumerated()), id: \.element.id) { index, entry in
                let current = index == model.setlistIndex
                let next = model.setlistIndex.map { index == $0 + 1 } ?? false
                HStack(spacing: 9) {
                    Text(String(format: "%02d", index + 1))
                        .font(Fonts.mono(10))
                        .foregroundStyle(current ? Theme.bg.opacity(0.6) : Theme.textDim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(Fonts.label(12.5, weight: current ? 800 : 600, width: 104))
                            .foregroundStyle(current ? Theme.bg : (entry.url == nil ? Theme.rec : Theme.text))
                            .lineLimit(1)
                        Text(details(entry, next: next))
                            .font(Fonts.mono(9))
                            .foregroundStyle(current ? Theme.bg.opacity(0.6) : (next ? Theme.reverb : Theme.textDim))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.text : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.openSetlistEntry(at: index) }
                .setlistDrag(entry, model: model)
                .contextMenu {
                    Button("Move up") { model.moveInSetlist(entry, by: -1) }
                    Button("Move down") { model.moveInSetlist(entry, by: 1) }
                    Button("Remove from setlist", role: .destructive) { model.removeFromSetlist(entry) }
                }
            }
        }
    }

    private func details(_ entry: SetlistEntry, next: Bool) -> String {
        guard entry.url != nil else { return "project not found" }
        var parts: [String] = []
        if let bpm = entry.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        parts.append(String(format: "%d:%02d", Int(entry.duration) / 60, Int(entry.duration) % 60))
        if next { parts.append("NEXT (N)") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// Setlist rows can be dragged onto one another to reorder the set (disabled for PNG captures).
    @ViewBuilder
    fileprivate func setlistDrag(_ entry: SetlistEntry, model: AppModel) -> some View {
        if model.isPreview {
            self
        } else {
            draggable(entry.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, let dragged = model.setlistEntries.first(where: { $0.id.uuidString == id }) else { return false }
                    model.moveInSetlist(dragged, onto: entry)
                    return true
                }
        }
    }
}

private struct SmallButton: View {
    var title: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.mono(9.5, weight: 700))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 24)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Hint: View {
    var key: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(Fonts.mono(9.5, weight: 700)).foregroundStyle(Theme.text)
            Text(text).font(Fonts.mono(9.5)).foregroundStyle(Theme.textDim)
        }
    }
}

/// The console sent something the factory mapping does not know (PRD § 4): how to put it back.
private struct MappingWarning: View {
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CONSOLE NOT ON FACTORY MAPPING")
                .font(Fonts.mono(9.5, weight: 700))
                .foregroundStyle(Theme.delay)
            Text("Received \(message), which the MIDImix does not send out of the box. Knobs, faders or buttons may not respond.")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Theme.textDim)
            Text("Fix: open the Akai MIDImix Editor, File ▸ New (factory mapping), then Send to Hardware. Then unplug and replug the console.")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Theme.text)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.delay, lineWidth: 1.5))
    }
}

private struct StatusLine: View {
    var color: Color
    var title: String
    var detail: String
    /// Optional second line, under the detail.
    var sub: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(Fonts.mono(9.5, weight: 700)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(detail).font(Fonts.mono(9.5)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                if let sub { Text(sub).font(Fonts.mono(9.5)).foregroundStyle(Theme.textDim).lineLimit(1) }
            }
        }
    }
}
