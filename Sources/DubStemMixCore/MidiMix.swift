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

/// A controller's factory mapping as data (PRD § 7): what each MIDI message means, and which notes light the
/// LEDs. Adding a controller with the MIDImix geometry (8 strips × 3 knobs + fader, MUTE / SOLO / REC ARM per
/// strip, two bank buttons, a master fader) is a matter of writing one of these, see the README's FAQ.
public struct ControllerProfile: Sendable {
    public var name: String
    /// Case-insensitive fragment of the CoreMIDI display name that identifies the device.
    public var deviceNameContains: String
    /// Control-change numbers of the knobs, per strip then per row (top, middle, bottom).
    public var knobCC: [[UInt8]]
    public var faderCC: [UInt8]
    public var masterCC: UInt8
    /// Note numbers of the buttons, per strip.
    public var muteNotes: [UInt8]
    public var soloNotes: [UInt8]
    public var recArmNotes: [UInt8]
    public var bankLeftNote: UInt8
    public var bankRightNote: UInt8
    /// A modifier button, held while pressing MUTE to solo (the MIDImix's SOLO); nil when the controller has none.
    public var soloModeNote: UInt8?
    /// LEDs are lit with a Note On (velocity 127) on the button's own note; false for a controller without LEDs.
    public var hasLEDs: Bool

    public init(name: String, deviceNameContains: String, knobCC: [[UInt8]], faderCC: [UInt8], masterCC: UInt8,
                muteNotes: [UInt8], soloNotes: [UInt8], recArmNotes: [UInt8], bankLeftNote: UInt8, bankRightNote: UInt8,
                soloModeNote: UInt8?, hasLEDs: Bool) {
        self.name = name
        self.deviceNameContains = deviceNameContains
        self.knobCC = knobCC
        self.faderCC = faderCC
        self.masterCC = masterCC
        self.muteNotes = muteNotes
        self.soloNotes = soloNotes
        self.recArmNotes = recArmNotes
        self.bankLeftNote = bankLeftNote
        self.bankRightNote = bankRightNote
        self.soloModeNote = soloModeNote
        self.hasLEDs = hasLEDs
    }

    /// Akai MIDImix, factory mapping, verified on the console (PRD § 4). Channel 1; buttons send Note On when
    /// pressed and Note Off when released; per strip i (0-based): MUTE = 1 + 3i, SOLO = 2 + 3i, REC ARM = 3 + 3i.
    public static let midiMix = ControllerProfile(
        name: "Akai MIDImix",
        deviceNameContains: "MIDI Mix",
        knobCC: [[16, 17, 18], [20, 21, 22], [24, 25, 26], [28, 29, 30], [46, 47, 48], [50, 51, 52], [54, 55, 56], [58, 59, 60]],
        faderCC: [19, 23, 27, 31, 49, 53, 57, 61],
        masterCC: 62,
        muteNotes: (0..<8).map { UInt8(1 + 3 * $0) },
        soloNotes: (0..<8).map { UInt8(2 + 3 * $0) },
        recArmNotes: (0..<8).map { UInt8(3 + 3 * $0) },
        bankLeftNote: 25,
        bankRightNote: 26,
        soloModeNote: 27,
        hasLEDs: true
    )

    /// Every profile the app knows; the first one whose device is plugged in wins.
    public static let all: [ControllerProfile] = [.midiMix]

    /// A 3-byte channel message → a surface event, or nil when the profile does not know it. Channel-agnostic.
    public func decode(status: UInt8, data1: UInt8, data2: UInt8) -> SurfaceEvent? {
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
            if data1 == bankLeftNote { return .button(.bankLeft, strip: 0, pressed: pressed) }
            if data1 == bankRightNote { return .button(.bankRight, strip: 0, pressed: pressed) }
            if data1 == soloModeNote { return .button(.soloMode, strip: 0, pressed: pressed) }
            if let strip = muteNotes.firstIndex(of: data1) { return .button(.mute, strip: strip, pressed: pressed) }
            if let strip = soloNotes.firstIndex(of: data1) { return .button(.solo, strip: strip, pressed: pressed) }
            if let strip = recArmNotes.firstIndex(of: data1) { return .button(.recArm, strip: strip, pressed: pressed) }
            return nil
        default:
            return nil
        }
    }

    /// Describes a control change or note that `decode` rejected; nil for anything else (clock, sysex…).
    public static func unmappedDescription(status: UInt8, data1: UInt8) -> String? {
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0: return "CC \(data1) on channel \(channel)"
        case 0x90, 0x80: return "note \(data1) on channel \(channel)"
        default: return nil
        }
    }
}

/// CoreMIDI transport for a controller profile (the MIDImix by default): finds the device by name, hot plug
/// and unplug, events delivered on the MainActor, LEDs sent back.
@MainActor
public final class MidiMix: ControlSurface {
    public var onEvent: ((SurfaceEvent) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    /// A control change or note the profile does not know: the console has probably been
    /// reconfigured with the Akai editor (PRD § 4). The string describes the message, e.g. "CC 70 on channel 2".
    public var onUnmappedMessage: ((String) -> Void)?
    public private(set) var isConnected = false
    public let profile: ControllerProfile

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0

    public init(profile: ControllerProfile = .midiMix) {
        self.profile = profile
    }

    public func start() {
        MIDIClientCreateWithBlock("DubStemMix" as CFString, &client, Self.notifyBlock { [weak self] in self?.rescan() })
        let profile = profile
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort, Self.readBlock(
            profile: profile,
            deliver: { [weak self] event in self?.onEvent?(event) },
            unmapped: { [weak self] description in self?.onUnmappedMessage?(description) }
        ))
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        rescan()
    }

    private func rescan() {
        let newSource = Self.endpoint(named: profile.deviceNameContains, count: MIDIGetNumberOfSources(), get: MIDIGetSource)
        destination = Self.endpoint(named: profile.deviceNameContains, count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination)
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

    private static func endpoint(named fragment: String, count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef {
        for i in 0..<count {
            let endpoint = get(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            if let name = name?.takeRetainedValue() as String?, name.localizedCaseInsensitiveContains(fragment) {
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
        profile: ControllerProfile,
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
                    if let event = profile.decode(status: bytes[i], data1: bytes[i + 1], data2: bytes[i + 2]) {
                        events.append(event)
                    } else if let description = ControllerProfile.unmappedDescription(status: bytes[i], data1: bytes[i + 1]) {
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

    // MARK: Factory mapping helpers kept for the tests

    nonisolated static func decode(status: UInt8, data1: UInt8, data2: UInt8) -> SurfaceEvent? {
        ControllerProfile.midiMix.decode(status: status, data1: data1, data2: data2)
    }

    nonisolated static func unmappedDescription(status: UInt8, data1: UInt8) -> String? {
        ControllerProfile.unmappedDescription(status: status, data1: data1)
    }

    // MARK: LEDs (Note On on the button's own note: 127 = lit, 0 = off)

    private func led(_ note: UInt8, _ on: Bool) {
        guard profile.hasLEDs, destination != 0 else { return }
        let bytes: [UInt8] = [0x90, note, on ? 127 : 0]
        var list = MIDIPacketList()
        var packet = MIDIPacketListInit(&list)
        packet = MIDIPacketListAdd(&list, 1024, packet, 0, bytes.count, bytes)
        MIDISend(outPort, destination, &list)
    }

    public func setMuteLed(strip: Int, _ on: Bool) { led(profile.muteNotes[strip], on) }
    public func setSoloLed(strip: Int, _ on: Bool) { led(profile.soloNotes[strip], on) }
    public func setRecLed(strip: Int, _ on: Bool) { led(profile.recArmNotes[strip], on) }
    public func setBankLeds(left: Bool, right: Bool) {
        led(profile.bankLeftNote, left)
        led(profile.bankRightNote, right)
    }
    public func allLedsOff() {
        for note in profile.muteNotes + profile.soloNotes + profile.recArmNotes + [profile.bankLeftNote, profile.bankRightNote] { led(note, false) }
        if let solo = profile.soloModeNote { led(solo, false) }
    }
}
