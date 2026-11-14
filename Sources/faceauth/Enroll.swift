import FaceAuthCapture
import FaceAuthCore
import Foundation

/// The 5 enrollment poses (SPEC Q12a).
enum Pose: String, CaseIterable {
    case center, left, right, up, down

    var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Turn your head slightly to your left"
        case .right: return "Turn your head slightly to your right"
        case .up: return "Tilt your head slightly up"
        case .down: return "Tilt your head slightly down"
        }
    }

    /// Whether the yaw/pitch fit this pose. For left/right the sign is not
    /// known before calibration, so `left` accepts either side and `right`
    /// then requires the opposite side to `left`.
    func accepts(yaw: Double, pitch: Double, leftSign: Double?) -> Bool {
        switch self {
        case .center: return abs(yaw) < 10 && abs(pitch) < 10
        case .left:
            return (8...30).contains(abs(yaw)) && abs(pitch) < 15
        case .right:
            guard (8...30).contains(abs(yaw)) && abs(pitch) < 15 else { return false }
            if let s = leftSign { return yaw * s < 0 }
            return true
        case .up, .down:
            // Pitch sign also differs by convention; up and down must have opposite signs.
            return (6...30).contains(abs(pitch)) && abs(yaw) < 12
        }
    }
}

/// Captures the 5 snaps from `source` and saves them with `save`.
/// The same logic runs in-process and, for `--system`, in root on frames
/// streamed by the capture helper.
func runEnroll(ui: Prompter, source: FrameSource, modelID: String,
               save: (Enrollment) throws -> String) async throws -> Int32 {
    try await source.start()
    defer { source.stop() }
    _ = try await source.first(timeout: 3)

    var embeddings: [[Float]] = []
    var poses: [String] = []
    var leftSign: Double?
    var upPitchSign: Double?

    for (i, pose) in Pose.allCases.enumerated() {
        ui.show(.enroll(step: i, of: 5, "Snap \(i + 1)/5: \(pose.instruction)"))
        // Up to 10 s to get into the pose; then the best frame of a 1 s burst.
        let poseStart = HostClock.now()
        let deadline = poseStart + 10
        var burstEnd: Double?
        var best: (q: Double, emb: [Float], yaw: Double, pitch: Double)?
        while HostClock.now() < deadline {
            guard let sf = try await source.next() else { break }
            let f = sf.frame
            guard f.time >= poseStart, f.faceCount == 1, let q = f.quality, q >= 0.3,
                  let yaw = f.yawDegrees, let pitch = f.pitchDegrees else { continue }
            var ok = pose.accepts(yaw: yaw, pitch: pitch, leftSign: leftSign)
            if pose == .down, let s = upPitchSign { ok = ok && pitch * s < 0 }
            guard ok else { continue }
            if burstEnd == nil { burstEnd = f.time + 1.0 }
            if q > (best?.q ?? -1), let e = try sf.embed() {
                best = (q, e, yaw, pitch)
            }
            if let end = burstEnd, f.time >= end { break }
        }
        guard let b = best else {
            throw Failure("Could not capture snap \(i + 1) (\(pose.rawValue)) within 10 s. Make sure your face is well lit and only one face is visible, then run faceauth enroll again.")
        }
        if pose == .left { leftSign = b.yaw > 0 ? 1 : -1 }
        if pose == .up { upPitchSign = b.pitch > 0 ? 1 : -1 }
        embeddings.append(b.emb)
        poses.append(pose.rawValue)
        ui.log(String(format: "snap %d %@: quality %.2f yaw %.1f pitch %.1f", i + 1, pose.rawValue, b.q, b.yaw, b.pitch))
    }

    guard let enrollment = Enrollment(modelID: modelID, embeddings: embeddings, poses: poses) else {
        throw Failure("The captured embeddings were invalid; please enroll again.")
    }
    let path = try save(enrollment)
    source.stop()
    await ui.finish(.success("Enrolled (5/5)"))
    say("Saved \(path) (embeddings only, mode 600).")
    return Exit.match
}

/// Plain `faceauth enroll`: the local camera and the user store.
func runLocalEnroll(ui: UI) async throws -> Int32 {
    ui.show(.enroll(step: 0, of: 5, "Starting the camera…")) // HUD first (R14)
    let store = EnrollmentStore(directory: EnrollmentStore.defaultDirectory)
    let embedder = try Embedder.load()
    let code = try await runEnroll(ui: ui, source: LocalSource(embedder: embedder), modelID: embedder.modelID) { e in
        try store.save(e)
        return store.enrollmentURL.path
    }
    if (try? store.loadConfig()) == nil {
        say("Next: run `faceauth calibrate` to choose your match threshold.")
    }
    return code
}
