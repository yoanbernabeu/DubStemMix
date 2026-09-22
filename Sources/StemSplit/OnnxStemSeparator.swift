import Foundation
import OnnxRuntimeBindings

/// htdemucs_ft through ONNX Runtime on the CPU (spec § 5.3, § 5.4): one session at a time, the whole song
/// per network, every run inside an autorelease pool.
public final class OnnxStemSeparator: StemSeparating {
    /// Where the networks run (spec § 9). CPU is the only configuration validated for the product; Core ML
    /// hands the graph to macOS, which spreads it over CPU, GPU and Neural Engine as asked.
    public enum ExecutionProvider: Sendable, Equatable {
        case cpu
        case coreML(computeUnits: String) // "CPUOnly", "CPUAndGPU", "CPUAndNeuralEngine", "All"
    }

    private let store: ModelStore
    private let provider: ExecutionProvider
    nonisolated(unsafe) private static let env: ORTEnv = { // one per app (spec § 5.4); ORT guards its own state
        do { return try ORTEnv(loggingLevel: .warning) } catch { fatalError("ONNX Runtime could not start: \(error)") }
    }()

    public init(store: ModelStore, provider: ExecutionProvider = .cpu) {
        self.store = store
        self.provider = provider
    }

    /// Compiled Core ML models are cached next to the ONNX files; a new model revision gets a new folder.
    private var coreMLCache: URL { store.directory.appending(path: "coreml-cache") }

    public func separate(_ stem: Stem, mix: StereoBuffer, progress: (Int, Int) -> Void) throws -> StereoBuffer {
        let n = OverlapAdd.chunkLength
        let count = OverlapAdd.chunkCount(total: mix.count)
        var accumulator = OverlapAccumulator(total: mix.count)
        try autoreleasepool {
            let options = try ORTSessionOptions()
            try options.setGraphOptimizationLevel(.all)
            if case let .coreML(units) = provider {
                try FileManager.default.createDirectory(at: coreMLCache, withIntermediateDirectories: true)
                try options.appendCoreMLExecutionProvider(withOptionsV2: [
                    "MLComputeUnits": units,
                    "ModelFormat": "MLProgram",
                    "ModelCacheDirectory": coreMLCache.path,
                    "RequireStaticInputShapes": "1",
                ])
            }
            let session = try ORTSession(env: Self.env, modelPath: store.url(for: stem).path, sessionOptions: options)
            let input = NSMutableData(length: 2 * n * MemoryLayout<Float>.size)!
            for chunk in 0..<count {
                try Task.checkCancellation()
                let start = chunk * OverlapAdd.stride
                let length = min(n, mix.count - start)
                // Fill the input: the chunk, zero-padded to N (spec § 5.2).
                let floats = input.mutableBytes.assumingMemoryBound(to: Float.self)
                floats.update(repeating: 0, count: 2 * n)
                mix.left.withUnsafeBufferPointer { floats.update(from: $0.baseAddress! + start, count: length) }
                mix.right.withUnsafeBufferPointer { (floats + n).update(from: $0.baseAddress! + start, count: length) }
                try autoreleasepool {
                    let value = try ORTValue(tensorData: input, elementType: .float, shape: [1, 2, NSNumber(value: n)])
                    let outputs = try session.run(withInputs: ["mix": value], outputNames: ["stems"], runOptions: nil)
                    guard let tensor = outputs["stems"] else { throw SeparationError.noOutput }
                    let data = try tensor.tensorData() // [1, 4, 2, N], contiguous
                    let base = data.bytes.assumingMemoryBound(to: Float.self)
                    let row = BagOutput.row(stem, in: base)
                    accumulator.add(left: row.left, right: row.right, start: start, length: length)
                }
                progress(chunk + 1, count)
            }
        }
        return accumulator.finish()
    }
}

public enum SeparationError: Error, LocalizedError {
    case noOutput, modelsMissing, busy

    public var errorDescription: String? {
        switch self {
        case .noOutput: "The model returned no output"
        case .modelsMissing: "The separation models are not downloaded"
        case .busy: "A separation is already running"
        }
    }
}
