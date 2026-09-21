import AVFoundation

/// Enregistre le master dans un fichier WAV 24 bits. Les tampons arrivent d'un tap AVAudioEngine,
/// c'est-à-dire hors du thread de rendu temps réel : écrire sur le disque ici ne peut pas faire décrocher l'audio.
public final class MasterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    private var sampleRate = 48_000.0

    public init() {}

    public var isRecording: Bool { lock.withLock { file != nil } }
    public var duration: Double { lock.withLock { Double(frames) / sampleRate } }

    public func start(to url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let newFile = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        lock.withLock {
            file = newFile
            self.url = url
            frames = 0
            sampleRate = format.sampleRate
        }
    }

    /// Ferme le fichier et renvoie son emplacement.
    @discardableResult
    public func stop() -> URL? {
        lock.withLock {
            defer { file = nil; url = nil }
            return file == nil ? nil : url
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file else { return }
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            } catch {
                self.file = nil // disque plein, volume éjecté… : on arrête proprement plutôt que d'insister
            }
        }
    }
}
