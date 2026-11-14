import Foundation
@testable import FaceAuthCore

/// Builds synthetic landmark frames for tests. Recorded fixtures (see
/// Fixtures/README.md) are used in addition when present.
enum Synthetic {
    /// An 8-point closed eye contour centred at `c` with width `w` and EAR `ear`.
    static func eye(center c: Point2, width w: Double, ear: Double) -> [Point2] {
        let h = ear * w
        return (0..<8).map { i in
            let t = Double(i) / 8 * 2 * .pi
            return Point2(c.x + cos(t) * w / 2, c.y + sin(t) * h / 2)
        }
    }

    /// A fixed 20-point "face shape" around the eyes; `wobble` perturbs it non-rigidly.
    static func shape(around box: Rect, wobble: Double) -> [Point2] {
        (0..<20).map { i in
            let t = Double(i) / 20 * 2 * .pi
            let r = 0.4 + wobble * sin(Double(i) * 1.7)
            return Point2(box.x + box.width * (0.5 + r * cos(t)), box.y + box.height * (0.5 + r * sin(t)))
        }
    }

    static func frame(
        t: Double,
        ear: Double = 0.30,
        yaw: Double = 0,
        pitch: Double = 0,
        box: Rect = Rect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
        wobble: Double = 0,
        faces: Int = 1,
        quality: Double = 0.8,
        shift: Point2 = Point2(0, 0)
    ) -> FaceFrame {
        guard faces == 1 else { return FaceFrame(time: t, faceCount: faces) }
        var b = box
        b.x += shift.x
        b.y += shift.y
        let l = Point2(b.x + b.width * 0.32, b.y + b.height * 0.62)
        let r = Point2(b.x + b.width * 0.68, b.y + b.height * 0.62)
        let le = eye(center: l, width: b.width * 0.18, ear: ear)
        let re = eye(center: r, width: b.width * 0.18, ear: ear)
        return FaceFrame(
            time: t, faceCount: 1, boundingBox: b, leftEye: le, rightEye: re,
            landmarks: le + re + shape(around: b, wobble: wobble),
            yawDegrees: yaw, pitchDegrees: pitch, quality: quality)
    }

    static func unit(_ v: [Float]) -> [Float] { Embeddings.normalized(v)! }

    /// A deterministic pseudo-random unit vector.
    static func embedding(seed: UInt64, dim: Int = 128) -> [Float] {
        var s = seed &* 6364136223846793005 &+ 1442695040888963407
        var v = [Float]()
        for _ in 0..<dim {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            v.append(Float(Int64(bitPattern: s >> 11) % 2000) / 1000 - 1)
        }
        return unit(v)
    }

    /// `base` blended with noise so that cosine(base, result) is about `similarity`.
    static func near(_ base: [Float], similarity: Double, seed: UInt64) -> [Float] {
        let n = embedding(seed: seed, dim: base.count)
        // Remove the component of n along base, then mix.
        let d = zip(base, n).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let ortho = unit(zip(n, base).map { Float(Double($0) - d * Double($1)) })
        let s = similarity, c = (1 - s * s).squareRoot()
        return unit(zip(base, ortho).map { Float(s * Double($0) + c * Double($1)) })
    }

    static func enrollment(base: [Float]) -> Enrollment {
        let embs = (0..<5).map { near(base, similarity: 0.9, seed: UInt64(100 + $0)) }
        return Enrollment(modelID: "test", embeddings: embs, poses: ["c", "l", "r", "u", "d"])!
    }
}
