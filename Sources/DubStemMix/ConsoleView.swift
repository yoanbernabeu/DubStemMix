import DubStemMixCore
import SwiftUI

// Miroir de la MIDImix : 8 tranches (3 potards, MUTE, REC ARM/throw, fader) + colonne master.

// Chaque tranche a deux zones : en haut les potards (envois, ou réglages d'effets sur la page FX),
// en bas ce qui appartient au stem sur les deux pages (nom, MUTE, THROW, fader).
private let knobCellHeight: CGFloat = 92
private let headerHeight: CGFloat = 30
private let namePlateHeight: CGFloat = 28

/// What a strip's knobs drive on the FX, MASTER or INSERTS page: the header title and tint of the knob zone.
@MainActor
private func fxGroup(strip: Int, model: AppModel) -> (title: String, color: Color)? {
    let mix = model.mix
    switch mix.page {
    case .mix:
        return nil
    case .inserts:
        let state = mix.strips[strip]
        if state.insertHosted { return ("AU", Theme.text) }
        return state.insert.map { ($0.shortLabel, Theme.text) }
    case .master:
        let parameters = FXParameter.masterLayout[strip].compactMap { $0 }
        guard let title = parameters.first?.masterGroup else { return nil }
        let color = parameters.first?.bus.map { Bus(rawValue: $0.rawValue)!.color } ?? Theme.text
        return (title, color)
    case .fx:
        let parameters = FXParameter.layout[strip].compactMap { $0 }
        if !parameters.isEmpty, parameters.allSatisfy(\.isBusSend) { return ("ROUTING", Theme.text) }
        let buses = Set(parameters.compactMap(\.bus))
        guard let first = buses.first else { return nil }
        if buses.count > 1 { return ("RETURNS", Theme.text) }
        let bus = Bus(rawValue: first.rawValue)!
        return (model.busLabel(first), bus.color)
    }
}

struct ConsoleView: View {
    var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RowLabels(page: model.mix.page, names: SendBus.allCases.map(model.busLabel))
                .frame(width: 70)
            ForEach(0..<AudioEngine.stripCount, id: \.self) { index in
                StripView(model: model, index: index)
            }
            MasterView(model: model)
                .frame(width: 118)
        }
    }
}

private struct RowLabels: View {
    var page: MixController.Page
    var names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: headerHeight)
            ForEach(Bus.allCases, id: \.self) { bus in
                VStack(alignment: .leading, spacing: 3) {
                    if page == .mix {
                        RoundedRectangle(cornerRadius: 1.5).fill(bus.color).frame(width: 22, height: 4)
                        Text(names[bus.rawValue])
                            .font(Fonts.label(11, weight: 800))
                            .tracking(1.2)
                            .foregroundStyle(bus.color)
                        Text("SEND")
                            .font(Fonts.mono(9))
                            .foregroundStyle(Theme.textDim)
                    } else {
                        Text(["TOP", "MID", "LOW"][bus.rawValue])
                            .font(Fonts.mono(10))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                .frame(height: knobCellHeight, alignment: .center)
            }
        }
    }
}

private struct StripView: View {
    var model: AppModel
    var index: Int

    @State private var dropTargeted = false
    @State private var renaming = false
    @State private var draftName = ""

    private var strip: MixController.Strip { model.mix.strips[index] }
    private var isEmpty: Bool { strip.stems.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: headerHeight)

            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    knobCell(row).frame(height: knobCellHeight)
                }
            }
            .frame(maxWidth: .infinity)
            .background(knobZoneBackground)

            namePlate.frame(height: namePlateHeight)

            VStack(spacing: 6) {
                // ⌥-clic = solo (sur la console : SOLO maintenu + MUTE).
                StripButton(title: strip.solo ? "SOLO" : "MUTE", active: strip.mute || strip.solo) {
                    if NSEvent.modifierFlags.contains(.option) || strip.solo {
                        model.mix.toggleSolo(strip: index)
                    } else {
                        model.mix.toggleMute(strip: index)
                    }
                }
                MomentaryButton(title: "THROW", active: strip.throwing, activeColor: Theme.delay) {
                    model.mix.setThrow(strip: index, $0)
                }
                keepMark
            }

            HStack(alignment: .center, spacing: 8) {
                Fader(
                    value: Binding(get: { strip.fader }, set: { model.mix.setFader(strip: index, $0) }),
                    ghost: model.mix.faderGhost(strip: index)
                )
                LiveMeter(model: model, index: index)
            }
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity)

            stems.frame(height: 42, alignment: .top)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: strip.throwing || dropTargeted ? 2 : 1)
        )
        .opacity(isEmpty && !dropTargeted ? 0.45 : 1)
        .stemDrop(enabled: !model.isPreview, isTargeted: $dropTargeted) { model.placeStems($0, onStrip: index) }
    }

    private var borderColor: Color {
        if strip.throwing { return Theme.delay }
        return dropTargeted ? Theme.text : Theme.border
    }

    private var group: (title: String, color: Color)? { fxGroup(strip: index, model: model) }

    /// En-tête de la zone des potards : sur la page FX, l'effet qu'ils pilotent — pas le stem.
    /// On the INSERTS page the title is the insert menu.
    private var header: some View {
        HStack(spacing: 5) {
            Text("\(index + 1)")
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.textDim)
            if model.mix.page == .inserts {
                Menu { insertMenuItems } label: {
                    HStack(spacing: 3) {
                        Text(model.loadingInsert.contains(index) ? "LOADING…" : (group?.title ?? "INSERT"))
                            .font(Fonts.label(11, weight: 850))
                            .tracking(1.2)
                            .foregroundStyle(group == nil ? Theme.textDim : Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Theme.textDim)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isPreview)
            } else if let group {
                Text(group.title)
                    .font(Fonts.label(11, weight: 850))
                    .tracking(1.2)
                    .foregroundStyle(group.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// KEEP mark: this strip survives the DROP gesture (PRD § 11.6). Belongs to the stem, like MUTE and THROW.
    private var keepMark: some View {
        Button { model.toggleKeep(strip: index) } label: {
            Text("KEEP")
                .font(Fonts.mono(9, weight: 700))
                .tracking(0.8)
                .foregroundStyle(strip.keep ? Theme.bg : Theme.textDim)
                .frame(maxWidth: .infinity, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(strip.keep ? Theme.text : .clear))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(strip.keep ? Theme.text : Theme.border, style: StrokeStyle(lineWidth: 1, dash: strip.keep ? [] : [3, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Keep this strip playing during DROP (hold D)")
    }

    /// Page FX : la zone des potards prend la teinte de l'effet, pour qu'on voie qu'elle a changé de rôle.
    @ViewBuilder
    private var knobZoneBackground: some View {
        if let group {
            RoundedRectangle(cornerRadius: 6)
                .fill(group.color.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(group.color.opacity(0.35), lineWidth: 1))
        }
    }

    /// Le nom du stem, collé à ce qui lui appartient sur les deux pages : MUTE, THROW et le fader.
    /// Double-click (or right-click) to type a name; an empty name goes back to the file's.
    @ViewBuilder
    private var namePlate: some View {
        if renaming {
            TextField("", text: $draftName)
                .textFieldStyle(.plain)
                .font(Fonts.label(14, weight: 850, width: 118))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = false }
                .onAppear { draftName = model.stripNames[index] ?? "" }
        } else {
            Text(isEmpty ? "—" : strip.name)
                .font(Fonts.label(14, weight: 850, width: 118))
                .tracking(0.8)
                .foregroundStyle(model.mix.isAudible(strip: index) ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if !isEmpty { renaming = true } }
                .contextMenu {
                    if !isEmpty {
                        Button("Rename…") { renaming = true }
                        if model.stripNames[index] != nil {
                            Button("Use the file name") { model.renameStrip(index, "") }
                        }
                    }
                    Menu("Insert") { insertMenuItems }
                }
                .help(isEmpty ? "" : "Double-click to rename the strip")
        }
    }

    private func commitRename() {
        model.renameStrip(index, draftName)
        renaming = false
    }

    @ViewBuilder
    private func knobCell(_ row: Int) -> some View {
        if model.mix.page == .mix {
            sendCell(row)
        } else if case let .parameter(parameter) = model.mix.cell(strip: index, row: row) {
            fxCell(parameter)
        } else if case let .macro(bus, macro) = model.mix.cell(strip: index, row: row) {
            macroCell(bus: bus, index: macro)
        } else if case let .insert(_, parameter) = model.mix.cell(strip: index, row: row) {
            insertCell(parameter)
        } else if case let .insertMacro(_, macro) = model.mix.cell(strip: index, row: row) {
            insertMacroCell(macro)
        } else {
            Circle()
                .stroke(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                .frame(width: 44, height: 44)
        }
    }

    /// Page FX : le potard pilote un paramètre d'effet, aux couleurs de son bus.
    private func fxCell(_ parameter: FXParameter) -> some View {
        let value = model.mix.fx[parameter] ?? 0
        let color = parameter.bus.map { Bus(rawValue: $0.rawValue)!.color } ?? Theme.text // master: cream
        // A bus-to-bus send: arc in its source's color, pointer and arrow in its target's, dimmed when it feeds no bus.
        let sendTarget = parameter.isBusSend ? parameter.bus.flatMap { model.busRouting.target(of: $0) } : nil
        let targetColor = sendTarget.map { Bus(rawValue: $0.rawValue)!.color }
        let unrouted = parameter.isBusSend && sendTarget == nil
        return VStack(spacing: 2) {
            Knob(
                value: Binding(get: { value }, set: { model.mix.setFX(parameter, $0) }),
                color: color,
                ghost: model.mix.fxGhost(parameter),
                size: 54,
                pointer: targetColor
            )
            .opacity(unrouted ? 0.4 : 1)
            fxLabel(parameter, color: color, targetColor: targetColor)
                .font(Fonts.label(9.5, weight: 800))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(model.mix.fxDisplay(parameter))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.text)
        }
    }

    private func fxLabel(_ parameter: FXParameter, color: Color, targetColor: Color?) -> Text {
        guard parameter.isBusSend, let source = parameter.bus else { return Text(model.fxLabel(parameter)).foregroundStyle(color) }
        let target = model.busRouting.target(of: source).map(model.busShortName) ?? "—"
        return Text(model.busShortName(source)).foregroundStyle(color)
            + Text("→" + target).foregroundStyle(targetColor ?? Theme.textDim)
    }

    /// Bus hébergeant un plugin : le potard est une macro, affectée par l'utilisateur à un paramètre du plugin.
    private func macroCell(bus: SendBus, index macro: Int) -> some View {
        let value = model.mix.macros[bus]?[macro] ?? 0
        let color = Bus(rawValue: bus.rawValue)!.color
        let target = model.macroTarget(bus: bus, index: macro)
        return VStack(spacing: 2) {
            Knob(
                value: Binding(get: { value }, set: { model.mix.setMacro(bus: bus, index: macro, $0) }),
                color: color,
                ghost: model.mix.macroGhost(bus: bus, index: macro),
                size: 54
            )
            .opacity(target == nil ? 0.35 : 1)
            .allowsHitTesting(target != nil)
            Menu {
                Button("None") { model.assignMacro(nil, bus: bus, index: macro) }
                Divider()
                ForEach(model.engine.plugins[bus]?.parameters ?? []) { parameter in
                    Button(parameter.name) { model.assignMacro(parameter, bus: bus, index: macro) }
                }
            } label: {
                Text(target?.name.uppercased() ?? "ASSIGN ▾")
                    .font(Fonts.label(9.5, weight: 800))
                    .tracking(0.6)
                    .foregroundStyle(target == nil ? Theme.textDim : color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Text(model.macroDisplay(bus: bus, index: macro))
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// INSERTS page: a parameter of the strip's built-in insert.
    private func insertCell(_ parameter: Int) -> some View {
        let value = strip.insertValues[parameter]
        return VStack(spacing: 2) {
            Knob(
                value: Binding(get: { value }, set: { model.setInsertValue(strip: index, index: parameter, $0) }),
                color: Theme.text,
                ghost: model.mix.insertGhost(strip: index, index: parameter),
                size: 54
            )
            Text(strip.insert?.parameters[parameter].label ?? "")
                .font(Fonts.label(9.5, weight: 800))
                .tracking(0.6)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(model.mix.insertDisplay(strip: index, index: parameter))
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// INSERTS page, plugin insert: a macro the user assigns to one of the plugin's parameters.
    private func insertMacroCell(_ macro: Int) -> some View {
        let value = strip.insertMacros[macro]
        let target = model.insertMacroTarget(strip: index, index: macro)
        return VStack(spacing: 2) {
            Knob(
                value: Binding(get: { value }, set: { model.mix.setInsertMacro(strip: index, index: macro, $0) }),
                color: Theme.text,
                ghost: model.mix.insertGhost(strip: index, index: macro),
                size: 54
            )
            .opacity(target == nil ? 0.35 : 1)
            .allowsHitTesting(target != nil)
            Menu {
                Button("None") { model.assignInsertMacro(nil, strip: index, index: macro) }
                Divider()
                ForEach(model.engine.insertPlugins[index]?.parameters ?? []) { parameter in
                    Button(parameter.name) { model.assignInsertMacro(parameter, strip: index, index: macro) }
                }
            } label: {
                Text(target?.name.uppercased() ?? "ASSIGN ▾")
                    .font(Fonts.label(9.5, weight: 800))
                    .tracking(0.6)
                    .foregroundStyle(target == nil ? Theme.textDim : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Text(model.insertMacroDisplay(strip: index, index: macro))
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// Insert menu (PRD § 11.5): none, a built-in insert, or any Audio Unit; in the INSERTS page header and
    /// in the name plate's context menu.
    @ViewBuilder
    private var insertMenuItems: some View {
        let hosted = strip.insertHosted
        Button((!hosted && strip.insert == nil ? "✓ " : "") + "None") { model.pickInsert(strip: index, nil) }
        ForEach(InsertKind.allCases, id: \.self) { kind in
            Button((!hosted && strip.insert == kind ? "✓ " : "") + "Built-in · \(kind.label)") { model.pickInsert(strip: index, kind) }
        }
        if strip.insert == .autoWah, strip.insertValues.count > 3 {
            let down = strip.insertValues[3] >= 0.5
            Button((down ? "✓ " : "") + "Down mode (louder closes the filter)") { model.setInsertValue(strip: index, index: 3, down ? 0 : 1) }
        }
        if hosted {
            Button("Open plugin window") { model.openInsertWindow(strip: index) }
        }
        Divider()
        ForEach(insertManufacturers, id: \.self) { manufacturer in
            Menu(manufacturer) {
                ForEach(model.installedPlugins.filter { $0.manufacturer == manufacturer }) { info in
                    let current = hosted && model.engine.insertPlugins[index]?.info.id == info.id
                    Button((current ? "✓ " : "") + info.name) { model.pickInsertPlugin(info, strip: index) }
                }
            }
        }
    }

    private var insertManufacturers: [String] {
        var seen = Set<String>()
        return model.installedPlugins.map(\.manufacturer).filter { seen.insert($0).inserted }
    }

    private func sendCell(_ row: Int) -> some View {
        let value = strip.sends[row]
        return VStack(spacing: 3) {
            Knob(
                value: Binding(get: { value }, set: { model.mix.setSend(strip: index, row: row, $0) }),
                color: Bus(rawValue: row)!.color,
                ghost: model.mix.knobGhost(strip: index, row: row)
            )
            Text("\(Int((value * 100).rounded()))")
                .font(Fonts.mono(10))
                .foregroundStyle(value > 0.005 ? Theme.text : Theme.textDim)
        }
    }

    private var stems: some View {
        VStack(spacing: 1) {
            ForEach(strip.stems.prefix(3)) { stem in
                Text(stem.name)
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .draggableStem(model.url(ofStem: stem.id), enabled: !model.isPreview)
                    .contextMenu {
                        Menu("Move to strip") {
                            ForEach(0..<AudioEngine.stripCount, id: \.self) { target in
                                if target != index, let url = model.url(ofStem: stem.id) {
                                    Button("\(target + 1)") { model.placeStems([url], onStrip: target) }
                                }
                            }
                        }
                        Button("Back to the stem list") { model.takeOffStrip(stem.id, remove: false) }
                        Button("Remove", role: .destructive) { model.takeOffStrip(stem.id, remove: true) }
                    }
            }
            if isEmpty {
                Text("drop a stem")
                    .font(Fonts.mono(9.5))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// Seule cette vue est redessinée 30 fois par seconde.
private struct LiveMeter: View {
    var model: AppModel
    var index: Int

    var body: some View {
        Meter(level: Double(model.levels[index]))
    }
}

private struct MasterView: View {
    var model: AppModel

    private var anySolo: Bool { model.mix.strips.contains(where: \.solo) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                Text("OUT").font(Fonts.mono(10)).foregroundStyle(Theme.textDim)
                Text("MASTER")
                    .font(Fonts.label(15, weight: 850, width: 118))
                    .tracking(0.8)
                    .foregroundStyle(Theme.text)
            }
            .frame(height: 44)

            // Comme sur la console : BANK LEFT / RIGHT et SOLO au-dessus du fader master.
            // Then the gestures (PRD § 11.6): DROP held, REWIND pressed.
            VStack(spacing: 6) {
                Text("PAGE")
                    .font(Fonts.mono(9))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StripButton(title: "◀ MIX", active: model.mix.page == .mix) { model.mix.setPage(.mix) }
                StripButton(title: "FX", active: model.mix.page == .fx) { model.mix.setPage(.fx) }
                StripButton(title: "MASTER", active: model.mix.page == .master) { model.mix.setPage(.master) }
                StripButton(title: "INSERTS ▶", active: model.mix.page == .inserts) { model.mix.setPage(.inserts) }
                Text("GESTURES")
                    .font(Fonts.mono(9))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                MomentaryButton(title: "DROP", active: model.mix.dropping, activeColor: Theme.rec) { model.mix.setDrop($0) }
                    .help("Hold: cuts every strip not marked KEEP (key D)")
                StripButton(title: "REWIND", active: model.engine.isPullingUp, activeColor: Theme.delay) { model.pullUp() }
                    .help("Pull-up: brake the tape, back to the top, play (key R)")
                MomentaryButton(title: "HOLD", active: model.holding, activeColor: Theme.delay) { model.setHold($0) }
                    .help("Hold: the delay loops on itself (key H)")
                StripButton(title: "CRASH", active: false, activeColor: Theme.reverb) { model.crash() }
                    .help("Hit the spring reverb (key C)")
                    .opacity(model.reverbModel == .spring ? 1 : 0.45)
                Spacer(minLength: 0)
                StripButton(title: anySolo ? "CLEAR SOLO" : "SOLO", active: anySolo) {
                    for (strip, state) in model.mix.strips.enumerated() where state.solo {
                        model.mix.toggleSolo(strip: strip)
                    }
                }
            }
            .frame(height: headerHeight + knobCellHeight * 3 + namePlateHeight + 66 - 44)

            HStack(alignment: .center, spacing: 8) {
                Fader(
                    value: Binding(get: { model.mix.master }, set: { model.mix.setMaster($0) }),
                    ghost: model.mix.masterGhost
                )
                LiveMeter(model: model, index: AudioEngine.masterMeter)
            }
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity)

            Text("LIMITER ON")
                .font(Fonts.mono(9.5))
                .foregroundStyle(Theme.reverb)
                .frame(height: 42, alignment: .top)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.text.opacity(0.35), lineWidth: 1))
    }
}
