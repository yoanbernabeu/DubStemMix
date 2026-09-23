import Foundation
import Observation

/// État du mix et logique de la console, indépendants de l'audio, du MIDI et de l'interface :
/// envois, faders, mute/solo, dub throw, rattrapage des contrôles (soft takeover), LEDs.
@MainActor
@Observable
public final class MixController {
    public struct StemInfo: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Strip {
        public var name = ""
        public var stems: [StemInfo] = []
        /// Envois delay, reverb, bus 3 — position du potard, 0…1.
        public var sends: [Double] = [0, 0, 0]
        public var fader = 0.8
        public var mute = false
        public var solo = false
        public var throwing = false
        /// Survives the DROP gesture (PRD § 11.6).
        public var keep = false
        /// Insert (PRD § 11.5): a built-in insert with its normalized values, or a hosted plugin with 3 macros.
        public var insert: InsertKind?
        public var insertValues: [Double] = []
        public var insertHosted = false
        public var insertMacros: [Double] = [0, 0, 0]
    }

    /// Ce que pilotent les 24 potards : les envois (BANK LEFT) ou les paramètres d'effets (BANK RIGHT).
    /// Les faders restent des volumes de tranche sur les deux pages.
    /// MASTER and INSERTS (PRD § 11.1): BANK RIGHT again from FX; BANK LEFT always returns to MIX.
    public enum Page: Sendable, CaseIterable {
        case mix, fx, master, inserts

        /// Knob layout of the page (nil for MIX, where the knobs are sends, and INSERTS, per strip).
        var layout: [[FXParameter?]]? {
            switch self {
            case .mix, .inserts: nil
            case .fx: FXParameter.layout
            case .master: FXParameter.masterLayout
            }
        }

        var next: Page {
            switch self {
            case .mix: .fx
            case .fx: .master
            case .master, .inserts: .inserts
            }
        }
    }

    public private(set) var strips = [Strip](repeating: Strip(), count: AudioEngine.stripCount)
    public private(set) var master = 0.8
    public private(set) var page = Page.mix
    /// DROP held: every strip not marked KEEP is cut, without touching mute or solo.
    public private(set) var dropping = false
    /// Paramètres d'effets, normalisés 0…1.
    public private(set) var fx: [FXParameter: Double] = Dictionary(
        uniqueKeysWithValues: FXParameter.allCases.map { ($0, $0.defaultValue) }
    )

    /// Ce que pilote un potard sur la page FX : un paramètre d'effet intégré, ou — quand le bus héberge
    /// un plugin — un potard macro affecté par l'utilisateur à un paramètre du plugin.
    public enum FXCell: Equatable, Sendable {
        case parameter(FXParameter)
        case macro(SendBus, Int)
        /// INSERTS page: a built-in insert's parameter, or a macro of a plugin insert, on that strip.
        case insert(Int, Int)
        case insertMacro(Int, Int)
    }

    /// Bus qui hébergent un plugin AU, et valeurs normalisées de leurs potards macros.
    public private(set) var hostedBuses: Set<SendBus> = []
    public private(set) var macros: [SendBus: [Double]] = [:]

    /// Tempo du morceau (nil = inconnu) et calage du delay sur ce tempo.
    public private(set) var bpm: Double?
    public private(set) var delaySync = false

    /// Divisions proposées par le potard TIME quand le delay est calé au tempo (en noires).
    public static let syncDivisions: [(label: String, beats: Double)] = [
        ("1/16", 0.25), ("1/8", 0.5), ("1/8.", 0.75), ("1/4", 1), ("1/4.", 1.5), ("1/2", 2),
    ]

    /// Un contrôle physique non motorisé : sa dernière position connue, et s'il « tient » la valeur.
    private struct Physical {
        var value: Double?
        var picked = true
    }

    private static let pickupWindow = 0.04

    @ObservationIgnored private let engine: MixEngineControl
    @ObservationIgnored private let surface: ControlSurface?
    private var knobs = [[Physical]](repeating: [Physical](repeating: Physical(), count: 3), count: AudioEngine.stripCount)
    private var faders = [Physical](repeating: Physical(), count: AudioEngine.stripCount)
    private var masterFader = Physical()

    public init(engine: MixEngineControl, surface: ControlSurface? = nil) {
        self.engine = engine
        self.surface = surface
        for strip in strips.indices { applyAll(strip: strip) }
        engine.setMasterGain(Self.faderGain(master))
        for (parameter, value) in fx { engine.setFX(parameter, engineValue(parameter, value)) }
    }

    // MARK: Lois de gain

    /// Gain unité à 80 % de la course, environ +5 dB en butée.
    public static func faderGain(_ position: Double) -> Float { Float(pow(position / 0.8, 2.5)) }
    public static func sendGain(_ position: Double) -> Float { Float(position * position) }

    // MARK: Console physique

    public func handle(_ event: SurfaceEvent) {
        switch event {
        case let .knob(strip, row, value):
            switch page {
            case .mix:
                if pickUp(&knobs[strip][row], physical: value, current: strips[strip].sends[row]) {
                    applySend(strip: strip, row: row, value)
                }
            case .fx, .master, .inserts:
                switch cell(strip: strip, row: row) {
                case let .parameter(parameter):
                    if pickUp(&knobs[strip][row], physical: value, current: fx[parameter] ?? 0) {
                        applyFX(parameter, value)
                    }
                case let .macro(bus, index):
                    if pickUp(&knobs[strip][row], physical: value, current: macros[bus]?[index] ?? 0) {
                        applyMacro(bus: bus, index: index, value)
                    }
                case let .insert(strip, index):
                    if pickUp(&knobs[strip][row], physical: value, current: strips[strip].insertValues[index]) {
                        applyInsertValue(strip: strip, index: index, value)
                    }
                case let .insertMacro(strip, index):
                    if pickUp(&knobs[strip][row], physical: value, current: strips[strip].insertMacros[index]) {
                        applyInsertMacro(strip: strip, index: index, value)
                    }
                case nil:
                    knobs[strip][row].value = value
                }
            }
        case let .fader(strip, value):
            if pickUp(&faders[strip], physical: value, current: strips[strip].fader) {
                applyFader(strip: strip, value)
            }
        case let .master(value):
            if pickUp(&masterFader, physical: value, current: master) { applyMaster(value) }
        case let .button(.mute, strip, pressed):
            if pressed { toggleMute(strip: strip) }
        case let .button(.solo, strip, pressed):
            if pressed { toggleSolo(strip: strip) }
        case let .button(.recArm, strip, pressed):
            setThrow(strip: strip, pressed)
        case let .button(.bankLeft, _, pressed):
            if pressed { setPage(.mix) }
        case let .button(.bankRight, _, pressed):
            if pressed { setPage(page.next) }
        case .button(.soloMode, _, _):
            break // SOLO maintenu : la console envoie alors elle-même les notes de solo
        }
    }

    /// Un contrôle qui ne « tient » pas la valeur n'agit qu'après l'avoir rejointe ou croisée.
    /// Le tout premier message (SEND ALL au démarrage) est adopté tel quel : la console fait foi.
    private func pickUp(_ control: inout Physical, physical: Double, current: Double) -> Bool {
        defer { control.value = physical }
        if control.picked { return true }
        let near = abs(physical - current) <= Self.pickupWindow
        // Position physique encore inconnue : sur la page MIX la console fait foi, mais un paramètre
        // d'effet ne doit pas sauter au premier effleurement d'un potard.
        let crossed = control.value.map { ($0 - current) * (physical - current) <= 0 } ?? (page == .mix)
        control.picked = near || crossed
        return control.picked
    }

    /// Après un changement à l'écran, le contrôle physique doit rattraper la nouvelle valeur.
    private func release(_ control: inout Physical, to value: Double) {
        guard let physical = control.value else { return }
        control.picked = abs(physical - value) <= Self.pickupWindow
    }

    private func ghost(_ control: Physical) -> Double? {
        control.picked ? nil : control.value
    }

    /// Position « fantôme » du potard physique — seulement pour la page qu'il pilote en ce moment.
    public func knobGhost(strip: Int, row: Int) -> Double? { page == .mix ? ghost(knobs[strip][row]) : nil }

    public func fxGhost(_ parameter: FXParameter) -> Double? {
        guard let (strip, row) = knob(for: parameter) else { return nil }
        return ghost(knobs[strip][row])
    }

    /// The knob driving a parameter on the current page, if the page shows it.
    private func knob(for parameter: FXParameter) -> (strip: Int, row: Int)? {
        guard let layout = page.layout else { return nil }
        for (strip, column) in layout.enumerated() {
            if let row = column.firstIndex(of: parameter) { return (strip, row) }
        }
        return nil
    }

    public func faderGhost(strip: Int) -> Double? { ghost(faders[strip]) }
    public var masterGhost: Double? { ghost(masterFader) }

    // MARK: Interface

    public func setSend(strip: Int, row: Int, _ value: Double) {
        applySend(strip: strip, row: row, value)
        if page == .mix { release(&knobs[strip][row], to: value) }
    }

    public func setFX(_ parameter: FXParameter, _ value: Double) {
        applyFX(parameter, value)
        if let (strip, row) = knob(for: parameter) { release(&knobs[strip][row], to: value) }
    }

    /// Changement de page : les potards ne sont pas motorisés, chacun devra rattraper
    /// la valeur de ce qu'il pilote désormais (sauf s'il s'y trouve déjà).
    public func setPage(_ newPage: Page) {
        page = newPage
        for strip in knobs.indices {
            for row in knobs[strip].indices {
                let target: Double? = switch newPage {
                case .mix: strips[strip].sends[row]
                case .fx, .master, .inserts: cellValue(strip: strip, row: row)
                }
                if let target, let physical = knobs[strip][row].value {
                    knobs[strip][row].picked = abs(physical - target) <= Self.pickupWindow
                } else {
                    knobs[strip][row].picked = false
                }
            }
        }
        surface?.setBankLeds(left: newPage != .fx, right: newPage != .mix) // MASTER lights both
    }

    public func setFader(strip: Int, _ value: Double) {
        applyFader(strip: strip, value)
        release(&faders[strip], to: value)
    }

    public func setMaster(_ value: Double) {
        applyMaster(value)
        release(&masterFader, to: value)
    }

    // MARK: Actions communes

    public func toggleMute(strip: Int) {
        strips[strip].mute.toggle()
        surface?.setMuteLed(strip: strip, strips[strip].mute)
        applyAudibility()
    }

    public func toggleSolo(strip: Int) {
        strips[strip].solo.toggle()
        surface?.setSoloLed(strip: strip, strips[strip].solo)
        applyAudibility()
    }

    public func setThrow(strip: Int, _ on: Bool) {
        strips[strip].throwing = on
        engine.setThrow(strip: strip, on)
        surface?.setRecLed(strip: strip, on)
    }

    public func setStems(strip: Int, name: String, stems: [StemInfo]) {
        strips[strip].name = name
        strips[strip].stems = stems
    }

    // MARK: DROP (PRD § 11.6)

    public func setKeep(strip: Int, _ keep: Bool) {
        strips[strip].keep = keep
        if dropping { applyAudibility() }
    }

    /// Held gesture: cuts every strip not marked KEEP; releasing gives the mix back exactly as it was.
    public func setDrop(_ on: Bool) {
        guard dropping != on else { return }
        dropping = on
        applyAudibility()
    }

    /// Solo « in place » : dès qu'une tranche est en solo, seules les tranches en solo passent.
    public func isAudible(strip: Int) -> Bool {
        if dropping, !strips[strip].keep { return false }
        return strips.contains(where: \.solo) ? strips[strip].solo : !strips[strip].mute
    }

    /// À la (re)connexion de la console : on rallume les LEDs selon l'état du mix.
    public func refreshSurface() {
        for (i, strip) in strips.enumerated() {
            surface?.setMuteLed(strip: i, strip.mute)
            surface?.setSoloLed(strip: i, strip.solo)
            surface?.setRecLed(strip: i, strip.throwing)
        }
        surface?.setBankLeds(left: page != .fx, right: page != .mix)
    }

    // MARK: Application au moteur

    private func applySend(strip: Int, row: Int, _ value: Double) {
        strips[strip].sends[row] = value
        guard let bus = SendBus(rawValue: row) else { return }
        engine.setSendGain(bus, strip: strip, Self.sendGain(value))
    }

    private func applyFader(strip: Int, _ value: Double) {
        strips[strip].fader = value
        engine.setFaderGain(strip: strip, isAudible(strip: strip) ? Self.faderGain(value) : 0)
    }

    private func applyFX(_ parameter: FXParameter, _ value: Double) {
        fx[parameter] = value
        engine.setFX(parameter, engineValue(parameter, value))
    }

    // MARK: Plugins et potards macros

    /// The 6 knobs of a bus on the FX page (2 strips × 3). Bus-to-bus sends live on strip 8, outside the macros.
    public static func macroSlot(strip: Int, row: Int) -> (bus: SendBus, index: Int)? {
        guard strip < 6, let bus = SendBus(rawValue: strip / 2) else { return nil }
        let index = (strip % 2) * 3 + row
        return (bus, index)
    }

    /// On the MASTER page, a master-chain parameter; on INSERTS, the strip's insert; otherwise the FX page's
    /// assignment (parameter or macro).
    public func cell(strip: Int, row: Int) -> FXCell? {
        switch page {
        case .master:
            return FXParameter.masterLayout[strip][row].map(FXCell.parameter)
        case .inserts:
            if strips[strip].insertHosted { return .insertMacro(strip, row) }
            if let kind = strips[strip].insert, row < kind.knobCount { return .insert(strip, row) }
            return nil
        case .mix, .fx:
            if let (bus, index) = Self.macroSlot(strip: strip, row: row), hostedBuses.contains(bus) { return .macro(bus, index) }
            return FXParameter.layout[strip][row].map(FXCell.parameter)
        }
    }

    private func cellValue(strip: Int, row: Int) -> Double? {
        switch cell(strip: strip, row: row) {
        case let .parameter(parameter): fx[parameter]
        case let .macro(bus, index): macros[bus]?[index]
        case let .insert(strip, index): strips[strip].insertValues[index]
        case let .insertMacro(strip, index): strips[strip].insertMacros[index]
        case nil: nil
        }
    }

    // MARK: Strip inserts (PRD § 11.5)

    /// A built-in insert on a strip (nil = none), starting from its default settings.
    public func setInsert(strip: Int, _ kind: InsertKind?) {
        strips[strip].insert = kind
        strips[strip].insertHosted = false
        strips[strip].insertValues = kind?.parameters.map(\.defaultValue) ?? []
        for (index, value) in strips[strip].insertValues.enumerated() { engine.setInsertParameter(strip: strip, index: index, value) }
        if page == .inserts { setPage(.inserts) } // the knobs have new targets to catch up with
    }

    /// A plugin was loaded in (or removed from) a strip's insert: its knobs become macros.
    public func setInsertHosted(strip: Int, _ hosted: Bool) {
        strips[strip].insertHosted = hosted
        if hosted { strips[strip].insert = nil; strips[strip].insertValues = [] }
        strips[strip].insertMacros = Array(repeating: 0, count: AudioEngine.insertMacroCount)
        if page == .inserts { setPage(.inserts) }
    }

    /// From the screen (or a project): a built-in insert's parameter, normalized.
    public func setInsertValue(strip: Int, index: Int, _ value: Double) {
        applyInsertValue(strip: strip, index: index, value)
        if page == .inserts, index < 3 { release(&knobs[strip][index], to: value) }
    }

    public func setInsertMacro(strip: Int, index: Int, _ value: Double) {
        applyInsertMacro(strip: strip, index: index, value)
        if page == .inserts { release(&knobs[strip][index], to: value) }
    }

    /// The value changed in the plugin itself: follow it without driving it back.
    public func syncInsertMacro(strip: Int, index: Int, _ value: Double) {
        guard abs(strips[strip].insertMacros[index] - value) > 0.0005 else { return }
        strips[strip].insertMacros[index] = value
        if page == .inserts { release(&knobs[strip][index], to: value) }
    }

    public func insertGhost(strip: Int, index: Int) -> Double? {
        page == .inserts && index < 3 ? ghost(knobs[strip][index]) : nil
    }

    public func insertDisplay(strip: Int, index: Int) -> String {
        guard let kind = strips[strip].insert, kind.parameters.indices.contains(index) else { return "" }
        return kind.parameters[index].display(strips[strip].insertValues[index])
    }

    private func applyInsertValue(strip: Int, index: Int, _ value: Double) {
        guard strips[strip].insertValues.indices.contains(index) else { return }
        strips[strip].insertValues[index] = value
        engine.setInsertParameter(strip: strip, index: index, value)
    }

    private func applyInsertMacro(strip: Int, index: Int, _ value: Double) {
        strips[strip].insertMacros[index] = value
        engine.setInsertMacro(strip: strip, index: index, value)
    }

    /// Un plugin vient d'être chargé sur ce bus (ou retiré) : ses potards changent de rôle.
    public func setHosted(_ bus: SendBus, _ hosted: Bool) {
        if hosted { hostedBuses.insert(bus) } else { hostedBuses.remove(bus) }
        macros[bus] = hosted ? Array(repeating: 0, count: AudioEngine.macroCount) : nil
        if page == .fx { setPage(.fx) } // les potards physiques devront rattraper leurs nouvelles cibles
    }

    /// Depuis l'écran.
    public func setMacro(bus: SendBus, index: Int, _ value: Double) {
        applyMacro(bus: bus, index: index, value)
        if page == .fx { releaseMacroKnob(bus: bus, index: index, to: value) }
    }

    /// La valeur a changé dans le plugin lui-même (sa fenêtre, un preset) : on suit, sans le repiloter.
    public func syncMacro(bus: SendBus, index: Int, _ value: Double) {
        guard let current = macros[bus]?[index], abs(current - value) > 0.0005 else { return }
        macros[bus]?[index] = value
        if page == .fx { releaseMacroKnob(bus: bus, index: index, to: value) }
    }

    public func macroGhost(bus: SendBus, index: Int) -> Double? {
        guard page == .fx else { return nil }
        return ghost(knobs[bus.rawValue * 2 + index / 3][index % 3])
    }

    private func releaseMacroKnob(bus: SendBus, index: Int, to value: Double) {
        release(&knobs[bus.rawValue * 2 + index / 3][index % 3], to: value)
    }

    private func applyMacro(bus: SendBus, index: Int, _ value: Double) {
        macros[bus]?[index] = value
        engine.setMacro(bus: bus, index: index, value)
    }

    // MARK: Tempo

    public func setTempo(_ newValue: Double?) {
        bpm = newValue.map { min(300, max(30, $0)) }
        applyFX(.delayTime, fx[.delayTime] ?? 0)
    }

    public func setDelaySync(_ on: Bool) {
        delaySync = on
        applyFX(.delayTime, fx[.delayTime] ?? 0)
    }

    /// Delay calé : le potard TIME ne choisit plus des millisecondes mais une division du temps.
    private func syncedDivision(_ normalized: Double) -> (label: String, seconds: Double)? {
        guard delaySync, let bpm else { return nil }
        let divisions = Self.syncDivisions
        let division = divisions[min(divisions.count - 1, Int(min(1, max(0, normalized)) * Double(divisions.count)))]
        return (division.label, 60 / bpm * division.beats)
    }

    private func engineValue(_ parameter: FXParameter, _ normalized: Double) -> Float {
        if parameter == .delayTime, let division = syncedDivision(normalized) { return Float(division.seconds) }
        return parameter.value(normalized)
    }

    /// Valeur affichée d'un paramètre (tient compte du calage au tempo).
    public func fxDisplay(_ parameter: FXParameter) -> String {
        let normalized = fx[parameter] ?? 0
        if parameter == .delayTime, let division = syncedDivision(normalized) {
            return "\(division.label) · \(Int((division.seconds * 1000).rounded())) ms"
        }
        return parameter.display(normalized)
    }

    private func applyMaster(_ value: Double) {
        master = value
        engine.setMasterGain(Self.faderGain(value))
    }

    private func applyAudibility() {
        for strip in strips.indices { applyFader(strip: strip, strips[strip].fader) }
    }

    private func applyAll(strip: Int) {
        applyFader(strip: strip, strips[strip].fader)
        for row in strips[strip].sends.indices { applySend(strip: strip, row: row, strips[strip].sends[row]) }
    }
}
