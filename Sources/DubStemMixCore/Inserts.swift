import DubDSP
import Foundation

/// Built-in strip inserts (PRD § 11.5). Raw values are stored in projects.
public enum InsertKind: String, CaseIterable, Sendable {
    case sub, autoWah

    public var label: String {
        switch self {
        case .sub: "Sub"
        case .autoWah: "Auto-wah"
        }
    }

    /// For the strip header, where the strip number must stay visible.
    public var shortLabel: String { self == .sub ? "SUB" : "WAH" }

    /// Position of this insert in the strip's switch (0 = straight through), and where its parameters start there.
    var switchSelect: Float { self == .sub ? 1 : 2 }
    var switchOffset: Int { self == .sub ? DUB_INSERT_SUB : DUB_INSERT_WAH }

    /// The knobs of the INSERTS page for this insert (up to 3), then any screen-only parameters.
    public var parameters: [InsertParameter] {
        switch self {
        case .sub:
            [InsertParameter(label: "AMOUNT", kernelIndex: DUB_SUB_AMOUNT, defaultValue: 0.6, mapping: .linear(0, 1), unit: .percent),
             InsertParameter(label: "CUTOFF", kernelIndex: DUB_SUB_CUTOFF, defaultValue: 0.5, mapping: .exponential(40, 160), unit: .hertz)]
        case .autoWah:
            [InsertParameter(label: "SENS", kernelIndex: DUB_WAH_SENSITIVITY, defaultValue: 0.6, mapping: .linear(0, 1), unit: .percent),
             InsertParameter(label: "RANGE", kernelIndex: DUB_WAH_RANGE, defaultValue: 0.7, mapping: .linear(0, 1), unit: .percent),
             InsertParameter(label: "RESO", kernelIndex: DUB_WAH_RESONANCE, defaultValue: 0.5, mapping: .linear(0, 1), unit: .percent),
             InsertParameter(label: "DOWN", kernelIndex: DUB_WAH_DIRECTION, defaultValue: 0, mapping: .linear(0, 1), unit: .toggle)]
        }
    }

    public var knobCount: Int { min(3, parameters.count) }
}

/// One parameter of a built-in insert: normalized 0…1 on the console and screen, real units in the kernel.
public struct InsertParameter: Sendable, Equatable {
    public enum Mapping: Sendable, Equatable { case linear(Double, Double), exponential(Double, Double) }
    public enum Unit: Sendable, Equatable { case percent, hertz, toggle }

    public let label: String
    public let kernelIndex: Int
    public let defaultValue: Double
    public let mapping: Mapping
    public let unit: Unit

    public func value(_ normalized: Double) -> Float {
        let n = min(1, max(0, normalized))
        switch mapping {
        case let .linear(low, high): return Float(low + (high - low) * n)
        case let .exponential(low, high): return Float(low * pow(high / low, n))
        }
    }

    public func display(_ normalized: Double) -> String {
        let value = Double(self.value(normalized))
        switch unit {
        case .percent: return "\(Int((min(1, max(0, normalized)) * 100).rounded())) %"
        case .hertz: return "\(Int(value.rounded())) Hz"
        case .toggle: return value >= 0.5 ? "ON" : "OFF"
        }
    }
}

/// Built-in effect on BUS 3 (PRD § 11.5). Raw values are stored in projects.
public enum Bus3Model: String, CaseIterable, Sendable {
    case phaser, flanger

    public var label: String { self == .phaser ? "Bi-Phaser" : "Tape Flanger" }
    var switchSelect: Float { self == .phaser ? 0 : 1 }
}
