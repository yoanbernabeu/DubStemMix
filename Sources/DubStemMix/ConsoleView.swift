import DubStemMixCore
import SwiftUI

// Miroir de la MIDImix : 8 tranches (3 potards, MUTE, REC ARM/throw, fader) + colonne master.

// Chaque tranche a deux zones : en haut les potards (envois, ou réglages d'effets sur la page FX),
// en bas ce qui appartient au stem sur les deux pages (nom, MUTE, THROW, fader).
private let knobCellHeight: CGFloat = 92
private let headerHeight: CGFloat = 30
private let namePlateHeight: CGFloat = 28

/// Ce que pilotent les potards d'une tranche sur la page FX.
private func fxGroup(strip: Int) -> (title: String, color: Color)? {
    let buses = Set(FXParameter.layout[strip].compactMap { $0?.bus })
    guard let first = buses.first else { return nil }
    if buses.count > 1 { return ("RETURNS", Theme.text) }
    let bus = Bus(rawValue: first.rawValue)!
    return (bus.label, bus.color)
}

struct ConsoleView: View {
    var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RowLabels(page: model.mix.page)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: headerHeight)
            ForEach(Bus.allCases, id: \.self) { bus in
                VStack(alignment: .leading, spacing: 3) {
                    if page == .mix {
                        RoundedRectangle(cornerRadius: 1.5).fill(bus.color).frame(width: 22, height: 4)
                        Text(bus.label)
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
        .stemDrop(enabled: !model.isPreview, isTargeted: $dropTargeted) { model.assign($0, toStrip: index) }
    }

    private var borderColor: Color {
        if strip.throwing { return Theme.delay }
        return dropTargeted ? Theme.text : Theme.border
    }

    private var onFXPage: Bool { model.mix.page == .fx }

    /// En-tête de la zone des potards : sur la page FX, l'effet qu'ils pilotent — pas le stem.
    private var header: some View {
        HStack(spacing: 5) {
            Text("\(index + 1)")
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.textDim)
            if onFXPage, let group = fxGroup(strip: index) {
                Text(group.title)
                    .font(Fonts.label(11, weight: 850))
                    .tracking(1.2)
                    .foregroundStyle(group.color)
            }
        }
    }

    /// Page FX : la zone des potards prend la teinte de l'effet, pour qu'on voie qu'elle a changé de rôle.
    @ViewBuilder
    private var knobZoneBackground: some View {
        if onFXPage, let group = fxGroup(strip: index) {
            RoundedRectangle(cornerRadius: 6)
                .fill(group.color.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(group.color.opacity(0.35), lineWidth: 1))
        }
    }

    /// Le nom du stem, collé à ce qui lui appartient sur les deux pages : MUTE, THROW et le fader.
    private var namePlate: some View {
        Text(isEmpty ? "—" : strip.name)
            .font(Fonts.label(14, weight: 850, width: 118))
            .tracking(0.8)
            .foregroundStyle(model.mix.isAudible(strip: index) ? Theme.text : Theme.textDim)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private func knobCell(_ row: Int) -> some View {
        if model.mix.page == .mix {
            sendCell(row)
        } else if case let .parameter(parameter) = model.mix.cell(strip: index, row: row) {
            fxCell(parameter)
        } else if case let .macro(bus, macro) = model.mix.cell(strip: index, row: row) {
            macroCell(bus: bus, index: macro)
        } else {
            Circle()
                .stroke(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                .frame(width: 44, height: 44)
        }
    }

    /// Page FX : le potard pilote un paramètre d'effet, aux couleurs de son bus.
    private func fxCell(_ parameter: FXParameter) -> some View {
        let value = model.mix.fx[parameter] ?? 0
        let color = Bus(rawValue: parameter.bus.rawValue)!.color
        return VStack(spacing: 2) {
            Knob(
                value: Binding(get: { value }, set: { model.mix.setFX(parameter, $0) }),
                color: color,
                ghost: model.mix.fxGhost(parameter),
                size: 54
            )
            Text(parameter.label)
                .font(Fonts.label(9.5, weight: 800))
                .tracking(0.6)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(model.mix.fxDisplay(parameter))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .font(Fonts.mono(10))
                .foregroundStyle(Theme.text)
        }
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
                                    Button("\(target + 1)") { model.assign([url], toStrip: target) }
                                }
                            }
                        }
                        Button("Back to the stem list") { model.unassign(stem.id) }
                        Button("Remove", role: .destructive) { model.removeStem(stem.id) }
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
            VStack(spacing: 6) {
                Text("PAGE")
                    .font(Fonts.mono(9))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StripButton(title: "◀ MIX", active: model.mix.page == .mix) { model.mix.setPage(.mix) }
                StripButton(title: "FX ▶", active: model.mix.page == .fx) { model.mix.setPage(.fx) }
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
