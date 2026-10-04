import Foundation
import DubStemMixCore
import StemSplit

/// Command-line checks for the stem separation (PRD § 12.5), with the real models:
///   --download-models          downloads the four networks (663 MB) into the app's model folder
///   --split <file> [--out dir] [--provider cpu|coreml-cpu|coreml-gpu|coreml-ane|coreml-all]
///                              separates a song and reports per-stem energy and Σ stems vs mix
///   --check-prepare <out dir> <files…>   runs the preparation queue of the real app model on these files (one
///                              unreadable file expected to fail), then a second queue cancelled after 5 s
///   --split <file> --project   also writes the song's ready project next to the stems (preparation mode, PRD § 12.6)
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

    static func split(_ path: String, out: String?, provider providerName: String?, threads: Int?, project: Bool = false) {
        let provider: OnnxStemSeparator.ExecutionProvider = switch providerName {
        case "coreml-cpu": .coreML(computeUnits: "CPUOnly")
        case "coreml-gpu": .coreML(computeUnits: "CPUAndGPU")
        case "coreml-ane": .coreML(computeUnits: "CPUAndNeuralEngine")
        case "coreml-all": .coreML(computeUnits: "All")
        default: .cpu
        }
        print("Execution provider: \(provider)" + (threads.map { " · \($0) threads" } ?? " · default threads"))
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
                let result = try await SeparationJob.run(source: source, outputRoot: root, separator: { OnnxStemSeparator(store: store, provider: provider, threads: threads) }) { progress in
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
            if project { writeProject(result, source: source) }
            report(source: source, result: result, elapsed: elapsed)
        }
    }

    static func checkPreparation(out: String, files: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let model = try? AppModel() else { print("❌ no app model"); exit(1) }
        model.stemsFolder = URL(fileURLWithPath: out)
        let urls = files.map { URL(fileURLWithPath: $0) }
        func wait(until done: () -> Bool, limit: TimeInterval) {
            let start = Date()
            var lastPrint = Date.distantPast
            while !done(), Date().timeIntervalSince(start) < limit {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                if Date().timeIntervalSince(lastPrint) > 5 {
                    lastPrint = .now
                    let left = model.prepTimeLeft.map { "\(Int($0)) s left" } ?? "estimating"
                    print("  \(Int(Date().timeIntervalSince(start))) s · \(model.prepQueue.doneCount) done · \(model.prepQueue.waitingCount) waiting · \(left)")
                }
            }
        }
        model.prepareSongs(urls + [urls[0]]) // the duplicate is not queued twice
        print("Queued: \(model.prepQueue.items.count) of \(urls.count + 1) · preparing: \(model.preparing)")
        wait(until: { !model.prepBusy }, limit: 900)
        for item in model.prepQueue.items { print("  \(item.source.lastPathComponent): \(item.status)") }
        var ok = model.prepQueue.items.count == urls.count && !model.prepBusy && model.prepQueue.failedCount >= 1
        print("Speed stored: \(model.splitSpeed.map { String(format: "%.2f s per audio second", $0) } ?? "none")")

        model.leavePreparation()
        model.preparing = true
        model.prepQueue.add(urls.map { ($0, AppModel.audioDuration(of: $0)) })
        let fresh = URL(fileURLWithPath: out).appending(path: "fresh")
        model.stemsFolder = fresh // nothing reused: the first song really runs when cancelled
        model.startPreparing()
        wait(until: { false }, limit: 5)
        model.cancelPreparation()
        wait(until: { false }, limit: 4)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fresh.path)) ?? []
        print("After cancel: \(model.prepQueue.items.count) in list · busy: \(model.prepBusy) · files left: \(leftovers)")
        ok = ok && model.prepQueue.items.isEmpty && !model.prepBusy && leftovers.isEmpty
        model.leavePreparation()
        print(ok ? "✅ preparation queue OK" : "❌ preparation queue")
        exit(ok ? 0 : 1)
    }

    private static func writeProject(_ result: SeparationResult, source: URL) {
        var finished = false
        Task {
            do {
                let (document, reused) = try await AppModel.writePreparedProject(result, source: source, duration: nil)
                let project = try Project.load(from: document)
                print((reused ? "Project already there: " : "Project written: ") + document.path)
                print("  \(project.title) · \(project.bpm.map { "\($0) BPM" } ?? "no tempo") · \(Int(project.duration)) s · "
                    + project.stems.map { "\($0.strip + 1)=\($0.file.fileName)" }.joined(separator: " ")
                    + " · pool: \(project.pool.map(\.fileName).joined(separator: ", "))")
                let missing = (project.stems.map(\.file) + project.pool).filter { $0.resolve(relativeTo: document) == nil }
                if !missing.isEmpty { print("❌ not found: \(missing.map(\.fileName))"); exit(1) }
            } catch {
                print("❌ project: \(error.localizedDescription)")
                exit(1)
            }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
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
