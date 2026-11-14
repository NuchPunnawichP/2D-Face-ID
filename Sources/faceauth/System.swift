import FaceAuthCapture
import FaceAuthCore
import Foundation

// MARK: - Root side: `sudo faceauth enroll|calibrate|unenroll --system` (SPEC rev 4)

struct SystemContext {
    let uid: uid_t
    let gid: gid_t
    let user: String
    let home: String
}

/// The invoking user, for a command run through sudo. Exit 2 otherwise (R25).
func systemContext() throws -> SystemContext {
    guard geteuid() == 0, getuid() == 0 else {
        throw Failure("--system must be run with sudo, e.g.: sudo /usr/local/libexec/faceauth enroll --system")
    }
    guard let s = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = uid_t(s), uid != 0 else {
        throw Failure("--system needs SUDO_UID: run it with sudo from your own account, not as root.")
    }
    guard let pw = getpwuid(uid) else { throw Failure("Unknown user id \(uid).") }
    return SystemContext(uid: uid, gid: pw.pointee.pw_gid,
                         user: String(cString: pw.pointee.pw_name), home: String(cString: pw.pointee.pw_dir))
}

/// The root-owned installed binary and model are required for --system, so
/// the helper and the model it uses cannot be swapped by the user.
func requireInstalled() throws -> URL {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath(),
          Embedder.installedModelURL() != nil else {
        throw Failure("--system must use the installed copy: sudo /usr/local/libexec/faceauth … --system (see README, Milestone 2).")
    }
    return exe
}

/// Frames streamed by a capture helper running as the user (Q21).
final class RemoteSource: FrameSource, @unchecked Sendable {
    private let process = Process()
    private let toHelper = Pipe()
    private let fromHelper = Pipe()
    private let dimension: Int
    private let lock = NSLock()
    private var stopping = false
    private var continuation: AsyncThrowingStream<HelperFrame, Error>.Continuation?
    private var iterator: AsyncThrowingStream<HelperFrame, Error>.AsyncIterator?

    init(executable: URL, ctx: SystemContext, dimension: Int, hud: Bool) {
        self.dimension = dimension
        process.executableURL = executable
        process.arguments = ["capture-helper", "--uid", String(ctx.uid)] + (hud ? [] : ["--no-hud"])
        process.environment = ["HOME": ctx.home, "USER": ctx.user, "LOGNAME": ctx.user,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
    }

    func start() async throws {
        signal(SIGPIPE, SIG_IGN) // a dead helper gives EPIPE, not a crash
        // Keep only the newest frames: stale ones are discarded anyway (bounded memory).
        let stream = AsyncThrowingStream<HelperFrame, Error>(bufferingPolicy: .bufferingNewest(32)) { c in
            lock.withLock { continuation = c }
        }
        iterator = stream.makeAsyncIterator()
        do { try process.run() } catch { throw Failure("Cannot start the capture helper: \(error.localizedDescription)") }
        let w = toHelper.fileHandleForWriting.fileDescriptor
        _ = fcntl(w, F_SETNOSIGPIPE, 1)
        _ = fcntl(w, F_SETFL, fcntl(w, F_GETFL) | O_NONBLOCK) // a stuck helper cannot block root
        let fd = fromHelper.fileHandleForReading.fileDescriptor
        let dim = dimension
        Thread.detachNewThread { [self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            let decoder = JSONDecoder()
            func fail(_ m: String) { lock.withLock { continuation?.finish(throwing: Failure(m)); continuation = nil } }
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if lock.withLock({ stopping }) { continue } // drain and discard
                    guard let hf = try? decoder.decode(HelperFrame.self, from: line), hf.isWellFormed(dimension: dim) else {
                        fail("The capture helper sent malformed data.")
                        return
                    }
                    lock.withLock { _ = continuation?.yield(hf) }
                }
                if buffer.count > HelperFrame.maxLineBytes {
                    fail("The capture helper sent an oversized message.")
                    return
                }
            }
            lock.withLock {
                if stopping { continuation?.finish() } else {
                    continuation?.finish(throwing: Failure("The capture helper stopped (camera error or no camera permission)."))
                }
                continuation = nil
            }
        }
    }

    private func wrap(_ hf: HelperFrame) -> SourceFrame {
        SourceFrame(frame: hf.frame) { hf.embedding }
    }

    private func nextRaw() async throws -> SourceFrame? {
        guard var it = iterator else { return nil }
        defer { iterator = it }
        return try await it.next().map(wrap)
    }

    func next() async throws -> SourceFrame? {
        if lock.withLock({ stopping }) { return nil }
        return try await withTimeout(Self.frameGapSeconds) { try await self.nextRaw() }
    }

    /// The helper also has to start, load the model and open the camera, so
    /// it gets a longer limit than the local 3 s.
    static let helperStartSeconds = 10.0
    /// After the first frame, no frame for this long means the helper is stuck.
    static let frameGapSeconds = 3.0

    func first(timeout: Double) async throws -> SourceFrame {
        try await withTimeout(max(timeout, Self.helperStartSeconds)) { try await self.nextRaw() }
    }

    private func withTimeout(_ seconds: Double, _ body: @escaping @Sendable () async throws -> SourceFrame?) async throws -> SourceFrame {
        try await withThrowingTaskGroup(of: SourceFrame?.self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                return nil
            }
            defer { g.cancelAll() }
            guard let r = try await g.next(), let value = r else {
                throw CaptureError.noFrames(seconds: seconds)
            }
            return value
        }
    }

    /// Stop using frames (the helper keeps its HUD until `shutdown`).
    func stop() { lock.withLock { stopping = true } }

    func send(_ c: HelperCommand) {
        guard var d = try? JSONEncoder().encode(c) else { return }
        d.append(0x0A)
        d.withUnsafeBytes { b in _ = write(toHelper.fileHandleForWriting.fileDescriptor, b.baseAddress!, b.count) }
    }

    /// Tells the helper to stop and waits up to 3 s for it to exit.
    func shutdown() {
        stop()
        send(.stop)
        try? toHelper.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }

    /// Asks the helper to show the result and waits for it to exit (HUD collapsed).
    func finishAndWait(success: Bool, _ text: String) {
        stop()
        send(.finish(success: success, text))
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
    }
}

/// Prompts for a root command: text on root's terminal, HUD in the helper.
final class RemotePrompter: Prompter, @unchecked Sendable {
    let source: RemoteSource
    let verbose: Bool
    init(source: RemoteSource, verbose: Bool) {
        self.source = source
        self.verbose = verbose
    }
    func log(_ s: String) { if verbose { say(s) } }
    func show(_ state: HUDState) {
        say(state.text)
        switch state {
        case .scanning(let t): source.send(.scanning(t))
        case .enroll(let s, let n, let t): source.send(.enroll(step: s, of: n, t))
        case .success(let t): source.send(.finish(success: true, t))
        case .failure(let t): source.send(.finish(success: false, t))
        }
    }
    func finish(_ state: HUDState) async {
        say(state.text)
        if case .success(let t) = state { source.finishAndWait(success: true, t) }
        else { source.finishAndWait(success: false, state.text) }
    }
}

func runSystem(command: String, opts: Options) async throws -> Int32 {
    let ctx = try systemContext()
    if command == "unenroll" {
        let removed = try SystemStore.remove(uid: ctx.uid)
        say(removed ? "Removed the sudo enrollment for \(ctx.user) (\(SystemStore.directory(forUID: ctx.uid).path))."
                    : "There was no sudo enrollment for \(ctx.user).")
        return Exit.match
    }
    let exe = try requireInstalled()
    let embedder = try Embedder.loadInstalled()
    guard let dim = embedder.dimension else { throw Failure("The face model has no embedding output.") }
    let store = try SystemStore.store(forUID: ctx.uid)
    func secureRootOwned(_ path: String) { _ = chown(path, 0, 0) }

    switch command {
    case "enroll":
        let source = RemoteSource(executable: exe, ctx: ctx, dimension: dim, hud: !opts.noHUD)
        defer { source.shutdown() }
        let ui = RemotePrompter(source: source, verbose: opts.verbose)
        say("Enrolling \(ctx.user) for sudo. Only the built-in camera is used.")
        return try await runEnroll(ui: ui, source: source, modelID: embedder.modelID) { e in
            try store.save(e)
            secureRootOwned(store.directory.path)
            secureRootOwned(store.enrollmentURL.path)
            return store.enrollmentURL.path
        }
    case "calibrate":
        let enrollment = try store.loadEnrollment(expectedModelID: embedder.modelID, expectedDimension: dim)
        let source = RemoteSource(executable: exe, ctx: ctx, dimension: dim, hud: false)
        defer { source.shutdown() }
        say("Calibrating \(ctx.user)'s sudo enrollment.")
        return try await runCalibrate(source: source, enrollment: enrollment,
                                      previous: (try? store.loadConfig())?.verify, modelID: embedder.modelID,
                                      fixedThreshold: opts.threshold) { c in
            try store.save(c)
            secureRootOwned(store.configURL.path)
            return store.configURL.path
        }
    default:
        throw Failure("--system works with enroll, calibrate and unenroll.")
    }
}

// MARK: - Helper side: `faceauth capture-helper --uid N` (started by root)

/// Drops root privileges to `uid` before anything else runs (no threads yet).
/// Called from the top of main.swift. Exits 2 on failure.
func dropPrivilegesForHelper(_ args: [String]) {
    guard geteuid() == 0 else { return }
    guard let i = args.firstIndex(of: "--uid"), i + 1 < args.count,
          let uid = uid_t(args[i + 1]), uid != 0, let pw = getpwuid(uid) else {
        say("capture-helper: --uid USER_ID is required when started as root")
        exit(Exit.error)
    }
    let gid = pw.pointee.pw_gid
    guard initgroups(pw.pointee.pw_name, Int32(bitPattern: gid)) == 0, setgid(gid) == 0, setuid(uid) == 0,
          setuid(0) != 0, geteuid() == uid else {
        say("capture-helper: could not drop privileges")
        exit(Exit.error)
    }
}

/// Streams analysed frames (with embeddings) as JSON lines on stdout and shows
/// the HUD commands it receives on stdin. Only the built-in camera is used.
func runCaptureHelper(ui: UI) async throws -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    let embedder = try Embedder.loadInstalled() // never a user-writable model
    let pipe = FramePipeline(builtInOnly: true) // R31

    // Commands from root.
    Thread.detachNewThread {
        let decoder = JSONDecoder()
        while let line = readLine(strippingNewline: true) {
            guard let cmd = try? decoder.decode(HelperCommand.self, from: Data(line.utf8)) else { continue }
            switch cmd {
            case .scanning(let t): ui.show(.scanning(t))
            case .enroll(let s, let n, let t): ui.show(.enroll(step: s, of: n, t))
            case .finish(let ok, let t):
                // Show the result and let the HUD collapse before exiting; the
                // frame loop keeps running (root discards its output) until then.
                let sem = DispatchSemaphore(value: 0)
                Task { await ui.finish(ok ? .success(t) : .failure(t)); sem.signal() }
                sem.wait()
                pipe.stop()
                exit(Exit.match)
            case .stop:
                pipe.stop()
                exit(Exit.match)
            }
        }
        pipe.stop()
        exit(Exit.match) // root closed the pipe
    }

    try await pipe.start()
    let out = FileHandle.standardOutput.fileDescriptor
    let encoder = JSONEncoder()
    while let (cf, r) = try await pipe.next() {
        let e = r.frame.faceCount == 1 ? try embedding(embedder, cf, r) : nil
        guard var d = try? encoder.encode(HelperFrame(frame: r.frame, embedding: e)) else { continue }
        d.append(0x0A)
        let ok = d.withUnsafeBytes { b -> Bool in
            var off = 0
            while off < b.count {
                let n = write(out, b.baseAddress! + off, b.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !ok { break } // root went away
    }
    return Exit.match
}
