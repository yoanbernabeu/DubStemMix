// Moniteur MIDI pour l'Akai MIDImix (CoreMIDI, sans dépendance).
// Usage : swift tools/midi-monitor.swift [durée_en_secondes] [--leds]
//   --leds : fait défiler les LEDs (Note On 1..27) avant d'écouter.

import CoreMIDI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let duration = args.dropFirst().compactMap { Double($0) }.first ?? 30
let ledTest = args.contains("--leds")
let deviceHint = "MIDI Mix"

func displayName(_ obj: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}

var client = MIDIClientRef()
MIDIClientCreateWithBlock("DubStemMixMonitor" as CFString, &client, nil)

var source: MIDIEndpointRef = 0
var destination: MIDIEndpointRef = 0

print("Sources MIDI :")
for i in 0..<MIDIGetNumberOfSources() {
    let s = MIDIGetSource(i)
    print("  [\(i)] \(displayName(s))")
    if source == 0, displayName(s).localizedCaseInsensitiveContains(deviceHint) { source = s }
}
print("Destinations MIDI :")
for i in 0..<MIDIGetNumberOfDestinations() {
    let d = MIDIGetDestination(i)
    print("  [\(i)] \(displayName(d))")
    if destination == 0, displayName(d).localizedCaseInsensitiveContains(deviceHint) { destination = d }
}

guard source != 0 else {
    print("ERREUR : aucune source « \(deviceHint) » trouvée.")
    exit(1)
}

let start = Date()
func stamp() -> String { String(format: "%7.3f", Date().timeIntervalSince(start)) }

var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { pktList, _ in
    for packet in pktList.unsafeSequence() {
        let len = Int(packet.pointee.length)
        let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(len)) }
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            let kind = status & 0xF0
            let ch = Int(status & 0x0F) + 1
            if (kind == 0x80 || kind == 0x90 || kind == 0xB0), i + 2 < bytes.count {
                let d1 = bytes[i + 1], d2 = bytes[i + 2]
                let label = kind == 0xB0 ? "CC      " : (kind == 0x90 ? "NOTE_ON " : "NOTE_OFF")
                print("\(stamp())  \(label) ch=\(ch) num=\(d1) val=\(d2)")
                i += 3
            } else {
                let hex = bytes[i...].map { String(format: "%02X", $0) }.joined(separator: " ")
                print("\(stamp())  RAW      \(hex)")
                break
            }
        }
    }
}
MIDIPortConnectSource(inPort, source, nil)

var outPort = MIDIPortRef()
MIDIOutputPortCreate(client, "out" as CFString, &outPort)

func send(_ bytes: [UInt8]) {
    guard destination != 0 else { return }
    var list = MIDIPacketList()
    var pkt = MIDIPacketListInit(&list)
    pkt = MIDIPacketListAdd(&list, 1024, pkt, 0, bytes.count, bytes)
    MIDISend(outPort, destination, &list)
}

if ledTest {
    DispatchQueue.global().async {
        print("\(stamp())  Test LEDs : chenillard notes 1..27")
        for note in UInt8(1)...27 {
            send([0x90, note, 127])
            Thread.sleep(forTimeInterval: 0.08)
        }
        Thread.sleep(forTimeInterval: 1.0)
        for note in UInt8(1)...27 { send([0x90, note, 0]) }
        print("\(stamp())  Test LEDs terminé (toutes éteintes)")
    }
}

print("Écoute de « \(displayName(source)) » pendant \(Int(duration)) s…")
RunLoop.main.run(until: Date().addingTimeInterval(duration))
print("Fin.")
