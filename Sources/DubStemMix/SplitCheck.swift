import Foundation
import StemSplit

/// Command-line checks for the stem separation (PRD § 12.5), with the real models:
///   --download-models          downloads the four networks (663 MB) into the app's model folder
///   --split <file> [--out dir] [--provider cpu|coreml-cpu|coreml-gpu|coreml-ane|coreml-all]
///                              separates a song and reports per-stem energy and Σ stems vs mix
@MainActor
enum SplitCheck {
    static func downloadModels() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = ModelStore(directory: ModelStore.defaultDirectory)
        print("Models: \(store.directory.path)")
        print("Status before: \(store.status)")
        var finished = false
        var failure: Error?
        let start = Date()
        Task {
            do {
                try await store.download { received, total in
                    print(String(format: "  %5.1f %%  (%.0f / %.0f MB)", Double(received) / Double(total) * 100, Double(received) / 1e6, Double(total) / 1e6))
                }
            } catch { failure = error }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        if let failure { print("❌ \(failure.localizedDescription)"); exit(1) }
        print("Status after: \(store.status) in \(Int(Date().timeIntervalSince(start))) s")
        exit(store.isReady ? 0 : 1)
    }

    static func split(_ path: String, out: String?, provider providerName: String?) {
        let provider: OnnxStemSeparator.ExecutionProvider = switch providerName {
        case "coreml-cpu": .coreML(computeUnits: "CPUOnly")
        case "coreml-gpu": .coreML(computeUnits: "CPUAndGPU")
        case "coreml-ane": .coreML(computeUnits: "CPUAndNeuralEngine")
        case "coreml-all": .coreML(computeUnits: "All")
        default: .cpu
        }
        print("Execution provider: \(provider)")
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = ModelStore(directory: ModelStore.defaultDirectory)
        guard store.isReady else {
            print("❌ models not downloaded (\(store.status)): run --download-models first")
            exit(1)
        }
        let source = URL(fileURLWithPath: path)
        let root = out.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appending(path: "DubStemMix/Stems")
        var finished = false
        var outcome: Result<SeparationResult, Error>?
        let start = Date()
        Task {
            do {
                let result = try await SeparationJob.run(source: source, outputRoot: root, separator: { OnnxStemSeparator(store: store, provider: provider) }) { progress in
                    print("  \(progress.stem.rawValue) \(progress.chunk)/\(progress.chunkCount) · \(Int(progress.fraction * 100)) % · \(Int(Date().timeIntervalSince(start))) s")
                }
                outcome = .success(result)
            } catch { outcome = .failure(error) }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        switch outcome! {
        case let .failure(error):
            print("❌ \(error.localizedDescription)")
            exit(1)
        case let .success(result):
            let elapsed = Date().timeIntervalSince(start)
            print(result.reused ? "Reused stems in \(result.folder.path)" : "Separated in \(Int(elapsed)) s → \(result.folder.path)")
            report(source: source, result: result, elapsed: elapsed)
        }
    }

    private static func rms(_ samples: [Float]) -> Double {
        (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))).squareRoot()
    }

    private static func report(source: URL, result: SeparationResult, elapsed: Double) {
        do {
            let mix = try AudioDecoder.load(source)
            var sum = [Float](repeating: 0, count: mix.count)
            print("Energy per stem (dBFS RMS, left):")
            for stem in Stem.allCases {
                let audio = try AudioDecoder.load(result.stems[stem]!)
                let n = min(audio.count, mix.count)
                for i in 0..<n { sum[i] += audio.left[i] }
                print(String(format: "  %-12@ %6.1f dB", stem.label as NSString, 20 * log10(max(1e-9, rms(audio.left)))))
            }
            let residual = zip(mix.left, sum).map { $0 - $1 }
            let reconstruction = 20 * log10(rms(mix.left) / max(1e-9, rms(residual)))
            print(String(format: "Σ stems vs mix: %.1f dB (≥ 25 dB expected)", reconstruction))
            let seconds = Double(mix.count) / AudioDecoder.sampleRate
            print(String(format: "Song %.0f s · real-time factor %.2f", seconds, elapsed / seconds))
            exit(reconstruction >= 25 ? 0 : 1)
        } catch {
            print("❌ report: \(error.localizedDescription)")
            exit(1)
        }
    }
}
