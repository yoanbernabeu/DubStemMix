import AVFoundation

// Jalon M0 — spike technique jetable (PRD § 7 et § 9).
//
//   swift run M0Spike --selftest
//       auto-test hors ligne : synchro des lecteurs + lissage des volumes
//   swift run M0Spike "<dossier de stems>" [--exclude "<texte>"] [--duration <secondes>]
//       mix live à la MIDImix : faders, MUTE, REC ARM = dub throw,
//       potard haut = envoi delay, potard milieu = envoi reverb,
//       tranche 8 : potards = temps / feedback / coupe-haut du delay.

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

if arguments.contains("--selftest") {
    do { try SelfTest.run() } catch { print("Échec de l'auto-test : \(error)"); exit(1) }
    exit(0)
}

let optionValues = Set(["--exclude", "--duration"].compactMap(option))
guard let folder = arguments.first(where: { !$0.hasPrefix("--") && !optionValues.contains($0) }) else {
    print("Usage : M0Spike --selftest | M0Spike <dossier> [--exclude <texte>] [--duration <s>]")
    exit(1)
}

// MARK: Chargement des stems

let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "m4a"]
let exclude = option("--exclude")
let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? [])
    .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
    .filter { url in exclude.map { !url.lastPathComponent.contains($0) } ?? true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .prefix(MixGraph.stripCount)

guard !urls.isEmpty else { print("Aucun fichier audio dans \(folder)"); exit(1) }

/// Noms de tranche : on retire le préfixe et le suffixe communs à tous les fichiers.
func stripNames(_ names: [String]) -> [String] {
    guard names.count > 1, let first = names.first else { return names }
    let prefix = names.dropFirst().reduce(first) { $0.commonPrefix(with: $1) }
    let suffix = String(names.dropFirst().reduce(String(first.reversed())) { $0.commonPrefix(with: String($1.reversed())) }.reversed())
    return names.map { name in
        let core = name.dropFirst(prefix.count).dropLast(suffix.count)
        return core.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]_-")).uppercased()
    }
}

let files = try urls.map { try AVAudioFile(forReading: $0) }
let names = stripNames(urls.map { $0.deletingPathExtension().lastPathComponent })
let graph = try MixGraph(format: files[0].processingFormat)
let sampleRate = files[0].processingFormat.sampleRate
let loopFrames = files.map(\.length).max()!

print("Stems :")
for (i, file) in files.enumerated() {
    let seconds = Double(file.length) / file.processingFormat.sampleRate
    print("  tranche \(i + 1) : \(names[i])  (\(String(format: "%.1f", seconds)) s)")
    let player = graph.addPlayer(strip: i, format: file.processingFormat)
    // Boucle calée à l'échantillon : chaque itération est programmée à un instant absolu du lecteur,
    // car les stems n'ont pas tous la même longueur.
    for iteration in 0..<64 {
        let when = AVAudioTime(sampleTime: AVAudioFramePosition(iteration) * loopFrames, atRate: sampleRate)
        player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: when)
    }
}

// MARK: État du mix

var faders = [Float](repeating: 0.8, count: MixGraph.stripCount)
var mutes = [Bool](repeating: false, count: MixGraph.stripCount)

/// Fader : gain unité à 80 % de la course. AVAudioMixerNode plafonne à 1,0 (pas de gain au-dessus de l'unité).
func applyFader(_ strip: Int) {
    let gain = mutes[strip] ? 0 : pow(min(1, faders[strip] / 0.8), 2.5)
    graph.setFader(strip: strip, gain)
}

for strip in 0..<MixGraph.stripCount { applyFader(strip) }
graph.setMaster(0.7)

// MARK: MIDImix

let midi = MidiMix()
if let midi {
    print("MIDImix connectée — appuie sur SEND ALL pour caler le mix sur la console.")
    midi.allLedsOff()
    midi.onEvent = { event in
        switch event {
        case let .fader(strip, value):
            faders[strip] = value
            applyFader(strip)
        case let .master(value):
            graph.setMaster(pow(min(1, value / 0.8), 2.5))
        case let .knob(strip, row, value):
            if strip == 7 {
                switch row {
                case 0: graph.delay.delayTime = 0.05 * pow(1.2 / 0.05, Double(value))
                case 1: graph.delay.feedback = value * 95
                default: graph.delay.lowPassCutoff = 300 * pow(12_000 / 300, value)
                }
            } else if row == 0 {
                graph.setSend(.delay, strip: strip, value * value)
            } else if row == 1 {
                graph.setSend(.reverb, strip: strip, value * value)
            }
        case let .button(.mute, strip, pressed) where pressed:
            mutes[strip].toggle()
            applyFader(strip)
            midi.setMuteLed(strip: strip, mutes[strip])
            print("  MUTE \(strip + 1) \(mutes[strip] ? "on" : "off")")
        case let .button(.recArm, strip, pressed):
            graph.setThrow(strip: strip, pressed ? 1 : 0)
            midi.setRecLed(strip: strip, pressed)
            if pressed { print("  THROW \(strip + 1)") }
        case let .button(.solo, strip, pressed):
            print("  SOLO+MUTE \(strip + 1) \(pressed ? "appuyé" : "relâché")  ← geste confirmé")
        default:
            break
        }
    }
} else {
    print("MIDImix introuvable : lecture seule, sans contrôle.")
}

// MARK: Lecture

try graph.engine.start()
let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.3))
for player in graph.players { player.node.play(at: startTime) }

let output = graph.engine.outputNode.outputFormat(forBus: 0)
print("Lecture en boucle — sortie \(Int(output.sampleRate)) Hz, \(output.channelCount) canaux. Ctrl-C pour quitter.")

func quit() -> Never {
    graph.engine.stop()
    midi?.allLedsOff()
    print("\nFin.")
    exit(0)
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { quit() }
interrupt.resume()

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { quit() }
terminate.resume()

if let duration = option("--duration").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { quit() }
}

let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 5, repeating: 5)
ticker.setEventHandler {
    let node = graph.players[0].node
    guard let renderTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: renderTime) else { return }
    let position = Double(time.sampleTime % loopFrames) / sampleRate
    print(String(format: "  position %d:%04.1f", Int(position) / 60, position.truncatingRemainder(dividingBy: 60)))
}
ticker.resume()

dispatchMain()
