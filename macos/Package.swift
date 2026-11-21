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
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
    ],
    targets: [
        .target(name: "CanvasCore"),
        .target(
            name: "CanvasUI",
            dependencies: [
                "CanvasCore",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ]
        ),
        .executableTarget(name: "CanvasApp", dependencies: ["CanvasCore", "CanvasUI"]),
        .executableTarget(name: "CanvasChecks", dependencies: ["CanvasCore", "CanvasUI"]),
    ]
)
