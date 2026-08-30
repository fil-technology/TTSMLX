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
        // Pinned to exact versions so `swift package resolve` never silently
        // drifts. Bump deliberately, validate, then move the pin.
        //
        // mlx-audio-swift: our fork carries the Mimi/PocketTTS KV-cache reset
        //   patches (broadcast_shapes crash fix on model-instance reuse).
        // mlx-swift: our fork is upstream 0.31.3 with the mlx C++ submodule
        //   repointed at fil-technology/mlx, which swallows iOS
        //   background-permission Metal errors in check_error()
        //   (Metal-in-background crash fix). Tagged 0.31.5 (a normal version,
        //   NOT a prerelease) so it satisfies mlx-swift-lm's 0.31.3..<0.32.0
        //   range; 0.31.5 is above upstream's latest 0.31.4 to mark it as ours.
        //   It is functionally 0.31.3 + the submodule patch, not upstream 0.31.5.
        // Both fixes are unavailable in any upstream tagged release as of
        //   2026-06; see Docs/mlx-swift-bg-safe-fork.md. Re-fork + re-tag when
        //   bumping the upstream base version.
        .package(url: "https://github.com/fil-technology/mlx-audio-swift.git", exact: "0.1.7-tts.1"),
        .package(url: "https://github.com/fil-technology/mlx-swift.git", exact: "0.31.5"),
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
