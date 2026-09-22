import Accelerate
import Foundation

/// Chunking and overlap-add for the fixed-size htdemucs_ft input (spec § 5.2).
public enum OverlapAdd {
    /// Samples per model input: 7.8 s at 44.1 kHz, imposed by the model.
    public static let chunkLength = 343_980
    public static let overlap = chunkLength / 4
    public static let stride = chunkLength - overlap

    public static func chunkCount(total: Int) -> Int {
        max(1, Int((Double(total) / Double(stride)).rounded(.up)))
    }

    /// Linear ramps over the overlap at both ends, 1 in between. As in Demucs, the ramp starts at 1/overlap,
    /// never at 0: every sample of the song gets a positive weight.
    public static func window() -> [Float] {
        var w = [Float](repeating: 1, count: chunkLength)
        for i in 0..<overlap {
            let ramp = Float(i + 1) / Float(overlap)
            w[i] = ramp
            w[chunkLength - 1 - i] = ramp
        }
        return w
    }
}

/// Accumulates windowed chunk outputs and normalizes by the summed window (spec § 5.2).
public struct OverlapAccumulator {
    public private(set) var output: StereoBuffer
    private var weights: [Float]
    private let window = OverlapAdd.window()

    public init(total: Int) {
        output = StereoBuffer(count: total)
        weights = [Float](repeating: 0, count: total)
    }

    /// Adds one chunk's output (`length` valid samples per channel, starting at `start` in the song).
    public mutating func add(left: UnsafePointer<Float>, right: UnsafePointer<Float>, start: Int, length: Int) {
        let n = min(length, output.count - start)
        guard n > 0 else { return }
        window.withUnsafeBufferPointer { w in
            output.left.withUnsafeMutableBufferPointer { out in
                vDSP_vma(left, 1, w.baseAddress!, 1, out.baseAddress! + start, 1, out.baseAddress! + start, 1, vDSP_Length(n))
            }
            output.right.withUnsafeMutableBufferPointer { out in
                vDSP_vma(right, 1, w.baseAddress!, 1, out.baseAddress! + start, 1, out.baseAddress! + start, 1, vDSP_Length(n))
            }
            weights.withUnsafeMutableBufferPointer { wt in
                vDSP_vadd(w.baseAddress!, 1, wt.baseAddress! + start, 1, wt.baseAddress! + start, 1, vDSP_Length(n))
            }
        }
    }

    public func finish() -> StereoBuffer {
        var result = output
        var floor: Float = 1e-8
        var safe = [Float](repeating: 0, count: weights.count)
        vDSP_vthr(weights, 1, &floor, &safe, 1, vDSP_Length(weights.count))
        vDSP_vdiv(safe, 1, result.left, 1, &result.left, 1, vDSP_Length(weights.count))
        vDSP_vdiv(safe, 1, result.right, 1, &result.right, 1, vDSP_Length(weights.count))
        return result
    }
}

/// The bag rule (spec § 4): a network's output is `[1, 4, 2, N]`; only its own row is kept.
public enum BagOutput {
    /// Pointers to the left and right channels of `stem`'s row inside a `[4, 2, N]` float tensor.
    public static func row(_ stem: Stem, in tensor: UnsafePointer<Float>) -> (left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
        let n = OverlapAdd.chunkLength
        return (tensor + (stem.row * 2) * n, tensor + (stem.row * 2 + 1) * n)
    }
}
