import Foundation

/// Rejects a static face (e.g. a photo) by measuring non-rigid landmark motion.
///
/// Each frame's landmarks are put into a face-relative frame: centred on the
/// eye midpoint, rotated so the eyes are horizontal and scaled so the
/// inter-ocular distance is 1. Moving, tilting or zooming a photo therefore
/// cancels out, while a live face's blinking, expression and 3D head turn
/// change the normalized shape. The score is the mean per-landmark standard
/// deviation over a sliding window.
public struct MotionCheck: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        public var windowSeconds: Double = 1.0
        public var minFrames: Int = 10
        /// Score at or below this is "static". Tuned by `faceauth calibrate`.
        public var minScore: Double = 0.004
        public init() {}
    }

    public let config: Config
    private var window: [(time: Double, shape: [Point2])] = []
    public private(set) var lastScore: Double?
    public private(set) var passed = false

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        self = MotionCheck(config: config)
    }

    /// Landmarks in the eye-normalized frame. Nil if the eyes are missing or coincide.
    public static func normalizedShape(_ frame: FaceFrame) -> [Point2]? {
        guard let pts = frame.landmarks, !pts.isEmpty,
              let l = frame.leftEyeCenter, let r = frame.rightEyeCenter else { return nil }
        let d = r - l
        let iod = d.length
        guard iod > 0 else { return nil }
        let mid = (l + r) * 0.5
        let c = d.x / iod, s = d.y / iod
        return pts.map { p in
            let q = p - mid
            // Rotate by -angle, then scale.
            return Point2((q.x * c + q.y * s) / iod, (-q.x * s + q.y * c) / iod)
        }
    }

    /// Feed one valid frame. Returns true once motion has been seen in some window.
    @discardableResult
    public mutating func add(_ frame: FaceFrame) -> Bool {
        if passed { return true }
        guard let shape = Self.normalizedShape(frame) else { return passed }
        if let first = window.first, first.shape.count != shape.count { window.removeAll() }
        window.append((frame.time, shape))
        window.removeAll { frame.time - $0.time > config.windowSeconds }
        guard window.count >= config.minFrames else { return passed }
        let score = Self.score(window.map(\.shape))
        lastScore = score
        if score > config.minScore { passed = true }
        return passed
    }

    /// Mean over landmarks of the standard deviation of their position.
    public static func score(_ shapes: [[Point2]]) -> Double {
        guard let n = shapes.first?.count, n > 0, shapes.count > 1 else { return 0 }
        var total = 0.0
        for i in 0..<n {
            let c = centroid(shapes.map { $0[i] })
            let v = shapes.reduce(0.0) { acc, s in
                let d = s[i] - c
                return acc + d.x * d.x + d.y * d.y
            } / Double(shapes.count)
            total += v.squareRoot()
        }
        return total / Double(n)
    }
}
