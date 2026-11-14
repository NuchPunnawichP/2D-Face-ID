import Foundation
import Testing
@testable import FaceAuthCore

private func bundleData(threshold: Double = 0.4, modelID: String = "test", enrollment: Enrollment? = nil) throws -> Data {
    let e = enrollment ?? Synthetic.enrollment(base: Synthetic.embedding(seed: 3))
    return try EnrollmentStore.encoder.encode(StoreBundle(enrollment: e, config: FaceAuthConfig(threshold: threshold, modelID: modelID)))
}

@Suite("Store bundle on a file descriptor (R23, R28)")
struct StoreBundleTests {
    @Test func validBundleDecodes() throws {
        let b = try StoreBundle.decode(try bundleData(), expectedModelID: "test", expectedDimension: 128)
        #expect(b.enrollment.embeddings.count == 5)
        #expect(b.config.threshold == 0.4)
    }

    @Test func realisticSizeFitsTheLimit() throws {
        #expect(try bundleData().count < StoreBundle.maxBytes)
    }

    @Test func oversizeIsRejected() throws {
        var d = try bundleData()
        d.append(Data(repeating: 0x20, count: StoreBundle.maxBytes))
        #expect(throws: (any Error).self) { try StoreBundle.decode(d) }
    }

    @Test func malformedIsRejected() {
        #expect(throws: (any Error).self) { try StoreBundle.decode(Data("{not json".utf8)) }
        #expect(throws: (any Error).self) { try StoreBundle.decode(Data()) }
        #expect(throws: (any Error).self) { try StoreBundle.decode(Data("{\"enrollment\":{}}".utf8)) }
    }

    @Test func outOfRangeSettingsAreRejected() throws {
        #expect(throws: (any Error).self) { try StoreBundle.decode(try bundleData(threshold: -0.9)) }
    }

    @Test func wrongModelOrDimensionIsRejected() throws {
        #expect(throws: (any Error).self) { try StoreBundle.decode(try bundleData(), expectedModelID: "other") }
        #expect(throws: (any Error).self) { try StoreBundle.decode(try bundleData(), expectedDimension: 512) }
        #expect(throws: (any Error).self) { try StoreBundle.decode(try bundleData(modelID: "x"), expectedModelID: "test") }
    }

    @Test func nonUnitEmbeddingsAreRejected() throws {
        var e = Synthetic.enrollment(base: Synthetic.embedding(seed: 3))
        e.embeddings[0] = e.embeddings[0].map { $0 * 3 }
        #expect(throws: (any Error).self) { try StoreBundle.decode(try bundleData(enrollment: e)) }
    }

    @Test func readsFromAPipeUpToTheLimit() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let payload = try bundleData()
        let writer = Thread {
            payload.withUnsafeBytes { buf in _ = write(fds[1], buf.baseAddress!, buf.count) }
            close(fds[1])
        }
        writer.start()
        let got = try StoreBundle.read(fd: fds[0])
        close(fds[0])
        #expect(got == payload)
    }

    @Test func readStopsAfterTheLimit() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        // Like the PAM module: a reader that stops early must not raise SIGPIPE.
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        let writer = Thread {
            let chunk = [UInt8](repeating: 0x41, count: 4096)
            for _ in 0..<40 { _ = write(fds[1], chunk, chunk.count) } // 160 KiB
            close(fds[1])
        }
        writer.start()
        let got = try StoreBundle.read(fd: fds[0])
        close(fds[0])
        #expect(got.count > StoreBundle.maxBytes)
        #expect(got.count <= StoreBundle.maxBytes + 8192)
        #expect(throws: (any Error).self) { try StoreBundle.decode(got) }
    }
}

@Suite("Camera selection (R31)")
struct CameraSelectionTests {
    let builtIn = CameraCandidate(name: "FaceTime HD", isBuiltInWideAngle: true, isBuiltInTransport: true, isContinuity: false)
    let external = CameraCandidate(name: "USB cam", isBuiltInWideAngle: false, isBuiltInTransport: false, isContinuity: false)
    let virtualCam = CameraCandidate(name: "Virtual", isBuiltInWideAngle: true, isBuiltInTransport: false, isContinuity: false)
    let iphone = CameraCandidate(name: "iPhone", isBuiltInWideAngle: true, isBuiltInTransport: false, isContinuity: true)

    @Test func builtInPreferredInBothModes() {
        #expect(CameraSelection.choose([external, iphone, builtIn], builtInOnly: false) == 2)
        #expect(CameraSelection.choose([external, iphone, builtIn], builtInOnly: true) == 2)
    }
    @Test func strictModeHasNoFallback() {
        #expect(CameraSelection.choose([external], builtInOnly: true) == nil)
        #expect(CameraSelection.choose([virtualCam, iphone], builtInOnly: true) == nil)
        #expect(CameraSelection.choose([], builtInOnly: true) == nil)
    }
    @Test func normalModeFallsBackButAvoidsContinuity() {
        #expect(CameraSelection.choose([iphone, external], builtInOnly: false) == 1)
    }
}

@Suite("Helper protocol (R25)")
struct HelperProtocolTests {
    @Test func commandsRoundTrip() throws {
        for c in [HelperCommand.scanning("x"), .enroll(step: 2, of: 5, "y"), .finish(success: true, "z"), .stop] {
            let d = try JSONEncoder().encode(c)
            #expect(try JSONDecoder().decode(HelperCommand.self, from: d) == c)
        }
    }
    @Test func frameSanity() {
        let f = Synthetic.frame(t: 1)
        #expect(HelperFrame(frame: f, embedding: Synthetic.embedding(seed: 1)).isWellFormed(dimension: 128))
        #expect(HelperFrame(frame: f, embedding: nil).isWellFormed(dimension: 128))
        #expect(!HelperFrame(frame: f, embedding: [1, 2, 3]).isWellFormed(dimension: 128))
        #expect(!HelperFrame(frame: f, embedding: Synthetic.embedding(seed: 1).map { $0 * 2 }).isWellFormed(dimension: 128))
        var bad = Synthetic.embedding(seed: 1)
        bad[0] = .nan
        #expect(!HelperFrame(frame: f, embedding: bad).isWellFormed(dimension: 128))
        var inf = f
        inf.time = .infinity
        #expect(!HelperFrame(frame: inf, embedding: nil).isWellFormed(dimension: 128))
    }
}

@Suite("Root store rules (R24, R25, R29)")
struct SystemStoreTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fa-sys-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func layoutAndModes() throws {
        let root = tempRoot()
        let store = try SystemStore.store(forUID: 501, root: root)
        try store.save(Synthetic.enrollment(base: Synthetic.embedding(seed: 2)))
        try store.save(FaceAuthConfig(threshold: 0.4, modelID: "test"))
        func mode(_ p: String) -> Int { var st = stat(); lstat(p, &st); return Int(st.st_mode) & 0o777 }
        #expect(mode(root.path) == 0o700)
        #expect(mode(store.directory.path) == 0o700)
        #expect(mode(store.enrollmentURL.path) == 0o600)
        #expect(mode(store.configURL.path) == 0o600)
        #expect(store.directory.lastPathComponent == "501")
        #expect(store.listFiles() == ["config.json", "enrollment.json"])
    }

    @Test func symlinkedFileIsRefused() throws {
        let root = tempRoot()
        let store = try SystemStore.store(forUID: 501, root: root)
        try store.save(Synthetic.enrollment(base: Synthetic.embedding(seed: 2)))
        let real = store.directory.appendingPathComponent("real.json")
        try FileManager.default.moveItem(at: store.enrollmentURL, to: real)
        try FileManager.default.createSymbolicLink(at: store.enrollmentURL, withDestinationURL: real)
        #expect(throws: (any Error).self) { try store.loadEnrollment() }
    }

    @Test func unenrollRemovesOnlyThatUser() throws {
        let root = tempRoot()
        try SystemStore.store(forUID: 501, root: root).save(Synthetic.enrollment(base: Synthetic.embedding(seed: 2)))
        try SystemStore.store(forUID: 502, root: root).save(Synthetic.enrollment(base: Synthetic.embedding(seed: 3)))
        #expect(try SystemStore.remove(uid: 501, root: root))
        #expect(!FileManager.default.fileExists(atPath: SystemStore.directory(forUID: 501, root: root).path))
        #expect(FileManager.default.fileExists(atPath: SystemStore.directory(forUID: 502, root: root).path))
        #expect(try !SystemStore.remove(uid: 501, root: root))
    }
}
