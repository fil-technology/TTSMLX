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
        //   range. It is functionally 0.31.3 + the submodule patch.
        //   CAUTION: upstream has since published its OWN 0.31.5 (eb889e01,
        //   the very drift commit WITHOUT the patch) and 0.31.6, so the tag
        //   name no longer distinguishes the fork. The `mlx-swift` identity is
        //   also named by mlx-swift-lm/mlx-audio-swift as upstream, so the
        //   ONLY thing keeping resolution on the fork is the SwiftPM mirror in
        //   .swiftpm/configuration/mirrors.json (tracked in git) plus
        //   Tools/verify-mlx-fork.sh in CI. Durable fix: re-tag the fork at a
        //   version upstream will never publish and move this pin.
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
