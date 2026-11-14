import Foundation

public enum VerifyOutcome: Equatable, Sendable {
    case pending
    case success
    /// The user turned the wrong way (exit 1).
    case wrongTurn
    /// The deadline passed without success (exit 1).
    case timeout

    public var isFinal: Bool { self != .pending }

    /// Process exit code for this outcome (errors are handled by the caller: 2).
    public var exitCode: Int32 {
        switch self {
        case .success: return 0
        case .pending, .wrongTurn, .timeout: return 1
        }
    }
}

/// Liveness and match progress for the current face track.
public struct VerifyProgress: Equatable, Sendable {
    public var blink = false
    public var turn = false
    public var motion = false
    public var frontalEmbeddings = 0
    public var match = false
    public init() {}
}

/// The decision rule, kept separate and pure so it can be checked exhaustively
/// (Tests/…/VerifyKernelTests and formal/verify_model.py).
public enum VerifyKernel {
    public static let deadlineSeconds = 5.0
    public static let minFrontalEmbeddings = 3

    /// - Parameter elapsed: seconds since t0 (the first camera frame).
    /// Order: deadline first (a frame after the deadline is not evaluated;
    /// exactly at the deadline still counts), then wrong turn, then success.
    public static func decide(elapsed: Double, progress p: VerifyProgress, wrongTurn: Bool) -> VerifyOutcome {
        if elapsed > deadlineSeconds { return .timeout }
        if wrongTurn { return .wrongTurn }
        if p.blink && p.turn && p.motion && p.frontalEmbeddings >= minFrontalEmbeddings && p.match {
            return .success
        }
        return .pending
    }
}

public struct VerifyConfig: Codable, Equatable, Sendable {
    public var gate = FrameGate.Config()
    public var blink = BlinkDetector.Config()
    public var turn = HeadTurnChallenge.Config()
    public var motion = MotionCheck.Config()
    /// |yaw| and |pitch| at or below this count as frontal (degrees).
    public var frontalMaxDegrees: Double = 15
    public init() {}
}

/// One verification attempt. Feed it frames in time order; it never touches
/// the camera, so it runs the same on live frames and recorded fixtures.
public struct VerifySession: Sendable {
    public let config: VerifyConfig
    public let challenge: TurnDirection
    public let enrollment: Enrollment
    public let threshold: Double

    private var gate: FrameGate
    private var blink: BlinkDetector
    private var turn: HeadTurnChallenge
    private var motion: MotionCheck
    private var embeddings: [[Float]] = []
    public private(set) var t0: Double?
    public private(set) var progress = VerifyProgress()
    public private(set) var outcome: VerifyOutcome = .pending
    public private(set) var lastScores: MatchDecision.Scores?
    /// Number of times progress was reset (second face / lost track).
    public private(set) var resets = 0

    public init(challenge: TurnDirection, enrollment: Enrollment, threshold: Double, config: VerifyConfig = VerifyConfig()) {
        self.config = config
        self.challenge = challenge
        self.enrollment = enrollment
        self.threshold = threshold
        gate = FrameGate(config: config.gate)
        blink = BlinkDetector(config: config.blink)
        turn = HeadTurnChallenge(challenge: challenge, config: config.turn)
        motion = MotionCheck(config: config.motion)
    }

    /// Whether the caller should compute an embedding for this frame
    /// (it is a single, good, frontal face). The gate is re-run in `process`.
    public func wantsEmbedding(_ frame: FaceFrame) -> Bool {
        guard frame.faceCount == 1, (frame.quality ?? 0) >= config.gate.minQuality,
              let yaw = frame.yawDegrees, let pitch = frame.pitchDegrees else { return false }
        return abs(yaw) <= config.frontalMaxDegrees && abs(pitch) <= config.frontalMaxDegrees
    }

    private mutating func resetProgress() {
        blink.reset()
        turn.reset()
        motion.reset()
        embeddings.removeAll()
        progress = VerifyProgress()
        lastScores = nil
        resets += 1
    }

    /// Feed one frame. `embedding` is the face embedding when `wantsEmbedding` was true.
    @discardableResult
    public mutating func process(_ frame: FaceFrame, embedding: [Float]? = nil) -> VerifyOutcome {
        guard !outcome.isFinal else { return outcome }
        if t0 == nil { t0 = frame.time }
        let elapsed = frame.time - t0!
        // Frames after the deadline are not evaluated.
        if elapsed > VerifyKernel.deadlineSeconds {
            outcome = .timeout
            return outcome
        }

        var wrongTurn = false
        switch gate.check(frame) {
        case .drop:
            break
        case .resetTrack:
            resetProgress()
        case .valid:
            if let ear = EyeAspectRatio.both(left: frame.leftEye, right: frame.rightEye) {
                progress.blink = blink.add(ear: ear)
            }
            if let yaw = frame.yawDegrees {
                let s = turn.add(yawDegrees: yaw)
                progress.turn = s == .passed
                wrongTurn = s == .wrongDirection
            }
            progress.motion = motion.add(frame)
            if let e = embedding, wantsEmbedding(frame) {
                embeddings.append(e)
                progress.frontalEmbeddings = embeddings.count
                if embeddings.count >= VerifyKernel.minFrontalEmbeddings,
                   let s = MatchDecision.scores(probe: embeddings, enrollment: enrollment) {
                    lastScores = s
                    progress.match = MatchDecision.isMatch(s, threshold: threshold)
                }
            }
        }
        outcome = VerifyKernel.decide(elapsed: elapsed, progress: progress, wrongTurn: wrongTurn)
        return outcome
    }

    /// Call on a timer so the deadline fires even when no frames arrive.
    @discardableResult
    public mutating func tick(now: Double) -> VerifyOutcome {
        guard !outcome.isFinal, let t0 else { return outcome }
        if now - t0 > VerifyKernel.deadlineSeconds { outcome = .timeout }
        return outcome
    }

    public var currentMotionScore: Double? { motion.lastScore }
    public var blinkOpenLevel: Double? { blink.openLevel }
}
