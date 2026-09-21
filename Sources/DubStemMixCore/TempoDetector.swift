import AVFoundation

/// Estimation du tempo d'un morceau à partir de ses stems, hors du thread principal.
///
/// Méthode : enveloppe d'attaques (hausse d'énergie par tranche de ~5 ms, sommée sur tous les stems),
/// autocorrélation, puis recherche du tempo dont la période ET ses multiples tombent sur des pics
/// (les multiples affinent la précision).
public enum TempoDetector {
    static let hop = 256
    static let analysisSeconds = 60.0
    /// Moitié et double tempo expliquent aussi bien le signal : on répond toujours dans la plage où le reggae
    /// se compte, et l'utilisateur a ×2 / ÷2 pour l'autre lecture.
    public static let range: ClosedRange<Double> = 58...125

    public static func detect(urls: [URL]) async -> Double? {
        await Task.detached(priority: .utility) { estimate(urls: urls) }.value
    }

    public static func estimate(urls: [URL]) -> Double? {
        var envelope: [Float] = []
        var rate = 0.0
        for url in urls {
            guard let (onsets, sampleRate) = onsetEnvelope(of: url) else { continue }
            if rate == 0 { rate = sampleRate }
            guard sampleRate == rate else { continue }
            if envelope.count < onsets.count { envelope += [Float](repeating: 0, count: onsets.count - envelope.count) }
            for (i, value) in onsets.enumerated() { envelope[i] += value }
        }
        return estimate(envelope: envelope, framesPerSecond: rate / Double(hop))
    }

    /// 60 s prises à partir du quart du morceau (on évite les intros sans rythme).
    private static func onsetEnvelope(of url: URL) -> ([Float], Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let wanted = AVAudioFramePosition(analysisSeconds * rate)
        let start = file.length > wanted * 2 ? file.length / 4 : 0
        let count = AVAudioFrameCount(min(wanted, file.length - start))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buffer, frameCount: count)) != nil, let channels = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        var onsets: [Float] = []
        var previous: Float = 0
        var frame = 0
        while frame + hop <= Int(buffer.frameLength) {
            var energy: Float = 0
            for channel in 0..<channelCount {
                for i in frame..<(frame + hop) { energy += channels[channel][i] * channels[channel][i] }
            }
            let level = log(1 + 1000 * energy / Float(hop * channelCount))
            onsets.append(max(0, level - previous))
            previous = level
            frame += hop
        }
        return (onsets, rate)
    }

    static func estimate(envelope: [Float], framesPerSecond: Double) -> Double? {
        let maxLag = Int(4 * 60 / range.lowerBound * framesPerSecond) + 2 // jusqu'à 4 périodes du tempo le plus lent
        guard envelope.count > maxLag * 2, envelope.contains(where: { $0 > 0 }) else { return nil }

        // Attaques élargies à ~25 ms : sans cela, une période qui ne tombe pas sur un nombre entier de tranches
        // est pénalisée face à une période fausse mais « ronde ».
        var envelope = envelope
        for _ in 0..<2 {
            var smoothed = envelope
            for i in 1..<(envelope.count - 1) { smoothed[i] = 0.25 * envelope[i - 1] + 0.5 * envelope[i] + 0.25 * envelope[i + 1] }
            envelope = smoothed
        }

        var autocorrelation = [Float](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum: Float = 0
            for i in 0..<(envelope.count - lag) { sum += envelope[i] * envelope[i + lag] }
            autocorrelation[lag] = sum / Float(envelope.count - lag)
        }
        func value(at lag: Double) -> Float {
            let i = Int(lag)
            guard i + 1 < autocorrelation.count else { return 0 }
            let fraction = Float(lag - Double(i))
            return autocorrelation[i] * (1 - fraction) + autocorrelation[i + 1] * fraction
        }

        var best = (bpm: 0.0, score: -Float.infinity)
        for step in 0...Int((range.upperBound - range.lowerBound) * 10) {
            let bpm = range.lowerBound + Double(step) / 10
            let period = 60 / bpm * framesPerSecond
            var score: Float = 0
            for multiple in 1...4 { score += value(at: period * Double(multiple)) / Float(multiple) }
            if score > best.score { best = (bpm, score) }
        }
        guard best.score > 0 else { return nil }
        let rounded = best.bpm.rounded()
        return abs(best.bpm - rounded) <= 0.15 ? rounded : best.bpm // la plupart des morceaux ont un tempo entier
    }
}
