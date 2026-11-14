import Foundation
import Testing
@testable import FaceAuthCore

/// A scripted live attempt: baseline, blink, frontal frames, then the turn.
func liveScript(challenge: TurnDirection, start: Double = 100, fps: Double = 30,
                        turnSign: Double = 1, ears: [Double]? = nil) -> [FaceFrame] {
    let earSeq = ears ?? ([0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.1, 0.08, 0.3] + Array(repeating: 0.3, count: 10))
    var frames: [FaceFrame] = []
    var t = start
    for (i, e) in earSeq.enumerated() {
        frames.append(Synthetic.frame(t: t, ear: e, wobble: 0.01 * sin(Double(i))))
        t += 1 / fps
    }
    let target = (challenge == .left ? 25.0 : -25.0) * turnSign
    for k in 1...12 {
        let yaw = target * min(1, Double(k) / 6)
        frames.append(Synthetic.frame(t: t, yaw: yaw, wobble: 0.02 * sin(Double(k))))
        t += 1 / fps
    }
    return frames
}

private struct Harness {
    var session: VerifySession
    let base: [Float]
    var probeSimilarity = 0.85
    var probeBase: [Float]? = nil

    init(challenge: TurnDirection, threshold: Double = 0.6) {
        base = Synthetic.embedding(seed: 7)
        session = VerifySession(challenge: challenge, enrollment: Synthetic.enrollment(base: base), threshold: threshold)
    }

    mutating func run(_ frames: [FaceFrame]) -> VerifyOutcome {
        var out = VerifyOutcome.pending
        for (i, f) in frames.enumerated() {
            let emb = session.wantsEmbedding(f)
                ? Synthetic.near(probeBase ?? base, similarity: probeSimilarity, seed: UInt64(500 + i)) : nil
            out = session.process(f, embedding: emb)
            if out.isFinal { break }
        }
        return out
    }
}

@Suite("Verify session (R10, R11, R12)")
struct VerifySessionTests {
    @Test(arguments: [TurnDirection.left, .right])
    func liveOwnerSucceeds(challenge: TurnDirection) {
        var h = Harness(challenge: challenge)
        #expect(h.run(liveScript(challenge: challenge)) == .success)
        #expect(VerifyOutcome.success.exitCode == 0)
    }

    @Test func wrongPersonTimesOut() {
        var h = Harness(challenge: .left)
        h.probeBase = Synthetic.embedding(seed: 12345)
        var frames = liveScript(challenge: .left)
        // Keep feeding frontal frames until past the deadline.
        let last = frames.last!.time
        frames += (1...200).map { Synthetic.frame(t: last + Double($0) / 30, wobble: 0.01) }
        #expect(h.run(frames) == .timeout)
        #expect(VerifyOutcome.timeout.exitCode == 1)
    }

    @Test func noBlinkNeverSucceeds() {
        var h = Harness(challenge: .left)
        let frames = liveScript(challenge: .left, ears: Array(repeating: 0.3, count: 19))
        let out = h.run(frames)
        #expect(out == .pending)
        #expect(h.session.progress.turn && !h.session.progress.blink)
    }

    @Test func wrongTurnFails() {
        var h = Harness(challenge: .left)
        #expect(h.run(liveScript(challenge: .right)) == .wrongTurn)
        #expect(VerifyOutcome.wrongTurn.exitCode == 1)
    }

    @Test func staticPhotoNeverSucceeds() {
        // Perfectly static landmarks, even with a matching embedding and fake yaw.
        var h = Harness(challenge: .left)
        var frames = (0..<20).map { Synthetic.frame(t: 100 + Double($0) / 30) }
        frames += (0..<10).map { Synthetic.frame(t: 101 + Double($0) / 30, yaw: 25) }
        #expect(h.run(frames) == .pending)
        #expect(!h.session.progress.motion)
        #expect(!h.session.progress.blink)
    }

    @Test func secondFaceResetsProgress() {
        var h = Harness(challenge: .left)
        var frames = liveScript(challenge: .left)
        // Insert a two-face frame just before the turn completes.
        frames.insert(Synthetic.frame(t: frames[25].time - 0.001, faces: 2), at: 25)
        let out = h.run(frames)
        #expect(out == .pending)
        #expect(h.session.resets == 1)
        #expect(!h.session.progress.blink)
    }

    @Test func deadlineIsInclusiveAtFiveSeconds() {
        var s = Harness(challenge: .left).session
        s.process(Synthetic.frame(t: 10))
        #expect(s.process(Synthetic.frame(t: 15.0)) == .pending)
        #expect(s.process(Synthetic.frame(t: 15.0001)) == .timeout)
    }

    @Test func frameAfterDeadlineIsNotEvaluated() {
        // A complete live attempt that only finishes after 5 s must fail.
        var h = Harness(challenge: .left)
        let slow = liveScript(challenge: .left, fps: 5) // 31 frames at 5 fps = 6.2 s
        #expect(h.run(slow) == .timeout)
    }

    @Test func tickFiresDeadlineWithoutFrames() {
        var s = Harness(challenge: .left).session
        #expect(s.tick(now: 1000) == .pending) // not started
        s.process(Synthetic.frame(t: 10))
        #expect(s.tick(now: 14.9) == .pending)
        #expect(s.tick(now: 15.1) == .timeout)
        // Final outcomes are sticky.
        #expect(s.process(Synthetic.frame(t: 15.2)) == .timeout)
    }

    @Test func needsThreeFrontalEmbeddings() {
        var p = VerifyProgress()
        p.blink = true; p.turn = true; p.motion = true; p.match = true
        p.frontalEmbeddings = 2
        #expect(VerifyKernel.decide(elapsed: 1, progress: p, wrongTurn: false) == .pending)
        p.frontalEmbeddings = 3
        #expect(VerifyKernel.decide(elapsed: 1, progress: p, wrongTurn: false) == .success)
    }
}

/// R10/R11 on the implementation's decision kernel: every combination of
/// progress flags × wrong turn × elapsed time on a 0.1 s grid (0…6 s, plus
/// the boundary values) is checked exhaustively.
@Suite("Verify kernel exhaustive (R10, R11)")
struct VerifyKernelTests {
    @Test func exhaustive() {
        var times = (0...60).map { Double($0) / 10 }
        times += [5.0, 5.0000001, 4.9999999]
        var checked = 0, successes = 0, timeouts = 0, wrongs = 0
        for bits in 0..<(1 << 5) {
            for emb in 0...4 {
                var p = VerifyProgress()
                p.blink = bits & 1 != 0
                p.turn = bits & 2 != 0
                p.motion = bits & 4 != 0
                p.match = bits & 8 != 0
                let wrong = bits & 16 != 0
                p.frontalEmbeddings = emb
                for t in times {
                    let o = VerifyKernel.decide(elapsed: t, progress: p, wrongTurn: wrong)
                    checked += 1
                    // R10: success only with every condition, within the deadline.
                    if o == .success {
                        successes += 1
                        #expect(p.blink && p.turn && p.motion && p.match && emb >= 3 && !wrong && t <= 5.0)
                    }
                    // R11: past the deadline the outcome is always final (timeout).
                    if t > 5.0 { #expect(o == .timeout); timeouts += 1 }
                    if o == .wrongTurn { wrongs += 1; #expect(wrong && t <= 5.0) }
                    if o == .pending { #expect(t <= 5.0) }
                }
            }
        }
        // Reachability: every outcome actually occurs (no vacuous pass).
        #expect(successes > 0 && timeouts > 0 && wrongs > 0)
        #expect(checked == 32 * 5 * 64)
    }
}

// MARK: R16 — prompts (HUD) can never change the verdict

private struct HUDBroken: Error {}

@Suite("Verify controller (R16)")
struct VerifyControllerTests {
    /// Runs the same scripted attempt with a working and a throwing prompt sink.
    func outcomes(challenge: TurnDirection, script: [FaceFrame], probe: [Float]? = nil) -> (VerifyOutcome, VerifyOutcome, Int) {
        let base = Synthetic.embedding(seed: 7)
        func make(_ sink: @escaping (Prompt) throws -> Void) -> VerifyController {
            VerifyController(session: VerifySession(challenge: challenge, enrollment: Synthetic.enrollment(base: base), threshold: 0.6),
                             prompt: sink)
        }
        func run(_ c: inout VerifyController) -> VerifyOutcome {
            var o = VerifyOutcome.pending
            for (i, f) in script.enumerated() {
                let e = c.session.wantsEmbedding(f) ? Synthetic.near(probe ?? base, similarity: 0.85, seed: UInt64(500 + i)) : nil
                o = c.handle(frame: f, embedding: e)
            }
            if !o.isFinal { o = c.handle(tick: script.last!.time + 10) }
            return o
        }
        var ok = make { _ in }
        var broken = make { _ in throw HUDBroken() }
        let a = run(&ok), b = run(&broken)
        return (a, b, broken.promptFailures)
    }

    @Test func successUnchangedWhenHUDThrows() {
        let (a, b, failures) = outcomes(challenge: .left, script: liveScriptForTests(.left))
        #expect(a == .success && b == .success)
        #expect(failures == 3) // look, challenge, result
    }

    @Test func failureUnchangedWhenHUDThrows() {
        let (a, b, _) = outcomes(challenge: .left, script: liveScriptForTests(.right))
        #expect(a == .wrongTurn && b == .wrongTurn)
        let (c, d, _) = outcomes(challenge: .left, script: liveScriptForTests(.left), probe: Synthetic.embedding(seed: 999))
        #expect(c == .timeout && d == .timeout)
    }

    @Test func promptsInOrder() {
        let base = Synthetic.embedding(seed: 7)
        var c = VerifyController(session: VerifySession(challenge: .right, enrollment: Synthetic.enrollment(base: base), threshold: 0.6), prompt: { _ in })
        c.start()
        c.handle(tick: 0)
        #expect(c.prompts == [.lookAtCamera, .challenge(.right)])
    }
}

func liveScriptForTests(_ c: TurnDirection) -> [FaceFrame] { liveScript(challenge: c) }
