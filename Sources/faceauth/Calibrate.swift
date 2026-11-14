import FaceAuthCapture
import FaceAuthCore
import Foundation

/// Scores collected over one calibration phase.
struct PhaseScores {
    var frameScores: [Double] = []   // single frame vs. enrolled mean
    var meanScores: [Double] = []    // rolling 3-frame mean (what verify uses)
    var motionScores: [Double] = []
    var blink = false
    var yaws: [Double] = []
}

func collect(_ pipe: FramePipeline, _ embedder: Embedder, _ e: Enrollment, seconds: Double) async throws -> PhaseScores {
    var p = PhaseScores()
    var gate = FrameGate()
    var motion = MotionCheck()
    var blink = BlinkDetector()
    var recent: [[Float]] = []
    let end = HostClock.now() + seconds
    while HostClock.now() < end {
        guard let (cf, r) = try await pipe.next() else { break }
        let f = r.frame
        guard gate.check(f) == .valid else { continue }
        if let y = f.yawDegrees { p.yaws.append(y) }
        motion.add(f)
        if let m = motion.lastScore { p.motionScores.append(m) }
        if let ear = EyeAspectRatio.both(left: f.leftEye, right: f.rightEye), blink.add(ear: ear) { p.blink = true }
        if let yaw = f.yawDegrees, let pitch = f.pitchDegrees, abs(yaw) <= 15, abs(pitch) <= 15,
           let emb = embedding(embedder, cf, r) {
            if let s = Embeddings.cosine(emb, e.mean) { p.frameScores.append(s) }
            recent.append(emb)
            if recent.count > 3 { recent.removeFirst() }
            if recent.count == 3, let sc = MatchDecision.scores(probe: recent, enrollment: e) {
                p.meanScores.append(min(sc.meanScore, sc.bestIndividualScore))
            }
        }
    }
    return p
}

func fmt(_ xs: [Double], digits: Int = 3) -> String {
    guard let s = xs.stats else { return "n=0" }
    let f = "%.\(digits)f"
    return "n=\(xs.count)  min \(String(format: f, s.min))  median \(String(format: f, s.median))  max \(String(format: f, s.max))"
}

func runCalibrate(ui: UI, fixedThreshold: Double?) async throws -> Int32 {
    let store = EnrollmentStore(directory: EnrollmentStore.defaultDirectory)
    let embedder = try Embedder.load()
    let enrollment = try store.loadEnrollment(expectedModelID: embedder.modelID)
    if fixedThreshold == nil && !isTTY() {
        throw Failure("calibrate needs a terminal to ask for the threshold, or pass --threshold X.")
    }
    let pipe = FramePipeline()
    try await pipe.start()
    defer { pipe.stop() }
    _ = try await pipe.first(timeout: 3)

    await waitForReturn("Step 1/3: look at the camera, move naturally and blink a few times for 5 s.")
    let live = try await collect(pipe, embedder, enrollment, seconds: 5)

    await waitForReturn("Step 2/3: turn your head to YOUR LEFT and hold it for 3 s.")
    let turn = try await collect(pipe, embedder, enrollment, seconds: 3)

    await waitForReturn("Step 3/3: hold your phone with a PHOTO of your face in front of the camera for 5 s (move it around a little).")
    let photo = try await collect(pipe, embedder, enrollment, seconds: 5)

    print("""

    Similarity to your enrollment (cosine; higher = more similar)
      live you,  single frame: \(fmt(live.frameScores))
      live you,  3-frame mean: \(fmt(live.meanScores))
      photo,     single frame: \(fmt(photo.frameScores))
      photo,     3-frame mean: \(fmt(photo.meanScores))
    Liveness signals
      live  motion score: \(fmt(live.motionScores, digits: 4))   blink seen: \(live.blink)
      photo motion score: \(fmt(photo.motionScores, digits: 4))   blink seen: \(photo.blink)
    """)

    // Head-turn sign: which way does Vision's yaw go when you turn left?
    var verify = (try? store.loadConfig())?.verify ?? VerifyConfig()
    if let extreme = turn.yaws.max(by: { abs($0) < abs($1) }), abs(extreme) >= 15 {
        verify.turn.leftYawSign = extreme > 0 ? 1 : -1
        print(String(format: "  turning left gives yaw %+.1f°, so leftYawSign = %+.0f", extreme, verify.turn.leftYawSign))
    } else {
        say("Warning: the left turn was too small to measure (|yaw| < 15°); keeping leftYawSign = \(verify.turn.leftYawSign).")
    }

    // Motion threshold: between the photo's highest and the live median, if they separate.
    if let pm = photo.motionScores.stats?.max, let lm = live.motionScores.stats?.median {
        if pm < lm {
            verify.motion.minScore = (pm * lm).squareRoot()
            print(String(format: "  motion threshold set to %.4f (photo max %.4f < live median %.4f)", verify.motion.minScore, pm, lm))
        } else {
            say(String(format: "Warning: the photo moved as much as your live face (photo max %.4f ≥ live median %.4f). Keeping motion threshold %.4f. Blink and head-turn checks still apply.", pm, lm, verify.motion.minScore))
        }
    }

    // A face match alone cannot tell you from a photo of you; liveness does that.
    // Suggest a threshold a little under your lowest live 3-frame score,
    // and not below the model's LFW operating point (≈0.34).
    let liveMin = live.meanScores.stats?.min ?? 0.5
    let suggested = max(0.34, ((liveMin - 0.05) * 100).rounded() / 100)
    print("""

    The photo scores show that a photo of you matches your face, as expected:
    the threshold separates you from other people, and liveness (blink, head
    turn, motion) separates you from a photo.
    Suggested threshold: \(String(format: "%.2f", suggested))
    """)

    let chosen: Double
    if let t = fixedThreshold {
        chosen = t
    } else {
        say("Enter threshold [\(String(format: "%.2f", suggested))]: ", terminator: false)
        let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { chosen = suggested }
        else if let v = Double(line), v > -1, v < 1 { chosen = v }
        else { throw Failure("Not a valid threshold: \(line)") }
    }
    try store.save(FaceAuthConfig(threshold: chosen, modelID: embedder.modelID, verify: verify))
    print("Saved threshold \(String(format: "%.3f", chosen)) to \(store.configURL.path) (mode 600).")
    print("Record this value in the README under \"Threshold I chose\".")
    return Exit.match
}

func say(_ s: String, terminator: Bool) {
    FileHandle.standardError.write(Data((s + (terminator ? "\n" : "")).utf8))
}
