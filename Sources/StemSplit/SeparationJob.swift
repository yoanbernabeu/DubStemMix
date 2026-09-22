import CryptoKit
import Foundation

/// Everything a separated song leaves on disk (PRD § 12.3): the four WAVs and a manifest.
public struct SeparationResult: Sendable {
    public let folder: URL
    public let stems: [Stem: URL]
    /// True when the stems were already there for this file and model: nothing was computed.
    public let reused: Bool
}

public struct StemManifest: Codable, Sendable, Equatable {
    public var source: String
    public var fingerprint: String
    public var model: String
    public var created: Date
    public static let fileName = "stems.json"
}

/// One song from file to four stems (spec § 6.2, PRD § 12.4): decode, one network at a time, each stem written as
/// soon as its network is done, manifest last. Runs off the main actor; cancellation is checked between chunks.
public enum SeparationJob {
    /// Folder name for a source file: "<title> [fingerprint]", so a re-split with the same file lands in the same place.
    public static func folder(for source: URL, fingerprint: String, in root: URL) -> URL {
        let title = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return root.appending(path: "\(title) [\(fingerprint.prefix(8))]")
    }

    /// SHA-256 of the file's contents.
    public static func fingerprint(of source: URL) throws -> String {
        try ModelStore.sha256(of: source)
    }

    /// Stems already computed for this file with the current model, if the manifest and the four files are there.
    public static func existingResult(for source: URL, fingerprint: String, in root: URL) -> SeparationResult? {
        let folder = folder(for: source, fingerprint: fingerprint, in: root)
        guard let data = try? Data(contentsOf: folder.appending(path: StemManifest.fileName)),
              let manifest = try? JSONDecoder().decode(StemManifest.self, from: data),
              manifest.fingerprint == fingerprint, manifest.model == ModelCatalog.id
        else { return nil }
        let stems = Dictionary(uniqueKeysWithValues: Stem.allCases.map { ($0, folder.appending(path: $0.fileName)) })
        guard stems.values.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return SeparationResult(folder: folder, stems: stems, reused: true)
    }

    /// - Parameter separator: built inside the job (ONNX sessions are not Sendable); tests pass a fake.
    public static func run(
        source: URL,
        outputRoot: URL,
        separator: @escaping @Sendable () throws -> any StemSeparating,
        progress: @escaping @Sendable (SeparationProgress) -> Void
    ) async throws -> SeparationResult {
        let fingerprint = try fingerprint(of: source)
        if let existing = existingResult(for: source, fingerprint: fingerprint, in: outputRoot) { return existing }
        let folder = folder(for: source, fingerprint: fingerprint, in: outputRoot)
        let task = Task.detached(priority: .utility) { () throws -> SeparationResult in
            let mix = try AudioDecoder.load(source)
            let temporary = outputRoot.appending(path: ".\(folder.lastPathComponent).tmp")
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            do {
                let engine = try separator()
                var stems: [Stem: URL] = [:]
                for stem in Stem.allCases {
                    try Task.checkCancellation()
                    let separated = try engine.separate(stem, mix: mix) { chunk, count in
                        progress(SeparationProgress(stem: stem, chunk: chunk, chunkCount: count))
                    }
                    let url = temporary.appending(path: stem.fileName)
                    try StemWriter.write(separated, to: url)
                    stems[stem] = url
                }
                let manifest = StemManifest(source: source.path, fingerprint: fingerprint, model: ModelCatalog.id, created: .now)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: temporary.appending(path: StemManifest.fileName))
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.moveItem(at: temporary, to: folder)
                return SeparationResult(
                    folder: folder,
                    stems: Dictionary(uniqueKeysWithValues: stems.map { ($0.key, folder.appending(path: $0.value.lastPathComponent)) }),
                    reused: false
                )
            } catch {
                try? FileManager.default.removeItem(at: temporary) // a cancelled or failed job leaves nothing behind
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
