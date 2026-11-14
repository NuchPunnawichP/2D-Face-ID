import CoreVideo
import FaceAuthCore
import Foundation
import Vision

/// Runs Vision on a camera frame and produces a `FaceFrame` (landmarks only).
public final class FaceAnalyzer: @unchecked Sendable {
    public init() {}

    public struct Result {
        public var frame: FaceFrame
        /// Image-pixel eye centres (origin bottom-left), for alignment.
        public var imageLeftEyePx: Point2?
        public var imageRightEyePx: Point2?
    }

    public func analyze(_ cf: CameraFrame) throws -> Result {
        let pb = cf.pixelBuffer
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])

        let rects = VNDetectFaceRectanglesRequest()
        rects.revision = VNDetectFaceRectanglesRequestRevision3 // continuous yaw and pitch
        try handler.perform([rects])
        let faces = rects.results ?? []
        guard faces.count == 1, let face = faces.first else {
            return Result(frame: FaceFrame(time: cf.time, faceCount: faces.count))
        }

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [face]
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = [face]
        try handler.perform([landmarks, quality])

        let lmFace = landmarks.results?.first
        let size = CGSize(width: w, height: h)
        func normalized(_ region: VNFaceLandmarkRegion2D?) -> [Point2]? {
            guard let region, region.pointCount > 0 else { return nil }
            return region.pointsInImage(imageSize: size).map { Point2(Double($0.x) / w, Double($0.y) / h) }
        }
        let a = normalized(lmFace?.landmarks?.leftEye)
        let b = normalized(lmFace?.landmarks?.rightEye)
        let all = normalized(lmFace?.landmarks?.allPoints)
        let bb = face.boundingBox

        // Name eyes by where they appear in the image, independent of Vision's naming.
        var imageLeft: [Point2]? = nil, imageRight: [Point2]? = nil
        if let a, let b {
            let ca = a.reduce(0.0) { $0 + $1.x } / Double(a.count)
            let cb = b.reduce(0.0) { $0 + $1.x } / Double(b.count)
            (imageLeft, imageRight) = ca <= cb ? (a, b) : (b, a)
        }

        let frame = FaceFrame(
            time: cf.time,
            faceCount: 1,
            boundingBox: Rect(x: bb.origin.x, y: bb.origin.y, width: bb.width, height: bb.height),
            leftEye: imageLeft,
            rightEye: imageRight,
            landmarks: all,
            yawDegrees: face.yaw.map { $0.doubleValue * 180 / .pi },
            pitchDegrees: face.pitch.map { $0.doubleValue * 180 / .pi },
            quality: (quality.results?.first?.faceCaptureQuality).map(Double.init)
        )
        return Result(
            frame: frame,
            imageLeftEyePx: frame.leftEyeCenter.map { Point2($0.x * w, $0.y * h) },
            imageRightEyePx: frame.rightEyeCenter.map { Point2($0.x * w, $0.y * h) }
        )
    }
}
