import Foundation

/// Everything the pure logic needs to know about one camera frame.
/// Built from Vision results by FaceAuthCapture, or loaded from a recorded
/// fixture in tests. Contains landmarks only, never pixels.
public struct FaceFrame: Codable, Equatable, Sendable {
    /// Seconds on a monotonic clock.
    public var time: Double
    /// Number of faces Vision found in the frame.
    public var faceCount: Int
    /// The remaining fields describe the single face and are nil when faceCount != 1.
    public var boundingBox: Rect?
    public var leftEye: [Point2]?
    public var rightEye: [Point2]?
    /// All landmark points (Vision allPoints), used for the motion check.
    public var landmarks: [Point2]?
    public var yawDegrees: Double?
    public var pitchDegrees: Double?
    /// Vision faceCaptureQuality, 0...1.
    public var quality: Double?

    public init(
        time: Double,
        faceCount: Int,
        boundingBox: Rect? = nil,
        leftEye: [Point2]? = nil,
        rightEye: [Point2]? = nil,
        landmarks: [Point2]? = nil,
        yawDegrees: Double? = nil,
        pitchDegrees: Double? = nil,
        quality: Double? = nil
    ) {
        self.time = time
        self.faceCount = faceCount
        self.boundingBox = boundingBox
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.landmarks = landmarks
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.quality = quality
    }

    /// Centre of an eye contour.
    public var leftEyeCenter: Point2? { leftEye.map(centroid) }
    public var rightEyeCenter: Point2? { rightEye.map(centroid) }
}

/// A recorded landmark sequence, written by `faceauth record-landmarks`
/// and used as a unit-test fixture.
public struct LandmarkRecording: Codable, Sendable {
    public var label: String
    public var note: String?
    public var frames: [FaceFrame]

    public init(label: String, note: String? = nil, frames: [FaceFrame]) {
        self.label = label
        self.note = note
        self.frames = frames
    }
}
