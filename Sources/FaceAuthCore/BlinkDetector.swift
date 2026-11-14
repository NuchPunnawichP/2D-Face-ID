import Foundation

public enum EyeAspectRatio {
    /// Eye aspect ratio for an eye contour of any point count.
    ///
    /// Vision's eye regions are closed contours, not dlib's fixed 6-point
    /// layout, so we generalise the Soukupová & Čech EAR: the two points
    /// farthest apart are the eye corners (width); height is the extent of
    /// the contour perpendicular to the corner-to-corner line.
    /// EAR = height / width. Nil if fewer than 4 points or zero width.
    public static func compute(_ eye: [Point2]) -> Double? {
        guard eye.count >= 4 else { return nil }
        var best = (0, 1, -1.0)
        for i in 0..<eye.count {
            for j in (i + 1)..<eye.count {
                let d = eye[i].distance(to: eye[j])
                if d > best.2 { best = (i, j, d) }
            }
        }
        let width = best.2
        guard width > 0 else { return nil }
        let a = eye[best.0], b = eye[best.1]
        let ux = (b.x - a.x) / width, uy = (b.y - a.y) / width
        // Perpendicular unit vector (-uy, ux).
        var lo = Double.infinity, hi = -Double.infinity
        for p in eye {
            let s = (p.x - a.x) * -uy + (p.y - a.y) * ux
            lo = min(lo, s)
            hi = max(hi, s)
        }
        return (hi - lo) / width
    }

    /// Mean EAR of both eyes, or the one available eye.
    public static func both(left: [Point2]?, right: [Point2]?) -> Double? {
        let values = [left, right].compactMap { $0.flatMap(compute) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// Detects one complete blink: open → closed for 1...maxClosedFrames
/// consecutive valid frames → open again.
public struct BlinkDetector: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        /// EAR below this counts as closed.
        public var closedThreshold: Double = 0.21
        /// Open level = median EAR of the first `baselineFrames` frames × openFactor.
        public var openFactor: Double = 0.8
        public var baselineFrames: Int = 5
        public var maxClosedFrames: Int = 8
        /// The closed threshold is also capped at closedFactor × baseline median,
        /// so that "closed" is always strictly below "open" (spec rev 3, R7).
        public var closedFactor: Double = 0.7
        public init() {}
    }

    private enum State: Sendable { case baseline, waitingOpen, open, closed(Int) }

    public let config: Config
    private var baseline: [Double] = []
    private var state: State = .baseline
    public private(set) var openLevel: Double?
    public private(set) var closedLevel: Double?
    public private(set) var blinkSeen = false

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        self = BlinkDetector(config: config)
    }

    /// Feed the EAR of one valid frame. Returns true once a blink has been seen.
    @discardableResult
    public mutating func add(ear: Double) -> Bool {
        if blinkSeen { return true }
        switch state {
        case .baseline:
            baseline.append(ear)
            if baseline.count >= config.baselineFrames {
                let m = median(baseline)
                openLevel = m * config.openFactor
                closedLevel = min(config.closedThreshold, m * config.closedFactor)
                // The baseline frame itself counts as "open" when it is.
                state = ear >= openLevel! ? .open : .waitingOpen
            }
        case .waitingOpen:
            if ear >= openLevel! { state = .open }
        case .open:
            if ear < closedLevel! { state = .closed(1) }
        case .closed(let n):
            if ear >= openLevel! {
                blinkSeen = true
            } else if ear < closedLevel! {
                // Eyes closed for too long is not a blink (e.g. eyes shut, or a photo).
                state = n + 1 > config.maxClosedFrames ? .waitingOpen : .closed(n + 1)
            }
            // Between closed and open levels: still in the same closure, no change.
        }
        return blinkSeen
    }
}
