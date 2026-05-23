// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TTSMLX",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TTSMLX",
            targets: ["TTSMLX"]
        )
    ],
    dependencies: [
        // Local-path during fork development. See Docs/mlx-audio-fork.md.
        .package(path: "../mlx-audio-swift"),
        // Pinned to exact versions so `swift package resolve` never silently
        // drifts. Bump deliberately, validate, then move the pin.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.8.1")
    ],
    targets: [
        .target(
            name: "TTSMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface")
            ],
            path: "Source",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
            ]
        ),
        .testTarget(
            name: "TTSMLXTests",
            dependencies: ["TTSMLX"],
            path: "Tests"
        )
    ]
)
