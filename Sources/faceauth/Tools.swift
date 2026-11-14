import AppKit
import CoreVideo
import FaceAuthCapture
import FaceAuthCore
import Foundation

/// `record-landmarks FILE --label L --seconds N`: landmark-only fixture.
func runRecord(ui: UI, path: String?, label: String?, seconds: Double?) async throws -> Int32 {
    guard let path else { throw Failure("usage: faceauth record-landmarks FILE --label LABEL [--seconds N]") }
    guard let label else { throw Failure("--label is required (blink, open, photo, turn-left, turn-right, two-faces)") }
    let pipe = FramePipeline()
    try await pipe.start()
    defer { pipe.stop() }
    _ = try await pipe.first(timeout: 3)
    await waitForReturn("Recording '\(label)' for \(seconds ?? 4) s.")
    var frames: [FaceFrame] = []
    let end = HostClock.now() + (seconds ?? 4)
    while HostClock.now() < end {
        guard let (_, r) = try await pipe.next() else { break }
        frames.append(r.frame)
    }
    let t0 = frames.first?.time ?? 0
    frames = frames.map { var f = $0; f.time -= t0; return f } // relative times
    let rec = LandmarkRecording(label: label, note: "recorded \(ISO8601DateFormatter().string(from: Date()))", frames: frames)
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    try enc.encode(rec).write(to: URL(fileURLWithPath: path))
    let faces = frames.filter { $0.faceCount == 1 }.count
    say("Wrote \(frames.count) frames (\(faces) with one face) to \(path). Landmarks only, no images.")
    return Exit.match
}

/// `hud-demo`: walks the live HUD through its states, for screenshots (R14, R17).
@MainActor
func runHUDDemo(ui: UI) async -> Int32 {
    let entered = secondsSinceProcessStart()
    guard let hud = ui.hud else {
        say("No GUI session (or --no-hud): nothing to show.")
        return Exit.error
    }
    let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    hud.show(.scanning(Prompt.lookAtCamera.text))
    let expandedAfter = secondsSinceProcessStart()
    let appearedAfter = expandedAfter - Date().timeIntervalSince(hud.onScreenAt ?? Date())
    say(String(format: "hud on screen %.3f s after process start (R14 limit 0.5 s); fully expanded at %.3f s", appearedAfter, expandedAfter))
    say(String(format: "main code started %.3f s after process start", entered))
    say("panel frame \(NSStringFromRect(hud.frame)) notch: \(hud.geometryInfo.hasNotch)")
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    say("expanded frame \(NSStringFromRect(hud.frame))")
    hud.update(.scanning(Prompt.challenge(.left).text))
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let t = HostClock.now()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in hud.finish(.success("Face matched")) { c.resume() } }
    say(String(format: "success → collapsed in %.3f s", HostClock.now() - t))
    try? await Task.sleep(nanoseconds: 500_000_000)
    hud.show(.scanning(Prompt.challenge(.right).text))
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let t2 = HostClock.now()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in hud.finish(.failure("Not recognized")) { c.resume() } }
    say(String(format: "failure → collapsed in %.3f s", HostClock.now() - t2))
    let after = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    say("frontmost app before: \(before), after: \(after) → focus \(before == after ? "unchanged" : "CHANGED")")
    return before == after ? Exit.match : Exit.error
}

/// `hud-snapshots DIR`: renders every HUD state offscreen to PNG (R15) and
/// checks that Reduce Motion removes pulse and shake (R18).
@MainActor
func runHUDSnapshots(dir: String?) throws -> Int32 {
    guard let dir else { throw Failure("usage: faceauth hud-snapshots DIR") }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let states: [(String, HUDState)] = [
        ("1-look", .scanning(Prompt.lookAtCamera.text)),
        ("2-challenge-left", .scanning(Prompt.challenge(.left).text)),
        ("3-enroll-3of5", .enroll(step: 2, of: 5, "Snap 3/5: Turn your head slightly to your right")),
        ("4-success", .success("Face matched")),
        ("5-failure", .failure("Not recognized")),
    ]
    for (notch, suffix) in [(true, "notch"), (false, "pill")] {
        for (name, state) in states {
            let layer = HUDContentLayer()
            layer.layout(size: HUDGeometry.expandedSize, topInset: notch ? 32 : 0, hasNotch: notch)
            layer.apply(state, animated: false)
            guard let png = layer.pngData() else { throw Failure("render failed") }
            let path = (dir as NSString).appendingPathComponent("\(name)-\(suffix).png")
            try png.write(to: URL(fileURLWithPath: path))
            say("wrote \(path)")
        }
    }
    // R18: animations with and without Reduce Motion.
    var results: [String] = []
    for reduce in [false, true] {
        for (name, state) in [("scanning", HUDState.scanning("x")), ("failure", HUDState.failure("x"))] {
            let layer = HUDContentLayer()
            layer.layout(size: HUDGeometry.expandedSize, topInset: 32, hasNotch: true)
            layer.reduceMotion = reduce
            layer.apply(state, animated: true)
            results.append("reduceMotion=\(reduce) \(name): motion animations \(layer.hasMotionAnimations)")
            if reduce && layer.hasMotionAnimations { throw Failure("R18 violated: \(name) animates with Reduce Motion on") }
        }
    }
    results.forEach { say($0) }
    return Exit.match
}

/// `self-test`: loads the model and embeds a synthetic image (no camera).
func runSelfTest() throws -> Int32 {
    let t0 = HostClock.now()
    let embedder = try Embedder.load()
    let loadTime = HostClock.now() - t0
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    guard let pb else { throw Failure("cannot allocate a test image") }
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<480 { for x in 0..<640 {
        let o = y * bpr + x * 4
        base[o] = UInt8((x * 255) / 640); base[o + 1] = UInt8((y * 255) / 480); base[o + 2] = 128; base[o + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pb, [])
    let frame = CameraFrame(pixelBuffer: pb, time: 0)
    var times: [Double] = []
    var e: [Float] = []
    for _ in 0..<10 {
        let t = HostClock.now()
        e = try embedder.embed(frame, imageLeftEye: Point2(270, 260), imageRightEye: Point2(370, 262))
        times.append(HostClock.now() - t)
    }
    let norm = e.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
    print("model \(embedder.modelID) at \(embedder.modelURL.path)")
    print(String(format: "load %.2f s, embedding dim %d, L2 norm %.4f, per-frame %.1f ms (median of 10)",
                 loadTime, e.count, norm, (times.sorted()[5]) * 1000))
    return e.count == 128 && abs(norm - 1) < 1e-3 ? Exit.match : Exit.error
}
