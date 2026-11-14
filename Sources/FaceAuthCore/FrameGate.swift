import Foundation

/// Decides whether a frame is usable and whether the face track is continuous.
public struct FrameGate: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        public var minQuality: Double = 0.3
        public var minIoU: Double = 0.3
        public var maxGapSeconds: Double = 0.3
        public init() {}
    }

    public enum Verdict: Equatable, Sendable {
        /// Exactly one good face, continuous with the previous valid frame.
        case valid
        /// No face, or a low-quality one: drop the frame, keep progress.
        case drop
        /// More than one face, or the track broke: drop and reset all progress.
        case resetTrack
    }

    public let config: Config
    private var last: (time: Double, box: Rect)?

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() { last = nil }

    public mutating func check(_ frame: FaceFrame) -> Verdict {
        if frame.faceCount > 1 {
            last = nil
            return .resetTrack
        }
        guard frame.faceCount == 1, let box = frame.boundingBox,
              (frame.quality ?? 0) >= config.minQuality,
              frame.leftEye != nil, frame.rightEye != nil else {
            return .drop
        }
        defer { last = (frame.time, box) }
        if let last {
            if frame.time - last.time > config.maxGapSeconds || box.iou(last.box) < config.minIoU {
                return .resetTrack
            }
        }
        return .valid
    }
}
