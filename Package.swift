// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "faceauth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "faceauth", targets: ["faceauth"]),
    ],
    targets: [
        // Pure logic: no camera, no Vision, no AppKit. Fully unit-tested.
        .target(name: "FaceAuthCore"),
        // Camera, Vision, Core ML and the notch HUD.
        .target(name: "FaceAuthCapture", dependencies: ["FaceAuthCore"]),
        .executableTarget(name: "faceauth", dependencies: ["FaceAuthCore", "FaceAuthCapture"]),
        .testTarget(
            name: "FaceAuthCoreTests",
            dependencies: ["FaceAuthCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
