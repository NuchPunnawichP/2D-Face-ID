import Foundation

/// A 2D similarity transform (rotation, uniform scale, translation):
/// x' = a·x − b·y + tx,  y' = b·x + a·y + ty.
public struct SimilarityTransform: Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var tx: Double
    public var ty: Double

    public func apply(_ p: Point2) -> Point2 {
        Point2(a * p.x - b * p.y + tx, b * p.x + a * p.y + ty)
    }

    /// The exact transform mapping two source points onto two target points.
    /// Nil if the source points coincide.
    public static func mapping(_ s1: Point2, _ s2: Point2, to d1: Point2, _ d2: Point2) -> SimilarityTransform? {
        let sv = s2 - s1, dv = d2 - d1
        let den = sv.x * sv.x + sv.y * sv.y
        guard den > 0 else { return nil }
        // Complex division: (dv) / (sv)
        let a = (dv.x * sv.x + dv.y * sv.y) / den
        let b = (dv.y * sv.x - dv.x * sv.y) / den
        let tx = d1.x - (a * s1.x - b * s1.y)
        let ty = d1.y - (b * s1.x + a * s1.y)
        return SimilarityTransform(a: a, b: b, tx: tx, ty: ty)
    }

    public var inverse: SimilarityTransform? {
        let den = a * a + b * b
        guard den > 0 else { return nil }
        let ia = a / den, ib = -b / den
        return SimilarityTransform(a: ia, b: ib, tx: -(ia * tx - ib * ty), ty: -(ib * tx + ia * ty))
    }
}

/// Where the eyes must land in the model's input crop, in crop pixels with
/// the origin at the top-left (image convention).
public struct AlignmentTemplate: Codable, Equatable, Sendable {
    public var size: Int
    /// The subject's right eye, which appears on the image's left.
    public var imageLeftEye: Point2
    public var imageRightEye: Point2

    public init(size: Int, imageLeftEye: Point2, imageRightEye: Point2) {
        self.size = size
        self.imageLeftEye = imageLeftEye
        self.imageRightEye = imageRightEye
    }

    /// The standard ArcFace/InsightFace 112×112 eye positions.
    public static let arcface112 = AlignmentTemplate(
        size: 112,
        imageLeftEye: Point2(38.2946, 51.6963),
        imageRightEye: Point2(73.5318, 51.5014)
    )

    /// Transform from source pixel coordinates (top-left origin) to crop pixels.
    /// `imageLeftEye` is the eye that appears on the left of the source image.
    public func transform(imageLeftEye l: Point2, imageRightEye r: Point2) -> SimilarityTransform? {
        SimilarityTransform.mapping(l, r, to: imageLeftEye, imageRightEye)
    }
}
