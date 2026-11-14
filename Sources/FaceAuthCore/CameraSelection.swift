import Foundation

/// A camera as seen by the selection rule (built from AVCaptureDevice).
public struct CameraCandidate: Equatable, Sendable {
    public var name: String
    /// deviceType == .builtInWideAngleCamera
    public var isBuiltInWideAngle: Bool
    /// transportType == built-in ('bltn')
    public var isBuiltInTransport: Bool
    /// An iPhone used as a webcam.
    public var isContinuity: Bool

    public init(name: String, isBuiltInWideAngle: Bool, isBuiltInTransport: Bool, isContinuity: Bool) {
        self.name = name
        self.isBuiltInWideAngle = isBuiltInWideAngle
        self.isBuiltInTransport = isBuiltInTransport
        self.isContinuity = isContinuity
    }

    public var isTrustedBuiltIn: Bool { isBuiltInWideAngle && isBuiltInTransport && !isContinuity }
}

public enum CameraSelection {
    /// Index of the camera to use. With `builtInOnly` (sudo, --system; SPEC R31)
    /// only a trusted built-in camera qualifies and there is no fallback.
    /// Otherwise the built-in camera is preferred, then any non-Continuity camera.
    public static func choose(_ cams: [CameraCandidate], builtInOnly: Bool) -> Int? {
        if let i = cams.firstIndex(where: \.isTrustedBuiltIn) { return i }
        if builtInOnly { return nil }
        return cams.firstIndex { !$0.isContinuity } ?? (cams.isEmpty ? nil : 0)
    }
}
