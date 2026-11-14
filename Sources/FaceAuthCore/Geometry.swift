import Foundation

/// A 2D point. Landmark coordinates are normalized to the camera image
/// (0...1, origin bottom-left, as Vision reports them) unless stated otherwise.
public struct Point2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    public static func * (a: Point2, s: Double) -> Point2 { Point2(a.x * s, a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point2) -> Double { (self - other).length }
}

/// An axis-aligned rectangle (normalized image coordinates).
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { max(0, width) * max(0, height) }

    /// Intersection over union, 0...1.
    public func iou(_ other: Rect) -> Double {
        let ix = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let iy = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let inter = ix * iy
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }
}

func centroid(_ points: [Point2]) -> Point2 {
    guard !points.isEmpty else { return Point2(0, 0) }
    var sx = 0.0, sy = 0.0
    for p in points { sx += p.x; sy += p.y }
    return Point2(sx / Double(points.count), sy / Double(points.count))
}

func median(_ values: [Double]) -> Double {
    precondition(!values.isEmpty)
    let s = values.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}
