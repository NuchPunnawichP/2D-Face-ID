import CoreImage
import CoreML
import CoreVideo
import FaceAuthCore
import Foundation

/// Aligns a face with the eye landmarks and runs the Core ML embedding model.
public final class Embedder: @unchecked Sendable {
    public let modelID: String
    public let modelURL: URL
    private let model: MLModel
    private let template = AlignmentTemplate.arcface112
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var cropBuffer: CVPixelBuffer?

    /// The running executable, symlinks resolved.
    static var executableURL: URL? { Bundle.main.executableURL?.resolvingSymlinksInPath() }

    /// True if `path` and every directory above it are owned by root, not
    /// writable by group or others, and not symlinks.
    static func rootChainOK(_ path: String) -> Bool {
        var p = path
        while true {
            var st = stat()
            guard lstat(p, &st) == 0, st.st_uid == 0, (st.st_mode & 0o022) == 0,
                  (st.st_mode & S_IFMT) != S_IFLNK else { return false }
            if p == "/" { return true }
            p = (p as NSString).deletingLastPathComponent
            if p.isEmpty { return false }
        }
    }

    /// True if every file and directory inside `dir` is root-owned and not writable by others.
    static func rootTreeOK(_ dir: String) -> Bool {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return false }
        for case let rel as String in e {
            var st = stat()
            let p = (dir as NSString).appendingPathComponent(rel)
            guard lstat(p, &st) == 0, st.st_uid == 0, (st.st_mode & 0o022) == 0,
                  (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        }
        return true
    }

    /// The installed .mlpackage (input to `install-model`), next to the installed binary.
    static func installedPackageURL() -> URL? {
        executableURL.map {
            $0.deletingLastPathComponent().appendingPathComponent("../share/faceauth/MobileFaceNet.mlpackage").standardized
        }
    }

    /// The installed, already-compiled model for sudo: root-owned all the way
    /// down and up (binary, model, and every parent directory). Processes that
    /// run as the user load it directly, with no compile step and no user cache.
    public static func installedModelURL() -> URL? {
        guard let exe = executableURL, let pkg = installedPackageURL() else { return nil }
        let compiled = pkg.deletingPathExtension().appendingPathExtension("mlmodelc")
        guard rootChainOK(exe.path), rootChainOK(compiled.path), rootTreeOK(compiled.path) else { return nil }
        return compiled
    }

    /// Where the model is looked for, in order (development use).
    public static func candidateModelURLs() -> [URL] {
        if let installed = installedModelURL() { return [installed] }
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FACEAUTH_MODEL"] { urls.append(URL(fileURLWithPath: env)) }
        urls.append(EnrollmentStore.defaultDirectory.appendingPathComponent("models/MobileFaceNet.mlpackage"))
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/MobileFaceNet.mlpackage"))
        return urls
    }

    /// The installed model if there is one, otherwise the first development location.
    public static func load() throws -> Embedder {
        if let installed = installedModelURL() { return try Embedder(compiledURL: installed) }
        guard let url = candidateModelURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CaptureError.model("""
            The face model was not found. Build it with scripts/convert_model.py (see README), \
            or set FACEAUTH_MODEL. Looked in:
            \(candidateModelURLs().map { "  " + $0.path }.joined(separator: "\n"))
            """)
        }
        return try Embedder(packageURL: url)
    }

    /// Only the installed, root-owned compiled model (sudo verifier, capture
    /// helper, --system). Never a user location (SPEC rev 4).
    public static func loadInstalled() throws -> Embedder {
        guard let url = installedModelURL() else {
            throw CaptureError.model("""
            The installed face model is missing or not root-owned \
            (expected /usr/local/share/faceauth/MobileFaceNet.mlmodelc next to a root-owned \
            /usr/local/libexec/faceauth, with root-owned parent directories). Re-run pam/install.sh.
            """)
        }
        return try Embedder(compiledURL: url)
    }

    /// `faceauth install-model` (run as root by install.sh): compiles the
    /// installed .mlpackage into a root-owned .mlmodelc next to it.
    public static func compileInstalledModel() throws -> URL {
        guard geteuid() == 0 else { throw CaptureError.model("install-model must run as root (install.sh does this).") }
        guard let exe = executableURL, rootChainOK(exe.path), let pkg = installedPackageURL(),
              rootChainOK(pkg.path), rootTreeOK(pkg.path) else {
            throw CaptureError.model("The installed binary and model package must be root-owned (run pam/install.sh).")
        }
        let target = pkg.deletingPathExtension().appendingPathExtension("mlmodelc")
        let tmp = try MLModel.compileModel(at: pkg) // root's private temp dir
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    /// Loads an already-compiled model without writing anything.
    public init(compiledURL: URL) throws {
        modelURL = compiledURL
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            model = try MLModel(contentsOf: compiledURL, configuration: cfg)
        } catch {
            throw CaptureError.model("Cannot load the face model at \(compiledURL.path): \(error.localizedDescription)")
        }
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        modelID = meta?["faceauth.model_id"] ?? compiledURL.lastPathComponent
    }

    /// Output dimension of the embedding (from the model description).
    public var dimension: Int? {
        model.modelDescription.outputDescriptionsByName["embedding"]?
            .multiArrayConstraint?.shape.last.map { $0.intValue }
    }

    /// Development use: compiles once and caches in the user's Caches folder.
    public init(packageURL: URL) throws {
        modelURL = packageURL
        // Compile once and cache in the user's Caches folder (no Xcode needed).
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("faceauth", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let compiled = cacheDir.appendingPathComponent(packageURL.deletingPathExtension().lastPathComponent + ".mlmodelc")
        let pkgDate = (try? packageURL.appendingPathComponent("Manifest.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let compiledDate = (try? compiled.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        do {
            if !FileManager.default.fileExists(atPath: compiled.path) || compiledDate < pkgDate {
                let tmp = try MLModel.compileModel(at: packageURL)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: tmp, to: compiled)
            }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            model = try MLModel(contentsOf: compiled, configuration: cfg)
        } catch {
            throw CaptureError.model("Cannot load the face model at \(packageURL.path): \(error.localizedDescription)")
        }
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        modelID = meta?["faceauth.model_id"] ?? packageURL.lastPathComponent
    }

    /// The aligned 112×112 crop (bottom-left origin coordinates, like Core Image).
    func alignedCrop(_ frame: CameraFrame, imageLeftEye l: Point2, imageRightEye r: Point2) -> CVPixelBuffer? {
        let s = Double(template.size)
        // Template is top-left origin; Core Image is bottom-left.
        let dl = Point2(template.imageLeftEye.x, s - template.imageLeftEye.y)
        let dr = Point2(template.imageRightEye.x, s - template.imageRightEye.y)
        guard let T = SimilarityTransform.mapping(l, r, to: dl, dr) else { return nil }
        let affine = CGAffineTransform(a: T.a, b: T.b, c: -T.b, d: T.a, tx: T.tx, ty: T.ty)
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
            .clampedToExtent()
            .transformed(by: affine)
            .cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
        if cropBuffer == nil {
            CVPixelBufferCreate(nil, template.size, template.size, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &cropBuffer)
        }
        guard let out = cropBuffer else { return nil }
        ciContext.render(image, to: out)
        return out
    }

    /// The L2-normalized embedding of the face in `frame`.
    public func embed(_ frame: CameraFrame, imageLeftEye l: Point2, imageRightEye r: Point2) throws -> [Float] {
        guard let crop = alignedCrop(frame, imageLeftEye: l, imageRightEye: r) else {
            throw CaptureError.model("Face alignment failed")
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: crop)])
        let out = try model.prediction(from: input)
        guard let arr = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw CaptureError.model("The model returned no embedding")
        }
        var v = [Float](repeating: 0, count: arr.count)
        for i in 0..<arr.count { v[i] = arr[i].floatValue }
        guard let n = Embeddings.normalized(v) else { throw CaptureError.model("Zero embedding") }
        return n
    }
}
