import AVFoundation

/// Crêtes d'un fichier audio pour la forme d'onde globale, calculées hors du thread principal.
public enum Waveform {
    /// Durée couverte par une crête. Commune à tous les stems pour pouvoir les superposer.
    public static let binDuration = 0.25

    public static func peaks(of url: URL) async -> [Float] {
        await Task.detached(priority: .utility) { computePeaks(of: url) }.value
    }

    static func computePeaks(of url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)
        else { return [] }
        let framesPerBin = max(1, Int(file.processingFormat.sampleRate * binDuration))
        var peaks = [Float](repeating: 0, count: Int(file.length) / framesPerBin + 1)
        var frame = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for i in stride(from: 0, to: Int(buffer.frameLength), by: 8) {
                    let bin = (frame + i) / framesPerBin
                    peaks[bin] = max(peaks[bin], abs(channels[channel][i]))
                }
            }
            frame += Int(buffer.frameLength)
        }
        return peaks
    }

    /// Superpose les crêtes de plusieurs stems (de longueurs différentes).
    public static func combine(_ all: [[Float]]) -> [Float] {
        var combined = [Float](repeating: 0, count: all.map(\.count).max() ?? 0)
        for peaks in all {
            for (i, peak) in peaks.enumerated() { combined[i] = max(combined[i], peak) }
        }
        return combined
    }
}
