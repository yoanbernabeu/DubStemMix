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
                    .overlay(alignment: .topTrailing) {
                        if let index = model.armedIndex { ArmedSong(model: model, index: index).padding(8) }
                    }
                FXRack(model: model)
                    .frame(height: FXRackLayout.height)
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
        .background { if !model.isPreview { CloseGuard(model: model) } }
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

/// Puts `WindowCloseGuard` in front of the window's delegate, once the view is in its window.
private struct CloseGuard: NSViewRepresentable {
    var model: AppModel

    final class Coordinator {
        var guardian: WindowCloseGuard?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { install(on: view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { install(on: view.window, context.coordinator) }
    }

    private func install(on window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, coordinator.guardian == nil || window.delegate !== coordinator.guardian else { return }
        let model = model
        let guardian = WindowCloseGuard(original: window.delegate) { model.confirmWhilePlaying("Quit") }
        coordinator.guardian = guardian // the window holds its delegate weakly
        window.delegate = guardian
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

    @State private var renaming = false

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
                if model.title.isEmpty {
                    Text("NO STEMS LOADED")
                        .font(Fonts.label(17, weight: 850, width: 118))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textDim)
                } else {
                    EditableTitle(text: model.title, editing: $renaming, onCommit: model.renameSong) {
                        Text(model.title).lineLimit(1).help("Double-click to rename the song")
                    }
                    .font(Fonts.label(17, weight: 850, width: 118))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text)
                }
                HStack(spacing: 6) {
                    Text(timecode(model.position, tenths: true))
                        .font(Fonts.mono(13, weight: 700))
                        .foregroundStyle(Theme.text)
                    Text("/ " + timecode(model.duration, tenths: false))
                        .font(Fonts.mono(13))
                        .foregroundStyle(Theme.textDim)
                    if model.duration > 0 {
                        Text("· −" + timecode(model.remaining.rounded(.up), tenths: false))
                            .font(Fonts.mono(13, weight: model.nearEnd ? 700 : 400))
                            .foregroundStyle(model.nearEnd ? Theme.bus3 : Theme.textDim)
                            .help("Time left in the song")
                    }
                }
            }

            Spacer()

            if let notice = model.notice {
                Text(notice).font(Fonts.mono(11)).foregroundStyle(Theme.delay).lineLimit(1)
            }

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

/// The song armed while this one plays, blinking: Space (or the pull-up) launches it.
private struct ArmedSong: View {
    var model: AppModel
    var index: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            VStack(alignment: .leading, spacing: 1) {
                Text("NEXT ▸ \(model.setlistEntries[index].title.uppercased())")
                    .font(Fonts.label(12, weight: 850))
                    .tracking(0.8)
                    .foregroundStyle(on ? Theme.bg : Theme.delay)
                    .lineLimit(1)
                Text(model.armWarning.map { "SPACE · \($0)" } ?? "SPACE to drop · R to pull up")
                    .font(Fonts.mono(9))
                    .foregroundStyle(on ? Theme.bg.opacity(0.75) : (model.armWarning == nil ? Theme.textDim : Theme.rec))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.delay : Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.delay, lineWidth: 1.5))
        }
        .fixedSize()
        .help("Space drops it now (the effect tails go on) · R pulls up into it · N / P arm another · click the current song to cancel")
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

// MARK: - Forme d'onde (clic ou glissé = déplacement ; en lecture, double-clic ou ⌥-clic)

private struct WaveformOverview: View {
    var model: AppModel

    @State private var lastClick: Date?

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
                    // The last seconds turn orange: time to arm the next song.
                    let playedColor = model.nearEnd ? Theme.bus3 : Theme.text
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
                                with: .color(played ? playedColor : Theme.textDim.opacity(0.45))
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
                    // While playing, a stray click must not jump: a double-click or an ⌥-click does.
                    let now = Date.now
                    let double = lastClick.map { now.timeIntervalSince($0) < NSEvent.doubleClickInterval } ?? false
                    lastClick = now
                    model.seekFromWaveform(fraction: min(1, max(0, drag.location.x / geo.size.width)),
                                           deliberate: double || NSEvent.modifierFlags.contains(.option))
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
        HStack(spacing: FXRackLayout.spacing) {
            ForEach(Bus.allCases, id: \.self) { bus in FXSlotCard(model: model, bus: bus) }
        }
        // The cables hang below the cards, in the gap above the console.
        .overlay(alignment: .top) {
            BusCables(model: model)
                .frame(height: FXRackLayout.height + FXRackLayout.cableDrop)
                .allowsHitTesting(false)
        }
    }
}

enum FXRackLayout {
    static let height: CGFloat = 64
    static let spacing: CGFloat = 8
    /// Room the cables take below the cards (the rack's gap to the console is 14).
    static let cableDrop: CGFloat = 13

    /// Where a bus's cable leaves (out) or arrives (in), on the bottom edge of its card.
    static func jack(_ bus: SendBus, out: Bool, width: CGFloat) -> CGPoint {
        let count = CGFloat(SendBus.allCases.count)
        let card = (width - spacing * (count - 1)) / count
        let x = CGFloat(bus.rawValue) * (card + spacing) + card * (out ? 0.62 : 0.38)
        return CGPoint(x: x, y: height)
    }
}

/// Bus-to-bus sends drawn as patch cables between the cards (issue #1): each routed bus's return leaves by its
/// out jack and plugs into its target's in jack. Dashed while its knob is at zero; lit by the signal it carries.
private struct BusCables: View {
    var model: AppModel

    var body: some View {
        let routes = SendBus.allCases.compactMap { source in
            model.busRouting.target(of: source).map { target in
                (source: source, target: target,
                 level: model.mix.fx[FXParameter.busSend(from: source)] ?? 0,
                 flow: model.activity(AudioEngine.busReturnMeter(source)))
            }
        }
        let phase = Date.timeIntervalSinceReferenceDate * 24
        Canvas { context, size in
            for route in routes {
                let from = FXRackLayout.jack(route.source, out: true, width: size.width)
                let to = FXRackLayout.jack(route.target, out: false, width: size.width)
                let low = FXRackLayout.height + FXRackLayout.cableDrop * 1.33 // the curve bottoms out at cableDrop
                var cable = Path()
                cable.move(to: from)
                cable.addCurve(to: to, control1: CGPoint(x: from.x, y: low), control2: CGPoint(x: to.x, y: low))
                let color = Bus(rawValue: route.source.rawValue)!.color
                if route.level < 0.005 {
                    context.stroke(cable, with: .color(Theme.textDim.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
                } else {
                    let width = 2 + 2 * route.level
                    context.stroke(cable, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    // The signal travelling down the cable, as bright as what the source bus gives back.
                    let carried = route.flow * min(1, route.level * 2)
                    if carried > 0.02 {
                        context.stroke(cable, with: .color(Theme.text.opacity(carried)),
                                       style: StrokeStyle(lineWidth: width * 0.6, lineCap: .round, dash: [3, 9], dashPhase: -phase))
                    }
                }
                for (point, jackColor) in [(from, color), (to, Bus(rawValue: route.target.rawValue)!.color)] {
                    let jack = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                    context.fill(jack, with: .color(Theme.bg))
                    context.stroke(jack, with: .color(jackColor), lineWidth: 1.5)
                }
            }
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
            BusInputBar(model: model, bus: sendBus)
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
        .background {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
            BusGlow(model: model, bus: sendBus, part: .fill)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .overlay(BusGlow(model: model, bus: sendBus, part: .border))
    }

    /// Le nom de l'effet est un menu : effet intégré, ou un plugin AU (rangés par éditeur).
    private var slotMenu: some View {
        Menu {
            if bus == .reverb {
                ForEach(ReverbModel.allCases, id: \.self) { reverb in
                    Button((plugin == nil && reverb == model.reverbModel ? "✓ " : "") + "Built-in · \(reverb.label)") {
                        model.pickBuiltInEffect(on: sendBus, reverb: reverb)
                    }
                }
            } else if bus == .bus3 {
                ForEach(Bus3Model.allCases, id: \.self) { effect in
                    Button((plugin == nil && effect == model.bus3Model ? "✓ " : "") + "Built-in · \(effect.label)") {
                        model.pickBuiltInEffect(on: sendBus, bus3: effect)
                    }
                }
            } else {
                Button((plugin == nil ? "✓ " : "") + "Built-in · \(builtInName)") { model.pickBuiltInEffect(on: sendBus) }
            }
            if plugin != nil {
                Button("Open plugin window") { model.openPluginWindow(on: sendBus) }
            }
            // Bus-to-bus send (issue #1): targets that would close a loop are disabled.
            Menu("Send to · \(model.busRouting.target(of: sendBus).map { model.busMenuName($0) } ?? "None")") {
                Button((model.busRouting.target(of: sendBus) == nil ? "✓ " : "") + "None") { model.pickBusSend(from: sendBus, to: nil) }
                ForEach(SendBus.allCases.filter { $0 != sendBus }, id: \.self) { target in
                    Button((model.busRouting.target(of: sendBus) == target ? "✓ " : "") + model.busMenuName(target)) {
                        model.pickBusSend(from: sendBus, to: target)
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
                        Button((plugin?.info.id == info.id ? "✓ " : "") + info.name) { model.pickPlugin(info, on: sendBus) }
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

/// The card's color bar doubles as the bus's input meter: it fills from the bottom with what enters the bus.
/// Only this view and `BusGlow` redraw 30 times a second, not the whole card.
private struct BusInputBar: View {
    var model: AppModel
    var bus: SendBus

    var body: some View {
        let color = Bus(rawValue: bus.rawValue)!.color
        let level = model.activity(AudioEngine.busInputMeter(bus))
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(0.3))
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(height: geometry.size.height * max(0.12, level))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: 5)
    }
}

/// The card lights up in its bus's color while its effect sounds, tails included: a tint behind the content
/// and a border over it.
private struct BusGlow: View {
    enum Part { case fill, border }

    var model: AppModel
    var bus: SendBus
    var part: Part

    var body: some View {
        let color = Bus(rawValue: bus.rawValue)!.color
        let glow = model.activity(AudioEngine.busReturnMeter(bus))
        // PANIC: one white flash, fading out in half a second.
        let flash = model.panicFlash.map { max(0, 1 - Date.now.timeIntervalSince($0) / 0.5) } ?? 0
        let shape = RoundedRectangle(cornerRadius: 8)
        Group {
            switch part {
            case .fill: shape.fill(color.opacity(0.1 * glow)).overlay(shape.fill(Theme.text.opacity(0.25 * flash)))
            case .border: shape.stroke(flash > 0 ? Theme.text.opacity(flash) : color.opacity(0.85 * glow), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
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
                    Hint(key: "ESC · BANK LEFT + RIGHT", text: "panic: empty the effects")
                    Hint(key: "T", text: "tap tempo")
                    Hint(key: "N · P", text: "next / previous song (armed while playing)")
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
                            Button("\(strip + 1)") { model.placeStems([item.url], onStrip: strip) }
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
    @State private var renamingEntry: UUID?
    @State private var dropTargeted = false

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
                        .contextMenu {
                            if model.setlist != nil {
                                Button("Rename…") { renaming = true }
                                Button("Save As…") { model.saveSetlistAs() }
                                Button("Export for Another Mac…") { model.exportSetlist() }.disabled(model.exportTask != nil)
                                Divider()
                            }
                            Button("New Setlist…") { model.newSetlist() }
                        }
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
            if !model.setlistEntries.isEmpty {
                Text(totalLine)
                    .font(Fonts.mono(9))
                    .foregroundStyle(Theme.textDim)
            }
            if model.isPreview { rows } else { ScrollView { rows }.frame(maxHeight: 260) }
            exportStatus
            if model.setlistHasMissingStems {
                SmallButton(title: "LOCATE MISSING STEMS…", color: Theme.rec) { model.locateMissingStemsInSetlist() }
                    .help("One folder for the whole setlist: missing stems are looked for by name in it and its subfolders")
            }
            if !model.title.isEmpty, model.setlistIndex == nil {
                SmallButton(title: "+ ADD THIS SONG", color: Theme.textDim) { model.addCurrentProjectToSetlist() }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).stroke(dropTargeted ? Theme.reverb : .clear, lineWidth: 1.5))
        .padding(-4)
        .stemDrop(enabled: !model.isPreview, isTargeted: $dropTargeted) { urls in
            // Projects join the setlist; anything else (stems, a setlist) opens as it would anywhere in the window.
            let projects = urls.filter { $0.pathExtension == Project.fileExtension }
            if projects.isEmpty { model.open(urls) } else { model.addToSetlist(projects) }
        }
    }

    private var rows: some View {
        VStack(spacing: 3) {
            ForEach(Array(model.setlistEntries.enumerated()), id: \.element.id) { index, entry in
                let current = index == model.setlistIndex
                let armed = index == model.armedIndex
                let next = !armed && model.armedIndex == nil && (model.setlistIndex.map { index == $0 + 1 } ?? false)
                HStack(spacing: 9) {
                    Text(String(format: "%02d", index + 1))
                        .font(Fonts.mono(10))
                        .foregroundStyle(current ? Theme.bg.opacity(0.6) : Theme.textDim)
                    VStack(alignment: .leading, spacing: 1) {
                        EditableTitle(text: entry.title, editing: renamingBinding(entry), doubleClick: false,
                                      onCommit: { model.renameSetlistEntry(entry, to: $0) }) {
                            Text((entry.problems.isEmpty ? "" : "⚠ ") + entry.title).lineLimit(1)
                        }
                        .font(Fonts.label(12.5, weight: current ? 800 : 600, width: 104))
                        .foregroundStyle(current ? Theme.bg : (entry.url == nil || !entry.problems.isEmpty ? Theme.rec : Theme.text))
                        Text(details(entry, next: next, armed: armed))
                            .font(Fonts.mono(9))
                            .foregroundStyle(current ? Theme.bg.opacity(0.6) : (armed ? Theme.delay : (next ? Theme.reverb : Theme.textDim)))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.text : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(armed ? Theme.delay : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
                .help(help(entry))
                .onTapGesture { model.openSetlistEntry(at: index) }
                .setlistDrag(entry, model: model)
                .contextMenu {
                    Button("Rename…") { renamingEntry = entry.id }.disabled(entry.url == nil)
                    Button("Move up") { model.moveInSetlist(entry, by: -1) }
                    Button("Move down") { model.moveInSetlist(entry, by: 1) }
                    Button("Remove from setlist", role: .destructive) { model.removeFromSetlist(entry) }
                }
            }
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.setlistExport {
        case .idle:
            EmptyView()
        case let .exporting(fraction):
            Text("EXPORTING… \(Int(fraction * 100)) %")
                .font(Fonts.mono(9.5, weight: 700))
                .foregroundStyle(Theme.delay)
        case let .done(folder, songs, missing, plugins):
            SmallButton(title: "EXPORTED \(songs) SONG\(songs == 1 ? "" : "S") — SHOW IN FINDER", color: Theme.reverb) {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            .help(plugins > 0 ? "PLUGINS.txt lists the Audio Unit plugins to install on the other Mac" : "")
            if !missing.isEmpty {
                Text("⚠ \(missing.count) NOT FOUND, NOT EXPORTED")
                    .font(Fonts.mono(9))
                    .foregroundStyle(Theme.rec)
                    .help(missing.joined(separator: "\n"))
            }
        case let .failed(message):
            Text("EXPORT FAILED: \(message)")
                .font(Fonts.mono(9))
                .foregroundStyle(Theme.rec)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "7 SONGS · 48:12": the length of the set, to fit a slot.
    private var totalLine: String {
        let count = model.setlistEntries.count
        let seconds = Int(model.setlistEntries.map(\.duration).reduce(0, +))
        let length = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(count) SONG\(count == 1 ? "" : "S") · \(length)"
    }

    private func renamingBinding(_ entry: SetlistEntry) -> Binding<Bool> {
        Binding(get: { renamingEntry == entry.id }, set: { renamingEntry = $0 ? entry.id : nil })
    }

    private func details(_ entry: SetlistEntry, next: Bool, armed: Bool) -> String {
        guard entry.url != nil else { return "project not found" }
        var parts: [String] = []
        if let bpm = entry.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        parts.append(String(format: "%d:%02d", Int(entry.duration) / 60, Int(entry.duration) % 60))
        if entry.ownRack { parts.append("≠ RACK") }
        if armed { parts.append("ARMED") } else if next { parts.append("NEXT (N)") }
        return parts.joined(separator: " · ")
    }

    private func help(_ entry: SetlistEntry) -> String {
        var lines = entry.problems
        if entry.ownRack { lines.append("Rack differs, setlist rack used") }
        return lines.joined(separator: "\n")
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
                    guard let id = ids.first, let dragged = model.setlistEntries.first(where: { $0.id.uuidString == id }) else {
                        // Projects dragged from the Finder can arrive here as text.
                        let urls = ids.compactMap(URL.init(string:)).filter(\.isFileURL)
                        model.addToSetlist(urls)
                        return !urls.isEmpty
                    }
                    model.moveInSetlist(dragged, onto: entry)
                    return true
                }
        }
    }
}

/// A title that turns into a text field on double-click (or when `editing` is set, e.g. from a context menu).
/// Return commits, Escape cancels.
private struct EditableTitle<Label: View>: View {
    var text: String
    @Binding var editing: Bool
    var doubleClick = true
    var onCommit: (String) -> Void
    @ViewBuilder var label: () -> Label

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    onCommit(draft)
                    editing = false
                }
                .onExitCommand { editing = false }
                .onAppear {
                    draft = text
                    focused = true
                }
        } else if doubleClick {
            label().contentShape(Rectangle()).onTapGesture(count: 2) { editing = true }
        } else {
            label()
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
