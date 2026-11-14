import Foundation
import Testing
@testable import FaceAuthCore

@Suite("Enrollment store (R6, R12)")
struct StoreTests {
    func tempStore() -> EnrollmentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faceauth-test-\(UUID().uuidString)/faceauth", isDirectory: true)
        return EnrollmentStore(directory: dir)
    }

    func mode(_ path: String) -> Int {
        var st = stat()
        stat(path, &st)
        return Int(st.st_mode) & 0o777
    }

    @Test func roundTripWithStrictPermissions() throws {
        let store = tempStore()
        let e = Synthetic.enrollment(base: Synthetic.embedding(seed: 3))
        try store.save(e)
        #expect(mode(store.directory.path) == 0o700)
        #expect(mode(store.enrollmentURL.path) == 0o600)
        let loaded = try store.loadEnrollment(expectedModelID: "test")
        #expect(loaded.embeddings.count == 5)
        #expect(loaded.mean == e.mean)
        // Only JSON is written, no images or temp files.
        #expect(store.listFiles() == ["enrollment.json"])
    }

    @Test func enrollmentHasFiveEmbeddingsPlusMean() throws {
        let e = Synthetic.enrollment(base: Synthetic.embedding(seed: 4))
        #expect(e.embeddings.count == 5)
        #expect(e.mean.count == e.dimension)
        #expect(abs(Embeddings.cosine(e.mean, Embeddings.normalizedMean(e.embeddings)!)! - 1) < 1e-6)
    }

    @Test func refusesLoosePermissions() throws {
        let store = tempStore()
        try store.save(Synthetic.enrollment(base: Synthetic.embedding(seed: 5)))
        chmod(store.enrollmentURL.path, 0o644)
        #expect(throws: StoreError.insecurePermissions(path: store.enrollmentURL.path, mode: 0o644)) {
            try store.loadEnrollment()
        }
    }

    @Test func refusesLooseDirectory() throws {
        let store = tempStore()
        try store.save(Synthetic.enrollment(base: Synthetic.embedding(seed: 5)))
        chmod(store.directory.path, 0o755)
        #expect(throws: StoreError.insecurePermissions(path: store.directory.path, mode: 0o755)) {
            try store.loadEnrollment()
        }
    }

    @Test func missingEnrollmentAndConfig() {
        let store = tempStore()
        #expect(throws: StoreError.notEnrolled) { try store.loadEnrollment() }
        #expect(throws: StoreError.notCalibrated) { try store.loadConfig() }
    }

    @Test func modelMismatchIsAnError() throws {
        let store = tempStore()
        try store.save(Synthetic.enrollment(base: Synthetic.embedding(seed: 6)))
        #expect(throws: StoreError.modelMismatch(stored: "test", current: "other")) {
            try store.loadEnrollment(expectedModelID: "other")
        }
    }

    @Test func corruptFileIsAnError() throws {
        let store = tempStore()
        try store.ensureDirectory()
        try store.writeSecure(Data("not json".utf8), to: store.enrollmentURL)
        #expect(throws: (any Error).self) { try store.loadEnrollment() }
    }

    @Test func configRoundTrip() throws {
        let store = tempStore()
        try store.save(FaceAuthConfig(threshold: 0.42, modelID: "test"))
        #expect(mode(store.configURL.path) == 0o600)
        #expect(try store.loadConfig().threshold == 0.42)
    }
}

@Suite("Config validation and store hardening (review fixes)")
struct HardeningTests {
    func tempStore() -> EnrollmentStore {
        EnrollmentStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("faceauth-test-\(UUID().uuidString)/faceauth", isDirectory: true))
    }

    @Test func defaultsAreValid() {
        #expect(FaceAuthConfig(threshold: 0.4, modelID: "m").invalidSettings().isEmpty)
    }

    @Test func tamperedLivenessSettingsAreRejected() throws {
        var v = VerifyConfig()
        v.blink.openFactor = 0
        v.blink.closedThreshold = 10
        v.motion.minScore = -1
        v.gate.minQuality = 0
        v.turn.leftYawSign = 0
        let c = FaceAuthConfig(threshold: -0.99, modelID: "m", verify: v)
        let bad = Set(c.invalidSettings())
        #expect(bad.isSuperset(of: ["threshold", "blink.openFactor", "blink.closedThreshold",
                                    "motion.minScore", "gate.minQuality", "turn.leftYawSign"]))
        let store = tempStore()
        try store.save(c)
        #expect(throws: (any Error).self) { try store.loadConfig() }
    }

    @Test func thresholdBounds() {
        #expect(!FaceAuthConfig(threshold: 0.19, modelID: "m").invalidSettings().isEmpty)
        #expect(FaceAuthConfig(threshold: 0.2, modelID: "m").invalidSettings().isEmpty)
        #expect(FaceAuthConfig(threshold: 0.99, modelID: "m").invalidSettings().isEmpty)
        #expect(!FaceAuthConfig(threshold: .nan, modelID: "m").invalidSettings().isEmpty)
    }

    @Test func enrollmentMustHaveExactlyFiveSnaps() throws {
        let store = tempStore()
        let four = Enrollment(modelID: "test", embeddings: (0..<4).map { Synthetic.embedding(seed: UInt64($0)) },
                              poses: ["a", "b", "c", "d"])!
        try store.save(four)
        #expect(throws: (any Error).self) { try store.loadEnrollment() }
    }

    @Test func dimensionMustMatchModel() throws {
        let store = tempStore()
        try store.save(Synthetic.enrollment(base: Synthetic.embedding(seed: 1)))
        #expect(throws: (any Error).self) { try store.loadEnrollment(expectedDimension: 512) }
        #expect(try store.loadEnrollment(expectedDimension: 128).dimension == 128)
    }

    @Test func configNeedsSecureDirectory() throws {
        let store = tempStore()
        try store.save(FaceAuthConfig(threshold: 0.4, modelID: "m"))
        chmod(store.directory.path, 0o755)
        #expect(throws: StoreError.insecurePermissions(path: store.directory.path, mode: 0o755)) {
            try store.loadConfig()
        }
    }
}
