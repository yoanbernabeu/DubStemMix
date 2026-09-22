@preconcurrency import AVFoundation

/// Un plugin Audio Unit d'effet installé sur la machine.
public struct PluginInfo: Identifiable, Hashable, Sendable, Codable {
    public var name: String
    public var manufacturer: String
    public var type: UInt32
    public var subType: UInt32
    public var manufacturerCode: UInt32

    public init(name: String, manufacturer: String, type: UInt32, subType: UInt32, manufacturerCode: UInt32) {
        self.name = name
        self.manufacturer = manufacturer
        self.type = type
        self.subType = subType
        self.manufacturerCode = manufacturerCode
    }

    /// Identifiant stable, ex. « aufx-dely-appl » : sert de clé pour mémoriser les macros par plugin.
    public var id: String { [type, subType, manufacturerCode].map(Self.fourCC).joined(separator: "-") }

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType,
                                  componentManufacturer: manufacturerCode, componentFlags: 0, componentFlagsMask: 0)
    }

    static func fourCC(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
    }

    /// Tous les effets AU installés (hors effets internes de DubStemMix), triés par éditeur puis par nom.
    public static func installed() -> [PluginInfo] {
        let manager = AVAudioUnitComponentManager.shared()
        let ours = "DbSM".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            manager.components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0
            ))
        }
        .filter { $0.audioComponentDescription.componentManufacturer != ours }
        .map { component in
            let description = component.audioComponentDescription
            return PluginInfo(name: component.name, manufacturer: component.manufacturerName, type: description.componentType,
                              subType: description.componentSubType, manufacturerCode: description.componentManufacturer)
        }
        .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }
}

/// Un paramètre de plugin affectable à un potard de la page FX.
public struct PluginParameter: Identifiable, Hashable, Sendable, Codable {
    public var address: UInt64
    public var name: String
    public var id: UInt64 { address }
}

public enum PluginError: Error, LocalizedError {
    case unsupportedFormat(String)
    case noEffectChain

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(name): "\(name) can't run in stereo at the engine's sample rate"
        case .noEffectChain: "this engine was built without effects"
        }
    }
}

/// Un plugin AU chargé sur un bus d'effet.
@MainActor
public final class HostedPlugin {
    public let info: PluginInfo
    public let unit: AVAudioUnit
    /// Chargé dans un processus séparé : s'il plante, l'app continue de jouer.
    public let isOutOfProcess: Bool

    init(info: PluginInfo, unit: AVAudioUnit, isOutOfProcess: Bool) {
        self.info = info
        self.unit = unit
        self.isOutOfProcess = isOutOfProcess
    }

    /// Hors processus si possible, sinon dans l'app.
    static func load(_ info: PluginInfo, format: AVAudioFormat) async throws -> HostedPlugin {
        var outOfProcess = true
        var unit: AVAudioUnit
        do {
            unit = try await AVAudioUnit.instantiate(with: info.componentDescription, options: .loadOutOfProcess)
        } catch {
            outOfProcess = false
            unit = try await AVAudioUnit.instantiate(with: info.componentDescription, options: [])
        }
        // Vérifié ici, car un format refusé au moment du branchement ferait planter AVAudioEngine.
        do {
            try unit.auAudioUnit.inputBusses[0].setFormat(format)
            try unit.auAudioUnit.outputBusses[0].setFormat(format)
        } catch {
            throw PluginError.unsupportedFormat(info.name)
        }
        return HostedPlugin(info: info, unit: unit, isOutOfProcess: outOfProcess)
    }

    /// False once the process hosting the plugin is gone: a property read then fails with an XPC error
    /// (connection invalid or interrupted) or `kAudioComponentErr_InstanceInvalidated`. The system's
    /// invalidation notification is not posted for v2 plugins bridged out of process, hence this poll.
    public var isAlive: Bool {
        guard isOutOfProcess else { return true }
        var latency: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioUnitGetProperty(unit.audioUnit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)
        let xpcInterrupted: OSStatus = 4097, xpcInvalid: OSStatus = 4099
        return ![xpcInterrupted, xpcInvalid, kAudioComponentErr_InstanceInvalidated].contains(status)
    }

    // MARK: Paramètres

    public var parameters: [PluginParameter] {
        (unit.auAudioUnit.parameterTree?.allParameters ?? [])
            .filter { $0.flags.contains(.flag_IsWritable) }
            .map { PluginParameter(address: $0.address, name: $0.displayName) }
    }

    private func parameter(_ address: UInt64) -> AUParameter? {
        unit.auAudioUnit.parameterTree?.parameter(withAddress: address)
    }

    /// Valeur normalisée 0…1 (nil si le paramètre n'existe pas).
    public func normalizedValue(_ address: UInt64) -> Double? {
        guard let parameter = parameter(address), parameter.maxValue > parameter.minValue else { return nil }
        return Double((parameter.value - parameter.minValue) / (parameter.maxValue - parameter.minValue))
    }

    public func setNormalizedValue(_ address: UInt64, _ normalized: Double) {
        guard let parameter = parameter(address) else { return }
        parameter.value = parameter.minValue + AUValue(min(1, max(0, normalized))) * (parameter.maxValue - parameter.minValue)
    }

    /// La valeur telle que le plugin l'affiche (« 350 ms », « Hall »…), sinon un pourcentage.
    public func displayValue(_ address: UInt64) -> String {
        guard let parameter = parameter(address) else { return "—" }
        var value = parameter.value
        let text = parameter.string(fromValue: &value)
        if !text.isEmpty, Double(text) == nil { return text }
        let unit = parameter.unitName.map { " \($0)" } ?? ""
        return (abs(value) >= 100 ? String(format: "%.0f", value) : String(format: "%.2f", value)) + unit
    }

    // MARK: État (enregistré dans le projet)

    public var state: Data? {
        guard let fullState = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: fullState, format: .binary, options: 0)
    }

    public func restore(_ data: Data) {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = plist
        }
    }
}
