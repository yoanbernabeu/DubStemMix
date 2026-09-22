import Foundation

/// The four stems, in the order they land on the strips (PRD § 12.1).
public enum Stem: String, CaseIterable, Sendable, Codable {
    case drums, bass, instruments, vocals

    /// The htdemucs_ft network that produces this stem.
    public var modelName: String { self == .instruments ? "other" : rawValue }
    /// Row of the network's output kept for this stem (bag rule: each network keeps its own speciality).
    public var row: Int { Self.allCases.firstIndex(of: self)! }
    public var fileName: String { rawValue + ".wav" }
    public var label: String { rawValue.uppercased() }
}

/// Stereo audio as two planar channels.
public struct StereoBuffer: Sendable {
    public var left: [Float]
    public var right: [Float]
    public var count: Int { left.count }

    public init(left: [Float], right: [Float]) {
        precondition(left.count == right.count)
        self.left = left
        self.right = right
    }

    public init(count: Int) {
        left = [Float](repeating: 0, count: count)
        right = [Float](repeating: 0, count: count)
    }
}

/// Where a separation stands (PRD § 12.4): one network at a time, chunk by chunk.
public struct SeparationProgress: Sendable {
    public let stem: Stem
    public let chunk: Int
    public let chunkCount: Int

    /// Over the whole job: 4 networks × chunkCount chunks.
    public var fraction: Double {
        Double(stem.row * chunkCount + chunk) / Double(Stem.allCases.count * chunkCount)
    }
}

/// One network's separation of a whole song; the job calls it once per stem.
public protocol StemSeparating {
    func separate(_ stem: Stem, mix: StereoBuffer, progress: (_ chunk: Int, _ chunkCount: Int) -> Void) throws -> StereoBuffer
}
