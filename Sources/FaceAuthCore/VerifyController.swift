import Foundation

/// What the user is told during verification (shown as text and in the HUD).
public enum Prompt: Equatable, Sendable {
    case lookAtCamera
    case challenge(TurnDirection)
    case success
    case failure(String)

    public var text: String {
        switch self {
        case .lookAtCamera: return "Look at the camera"
        case .challenge(let d): return "Blink, then turn your head \(d.rawValue)"
        case .success: return "Face matched"
        case .failure(let why): return why
        }
    }
}

/// Drives a `VerifySession` and emits prompts. Prompt delivery is
/// best-effort: an error from the prompt sink (e.g. the HUD could not draw)
/// is counted and ignored, so it can never change the verdict (R16).
public struct VerifyController {
    public private(set) var session: VerifySession
    private let prompt: (Prompt) throws -> Void
    public private(set) var promptFailures = 0
    public private(set) var prompts: [Prompt] = []
    private var started = false

    public init(session: VerifySession, prompt: @escaping (Prompt) throws -> Void) {
        self.session = session
        self.prompt = prompt
    }

    private mutating func emit(_ p: Prompt) {
        prompts.append(p)
        do { try prompt(p) } catch { promptFailures += 1 }
    }

    public mutating func start() {
        guard !started else { return }
        started = true
        emit(.lookAtCamera)
        emit(.challenge(session.challenge))
    }

    private mutating func finishIfFinal(_ o: VerifyOutcome) -> VerifyOutcome {
        switch o {
        case .pending: break
        case .success: emit(.success)
        case .wrongTurn: emit(.failure("Wrong direction"))
        case .timeout: emit(.failure("Not recognized"))
        }
        return o
    }

    @discardableResult
    public mutating func handle(frame: FaceFrame, embedding: [Float]?) -> VerifyOutcome {
        start()
        guard !session.outcome.isFinal else { return session.outcome }
        return finishIfFinal(session.process(frame, embedding: embedding))
    }

    @discardableResult
    public mutating func handle(tick now: Double) -> VerifyOutcome {
        guard !session.outcome.isFinal else { return session.outcome }
        return finishIfFinal(session.tick(now: now))
    }
}
