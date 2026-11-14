import AppKit
import FaceAuthCapture
import FaceAuthCore
import Foundation

/// Exit codes (SPEC contract).
enum Exit {
    static let match: Int32 = 0
    static let noMatch: Int32 = 1
    static let error: Int32 = 2
}

/// An error that ends the program with exit 2 and a message.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func say(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

struct Options {
    var command = "help"
    var positional: [String] = []
    var noHUD = false
    var verbose = false
    var label: String?
    var seconds: Double?
    var threshold: Double?

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var it = args.makeIterator()
        var first = true
        while let a = it.next() {
            switch a {
            case "--no-hud": o.noHUD = true
            case "--verbose", "-v": o.verbose = true
            case "--label":
                guard let v = it.next() else { throw Failure("--label needs a value") }
                o.label = v
            case "--seconds":
                guard let v = it.next(), let d = Double(v), d > 0, d <= 60 else { throw Failure("--seconds needs a number (0-60]") }
                o.seconds = d
            case "--threshold":
                guard let v = it.next(), let d = Double(v), d > -1, d < 1 else { throw Failure("--threshold needs a number in (-1, 1)") }
                o.threshold = d
            case "-h", "--help": o.command = "help"; first = false
            default:
                if a.hasPrefix("-") { throw Failure("Unknown option \(a)") }
                if first { o.command = a; first = false } else { o.positional.append(a) }
            }
        }
        return o
    }
}

let usage = """
usage: faceauth <command> [options]

commands:
  enroll                 Capture 5 snaps of your face and save the embeddings
  verify                 Check your face with liveness. Exit 0 match, 1 no match, 2 error
  calibrate              Measure live vs. photo scores and choose the threshold
  record-landmarks FILE  Record a landmark-only test fixture (--label L, --seconds N)
  hud-demo               Show the notch HUD going through its states
  hud-snapshots DIR      Render each HUD state to PNG files in DIR
  self-test              Load the face model and time one embedding (no camera)

options:
  --no-hud               Text prompts only
  --verbose, -v          Print timings and scores
  --threshold X          (calibrate) save X without asking
"""

/// Sends prompts to stderr and, when available, to the notch HUD.
/// HUD calls are dispatched to the main thread and never throw into the caller.
final class UI: @unchecked Sendable {
    let hud: NotchHUD?
    let verbose: Bool
    let start = HostClock.now()

    init(hud: NotchHUD?, verbose: Bool) {
        self.hud = hud
        self.verbose = verbose
    }

    func log(_ s: String) {
        if verbose { say(String(format: "[+%.3fs] ", HostClock.now() - start) + s) }
    }

    func show(_ state: HUDState) {
        say(state.text)
        guard let hud else { return }
        DispatchQueue.main.async {
            if hud.isShown { hud.update(state) } else {
                hud.show(state)
                self.log(String(format: "hud expanded %.3f s after process start", secondsSinceProcessStart()))
            }
        }
    }

    /// Shows the final state, waits for the HUD to collapse, then returns.
    func finish(_ state: HUDState) async {
        say(state.text)
        guard let hud else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                hud.finish(state) { c.resume() }
            }
        }
    }
}

/// Camera frames analysed by Vision, one at a time.
final class FramePipeline: @unchecked Sendable {
    let camera = Camera()
    let analyzer = FaceAnalyzer()
    private var iterator: AsyncStream<CameraFrame>.AsyncIterator?

    func start() async throws {
        try await Camera.ensurePermission()
        iterator = try camera.start().makeAsyncIterator()
    }

    /// The next analysed frame, or nil if the camera was stopped by us.
    /// Throws if the camera failed or the stream ended on its own.
    func next() async throws -> (CameraFrame, FaceAnalyzer.Result)? {
        guard let cf = await iterator?.next() else {
            if camera.endedUnexpectedly {
                throw CaptureError.cannotConfigure(camera.failure ?? "the camera stopped delivering frames")
            }
            return nil
        }
        return (cf, try analyzer.analyze(cf))
    }

    /// Waits for the first frame, failing after `timeout` seconds (Q7: 3 s).
    func first(timeout: Double) async throws -> (CameraFrame, FaceAnalyzer.Result) {
        try await withThrowingTaskGroup(of: (CameraFrame, FaceAnalyzer.Result)?.self) { g in
            g.addTask { try await self.next() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            defer { g.cancelAll() }
            guard let r = try await g.next(), let value = r else {
                throw CaptureError.noFrames(seconds: timeout)
            }
            return value
        }
    }

    func stop() { camera.stop() }
}

/// The embedding for a frame. Nil only when the eyes were not found; a Core ML
/// failure throws (→ exit 2), it is never silently treated as "no match".
func embedding(_ embedder: Embedder, _ cf: CameraFrame, _ r: FaceAnalyzer.Result) throws -> [Float]? {
    guard let l = r.imageLeftEyePx, let rr = r.imageRightEyePx else { return nil }
    return try embedder.embed(cf, imageLeftEye: l, imageRightEye: rr)
}

/// Seconds since this process started (from the kernel's start time).
func secondsSinceProcessStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    let st = info.kp_proc.p_un.__p_starttime
    let start = Double(st.tv_sec) + Double(st.tv_usec) / 1e6
    return Date().timeIntervalSince1970 - start
}

func isTTY() -> Bool { isatty(STDIN_FILENO) == 1 }

func waitForReturn(_ message: String) async {
    if isTTY() {
        say(message + " Press Return when ready.")
        _ = readLine()
    } else {
        say(message + " Starting in 3 s.")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
}

extension Array where Element == Double {
    var stats: (min: Double, median: Double, max: Double)? {
        guard !isEmpty else { return nil }
        let s = sorted()
        return (s.first!, s[s.count / 2], s.last!)
    }
}
