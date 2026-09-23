import DubDSP
import Foundation

/// Paramètres d'effets pilotés par la page FX. Côté console et interface tout est normalisé 0…1 ;
/// la conversion en unités réelles (et l'affichage) se fait ici.
/// Les noms des cas sont enregistrés dans les projets : ne pas les renommer.
public enum FXParameter: String, CaseIterable, Sendable {
    case delayTime, delayFeedback, delayWow
    case delayLowCut, delayHighCut, delayToReverb
    case reverbDecay, reverbDamping, reverbPredelay
    case reverbLowCut, reverbTone
    case phaserRate, phaserDepth, phaserFeedback
    case phaserCenter, phaserStereo
    case delayReturn, reverbReturn, phaserReturn
    // Master chain (PRD § 11.3), on the MASTER page.
    case masterHighPass
    case killBass, killMid, killTop
    case dubplate, crackle
    // Delay additions (PRD § 11.4), on the MASTER page too.
    case delayHeads, delayPingPong
    // Bus-to-bus sends (issue #1): the reverb's and bus 3's, on strip 8 of the FX page. The delay's is
    // `delayToReverb`, kept on strip 2 under its old name for existing projects. Targets: `BusRouting`.
    case reverbSend, bus3Send

    /// Page FX (BANK RIGHT) : potards des tranches 1 à 8, du haut vers le bas. PRD § 5.3.
    public static let layout: [[FXParameter?]] = [
        [.delayTime, .delayFeedback, .delayWow],
        [.delayLowCut, .delayHighCut, .delayToReverb],
        [.reverbDecay, .reverbDamping, .reverbPredelay],
        [.reverbLowCut, .reverbTone, nil],
        [.phaserRate, .phaserDepth, .phaserFeedback],
        [.phaserCenter, .phaserStereo, nil],
        [.delayReturn, .reverbReturn, .phaserReturn],
        [.reverbSend, .bus3Send, nil],
    ]

    /// MASTER page (PRD § 11.2): strips 1 to 8, top to bottom. Strip 4 (delay heads, ping-pong) comes with M7.
    public static let masterLayout: [[FXParameter?]] = [
        [.masterHighPass, nil, nil],
        [.killBass, .killMid, .killTop],
        [.dubplate, .crackle, nil],
        [.delayHeads, .delayPingPong, nil],
        [nil, nil, nil],
        [nil, nil, nil],
        [nil, nil, nil],
        [nil, nil, nil],
    ]

    /// Space Echo head patterns, in the kernel's order.
    public static let headPatterns = ["1", "2", "3", "1+2", "2+3", "1+3", "1+2+3"]

    /// Steps of the big knob, in Hz; the first one is "off".
    public static let highPassSteps: [Double] = [20, 70, 100, 150, 200, 300, 500, 800, 1000, 2000, 5000, 10_000]

    /// The send bus this parameter belongs to; nil for the master chain.
    public var bus: SendBus? {
        switch self {
        case .delayTime, .delayFeedback, .delayWow, .delayLowCut, .delayHighCut, .delayToReverb, .delayReturn,
             .delayHeads, .delayPingPong: .delay
        case .reverbDecay, .reverbDamping, .reverbPredelay, .reverbLowCut, .reverbTone, .reverbReturn, .reverbSend: .reverb
        case .phaserRate, .phaserDepth, .phaserFeedback, .phaserCenter, .phaserStereo, .phaserReturn, .bus3Send: .bus3
        case .masterHighPass, .killBass, .killMid, .killTop, .dubplate, .crackle: nil
        }
    }

    /// A send from one bus's return into another bus (the knob's bus is the source).
    public var isBusSend: Bool { [.delayToReverb, .reverbSend, .bus3Send].contains(self) }

    /// The knob sending a bus's return to its chosen bus.
    public static func busSend(from source: SendBus) -> FXParameter {
        switch source {
        case .delay: .delayToReverb
        case .reverb: .reverbSend
        case .bus3: .bus3Send
        }
    }

    /// Label of a bus-send knob for its current target ("REV→—" when it feeds no bus).
    public func label(sendingTo target: SendBus?) -> String {
        guard isBusSend, let source = bus else { return label }
        return "\(source.shortName)→\(target?.shortName ?? "—")"
    }

    /// Master-page group title (PRD § 11.2), for the strip header.
    public var masterGroup: String? {
        switch self {
        case .masterHighPass: "BIG KNOB"
        case .killBass, .killMid, .killTop: "KILLS"
        case .dubplate, .crackle: "DUBPLATE"
        case .delayHeads, .delayPingPong: "DELAY+"
        default: nil
        }
    }

    public var label: String {
        switch self {
        case .delayTime: "TIME"
        case .delayFeedback: "FEEDBACK"
        case .phaserFeedback: "RESONANCE"
        case .delayWow: "WOW"
        case .delayLowCut, .reverbLowCut: "LOW CUT"
        case .delayHighCut: "HIGH CUT"
        case .delayToReverb: "DLY→REV"
        case .reverbDecay: "DECAY"
        case .reverbDamping: "DAMPING"
        case .reverbPredelay: "PREDELAY"
        case .reverbTone: "TONE"
        case .phaserRate: "RATE"
        case .phaserDepth: "DEPTH"
        case .phaserCenter: "CENTER"
        case .phaserStereo: "STEREO"
        case .delayReturn: "DLY RETURN"
        case .reverbReturn: "REV RETURN"
        case .phaserReturn: "PHS RETURN"
        case .masterHighPass: "BIG KNOB"
        case .killBass: "BASS"
        case .killMid: "MID"
        case .killTop: "TOP"
        case .dubplate: "DUBPLATE"
        case .crackle: "CRACKLE"
        case .delayHeads: "HEADS"
        case .delayPingPong: "PING-PONG"
        case .reverbSend: "REV→"
        case .bus3Send: "B3→"
        }
    }

    public var defaultValue: Double {
        switch self {
        case .delayTime: 0.62
        case .delayFeedback: 0.5
        case .delayWow: 0.25
        case .delayLowCut: 0.45
        case .delayHighCut: 0.55
        case .delayToReverb: 0.2
        case .reverbDecay: 0.7
        case .reverbDamping: 0.4
        case .reverbPredelay: 0.1
        case .reverbLowCut: 0.55
        case .reverbTone: 0.65
        case .phaserRate: 0.35
        case .phaserDepth: 0.75
        case .phaserFeedback: 0.74
        case .phaserCenter: 0.5
        case .phaserStereo: 0.5
        case .delayReturn, .reverbReturn: 0.9
        // À 0 dB, un envoi à fond creuse des encoches complètes contre le signal direct de la tranche.
        case .phaserReturn: 1
        // Master chain: neutral until touched.
        case .masterHighPass, .dubplate, .crackle, .delayHeads, .delayPingPong: 0
        // New bus-to-bus sends: closed, so existing projects sound the same.
        case .reverbSend, .bus3Send: 0
        case .killBass, .killMid, .killTop: 1
        }
    }

    /// Valeur en unités réelles : secondes, Hz, coefficient ou gain linéaire.
    public func value(_ normalized: Double) -> Float {
        let n = min(1, max(0, normalized))
        func exp(_ low: Double, _ high: Double) -> Double { low * pow(high / low, n) }
        let value: Double = switch self {
        case .delayTime: exp(0.04, 1.5)
        case .delayFeedback: n * 1.15
        case .delayLowCut: exp(20, 1500)
        case .delayHighCut: exp(400, 14_000)
        case .reverbDecay: 0.2 + 0.77 * n
        case .reverbDamping: 0.9 * n
        case .reverbPredelay: 0.2 * n
        case .reverbLowCut: exp(20, 800)
        case .reverbTone: exp(800, 16_000)
        case .phaserRate: exp(0.05, 8)
        case .phaserFeedback: 0.95 * n
        case .phaserCenter: exp(200, 2000)
        case .delayWow, .phaserDepth, .phaserStereo: n
        case .delayToReverb, .reverbSend, .bus3Send, .delayReturn, .reverbReturn, .phaserReturn: n * n // gain, 100 % = unité
        case .masterHighPass: Self.highPassSteps[min(Self.highPassSteps.count - 1, Int(n * Double(Self.highPassSteps.count)))]
        case .killBass, .killMid, .killTop: n * n // kill gain, 100 % = unity
        case .dubplate, .crackle, .delayPingPong: n
        case .delayHeads: Double(min(Self.headPatterns.count - 1, Int(n * Double(Self.headPatterns.count))))
        }
        return Float(value)
    }

    public func display(_ normalized: Double) -> String {
        let value = Double(self.value(normalized))
        switch self {
        case .delayTime, .reverbPredelay:
            return "\(Int((value * 1000).rounded())) ms"
        case .delayLowCut, .delayHighCut, .reverbLowCut, .reverbTone, .phaserCenter:
            return value >= 1000 ? String(format: "%.1f kHz", value / 1000) : "\(Int(value.rounded())) Hz"
        case .phaserRate:
            return String(format: "%.2f Hz", value)
        case .delayFeedback:
            return "\(Int((value * 100).rounded())) %"
        case .delayToReverb, .reverbSend, .bus3Send, .delayReturn, .reverbReturn, .phaserReturn, .killBass, .killMid, .killTop:
            return value < 0.001 ? "−∞ dB" : String(format: "%+.0f dB", 20 * log10(value)).replacingOccurrences(of: "-", with: "−")
        case .masterHighPass:
            if value <= 20 { return "OFF" }
            return value >= 1000 ? String(format: "%.0f kHz", value / 1000) : "\(Int(value.rounded())) Hz"
        case .delayHeads:
            return Self.headPatterns[Int(value)]
        default:
            return "\(Int((min(1, max(0, normalized)) * 100).rounded())) %"
        }
    }

    /// Paramètre du noyau DSP correspondant (les retours et DLY→REV sont des niveaux de mixage du moteur).
    var kernelParameter: (effect: BuiltInEffect.Kind, index: Int)? {
        switch self {
        case .delayTime: (.delay, DUB_DELAY_TIME)
        case .delayFeedback: (.delay, DUB_DELAY_FEEDBACK)
        case .delayWow: (.delay, DUB_DELAY_WOW)
        case .delayLowCut: (.delay, DUB_DELAY_LOW_CUT)
        case .delayHighCut: (.delay, DUB_DELAY_HIGH_CUT)
        case .reverbDecay: (.plate, DUB_PLATE_DECAY)
        case .reverbDamping: (.plate, DUB_PLATE_DAMPING)
        case .reverbPredelay: (.plate, DUB_PLATE_PREDELAY)
        case .reverbLowCut: (.plate, DUB_PLATE_LOW_CUT)
        case .reverbTone: (.plate, DUB_PLATE_TONE)
        case .phaserRate: (.phaser, DUB_PHASER_RATE)
        case .phaserDepth: (.phaser, DUB_PHASER_DEPTH)
        case .phaserFeedback: (.phaser, DUB_PHASER_FEEDBACK)
        case .phaserCenter: (.phaser, DUB_PHASER_CENTER)
        case .phaserStereo: (.phaser, DUB_PHASER_STEREO)
        case .masterHighPass: (.master, DUB_MASTER_HIGH_PASS)
        case .killBass: (.master, DUB_MASTER_BASS)
        case .killMid: (.master, DUB_MASTER_MID)
        case .killTop: (.master, DUB_MASTER_TOP)
        case .dubplate: (.master, DUB_MASTER_DUBPLATE)
        case .crackle: (.master, DUB_MASTER_CRACKLE)
        case .delayHeads: (.delay, DUB_DELAY_HEADS)
        case .delayPingPong: (.delay, DUB_DELAY_PINGPONG)
        case .delayToReverb, .reverbSend, .bus3Send, .delayReturn, .reverbReturn, .phaserReturn: nil
        }
    }
}
