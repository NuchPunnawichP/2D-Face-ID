import Foundation
import Testing
@testable import FaceAuthCore

// MARK: R21 — cosine similarity

@Suite("Cosine similarity (R21)")
struct CosineTests {
    @Test func identicalIsOne() {
        let v: [Float] = [1, 2, 3]
        #expect(abs(Embeddings.cosine(v, v)! - 1) < 1e-9)
    }
    @Test func orthogonalIsZero() {
        #expect(abs(Embeddings.cosine([1, 0], [0, 1])!) < 1e-12)
    }
    @Test func oppositeIsMinusOne() {
        #expect(abs(Embeddings.cosine([1, 2], [-1, -2])! + 1) < 1e-9)
    }
    @Test func scaleInvariant() {
        #expect(abs(Embeddings.cosine([1, 2, 3], [10, 20, 30])! - 1) < 1e-9)
    }
    @Test func invalidInputsAreNil() {
        #expect(Embeddings.cosine([], []) == nil)
        #expect(Embeddings.cosine([1, 2], [1]) == nil)
        #expect(Embeddings.cosine([0, 0], [1, 1]) == nil)
    }
    @Test func normalizedMeanIsUnit() {
        let m = Embeddings.normalizedMean([[1, 0], [0, 1]])!
        #expect(abs(Double(m[0]) - 0.5.squareRoot()) < 1e-6)
        #expect(abs(Double(m[0] * m[0] + m[1] * m[1]) - 1) < 1e-6)
        #expect(Embeddings.normalizedMean([[1, 0], [1]]) == nil)
    }
}

// MARK: R7 — eye aspect ratio and blink detection

@Suite("Blink detector (R7)")
struct BlinkTests {
    @Test func earMatchesConstruction() {
        let e = Synthetic.eye(center: Point2(0.5, 0.5), width: 0.1, ear: 0.3)
        #expect(abs(EyeAspectRatio.compute(e)! - 0.3) < 0.02)
        #expect(EyeAspectRatio.compute(Array(e.prefix(3))) == nil)
    }

    @Test func earIsRotationInvariant() {
        let e = Synthetic.eye(center: Point2(0, 0), width: 0.1, ear: 0.25)
        let a = 0.4
        let rotated = e.map { Point2($0.x * cos(a) - $0.y * sin(a), $0.x * sin(a) + $0.y * cos(a)) }
        #expect(abs(EyeAspectRatio.compute(rotated)! - EyeAspectRatio.compute(e)!) < 0.02)
    }

    static func run(_ ears: [Double]) -> Bool {
        var d = BlinkDetector()
        var seen = false
        for e in ears { seen = d.add(ear: e) }
        return seen
    }

    @Test func detectsNormalBlink() {
        #expect(Self.run([0.3, 0.3, 0.31, 0.29, 0.3, 0.3, 0.12, 0.08, 0.15, 0.3, 0.3]))
    }
    @Test func noBlinkWithOpenEyes() {
        #expect(!Self.run(Array(repeating: 0.3, count: 60)))
    }
    @Test func noBlinkWhenEyesStayClosed() {
        // Closed for 12 frames (> 8): not a blink.
        #expect(!Self.run([0.3, 0.3, 0.3, 0.3, 0.3] + Array(repeating: 0.1, count: 12) + [0.3, 0.3]))
    }
    @Test func closedForExactlyEightFramesCounts() {
        #expect(Self.run([0.3, 0.3, 0.3, 0.3, 0.3] + Array(repeating: 0.1, count: 8) + [0.3]))
    }
    @Test func constantLowEarNeverBlinks() {
        // Regression for the spec-rev-2 definition: with open-eye EAR below 0.21,
        // "open level" (0.8 × median) fell below the closed threshold and a
        // perfectly static photo could "blink". The closed level is now capped.
        #expect(!Self.run(Array(repeating: 0.20, count: 60)))
        #expect(!Self.run(Array(repeating: 0.15, count: 60)))
    }
    @Test func blinkWithLowBaselineStillWorks() {
        // Narrow eyes (baseline 0.19): closed level = 0.133, open level = 0.152.
        #expect(Self.run(Array(repeating: 0.19, count: 6) + [0.08, 0.07, 0.19]))
    }
    @Test func slowDriftThroughMiddleBandIsNotABlink() {
        // Baseline 0.30: open level 0.24, closed level 0.21. One closed frame,
        // then a long stretch in the middle band (0.22) before reopening.
        let ears = Array(repeating: 0.30, count: 6) + [0.15] + Array(repeating: 0.22, count: 10) + [0.30]
        #expect(!Self.run(ears))
    }
    @Test func noiseAroundBaselineIsNotABlink() {
        let ears = (0..<90).map { 0.30 + 0.02 * sin(Double($0)) }
        #expect(!Self.run(ears))
    }
}

// MARK: R8 — head-turn challenge

@Suite("Head-turn challenge (R8)")
struct TurnTests {
    static func run(_ c: TurnDirection, _ yaws: [Double], sign: Double = 1) -> HeadTurnChallenge.Status {
        var cfg = HeadTurnChallenge.Config()
        cfg.leftYawSign = sign
        var t = HeadTurnChallenge(challenge: c, config: cfg)
        var s = HeadTurnChallenge.Status.pending
        for y in yaws { s = t.add(yawDegrees: y) }
        return s
    }

    @Test func leftPassesWhenHeld() { #expect(Self.run(.left, [0, 10, 22, 25, 24]) == .passed) }
    @Test func rightPassesWhenHeld() { #expect(Self.run(.right, [0, -10, -22, -25, -24]) == .passed) }
    @Test func twoFramesIsNotEnough() { #expect(Self.run(.left, [0, 25, 25, 0, 0]) == .pending) }
    @Test func thresholdIsInclusive() { #expect(Self.run(.left, [20, 20, 20]) == .passed) }
    @Test func belowThresholdNeverPasses() { #expect(Self.run(.left, Array(repeating: 19.9, count: 30)) == .pending) }
    @Test func wrongDirectionFails() { #expect(Self.run(.left, [0, -25, -25, -25]) == .wrongDirection) }
    @Test func briefWrongTwitchIsTolerated() { #expect(Self.run(.left, [0, -25, -25, 0, 25, 25, 25]) == .passed) }
    @Test func signConventionIsRespected() {
        #expect(Self.run(.left, [-25, -25, -25], sign: -1) == .passed)
        #expect(Self.run(.left, [25, 25, 25], sign: -1) == .wrongDirection)
    }
    @Test func randomChallengeUsesBothDirections() {
        let seen = Set((0..<200).map { _ in TurnDirection.random() })
        #expect(seen == [.left, .right])
    }
}

// MARK: R9 — motion check

@Suite("Motion check (R9)")
struct MotionTests {
    static func run(_ frames: [FaceFrame]) -> Bool {
        var m = MotionCheck()
        var ok = false
        for f in frames { ok = m.add(f) }
        return ok
    }

    @Test func staticFaceIsRejected() {
        #expect(!Self.run((0..<30).map { Synthetic.frame(t: Double($0) / 30) }))
    }
    @Test func translatedPhotoIsRejected() {
        // A photo moved around by a shaky hand: rigid motion only.
        let frames = (0..<30).map { i -> FaceFrame in
            let d = 0.02 * sin(Double(i))
            return Synthetic.frame(t: Double(i) / 30, shift: Point2(d, -d))
        }
        #expect(!Self.run(frames))
    }
    @Test func zoomedPhotoIsRejected() {
        let frames = (0..<30).map { i -> FaceFrame in
            let s = 0.4 + 0.05 * sin(Double(i) / 3)
            return Synthetic.frame(t: Double(i) / 30, box: Rect(x: 0.3, y: 0.3, width: s, height: s))
        }
        #expect(!Self.run(frames))
    }
    @Test func liveFaceIsAccepted() {
        let frames = (0..<30).map { i in
            Synthetic.frame(t: Double(i) / 30, ear: 0.3 - 0.15 * max(0, sin(Double(i) / 2)), wobble: 0.03 * sin(Double(i) / 3))
        }
        #expect(Self.run(frames))
    }
    @Test func needsMinimumFrames() {
        let frames = (0..<9).map { i in Synthetic.frame(t: Double(i) / 30, wobble: 0.05 * sin(Double(i))) }
        #expect(!Self.run(frames))
    }
}

// MARK: R3 — frame gate

@Suite("Frame gate (R3)")
struct GateTests {
    @Test func zeroFacesDropped() {
        var g = FrameGate()
        #expect(g.check(Synthetic.frame(t: 0, faces: 0)) == .drop)
    }
    @Test func twoFacesReset() {
        var g = FrameGate()
        #expect(g.check(Synthetic.frame(t: 0, faces: 2)) == .resetTrack)
    }
    @Test func lowQualityDropped() {
        var g = FrameGate()
        #expect(g.check(Synthetic.frame(t: 0, quality: 0.29)) == .drop)
        #expect(g.check(Synthetic.frame(t: 0.03, quality: 0.3)) == .valid)
    }
    @Test func jumpBreaksTrack() {
        var g = FrameGate()
        #expect(g.check(Synthetic.frame(t: 0)) == .valid)
        #expect(g.check(Synthetic.frame(t: 0.03, shift: Point2(0.35, 0))) == .resetTrack)
    }
    @Test func gapBreaksTrack() {
        var g = FrameGate()
        #expect(g.check(Synthetic.frame(t: 0)) == .valid)
        #expect(g.check(Synthetic.frame(t: 0.3)) == .valid)
        #expect(g.check(Synthetic.frame(t: 0.61)) == .resetTrack)
    }
    @Test func iouIsCorrect() {
        let a = Rect(x: 0, y: 0, width: 1, height: 1)
        #expect(a.iou(a) == 1)
        #expect(a.iou(Rect(x: 2, y: 2, width: 1, height: 1)) == 0)
        #expect(abs(a.iou(Rect(x: 0.5, y: 0, width: 1, height: 1)) - 1.0 / 3) < 1e-12)
    }
}

// MARK: R4 — alignment

@Suite("Eye alignment (R4)")
struct AlignmentTests {
    @Test func eyesLandOnTemplate() {
        let tpl = AlignmentTemplate.arcface112
        let l = Point2(250, 210), r = Point2(390, 230) // tilted face in a 640×480 frame
        let T = tpl.transform(imageLeftEye: l, imageRightEye: r)!
        #expect(T.apply(l).distance(to: tpl.imageLeftEye) < 1)
        #expect(T.apply(r).distance(to: tpl.imageRightEye) < 1)
        let back = T.inverse!
        #expect(back.apply(tpl.imageLeftEye).distance(to: l) < 1e-6)
    }
    @Test func coincidentEyesRejected() {
        #expect(AlignmentTemplate.arcface112.transform(imageLeftEye: Point2(1, 1), imageRightEye: Point2(1, 1)) == nil)
    }
}

// MARK: R21 — threshold decision

@Suite("Match decision (R21)")
struct MatchTests {
    let base = Synthetic.embedding(seed: 7)

    @Test func samePersonMatches() {
        let e = Synthetic.enrollment(base: base)
        let probe = (0..<3).map { Synthetic.near(base, similarity: 0.85, seed: UInt64(200 + $0)) }
        let s = MatchDecision.scores(probe: probe, enrollment: e)!
        #expect(MatchDecision.isMatch(s, threshold: 0.6))
    }
    @Test func otherPersonDoesNotMatch() {
        let e = Synthetic.enrollment(base: base)
        let other = Synthetic.embedding(seed: 99)
        let probe = (0..<3).map { Synthetic.near(other, similarity: 0.9, seed: UInt64(300 + $0)) }
        let s = MatchDecision.scores(probe: probe, enrollment: e)!
        #expect(!MatchDecision.isMatch(s, threshold: 0.6))
    }
    @Test func thresholdIsInclusiveAndNeedsBothScores() {
        let s = MatchDecision.Scores(meanScore: 0.5, bestIndividualScore: 0.5)
        #expect(MatchDecision.isMatch(s, threshold: 0.5))
        #expect(!MatchDecision.isMatch(s, threshold: 0.5001))
        #expect(!MatchDecision.isMatch(.init(meanScore: 0.7, bestIndividualScore: 0.4), threshold: 0.5))
        #expect(!MatchDecision.isMatch(.init(meanScore: 0.4, bestIndividualScore: 0.7), threshold: 0.5))
    }
    @Test func dimensionMismatchGivesNoScores() {
        let e = Synthetic.enrollment(base: base)
        #expect(MatchDecision.scores(probe: [[1, 2, 3]], enrollment: e) == nil)
    }
}
