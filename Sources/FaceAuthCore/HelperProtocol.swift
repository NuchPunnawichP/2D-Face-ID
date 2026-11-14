import Foundation

/// Messages between a root `--system` command and its capture helper, which
/// runs as the invoking user (SPEC rev 4, Q21). One JSON object per line.

/// Helper → root: one analysed frame. The embedding is present when the frame
/// has exactly one face with both eyes.
public struct HelperFrame: Codable, Sendable {
    public var frame: FaceFrame
    public var embedding: [Float]?

    public init(frame: FaceFrame, embedding: [Float]?) {
        self.frame = frame
        self.embedding = embedding
    }

    /// Root-side sanity checks on helper output.
    public func isWellFormed(dimension: Int) -> Bool {
        guard frame.time.isFinite, frame.faceCount >= 0, frame.faceCount < 100 else { return false }
        if let e = embedding {
            guard e.count == dimension, e.allSatisfy({ $0.isFinite }) else { return false }
            let n = e.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            if abs(n - 1) > 1e-3 { return false }
        }
        return true
    }

    /// Longest accepted line, in bytes.
    public static let maxLineBytes = 64 * 1024
}

/// Root → helper: what to show in the HUD, or stop.
public enum HelperCommand: Codable, Equatable, Sendable {
    case scanning(String)
    case enroll(step: Int, of: Int, String)
    case finish(success: Bool, String)
    case stop
}
