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
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.30.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.8.1")
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
