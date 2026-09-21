import AVFoundation

/// Auto-test hors ligne des risques 1 et 2 du PRD, sans carte son ni console :
///  - synchro : deux lecteurs démarrés au même instant sortent-ils au même échantillon ?
///  - lissage : un changement de volume produit-il un saut (« zipper noise ») dans le signal ?
enum SelfTest {
    static let sampleRate = 48_000.0
    static let block = 512
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    static func run() throws {
        print("== Synchro de deux lecteurs ==")
        try syncTest()
        print("\n== Lissage des changements de volume (sinus 100 Hz, amplitude 0,8) ==")
        print("   pente naturelle max du sinus : \(String(format: "%.4f", naturalSlope)) par échantillon")
        try zipperTest("fader de tranche 1 → 0,1 (outputVolume)", prepare: { _ in }) { $0.setFader(strip: 0, 0.1) }
        try zipperTest("envoi delay 0 → 1 (destination)", prepare: { $0.setDirect(strip: 0, 0) }) {
            $0.setSend(.delay, strip: 0, 1)
        }
        try zipperTest("dub throw 0 → 1 (destination du lecteur)", prepare: { $0.setFader(strip: 0, 0) }) {
            $0.setThrow(strip: 0, 1)
        }
        try zipperTest("master 1 → 0,1 (mainMixer.outputVolume)", prepare: { _ in }) { $0.setMaster(0.1) }
    }

    // MARK: Synchro

    static func syncTest() throws {
        let graph = try MixGraph(format: format, offline: true, effects: false)
        let impulse = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        impulse.frameLength = 4800
        for channel in 0..<2 { impulse.floatChannelData![channel][0] = 0.5 }

        let a = graph.addPlayer(strip: 0)
        let b = graph.addPlayer(strip: 1)
        try graph.engine.start()
        let startTime = AVAudioTime(sampleTime: 4800, atRate: sampleRate)
        for player in [a, b] {
            player.scheduleBuffer(impulse, at: nil)
            player.play(at: startTime)
        }
        let output = try render(graph, frames: 24_000) { _ in }
        let hits = output.enumerated().filter { abs($0.element) > 0.01 }
        for hit in hits { print("   échantillon \(hit.offset) : \(String(format: "%.3f", hit.element))") }
        if hits.count == 1, abs(hits[0].element - 1.0) < 0.01 {
            print("   ✅ une seule impulsion d'amplitude 1,0 → les deux lecteurs sont calés à l'échantillon")
        } else {
            print("   ❌ attendu : une seule impulsion d'amplitude 1,0")
        }
    }

    // MARK: Lissage

    static let naturalSlope = Float(0.8 * 2 * Double.pi * 100 / sampleRate)

    /// Rend 1 s du graphe avec un signal test sur la tranche 1 ; `change` est appliqué juste avant le bloc 20.
    static func renderChange(dc: Bool, prepare: (MixGraph) -> Void, change: (MixGraph) -> Void) throws -> [Float] {
        let graph = try MixGraph(format: format, offline: true, effects: false)
        let signal = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        signal.frameLength = 96_000
        for channel in 0..<2 {
            for n in 0..<96_000 {
                signal.floatChannelData![channel][n] = dc ? 0.8 : Float(0.8 * sin(2 * Double.pi * 100 * Double(n) / sampleRate))
            }
        }
        let player = graph.addPlayer(strip: 0)
        prepare(graph)
        try graph.engine.start()
        player.scheduleBuffer(signal, at: nil)
        player.play()
        return try render(graph, frames: 48_000) { blockIndex in
            if blockIndex == 20 { change(graph) }
        }
    }

    static func zipperTest(_ name: String, prepare: (MixGraph) -> Void, change: (MixGraph) -> Void) throws {
        // Signal continu : la sortie EST la courbe de gain → on voit la rampe réellement appliquée.
        let gain = try renderChange(dc: true, prepare: prepare, change: change)
        let before = gain[20 * block - 1]
        let after = gain[gain.count - 1]
        let rampStart = (20 * block..<gain.count).first { abs(gain[$0] - before) > 0.0005 } ?? -1
        let rampEnd = (20 * block..<gain.count).first { abs(gain[$0] - after) < 0.0005 } ?? -1
        var maxStep: Float = 0
        for n in (20 * block)..<gain.count { maxStep = max(maxStep, abs(gain[n] - gain[n - 1])) }
        print("   · \(name)")
        print("       gain \(String(format: "%.3f", before)) → \(String(format: "%.3f", after)), rampe de l'échantillon \(rampStart) à \(rampEnd) (\(rampEnd - rampStart) éch.), plus grand pas : \(String(format: "%.5f", maxStep))")

        // Sinus : le changement tombe près d'une crête (là où un saut s'entendrait le plus).
        let output = try renderChange(dc: false, prepare: prepare, change: change)
        var maxSlope: Float = 0
        var maxIndex = 0
        for n in 1..<output.count {
            let slope = abs(output[n] - output[n - 1])
            if slope > maxSlope { maxSlope = slope; maxIndex = n }
        }
        let ratio = maxSlope / naturalSlope
        let verdict = ratio < 2 ? "✅ lissé" : "❌ SAUT audible"
        print("       \(verdict) sur sinus : pente max \(String(format: "%.4f", maxSlope)) (×\(String(format: "%.1f", ratio))) à l'échantillon \(maxIndex)")
    }

    // MARK: Rendu hors ligne

    static func render(_ graph: MixGraph, frames: Int, onBlock: (Int) -> Void) throws -> [Float] {
        let engine = graph.engine
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(block))!
        var output: [Float] = []
        var blockIndex = 0
        while output.count < frames {
            onBlock(blockIndex)
            let status = try engine.renderOffline(AVAudioFrameCount(block), to: buffer)
            guard status == .success else {
                print("   rendu interrompu (statut \(status.rawValue))")
                break
            }
            output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            blockIndex += 1
        }
        return output
    }
}
