import Foundation

/// The root-owned store `sudo` uses (SPEC rev 4, Q16): /var/db/faceauth/<uid>/,
/// directories 0700 and files 0600, owned by root:wheel.
public enum SystemStore {
    public static let rootDirectory = URL(fileURLWithPath: "/var/db/faceauth", isDirectory: true)

    public static func directory(forUID uid: uid_t, root: URL = rootDirectory) -> URL {
        root.appendingPathComponent(String(uid), isDirectory: true)
    }

    /// An EnrollmentStore for `uid`'s root store. Must be used by root.
    /// Creates /var/db/faceauth (0700) if needed and enforces its mode and owner.
    public static func store(forUID uid: uid_t, root: URL = rootDirectory) throws -> EnrollmentStore {
        let fm = FileManager.default
        var st = stat()
        if lstat(root.path, &st) != 0 {
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } else if (st.st_mode & S_IFMT) != S_IFDIR {
            throw StoreError.corrupt(path: root.path, reason: "is not a directory")
        }
        guard chmod(root.path, 0o700) == 0, chown(root.path, 0, 0) == 0 || getuid() != 0 else {
            throw StoreError.io("Cannot secure \(root.path)")
        }
        var s = EnrollmentStore(directory: directory(forUID: uid, root: root))
        if getuid() == 0 { s.requiredGroup = 0 }
        return s
    }

    /// Removes `uid`'s root store (unenroll --system). Refuses symlinks.
    public static func remove(uid: uid_t, root: URL = rootDirectory) throws -> Bool {
        let dir = directory(forUID: uid, root: root)
        var st = stat()
        guard lstat(dir.path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw StoreError.corrupt(path: dir.path, reason: "is not a directory")
        }
        try FileManager.default.removeItem(at: dir)
        return true
    }
}

/// What the PAM module hands the verifier on a file descriptor (SPEC rev 4, Q19, Q24):
/// `{"enrollment": <enrollment.json>, "config": <config.json>}`.
public struct StoreBundle: Codable, Sendable {
    public static let maxBytes = 64 * 1024

    public var enrollment: Enrollment
    public var config: FaceAuthConfig

    public init(enrollment: Enrollment, config: FaceAuthConfig) {
        self.enrollment = enrollment
        self.config = config
    }

    /// Decodes and validates. Any problem throws (the verifier exits 2).
    public static func decode(_ data: Data, expectedModelID: String? = nil, expectedDimension: Int? = nil) throws -> StoreBundle {
        guard data.count <= maxBytes else {
            throw StoreError.corrupt(path: "store fd", reason: "more than \(maxBytes) bytes")
        }
        let b: StoreBundle
        do {
            b = try EnrollmentStore.decoder.decode(StoreBundle.self, from: data)
        } catch {
            throw StoreError.corrupt(path: "store fd", reason: "malformed: \(error)")
        }
        try b.enrollment.check(source: "store fd", expectedModelID: expectedModelID, expectedDimension: expectedDimension)
        let bad = b.config.invalidSettings()
        if !bad.isEmpty { throw StoreError.invalidSettings(path: "store fd", names: bad) }
        if let expectedModelID, b.config.modelID != expectedModelID {
            throw StoreError.modelMismatch(stored: b.config.modelID, current: expectedModelID)
        }
        return b
    }

    /// Reads at most maxBytes + 1 bytes from `fd` until EOF.
    public static func read(fd: Int32) throws -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while data.count <= maxBytes {
            let n = Foundation.read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw StoreError.io("Cannot read the store from fd \(fd)")
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }
}
