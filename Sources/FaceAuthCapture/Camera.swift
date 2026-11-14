import AVFoundation
import CoreMedia
import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case permissionRestricted
    case noCamera
    case cannotConfigure(String)
    case noFrames(seconds: Double)
    case model(String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return """
            Camera access is denied. Turn it on in System Settings → Privacy & Security → Camera \
            for the app you run faceauth from (e.g. Terminal), then try again.
            """
        case .permissionRestricted:
            return "Camera access is restricted on this Mac (e.g. by a profile)."
        case .noCamera:
            return "No built-in front camera was found."
        case .cannotConfigure(let m):
            return "Cannot configure the camera: \(m)"
        case .noFrames(let s):
            return "The camera delivered no frames within \(s) s."
        case .model(let m):
            return m
        }
    }
}

/// The monotonic host clock shared by frame timestamps and timers.
public enum HostClock {
    public static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// One frame from the camera. The pixel buffer stays in memory only.
public struct CameraFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Host-clock seconds.
    public let time: Double

    public init(pixelBuffer: CVPixelBuffer, time: Double) {
        self.pixelBuffer = pixelBuffer
        self.time = time
    }
}

/// The built-in front camera at 640×480, delivering frames as an AsyncStream.
public final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "faceauth.camera")
    private var continuation: AsyncStream<CameraFrame>.Continuation?

    /// Asks for camera permission if needed. Throws if access is not granted.
    public static func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CaptureError.permissionDenied }
        case .denied:
            throw CaptureError.permissionDenied
        case .restricted:
            throw CaptureError.permissionRestricted
        @unknown default:
            throw CaptureError.permissionDenied
        }
    }

    static func frontCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        // Macs report the built-in FaceTime camera as .front or .unspecified.
        return discovery.devices.first { $0.position == .front }
            ?? discovery.devices.first { !$0.localizedName.localizedCaseInsensitiveContains("iphone") }
            ?? AVCaptureDevice.default(for: .video)
    }

    /// Starts capturing and returns the frame stream.
    public func start() throws -> AsyncStream<CameraFrame> {
        guard let device = Self.frontCamera() else { throw CaptureError.noCamera }
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw CaptureError.cannotConfigure(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw CaptureError.cannotConfigure("cannot add input") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotConfigure("cannot add output") }
        session.addOutput(output)
        session.commitConfiguration()

        let stream = AsyncStream<CameraFrame>(bufferingPolicy: .bufferingNewest(2)) { c in
            self.continuation = c
        }
        queue.async { self.session.startRunning() }
        return stream
    }

    public func stop() {
        queue.sync {
            if session.isRunning { session.stopRunning() }
            continuation?.finish()
            continuation = nil
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        continuation?.yield(CameraFrame(pixelBuffer: pb, time: t.isFinite ? t : HostClock.now()))
    }
}
