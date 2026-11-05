// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElixirCanvasNative",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CanvasCore", targets: ["CanvasCore"]),
        .executable(name: "CanvasApp", targets: ["CanvasApp"]),
        .executable(name: "CanvasChecks", targets: ["CanvasChecks"]),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasCore"]),
        .executableTarget(name: "CanvasChecks", dependencies: ["CanvasCore"]),
    ]
)
