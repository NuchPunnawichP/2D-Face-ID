import Foundation

/// What `enroll` saves. Embeddings only, never images.
public struct Enrollment: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var modelID: String
    public var dimension: Int
    /// L2-normalized embeddings, one per enrollment snap.
    public var embeddings: [[Float]]
    /// L2-normalized mean of `embeddings`.
    public var mean: [Float]
    public var poses: [String]
    public var created: Date

    public init?(modelID: String, embeddings: [[Float]], poses: [String], created: Date = Date()) {
        guard let dim = embeddings.first?.count,
              let normalized = Optional(embeddings.compactMap(Embeddings.normalized)),
              normalized.count == embeddings.count,
              let mean = Embeddings.normalizedMean(normalized) else { return nil }
        self.formatVersion = Self.formatVersion
        self.modelID = modelID
        self.dimension = dim
        self.embeddings = normalized
        self.mean = mean
        self.poses = poses
        self.created = created
    }
}

/// Calibration results and tunables saved by `calibrate`.
public struct FaceAuthConfig: Codable, Equatable, Sendable {
    public var threshold: Double
    public var calibrated: Date
    public var modelID: String
    public var verify: VerifyConfig

    public init(threshold: Double, calibrated: Date = Date(), modelID: String, verify: VerifyConfig = VerifyConfig()) {
        self.threshold = threshold
        self.calibrated = calibrated
        self.modelID = modelID
        self.verify = verify
    }
}

public enum StoreError: Error, CustomStringConvertible, Equatable {
    case notEnrolled
    case notCalibrated
    case insecurePermissions(path: String, mode: Int)
    case wrongOwner(path: String)
    case corrupt(path: String, reason: String)
    case modelMismatch(stored: String, current: String)
    case io(String)

    public var description: String {
        switch self {
        case .notEnrolled:
            return "No face is enrolled. Run: faceauth enroll"
        case .notCalibrated:
            return "No threshold is set. Run: faceauth calibrate"
        case .insecurePermissions(let p, let m):
            return "\(p) has mode \(String(m, radix: 8)); it must be 600 (files) or 700 (directory). Fix with: chmod \(p.hasSuffix(".json") ? "600" : "700") \"\(p)\""
        case .wrongOwner(let p):
            return "\(p) is not owned by the current user. Remove it and enroll again."
        case .corrupt(let p, let r):
            return "\(p) could not be read (\(r)). Remove it and run: faceauth enroll"
        case .modelMismatch(let s, let c):
            return "The enrollment was made with model \(s) but the current model is \(c). Run: faceauth enroll"
        case .io(let m):
            return m
        }
    }
}

/// Reads and writes `enrollment.json` and `config.json` with strict permissions.
public struct EnrollmentStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `FACEAUTH_STORE_DIR` overrides the location (used by tests). The
    /// ownership and permission checks apply wherever the store is.
    public static var defaultDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["FACEAUTH_STORE_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/faceauth", isDirectory: true)
    }

    public var enrollmentURL: URL { directory.appendingPathComponent("enrollment.json") }
    public var configURL: URL { directory.appendingPathComponent("config.json") }

    public var hasEnrollment: Bool { FileManager.default.fileExists(atPath: enrollmentURL.path) }

    // MARK: Writing

    public func ensureDirectory() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw StoreError.io("Cannot create \(directory.path): \(error.localizedDescription)")
            }
        }
        // Always enforce 0700, even if it existed already.
        if chmod(directory.path, 0o700) != 0 {
            throw StoreError.io("Cannot set permissions on \(directory.path)")
        }
    }

    /// Writes atomically: a temp file created with 0600 is renamed into place,
    /// so the data is never readable by others, even briefly.
    func writeSecure(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StoreError.io("Cannot create \(tmp.path)") }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw StoreError.io("Cannot write \(url.path)")
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func save(_ enrollment: Enrollment) throws {
        try writeSecure(try Self.encoder.encode(enrollment), to: enrollmentURL)
    }

    public func save(_ config: FaceAuthConfig) throws {
        try writeSecure(try Self.encoder.encode(config), to: configURL)
    }

    // MARK: Reading

    /// Checks that `path` is owned by us and its mode is exactly `mode`.
    func checkSecure(_ path: String, mode: Int) throws {
        var st = stat()
        guard stat(path, &st) == 0 else { throw StoreError.io("Cannot stat \(path)") }
        if st.st_uid != getuid() { throw StoreError.wrongOwner(path: path) }
        let m = Int(st.st_mode) & 0o777
        if m != mode { throw StoreError.insecurePermissions(path: path, mode: m) }
    }

    public func loadEnrollment(expectedModelID: String? = nil) throws -> Enrollment {
        guard hasEnrollment else { throw StoreError.notEnrolled }
        try checkSecure(directory.path, mode: 0o700)
        try checkSecure(enrollmentURL.path, mode: 0o600)
        let e: Enrollment
        do {
            e = try Self.decoder.decode(Enrollment.self, from: Data(contentsOf: enrollmentURL))
        } catch {
            throw StoreError.corrupt(path: enrollmentURL.path, reason: "\(error)")
        }
        guard e.formatVersion == Enrollment.formatVersion,
              !e.embeddings.isEmpty, e.mean.count == e.dimension,
              e.embeddings.allSatisfy({ $0.count == e.dimension }) else {
            throw StoreError.corrupt(path: enrollmentURL.path, reason: "wrong format or dimension")
        }
        if let expectedModelID, e.modelID != expectedModelID {
            throw StoreError.modelMismatch(stored: e.modelID, current: expectedModelID)
        }
        return e
    }

    public func loadConfig() throws -> FaceAuthConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else { throw StoreError.notCalibrated }
        try checkSecure(configURL.path, mode: 0o600)
        do {
            return try Self.decoder.decode(FaceAuthConfig.self, from: Data(contentsOf: configURL))
        } catch {
            throw StoreError.corrupt(path: configURL.path, reason: "\(error)")
        }
    }

    /// Lists every file in the store directory (used to prove no images are written).
    public func listFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }
}
