import CoreMIDI
import Foundation

/// Akai MIDImix via CoreMIDI — mapping d'usine vérifié (PRD § 4). Événements livrés sur la file principale.
final class MidiMix {
    enum Button { case mute, solo, recArm, bankLeft, bankRight, soloMode }
    enum Event {
        case knob(strip: Int, row: Int, value: Float)
        case fader(strip: Int, value: Float)
        case master(value: Float)
        case button(Button, strip: Int, pressed: Bool)
    }

    var onEvent: ((Event) -> Void)?

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var destination: MIDIEndpointRef = 0

    private static let knobCC: [[UInt8]] = [
        [16, 17, 18], [20, 21, 22], [24, 25, 26], [28, 29, 30],
        [46, 47, 48], [50, 51, 52], [54, 55, 56], [58, 59, 60],
    ]
    private static let faderCC: [UInt8] = [19, 23, 27, 31, 49, 53, 57, 61]
    private static let masterCC: UInt8 = 62

    init?() {
        MIDIClientCreateWithBlock("DubStemMix-M0" as CFString, &client, nil)
        guard let source = Self.endpoint(count: MIDIGetNumberOfSources(), get: MIDIGetSource) else { return nil }
        destination = Self.endpoint(count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination) ?? 0

        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] packetList, _ in
            for packet in packetList.unsafeSequence() {
                let length = Int(packet.pointee.length)
                let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
                var i = 0
                while i + 2 < bytes.count {
                    self?.handle(status: bytes[i], data1: bytes[i + 1], data2: bytes[i + 2])
                    i += 3
                }
            }
        }
        MIDIPortConnectSource(inPort, source, nil)
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    }

    private static func endpoint(count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
        for i in 0..<count {
            let endpoint = get(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            if let name = name?.takeRetainedValue() as String?, name.localizedCaseInsensitiveContains("MIDI Mix") {
                return endpoint
            }
        }
        return nil
    }

    private func handle(status: UInt8, data1: UInt8, data2: UInt8) {
        let kind = status & 0xF0
        var event: Event?
        if kind == 0xB0 {
            let value = Float(data2) / 127
            if data1 == Self.masterCC {
                event = .master(value: value)
            } else if let strip = Self.faderCC.firstIndex(of: data1) {
                event = .fader(strip: strip, value: value)
            } else if let strip = Self.knobCC.firstIndex(where: { $0.contains(data1) }) {
                event = .knob(strip: strip, row: Self.knobCC[strip].firstIndex(of: data1)!, value: value)
            }
        } else if kind == 0x90 || kind == 0x80 {
            let pressed = kind == 0x90 && data2 > 0
            switch data1 {
            case 25: event = .button(.bankLeft, strip: 0, pressed: pressed)
            case 26: event = .button(.bankRight, strip: 0, pressed: pressed)
            case 27: event = .button(.soloMode, strip: 0, pressed: pressed)
            case 1...24:
                let strip = Int(data1 - 1) / 3
                let button: Button = [.mute, .solo, .recArm][Int(data1 - 1) % 3]
                event = .button(button, strip: strip, pressed: pressed)
            default: break
            }
        }
        if let event {
            DispatchQueue.main.async { self.onEvent?(event) }
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

    func setMuteLed(strip: Int, _ on: Bool) { led(1 + 3 * strip, on) }
    func setSoloLed(strip: Int, _ on: Bool) { led(2 + 3 * strip, on) }
    func setRecLed(strip: Int, _ on: Bool) { led(3 + 3 * strip, on) }
    func allLedsOff() { for note in 1...27 { led(note, false) } }
}
