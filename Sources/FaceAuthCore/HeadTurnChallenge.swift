import Foundation

public enum TurnDirection: String, Codable, CaseIterable, Sendable {
    case left, right

    public var opposite: TurnDirection { self == .left ? .right : .left }

    /// Chosen per attempt from the system's cryptographically secure generator.
    public static func random() -> TurnDirection {
        var rng = SystemRandomNumberGenerator()
        return Bool.random(using: &rng) ? .left : .right
    }
}

/// Checks a "turn your head left/right" challenge from Vision yaw.
public struct HeadTurnChallenge: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        /// |yaw| at or beyond this counts as turned.
        public var yawThresholdDegrees: Double = 20
        /// Consecutive valid frames the turn must be held.
        public var holdFrames: Int = 3
        /// +1 if the user turning their head to *their* left gives positive
        /// Vision yaw, -1 otherwise. Measured by `faceauth calibrate`.
        public var leftYawSign: Double = 1
        public init() {}
    }

    public enum Status: Equatable, Sendable { case pending, passed, wrongDirection }

    public let config: Config
    public let challenge: TurnDirection
    private var correctRun = 0
    private var wrongRun = 0
    public private(set) var status: Status = .pending

    public init(challenge: TurnDirection, config: Config = Config()) {
        self.challenge = challenge
        self.config = config
    }

    public mutating func reset() {
        self = HeadTurnChallenge(challenge: challenge, config: config)
    }

    /// Which way, if any, this yaw counts as turned.
    public func direction(forYaw yaw: Double) -> TurnDirection? {
        let signed = yaw * config.leftYawSign
        if signed >= config.yawThresholdDegrees { return .left }
        if signed <= -config.yawThresholdDegrees { return .right }
        return nil
    }

    /// Feed the yaw (degrees) of one valid frame.
    @discardableResult
    public mutating func add(yawDegrees yaw: Double) -> Status {
        guard status == .pending else { return status }
        switch direction(forYaw: yaw) {
        case challenge?:
            correctRun += 1
            wrongRun = 0
        case challenge.opposite?:
            wrongRun += 1
            correctRun = 0
        default:
            correctRun = 0
            wrongRun = 0
        }
        if correctRun >= config.holdFrames { status = .passed }
        else if wrongRun >= config.holdFrames { status = .wrongDirection }
        return status
    }
}
