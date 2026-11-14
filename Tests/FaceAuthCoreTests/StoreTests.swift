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
