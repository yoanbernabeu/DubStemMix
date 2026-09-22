import CoreMIDI
import Foundation

/// Retour visuel vers la console (LEDs). Abstrait pour tester le contrôleur sans matériel.
@MainActor
public protocol ControlSurface: AnyObject {
    func setMuteLed(strip: Int, _ on: Bool)
    func setSoloLed(strip: Int, _ on: Bool)
    func setRecLed(strip: Int, _ on: Bool)
    func setBankLeds(left: Bool, right: Bool)
}

public enum SurfaceButton: Sendable {
    case mute, solo, recArm, bankLeft, bankRight, soloMode
}

public enum SurfaceEvent: Sendable {
    case knob(strip: Int, row: Int, value: Double)
    case fader(strip: Int, value: Double)
    case master(value: Double)
    case button(SurfaceButton, strip: Int, pressed: Bool)
}

/// Akai MIDImix via CoreMIDI — mapping d'usine vérifié sur la console (PRD § 4).
/// Branchement et débranchement à chaud ; événements livrés sur le MainActor.
@MainActor
public final class MidiMix: ControlSurface {
    public var onEvent: ((SurfaceEvent) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    /// A control change or note the factory mapping does not know: the console has probably been
    /// reconfigured with the Akai editor (PRD § 4). The string describes the message, e.g. "CC 70 on channel 2".
    public var onUnmappedMessage: ((String) -> Void)?
    public private(set) var isConnected = false

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0

    public init() {}

    public func start() {
        MIDIClientCreateWithBlock("DubStemMix" as CFString, &client, Self.notifyBlock { [weak self] in self?.rescan() })
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort, Self.readBlock(
            deliver: { [weak self] event in self?.onEvent?(event) },
            unmapped: { [weak self] description in self?.onUnmappedMessage?(description) }
        ))
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        rescan()
    }

    private func rescan() {
        let newSource = Self.endpoint(count: MIDIGetNumberOfSources(), get: MIDIGetSource)
        destination = Self.endpoint(count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination)
        if newSource != source {
            if source != 0 { MIDIPortDisconnectSource(inPort, source) }
            if newSource != 0 { MIDIPortConnectSource(inPort, newSource, nil) }
            source = newSource
        }
        let connected = source != 0
        if connected != isConnected {
            isConnected = connected
            onConnectionChange?(connected)
        }
    }

    private static func endpoint(count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef {
        for i in 0..<count {
            let endpoint = get(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            if let name = name?.takeRetainedValue() as String?, name.localizedCaseInsensitiveContains("MIDI Mix") {
                return endpoint
            }
        }
        return 0
    }

    // Les blocs CoreMIDI s'exécutent sur des threads système : ils sont construits hors du MainActor
    // et y reviennent explicitement.

    private nonisolated static func notifyBlock(_ onChange: @escaping @MainActor () -> Void) -> MIDINotifyBlock {
        { notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
        }
    }

    private nonisolated static func readBlock(
        deliver: @escaping @MainActor (SurfaceEvent) -> Void,
        unmapped: @escaping @MainActor (String) -> Void
    ) -> MIDIReadBlock {
        { packetList, _ in
            var events: [SurfaceEvent] = []
            var unknown: [String] = []
            for packet in packetList.unsafeSequence() {
                let length = Int(packet.pointee.length)
                let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
                var i = 0
                while i + 2 < bytes.count {
                    if let event = decode(status: bytes[i], data1: bytes[i + 1], data2: bytes[i + 2]) {
                        events.append(event)
                    } else if let description = unmappedDescription(status: bytes[i], data1: bytes[i + 1]) {
                        unknown.append(description)
                    }
                    i += 3
                }
            }
            guard !events.isEmpty || !unknown.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                events.forEach(deliver)
                unknown.forEach(unmapped)
            } }
        }
    }

    // MARK: Mapping d'usine

    private nonisolated static let knobCC: [[UInt8]] = [
        [16, 17, 18], [20, 21, 22], [24, 25, 26], [28, 29, 30],
        [46, 47, 48], [50, 51, 52], [54, 55, 56], [58, 59, 60],
    ]
    private nonisolated static let faderCC: [UInt8] = [19, 23, 27, 31, 49, 53, 57, 61]
    private nonisolated static let masterCC: UInt8 = 62
    private nonisolated static let bankLeftNote = 25
    private nonisolated static let bankRightNote = 26
    private nonisolated static let soloModeNote = 27

    nonisolated static func decode(status: UInt8, data1: UInt8, data2: UInt8) -> SurfaceEvent? {
        switch status & 0xF0 {
        case 0xB0:
            let value = Double(data2) / 127
            if data1 == masterCC { return .master(value: value) }
            if let strip = faderCC.firstIndex(of: data1) { return .fader(strip: strip, value: value) }
            if let strip = knobCC.firstIndex(where: { $0.contains(data1) }),
               let row = knobCC[strip].firstIndex(of: data1) {
                return .knob(strip: strip, row: row, value: value)
            }
            return nil
        case 0x90, 0x80:
            let pressed = status & 0xF0 == 0x90 && data2 > 0
            switch Int(data1) {
            case bankLeftNote: return .button(.bankLeft, strip: 0, pressed: pressed)
            case bankRightNote: return .button(.bankRight, strip: 0, pressed: pressed)
            case soloModeNote: return .button(.soloMode, strip: 0, pressed: pressed)
            case 1...24:
                // Par tranche : mute = 1 + 3i, solo (MUTE avec SOLO maintenu) = 2 + 3i, rec arm = 3 + 3i.
                let button: SurfaceButton = [.mute, .solo, .recArm][Int(data1 - 1) % 3]
                return .button(button, strip: Int(data1 - 1) / 3, pressed: pressed)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Describes a control change or note that `decode` rejected; nil for anything else (clock, sysex…).
    nonisolated static func unmappedDescription(status: UInt8, data1: UInt8) -> String? {
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0: return "CC \(data1) on channel \(channel)"
        case 0x90, 0x80: return "note \(data1) on channel \(channel)"
        default: return nil
        }
    }

    // MARK: LEDs (Note On sur la note du bouton : 127 = allumée, 0 = éteinte)

    private func led(_ note: Int, _ on: Bool) {
        guard destination != 0 else { return }
        let bytes: [UInt8] = [0x90, UInt8(note), on ? 127 : 0]
        var list = MIDIPacketList()
        var packet = MIDIPacketListInit(&list)
        packet = MIDIPacketListAdd(&list, 1024, packet, 0, bytes.count, bytes)
        MIDISend(outPort, destination, &list)
    }

    public func setMuteLed(strip: Int, _ on: Bool) { led(1 + 3 * strip, on) }
    public func setSoloLed(strip: Int, _ on: Bool) { led(2 + 3 * strip, on) }
    public func setRecLed(strip: Int, _ on: Bool) { led(3 + 3 * strip, on) }
    public func setBankLeds(left: Bool, right: Bool) {
        led(Self.bankLeftNote, left)
        led(Self.bankRightNote, right)
    }
    public func allLedsOff() { for note in 1...27 { led(note, false) } }
}
