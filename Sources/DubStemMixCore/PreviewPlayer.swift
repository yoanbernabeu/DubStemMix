import AVFoundation
import CoreAudio

/// Listening to a song in the setlist workshop (PRD § 13): its files summed, raw, without effects, from any point.
/// A small engine of its own on the console's output device: the console's engine and session are not touched.
/// One song at a time.
public final class PreviewPlayer {
    private let engine = AVAudioEngine()
    private var tracks: [(player: AVAudioPlayerNode, file: AVAudioFile)] = []
    /// Where playback started from, in seconds; the players count from there.
    private var startOffset = 0.0

    public private(set) var duration = 0.0
    public private(set) var isPlaying = false

    public init() {}

    /// Plays `files` together from `seconds`, on the device `deviceID` (the default output when nil).
    public func play(_ files: [URL], deviceID: AudioDeviceID?, from seconds: Double = 0) throws {
        stop()
        tracks.forEach { engine.detach($0.player) }
        tracks = []
        let opened = files.compactMap { try? AVAudioFile(forReading: $0) }
        guard !opened.isEmpty else { throw PreviewError.nothingToPlay }
        for file in opened {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            tracks.append((player, file))
        }
        // Several stems summed: kept clear of clipping.
        engine.mainMixerNode.outputVolume = opened.count > 1 ? 0.7 : 1
        duration = opened.map { Double($0.length) / $0.processingFormat.sampleRate }.max() ?? 0
        if let deviceID, deviceID != 0, engine.outputNode.auAudioUnit.deviceID != deviceID {
            try? engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        }
        engine.prepare()
        try engine.start()
        start(at: seconds)
    }

    /// Jumps to `seconds` in the song being played.
    public func seek(to seconds: Double) {
        guard !tracks.isEmpty else { return }
        tracks.forEach { $0.player.stop() }
        if !engine.isRunning { try? engine.start() }
        start(at: seconds)
    }

    public func stop() {
        tracks.forEach { $0.player.stop() }
        engine.stop()
        isPlaying = false
    }

    /// Seconds from the start of the song.
    public var position: Double {
        guard isPlaying, let track = tracks.first, let nodeTime = track.player.lastRenderTime,
              let playerTime = track.player.playerTime(forNodeTime: nodeTime), playerTime.sampleRate > 0
        else { return startOffset }
        return min(duration, startOffset + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate))
    }

    private func start(at seconds: Double) {
        startOffset = min(max(0, seconds), duration)
        for (player, file) in tracks {
            let rate = file.processingFormat.sampleRate
            let first = AVAudioFramePosition(startOffset * rate)
            guard first < file.length else { continue }
            player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(file.length - first), at: nil)
        }
        // All together, a few milliseconds from now.
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        tracks.forEach { $0.player.play(at: when) }
        isPlaying = true
    }

    public enum PreviewError: Error { case nothingToPlay }
}
