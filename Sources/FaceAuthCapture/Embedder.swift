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

    /// The root-owned model next to a root-owned binary (installed for sudo).
    /// When it exists, it is the only model used and user locations are ignored.
    public static func installedModelURL() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let model = exe.deletingLastPathComponent().appendingPathComponent("../share/faceauth/MobileFaceNet.mlpackage").standardized
        func rootOwned(_ p: String) -> Bool {
            var st = stat()
            return lstat(p, &st) == 0 && st.st_uid == 0 && (st.st_mode & 0o022) == 0
        }
        guard rootOwned(exe.path), rootOwned(model.path),
              rootOwned(model.deletingLastPathComponent().path) else { return nil }
        return model
    }

    /// Where the model is looked for, in order.
    public static func candidateModelURLs() -> [URL] {
        if let installed = installedModelURL() { return [installed] }
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FACEAUTH_MODEL"] { urls.append(URL(fileURLWithPath: env)) }
        urls.append(EnrollmentStore.defaultDirectory.appendingPathComponent("models/MobileFaceNet.mlpackage"))
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        urls.append(exe.deletingLastPathComponent().appendingPathComponent("../share/faceauth/MobileFaceNet.mlpackage").standardized)
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models/MobileFaceNet.mlpackage"))
        return urls
    }

    public static func load() throws -> Embedder {
        guard let url = candidateModelURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CaptureError.model("""
            The face model was not found. Build it with scripts/convert_model.py (see README), \
            or set FACEAUTH_MODEL. Looked in:
            \(candidateModelURLs().map { "  " + $0.path }.joined(separator: "\n"))
            """)
        }
        // The installed (root-owned) model is compiled fresh each run into a private
        // temp dir, so a tampered user cache cannot replace it.
        return try Embedder(packageURL: url, useCache: installedModelURL() == nil)
    }

    /// Output dimension of the embedding (from the model description).
    public var dimension: Int? {
        model.modelDescription.outputDescriptionsByName["embedding"]?
            .multiArrayConstraint?.shape.last.map { $0.intValue }
    }

    public init(packageURL: URL, useCache: Bool = true) throws {
        modelURL = packageURL
        if !useCache {
            do {
                let tmp = try MLModel.compileModel(at: packageURL)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .all
                model = try MLModel(contentsOf: tmp, configuration: cfg)
            } catch {
                throw CaptureError.model("Cannot load the face model at \(packageURL.path): \(error.localizedDescription)")
            }
            let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            modelID = meta?["faceauth.model_id"] ?? packageURL.lastPathComponent
            return
        }
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
