import AVFoundation
import Foundation
import Testing
@testable import StemSplit

// MARK: - Chunking and overlap-add (spec § 8)

@Test func chunkCountsMatchTheSpec() {
    let n = OverlapAdd.chunkLength
    #expect(OverlapAdd.chunkCount(total: 44_100) == 1)
    #expect(OverlapAdd.chunkCount(total: n) == 2) // N samples: one full stride plus a tail
    #expect(OverlapAdd.chunkCount(total: OverlapAdd.stride) == 1)
    #expect(OverlapAdd.chunkCount(total: OverlapAdd.stride + 1) == 2)
    #expect(OverlapAdd.chunkCount(total: 8_772_480) == 35) // 198.9 s
}

@Test func overlapAddWithIdentityChunksReturnsTheSignal() {
    let total = OverlapAdd.stride * 2 + 1234
    let signal = (0..<total).map { Float(sin(Double($0) * 0.01)) + 0.5 }
    var accumulator = OverlapAccumulator(total: total)
    let n = OverlapAdd.chunkLength
    for chunk in 0..<OverlapAdd.chunkCount(total: total) {
        let start = chunk * OverlapAdd.stride
        let length = min(n, total - start)
        var padded = [Float](repeating: 0, count: n)
        for i in 0..<length { padded[i] = signal[start + i] }
        padded.withUnsafeBufferPointer { accumulator.add(left: $0.baseAddress!, right: $0.baseAddress!, start: start, length: length) }
    }
    let out = accumulator.finish()
    for i in stride(from: 0, to: total, by: 97) {
        #expect(abs(out.left[i] - signal[i]) < 1e-4, "sample \(i)")
    }
}

@Test func windowIsPositiveAndCoversEverySample() {
    let w = OverlapAdd.window()
    #expect(w.count == OverlapAdd.chunkLength)
    #expect(w[0] > 0 && w[0] < 0.001 && w[OverlapAdd.overlap] == 1 && w[w.count - 1] == w[0])
    var accumulator = OverlapAccumulator(total: OverlapAdd.stride * 3 + 7)
    let ones = [Float](repeating: 1, count: OverlapAdd.chunkLength)
    for chunk in 0..<OverlapAdd.chunkCount(total: OverlapAdd.stride * 3 + 7) {
        let start = chunk * OverlapAdd.stride
        ones.withUnsafeBufferPointer { accumulator.add(left: $0.baseAddress!, right: $0.baseAddress!, start: start, length: min(ones.count, OverlapAdd.stride * 3 + 7 - start)) }
    }
    let out = accumulator.finish()
    #expect(out.left.allSatisfy { abs($0 - 1) < 1e-4 }) // every sample got weight > 0
}

@Test func bagRowsAreTheNetworksOwnSpeciality() {
    let n = OverlapAdd.chunkLength
    var tensor = [Float](repeating: 0, count: 4 * 2 * n)
    for row in 0..<4 { for c in 0..<2 { tensor[(row * 2 + c) * n] = Float(row * 10 + c) } }
    tensor.withUnsafeBufferPointer { base in
        for stem in Stem.allCases {
            let (left, right) = BagOutput.row(stem, in: base.baseAddress!)
            #expect(left.pointee == Float(stem.row * 10) && right.pointee == Float(stem.row * 10 + 1), "\(stem)")
        }
    }
    #expect(Stem.instruments.modelName == "other" && Stem.instruments.row == 2)
}

// MARK: - Decoding

private func writeFile(rate: Double, channels: AVAudioChannelCount, seconds: Double, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "stemsplit-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let frames = Int(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<Int(channels) {
        for n in 0..<frames { buffer.floatChannelData![c][n] = Float(0.4 * sin(2 * Double.pi * 220 * Double(n) / rate)) }
    }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
}

@Test func decoderGivesStereo44kWhateverTheSource() throws {
    for (rate, channels) in [(22_050.0, AVAudioChannelCount(1)), (48_000.0, 2), (44_100.0, 2)] {
        let url = try writeFile(rate: rate, channels: channels, seconds: 2, name: "\(Int(rate))")
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try AudioDecoder.load(url)
        #expect(abs(audio.count - 88_200) < 2048, "\(rate) Hz: \(audio.count) samples")
        #expect(audio.left.count == audio.right.count)
        let energy = audio.left[4410..<8820].reduce(0) { $0 + $1 * $1 } / 4410
        #expect(abs(energy - 0.08) < 0.02, "\(rate) Hz: energy \(energy)") // 0.4 sine → 0.08
        if channels == 1 { #expect(audio.left[5000] == audio.right[5000]) }
    }
}

@Test func writerRoundTripsFloat32() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "stemsplit-out-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let audio = StereoBuffer(left: (0..<10_000).map { Float($0) / 10_000 * 1.5 }, right: (0..<10_000).map { -Float($0) / 10_000 })
    try StemWriter.write(audio, to: url)
    let back = try AudioDecoder.load(url)
    #expect(back.count == 10_000)
    #expect(abs(back.left[9999] - 1.4998) < 1e-4) // above 1.0 survives: float file
    #expect(abs(back.right[5000] + 0.5) < 1e-4)
}

// MARK: - Job with a fake separator

/// Returns the mix scaled by a factor per stem, slowly, so cancellation has something to interrupt.
private struct FakeSeparator: StemSeparating {
    var delayPerChunk: Duration = .zero
    func separate(_ stem: Stem, mix: StereoBuffer, progress: (Int, Int) -> Void) throws -> StereoBuffer {
        let count = OverlapAdd.chunkCount(total: mix.count)
        for chunk in 0..<count {
            try Task.checkCancellation()
            if delayPerChunk > .zero { Thread.sleep(forTimeInterval: 0.05) }
            progress(chunk + 1, count)
        }
        let gain = Float(stem.row + 1) * 0.1
        return StereoBuffer(left: mix.left.map { $0 * gain }, right: mix.right.map { $0 * gain })
    }
}

@Test func jobWritesFourStemsAndAManifestThenReusesThem() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "stemsplit-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeFile(rate: 44_100, channels: 2, seconds: 1, name: "song")
    defer { try? FileManager.default.removeItem(at: source) }
    var seen: [Stem] = []
    let result = try await SeparationJob.run(source: source, outputRoot: root, separator: { FakeSeparator() }) { _ in }
    #expect(!result.reused && result.stems.count == 4)
    #expect(result.folder.lastPathComponent.hasPrefix(source.deletingPathExtension().lastPathComponent))
    for stem in Stem.allCases {
        let audio = try AudioDecoder.load(result.stems[stem]!)
        let expected = 0.4 * Float(stem.row + 1) * 0.1
        #expect(abs(audio.left[1000...].max()! - expected) < 0.01, "\(stem)")
        seen.append(stem)
    }
    #expect(FileManager.default.fileExists(atPath: result.folder.appending(path: StemManifest.fileName).path))
    let again = try await SeparationJob.run(source: source, outputRoot: root, separator: { fatalError("must not run") }) { _ in }
    #expect(again.reused && again.folder == result.folder)
}

@Test func cancelledJobStopsQuicklyAndLeavesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "stemsplit-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeFile(rate: 44_100, channels: 2, seconds: 30, name: "long")
    defer { try? FileManager.default.removeItem(at: source) }
    let task = Task {
        try await SeparationJob.run(source: source, outputRoot: root, separator: { FakeSeparator(delayPerChunk: .milliseconds(50)) }) { _ in }
    }
    try await Task.sleep(for: .milliseconds(120))
    let started = Date()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 3)
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    #expect(leftovers.isEmpty, "\(leftovers)")
}
