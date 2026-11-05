// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElixirCanvasNative",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CanvasCore", targets: ["CanvasCore"]),
        .library(name: "CanvasUI", targets: ["CanvasUI"]),
        .executable(name: "CanvasApp", targets: ["CanvasApp"]),
        .executable(name: "CanvasChecks", targets: ["CanvasChecks"]),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .target(name: "CanvasUI", dependencies: ["CanvasCore"]),
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasCore", "CanvasUI"]),
        .executableTarget(name: "CanvasChecks", dependencies: ["CanvasCore", "CanvasUI"]),
    ]
)
