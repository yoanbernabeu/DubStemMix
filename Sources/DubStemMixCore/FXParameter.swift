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

    /// Page FX (BANK RIGHT) : potards des tranches 1 à 8, du haut vers le bas. PRD § 5.3.
    public static let layout: [[FXParameter?]] = [
        [.delayTime, .delayFeedback, .delayWow],
        [.delayLowCut, .delayHighCut, .delayToReverb],
        [.reverbDecay, .reverbDamping, .reverbPredelay],
        [.reverbLowCut, .reverbTone, nil],
        [.phaserRate, .phaserDepth, .phaserFeedback],
        [.phaserCenter, .phaserStereo, nil],
        [.delayReturn, .reverbReturn, .phaserReturn],
        [nil, nil, nil],
    ]

    public var bus: SendBus {
        switch self {
        case .delayTime, .delayFeedback, .delayWow, .delayLowCut, .delayHighCut, .delayToReverb, .delayReturn: .delay
        case .reverbDecay, .reverbDamping, .reverbPredelay, .reverbLowCut, .reverbTone, .reverbReturn: .reverb
        case .phaserRate, .phaserDepth, .phaserFeedback, .phaserCenter, .phaserStereo, .phaserReturn: .bus3
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
        case .delayToReverb, .delayReturn, .reverbReturn, .phaserReturn: n * n // gain, 100 % = unité
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
        case .delayToReverb, .delayReturn, .reverbReturn, .phaserReturn:
            return value < 0.001 ? "−∞ dB" : String(format: "%+.0f dB", 20 * log10(value)).replacingOccurrences(of: "-", with: "−")
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
        case .delayToReverb, .delayReturn, .reverbReturn, .phaserReturn: nil
        }
    }
}
