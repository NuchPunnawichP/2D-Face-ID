// swift-tools-version:5.9
import Foundation
import PackageDescription

// Embed Info.plist (camera usage text) in the CLI binary.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

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
        .executableTarget(
            name: "faceauth",
            dependencies: ["FaceAuthCore", "FaceAuthCapture"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "\(root)/Sources/faceauth/Info.plist",
            ])]
        ),
        .testTarget(
            name: "FaceAuthCoreTests",
            dependencies: ["FaceAuthCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
