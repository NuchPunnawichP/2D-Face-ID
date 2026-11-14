import FaceAuthCapture
import FaceAuthCore
import Foundation

/// Serialises access to the controller between the frame loop and the timer.
actor VerifyState {
    var controller: VerifyController
    init(_ c: VerifyController) { controller = c }

    func start() { controller.start() }
    func frame(_ f: FaceFrame, _ e: [Float]?) -> VerifyOutcome { controller.handle(frame: f, embedding: e) }
    func tick(_ now: Double) -> VerifyOutcome { controller.handle(tick: now) }
    func wantsEmbedding(_ f: FaceFrame) -> Bool { controller.session.wantsEmbedding(f) }
    var outcome: VerifyOutcome { controller.session.outcome }
    var session: VerifySession { controller.session }
}

/// - Parameter storeData: under sudo, the root-store bundle the PAM module wrote
///   to `--store-fd` (SPEC rev 4). Then the user store is never read and only
///   the built-in camera is used.
func runVerify(ui: UI, storeData: Data? = nil) async throws -> Int32 {
    // Show the HUD first, before anything slow (R14).
    ui.show(.scanning(Prompt.lookAtCamera.text))
    // Under sudo: only the installed, root-owned compiled model (SPEC rev 4).
    let embedder = storeData != nil ? try Embedder.loadInstalled() : try Embedder.load()
    let config: FaceAuthConfig
    let enrollment: Enrollment
    if let storeData {
        let bundle = try StoreBundle.decode(storeData, expectedModelID: embedder.modelID,
                                            expectedDimension: embedder.dimension)
        config = bundle.config
        enrollment = bundle.enrollment
        ui.log("using the root store passed on the store fd")
    } else {
        let store = EnrollmentStore(directory: EnrollmentStore.defaultDirectory)
        config = try store.loadConfig()            // Q11: refuse until calibrated
        enrollment = try store.loadEnrollment(expectedModelID: embedder.modelID, expectedDimension: embedder.dimension)
        if config.modelID != embedder.modelID {
            throw Failure("The threshold was calibrated for model \(config.modelID); run faceauth calibrate again.")
        }
    }

    let challenge = TurnDirection.random()
    let session = VerifySession(challenge: challenge, enrollment: enrollment,
                                threshold: config.threshold, config: config.verify)
    let state = VerifyState(VerifyController(session: session) { p in
        switch p {
        case .lookAtCamera, .challenge: ui.show(.scanning(p.text))
        case .success, .failure: break // shown by ui.finish below
        }
    })

    let pipe = FramePipeline(builtInOnly: storeData != nil) // R31
    try await pipe.start()
    defer { pipe.stop() }
    let (cf0, r0) = try await pipe.first(timeout: 3) // Q7: 3 s camera start limit → exit 2
    ui.log("first frame; t0 set, challenge \(challenge.rawValue)")
    await state.start()

    // Timer: fires the deadline even if frames stop arriving (R11). Frames are
    // judged by their capture time, so the timer allows 0.3 s for a frame
    // captured before the deadline that is still being analysed.
    let processingGrace = 0.3
    let ticker = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if await state.tick(HostClock.now() - processingGrace).isFinal { pipe.stop(); break }
        }
    }
    defer { ticker.cancel() }

    var outcome = await state.frame(r0.frame, await state.wantsEmbedding(r0.frame) ? try embedding(embedder, cf0, r0) : nil)
    while !outcome.isFinal {
        guard let (cf, r) = try await pipe.next() else { break }
        let e = await state.wantsEmbedding(r.frame) ? try embedding(embedder, cf, r) : nil
        outcome = await state.frame(r.frame, e)
    }
    outcome = await state.outcome
    if outcome == .pending { throw Failure("The camera stopped delivering frames.") } // camera error → exit 2
    let decidedAt = HostClock.now()
    pipe.stop() // stop the camera before the HUD animation (R17)
    let s = await state.session
    if ui.verbose {
        let sc = s.lastScores.map { String(format: "mean %.3f best %.3f", $0.meanScore, $0.bestIndividualScore) } ?? "none"
        ui.log("outcome \(outcome) | blink \(s.progress.blink) turn \(s.progress.turn) motion \(s.progress.motion) " +
               "frontal \(s.progress.frontalEmbeddings) match \(s.progress.match) | scores \(sc) | resets \(s.resets)" +
               (s.currentMotionScore.map { String(format: " | motion %.4f", $0) } ?? ""))
    }
    switch outcome {
    case .success: await ui.finish(.success(Prompt.success.text))
    case .wrongTurn: await ui.finish(.failure("Wrong direction"))
    case .timeout, .pending: await ui.finish(.failure("Not recognized"))
    }
    ui.log(String(format: "exit %.3f s after the decision", HostClock.now() - decidedAt))
    return outcome == .success ? Exit.match : Exit.noMatch
}
