import AVFoundation

/// Any file AVAudioFile reads → stereo Float32 at 44.1 kHz, the model's rate (spec § 5.1).
public enum AudioDecoder {
    public static let sampleRate = 44_100.0

    public enum DecodeError: Error, LocalizedError {
        case empty, conversion
        public var errorDescription: String? {
            switch self {
            case .empty: "The file has no audio"
            case .conversion: "The file could not be converted to 44.1 kHz stereo"
            }
        }
    }

    public static func load(_ url: URL) throws -> StereoBuffer {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw DecodeError.empty
        }
        try file.read(into: buffer)
        guard let stereo = makeStereo(buffer) else { throw DecodeError.conversion }
        if stereo.format.sampleRate == sampleRate { return planar(stereo) }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        guard let converter = AVAudioConverter(from: stereo.format, to: target) else { throw DecodeError.conversion }
        let capacity = AVAudioFrameCount(Double(stereo.frameLength) * sampleRate / stereo.format.sampleRate) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw DecodeError.conversion }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return stereo
        }
        if let conversionError { throw conversionError }
        return planar(converted)
    }

    /// Mono → duplicated channel; more than two channels → the first two. Same rate, Float32 planar.
    private static func makeStereo(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let rate = buffer.format.sampleRate
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        guard let stereo = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        stereo.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        if buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved, let data = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            for c in 0..<2 {
                stereo.floatChannelData![c].update(from: data[min(c, channels - 1)], count: frames)
            }
            return stereo
        }
        // Other sample formats: let AVAudioConverter turn them into float first.
        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: buffer.format.channelCount, interleaved: false)!
        guard let converter = AVAudioConverter(from: buffer.format, to: floatFormat),
              let asFloat = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: buffer.frameLength) else { return nil }
        do { try converter.convert(to: asFloat, from: buffer) } catch { return nil }
        return makeStereo(asFloat)
    }

    private static func planar(_ buffer: AVAudioPCMBuffer) -> StereoBuffer {
        let frames = Int(buffer.frameLength)
        let data = buffer.floatChannelData!
        return StereoBuffer(left: Array(UnsafeBufferPointer(start: data[0], count: frames)),
                            right: Array(UnsafeBufferPointer(start: data[1], count: frames)))
    }
}

/// WAV Float32, 44.1 kHz, stereo (spec § 6.5: interleaved settings, planar buffer).
public enum StemWriter {
    public static func write(_ audio: StereoBuffer, to url: URL, sampleRate: Double = AudioDecoder.sampleRate) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        var offset = 0
        while offset < audio.count {
            let n = min(chunk, audio.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            audio.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: n) }
            audio.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress! + offset, count: n) }
            try file.write(from: buffer)
            offset += n
        }
    }
}
