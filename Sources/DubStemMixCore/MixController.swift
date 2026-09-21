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
    }

    /// Ce que pilotent les 24 potards : les envois (BANK LEFT) ou les paramètres d'effets (BANK RIGHT).
    /// Les faders restent des volumes de tranche sur les deux pages.
    public enum Page: Sendable { case mix, fx }

    public private(set) var strips = [Strip](repeating: Strip(), count: AudioEngine.stripCount)
    public private(set) var master = 0.8
    public private(set) var page = Page.mix
    /// Paramètres d'effets, normalisés 0…1.
    public private(set) var fx: [FXParameter: Double] = Dictionary(
        uniqueKeysWithValues: FXParameter.allCases.map { ($0, $0.defaultValue) }
    )

    /// Ce que pilote un potard sur la page FX : un paramètre d'effet intégré, ou — quand le bus héberge
    /// un plugin — un potard macro affecté par l'utilisateur à un paramètre du plugin.
    public enum FXCell: Equatable, Sendable {
        case parameter(FXParameter)
        case macro(SendBus, Int)
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
            case .fx:
                switch cell(strip: strip, row: row) {
                case let .parameter(parameter):
                    if pickUp(&knobs[strip][row], physical: value, current: fx[parameter] ?? 0) {
                        applyFX(parameter, value)
                    }
                case let .macro(bus, index):
                    if pickUp(&knobs[strip][row], physical: value, current: macros[bus]?[index] ?? 0) {
                        applyMacro(bus: bus, index: index, value)
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
            if pressed { setPage(.fx) }
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
        guard page == .fx, let (strip, row) = Self.knob(for: parameter) else { return nil }
        return ghost(knobs[strip][row])
    }

    private static func knob(for parameter: FXParameter) -> (strip: Int, row: Int)? {
        for (strip, column) in FXParameter.layout.enumerated() {
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
        if page == .fx, let (strip, row) = Self.knob(for: parameter) { release(&knobs[strip][row], to: value) }
    }

    /// Changement de page : les potards ne sont pas motorisés, chacun devra rattraper
    /// la valeur de ce qu'il pilote désormais (sauf s'il s'y trouve déjà).
    public func setPage(_ newPage: Page) {
        page = newPage
        for strip in knobs.indices {
            for row in knobs[strip].indices {
                let target: Double? = switch newPage {
                case .mix: strips[strip].sends[row]
                case .fx: cellValue(strip: strip, row: row)
                }
                if let target, let physical = knobs[strip][row].value {
                    knobs[strip][row].picked = abs(physical - target) <= Self.pickupWindow
                } else {
                    knobs[strip][row].picked = false
                }
            }
        }
        surface?.setBankLeds(left: newPage == .mix, right: newPage == .fx)
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

    /// Solo « in place » : dès qu'une tranche est en solo, seules les tranches en solo passent.
    public func isAudible(strip: Int) -> Bool {
        strips.contains(where: \.solo) ? strips[strip].solo : !strips[strip].mute
    }

    /// À la (re)connexion de la console : on rallume les LEDs selon l'état du mix.
    public func refreshSurface() {
        for (i, strip) in strips.enumerated() {
            surface?.setMuteLed(strip: i, strip.mute)
            surface?.setSoloLed(strip: i, strip.solo)
            surface?.setRecLed(strip: i, strip.throwing)
        }
        surface?.setBankLeds(left: page == .mix, right: page == .fx)
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

    /// Les 6 potards d'un bus sur la page FX (2 tranches × 3). Le 6e du delay reste DLY→REV : c'est du routage.
    public static func macroSlot(strip: Int, row: Int) -> (bus: SendBus, index: Int)? {
        guard strip < 6, let bus = SendBus(rawValue: strip / 2) else { return nil }
        let index = (strip % 2) * 3 + row
        return bus == .delay && index == 5 ? nil : (bus, index)
    }

    public func cell(strip: Int, row: Int) -> FXCell? {
        if let (bus, index) = Self.macroSlot(strip: strip, row: row), hostedBuses.contains(bus) { return .macro(bus, index) }
        return FXParameter.layout[strip][row].map(FXCell.parameter)
    }

    private func cellValue(strip: Int, row: Int) -> Double? {
        switch cell(strip: strip, row: row) {
        case let .parameter(parameter): fx[parameter]
        case let .macro(bus, index): macros[bus]?[index]
        case nil: nil
        }
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
