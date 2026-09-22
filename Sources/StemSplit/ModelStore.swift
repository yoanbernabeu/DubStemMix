import CryptoKit
import Foundation

/// The htdemucs_ft ONNX exports (spec § 4): pinned revision, sizes and hashes. Never bundled.
public enum ModelCatalog {
    public static let name = "htdemucs_ft"
    public static let revision = "8616370ed541bc183dbe15fb0d54d5f49918f47e"
    public static let shortRevision = String(revision.prefix(8))
    /// Identifies the model in stem manifests: changing it invalidates every cached separation.
    public static let id = "\(name)@\(shortRevision)"
    public static let repository = "StemSplitio/htdemucs-ft-onnx"

    public struct File: Sendable, Hashable {
        public let stem: Stem
        public let name: String
        public let bytes: Int64
        public let sha256: String

        public var url: URL {
            URL(string: "https://huggingface.co/\(ModelCatalog.repository)/resolve/\(ModelCatalog.revision)/\(name)")!
        }
    }

    public static let files: [File] = [
        File(stem: .drums, name: "htdemucs_ft_drums_fp16weights.onnx", bytes: 165_612_636,
             sha256: "047764dff888cfb87da917013377d4ec7a134f7419cbe486d9c339aa17975ddd"),
        File(stem: .bass, name: "htdemucs_ft_bass_fp16weights.onnx", bytes: 165_612_636,
             sha256: "b533037176b14b2df31c92a5d5b3d5660d0811b9b360d3db761964768b079961"),
        File(stem: .instruments, name: "htdemucs_ft_other_fp16weights.onnx", bytes: 165_612_636,
             sha256: "b739171a7057b3107bb0711c6222d4a619b41b13a8f04026431d30f32ad2bd71"),
        File(stem: .vocals, name: "htdemucs_ft_vocals_fp16weights.onnx", bytes: 165_612_636,
             sha256: "0cbe651f535415c9d26a7bb614f7d322dd5a080fa0298f2e50f478030a994dce"),
    ]

    public static let totalBytes = files.reduce(0) { $0 + $1.bytes }

    /// Shown before any download and in the settings (spec § 10).
    public static let licenseNotice = """
        Weights: htdemucs_ft by Meta (Demucs), ONNX export by StemSplitio (Hugging Face, revision \(shortRevision)). \
        The export is published under MIT, but Meta's original weights carry no explicit license and were trained on \
        MUSDB18-HQ ("educational purposes only"). DubStemMix downloads them on your request and never redistributes them.
        """
}

/// Where the model files live and how they get there (spec § 6.3): explicit download, resume, size and
/// SHA-256 check, atomic move. Files present in the directory are considered verified.
public final class ModelStore: Sendable {
    public let directory: URL

    public enum Status: Equatable, Sendable {
        case missing
        case partial(ready: Int)
        case ready
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/DubStemMix/Models/htdemucs_ft/<revision>/`
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DubStemMix/Models/\(ModelCatalog.name)/\(ModelCatalog.shortRevision)")
    }

    public func url(for stem: Stem) -> URL {
        directory.appending(path: ModelCatalog.files.first { $0.stem == stem }!.name)
    }

    private func isPresent(_ file: ModelCatalog.File) -> Bool {
        let path = directory.appending(path: file.name).path
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 else { return false }
        return size == file.bytes
    }

    public var status: Status {
        let ready = ModelCatalog.files.filter(isPresent).count
        switch ready {
        case 0: return .missing
        case ModelCatalog.files.count: return .ready
        default: return .partial(ready: ready)
        }
    }

    public var isReady: Bool { status == .ready }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    // MARK: Download

    /// Downloads the missing files one after the other. `progress` gets the bytes received so far over the
    /// total of the catalog (files already present count as received).
    public func download(progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var done: Int64 = ModelCatalog.files.filter(isPresent).reduce(0) { $0 + $1.bytes }
        progress(done, ModelCatalog.totalBytes)
        for file in ModelCatalog.files where !isPresent(file) {
            let base = done
            try await Downloader.fetch(file.url, to: directory.appending(path: file.name + ".part"), expectedBytes: file.bytes) { received in
                progress(base + received, ModelCatalog.totalBytes)
            }
            try Task.checkCancellation()
            let part = directory.appending(path: file.name + ".part")
            guard try Self.sha256(of: part) == file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                throw DownloadError.corrupted(file.name)
            }
            let final = directory.appending(path: file.name)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            done += file.bytes
            progress(done, ModelCatalog.totalBytes)
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadError: Error, LocalizedError {
    case badResponse(Int), corrupted(String), truncated(String)

    public var errorDescription: String? {
        switch self {
        case let .badResponse(code): "The server answered \(code)"
        case let .corrupted(name): "\(name) did not match its checksum and was discarded"
        case let .truncated(name): "\(name) came back incomplete"
        }
    }
}

/// Streams a URL into a file, resuming from whatever is already there with a Range request (spec § 6.3).
enum Downloader {
    static func fetch(_ url: URL, to destination: URL, expectedBytes: Int64,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        var existing: Int64 = 0
        if let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 {
            existing = size
        }
        if existing >= expectedBytes {
            if existing > expectedBytes { try? FileManager.default.removeItem(at: destination); existing = 0 } else {
                progress(existing)
                return
            }
        }
        if existing == 0 { FileManager.default.createFile(atPath: destination.path, contents: nil) }
        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(0) }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw DownloadError.badResponse(http.statusCode) }
        if http.statusCode == 200, existing > 0 {
            // The server ignored the range: start over.
            try FileManager.default.removeItem(at: destination)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            existing = 0
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var received = existing
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = Date()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    progress(received)
                }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        progress(received)
        guard received == expectedBytes else { throw DownloadError.truncated(destination.lastPathComponent) }
    }
}
