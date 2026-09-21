import AVFoundation

/// Topologie testée par le spike — la même en live et dans l'auto-test hors ligne :
///
///   lecteur ─┬─▶ mixeur de tranche (fader/mute) ─┬─▶ master
///            │                                   ├─▶ bus delay   (envoi post-fader)
///            │                                   └─▶ bus reverb  (envoi post-fader)
///            └─▶ bus delay (dub throw, pris avant fader et mute)
///
/// Les niveaux d'envoi passent par AVAudioMixingDestination (volume par destination d'un fan-out).
final class MixGraph {
    enum SendBus { case delay, reverb }

    static let stripCount = 8
    private static let delayReturnBus = 8
    private static let reverbReturnBus = 9

    let engine = AVAudioEngine()
    let format: AVAudioFormat
    let stripMixers: [AVAudioMixerNode]
    let delayIn = AVAudioMixerNode()
    let reverbIn = AVAudioMixerNode()
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()

    struct Player {
        let node: AVAudioPlayerNode
        let strip: Int
        let throwBus: Int
    }
    private(set) var players: [Player] = []

    /// - Parameter offline: rendu manuel hors ligne (auto-test), sans carte son.
    /// - Parameter effects: faux → les bus reviennent secs au master (pour mesurer le chemin d'envoi).
    init(format: AVAudioFormat, offline: Bool = false, effects: Bool = true) throws {
        self.format = format
        stripMixers = (0..<Self.stripCount).map { _ in AVAudioMixerNode() }
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        }

        let main = engine.mainMixerNode
        for node in stripMixers + [delayIn, reverbIn] { engine.attach(node) }

        for (i, strip) in stripMixers.enumerated() {
            engine.connect(strip, to: [
                AVAudioConnectionPoint(node: main, bus: i),
                AVAudioConnectionPoint(node: delayIn, bus: i),
                AVAudioConnectionPoint(node: reverbIn, bus: i),
            ], fromBus: 0, format: format)
            setSend(.delay, strip: i, 0)
            setSend(.reverb, strip: i, 0)
        }

        if effects {
            engine.attach(delay)
            engine.attach(reverb)
            delay.wetDryMix = 100
            delay.delayTime = 0.45
            delay.feedback = 55
            delay.lowPassCutoff = 2500
            reverb.loadFactoryPreset(.plate)
            reverb.wetDryMix = 100
            engine.connect(delayIn, to: delay, format: format)
            engine.connect(delay, to: main, fromBus: 0, toBus: Self.delayReturnBus, format: format)
            engine.connect(reverbIn, to: reverb, format: format)
            engine.connect(reverb, to: main, fromBus: 0, toBus: Self.reverbReturnBus, format: format)
        } else {
            engine.connect(delayIn, to: main, fromBus: 0, toBus: Self.delayReturnBus, format: format)
            engine.connect(reverbIn, to: main, fromBus: 0, toBus: Self.reverbReturnBus, format: format)
        }
    }

    @discardableResult
    func addPlayer(strip: Int, format playerFormat: AVAudioFormat? = nil) -> AVAudioPlayerNode {
        let node = AVAudioPlayerNode()
        let throwBus = Self.stripCount + players.count
        engine.attach(node)
        engine.connect(node, to: [
            AVAudioConnectionPoint(node: stripMixers[strip], bus: stripMixers[strip].nextAvailableInputBus),
            AVAudioConnectionPoint(node: delayIn, bus: throwBus),
        ], fromBus: 0, format: playerFormat ?? format)
        players.append(Player(node: node, strip: strip, throwBus: throwBus))
        setThrow(player: players.count - 1, 0)
        return node
    }

    // MARK: Niveaux

    func setFader(strip: Int, _ gain: Float) {
        stripMixers[strip].outputVolume = gain
    }

    func setSend(_ bus: SendBus, strip: Int, _ gain: Float) {
        let mixer = bus == .delay ? delayIn : reverbIn
        guard let destination = stripMixers[strip].destination(forMixer: mixer, bus: strip) else {
            print("⚠️  pas de destination d'envoi pour la tranche \(strip + 1)")
            return
        }
        destination.volume = gain
    }

    /// Coupe le chemin direct tranche → master (sert à l'auto-test pour n'écouter que l'envoi).
    func setDirect(strip: Int, _ gain: Float) {
        stripMixers[strip].destination(forMixer: engine.mainMixerNode, bus: strip)?.volume = gain
    }

    func setThrow(player index: Int, _ gain: Float) {
        let player = players[index]
        guard let destination = player.node.destination(forMixer: delayIn, bus: player.throwBus) else {
            print("⚠️  pas de destination de throw pour le lecteur \(index)")
            return
        }
        destination.volume = gain
    }

    func setThrow(strip: Int, _ gain: Float) {
        for (index, player) in players.enumerated() where player.strip == strip {
            setThrow(player: index, gain)
        }
    }

    func setMaster(_ gain: Float) {
        engine.mainMixerNode.outputVolume = gain
    }
}
