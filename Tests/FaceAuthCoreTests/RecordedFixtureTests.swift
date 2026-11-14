import Foundation
import Testing
@testable import FaceAuthCore

/// Tests on landmark sequences recorded from the real camera with
/// `faceauth record-landmarks`. See Fixtures/README.md for how to record them.
/// Each fixture's `label` says what it must (or must not) trigger.
enum Recorded {
    static func all() -> [LandmarkRecording] {
        guard let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            try? JSONDecoder().decode(LandmarkRecording.self, from: Data(contentsOf: $0))
        }
    }

    static func with(_ label: String) -> [LandmarkRecording] { all().filter { $0.label == label } }

    static func blinkSeen(_ r: LandmarkRecording) -> Bool {
        var gate = FrameGate(), d = BlinkDetector()
        for f in r.frames where gate.check(f) == .valid {
            if let e = EyeAspectRatio.both(left: f.leftEye, right: f.rightEye), d.add(ear: e) { return true }
        }
        return false
    }

    static func motionSeen(_ r: LandmarkRecording) -> Bool {
        var gate = FrameGate(), m = MotionCheck()
        for f in r.frames where gate.check(f) == .valid { if m.add(f) { return true } }
        return false
    }

    static func turn(_ r: LandmarkRecording, _ c: TurnDirection, sign: Double) -> HeadTurnChallenge.Status {
        var gate = FrameGate()
        var cfg = HeadTurnChallenge.Config()
        cfg.leftYawSign = sign
        var t = HeadTurnChallenge(challenge: c, config: cfg)
        var s = HeadTurnChallenge.Status.pending
        for f in r.frames where gate.check(f) == .valid { if let y = f.yawDegrees { s = t.add(yawDegrees: y) } }
        return s
    }

    /// The left-yaw sign, read from the recorded `turn-left` fixture.
    static var leftYawSign: Double? {
        guard let r = with("turn-left").first else { return nil }
        let yaws = r.frames.compactMap(\.yawDegrees)
        guard let extreme = yaws.max(by: { abs($0) < abs($1) }), abs(extreme) >= 20 else { return nil }
        return extreme > 0 ? 1 : -1
    }
}

@Suite("Recorded fixtures (R7, R8, R9)")
struct RecordedFixtureTests {
    @Test(.enabled(if: !Recorded.with("blink").isEmpty, "no recorded 'blink' fixture yet"))
    func blinkFixturesBlink() {
        for r in Recorded.with("blink") { #expect(Recorded.blinkSeen(r), "\(r.label): \(r.note ?? "")") }
    }

    @Test(.enabled(if: !Recorded.with("open").isEmpty, "no recorded 'open' fixture yet"))
    func openEyesDoNotBlink() {
        for r in Recorded.with("open") { #expect(!Recorded.blinkSeen(r)) }
    }

    @Test(.enabled(if: !Recorded.with("photo").isEmpty, "no recorded 'photo' fixture yet"))
    func photoHasNoBlinkAndNoMotion() {
        for r in Recorded.with("photo") {
            #expect(!Recorded.blinkSeen(r))
            #expect(!Recorded.motionSeen(r))
        }
    }

    @Test(.enabled(if: !Recorded.with("blink").isEmpty, "no recorded live fixture yet"))
    func liveHasMotion() {
        for r in Recorded.with("blink") { #expect(Recorded.motionSeen(r)) }
    }

    @Test(.enabled(if: Recorded.leftYawSign != nil && !Recorded.with("turn-right").isEmpty,
                   "needs recorded 'turn-left' and 'turn-right' fixtures"))
    func turnsMatchDirection() {
        let sign = Recorded.leftYawSign!
        for r in Recorded.with("turn-left") {
            #expect(Recorded.turn(r, .left, sign: sign) == .passed)
            #expect(Recorded.turn(r, .right, sign: sign) == .wrongDirection)
        }
        for r in Recorded.with("turn-right") {
            #expect(Recorded.turn(r, .right, sign: sign) == .passed)
            #expect(Recorded.turn(r, .left, sign: sign) == .wrongDirection)
        }
    }

    @Test(.enabled(if: !Recorded.with("two-faces").isEmpty, "no recorded 'two-faces' fixture yet"))
    func twoFacesNeverValid() {
        for r in Recorded.with("two-faces") {
            var gate = FrameGate()
            for f in r.frames where f.faceCount > 1 { #expect(gate.check(f) == .resetTrack) }
            #expect(r.frames.contains { $0.faceCount > 1 }, "fixture must contain a 2-face frame")
        }
    }
}
