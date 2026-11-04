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
        // mlx-audio-swift: our fork of Blaizzy/mlx-audio-swift v0.1.8. Fork
        //   additions on top of upstream: TTSModelRegistry (queryable loader
        //   table + companion repositories) and MOSS-TTS-Nano bundled voices,
        //   codebook dial and per-chunk decoding. See Docs/model-support.md.
        // mlx-swift: our fork is upstream 0.33.0 with the mlx C++ submodule
        //   repointed at fil-technology/mlx, which ignores the iOS
        //   background-clamp Metal error on in-flight command buffers
        //   (Metal-in-background crash fix). Tagged 0.33.100: a NORMAL version
        //   so it satisfies every `>= 0.33.0` range in a graph (prerelease tags
        //   would not), with a patch number upstream will never publish so the
        //   tag can no longer collide with an upstream release (0.31.5 did).
        //   Upstream mlx-audio-swift names ml-explore/mlx-swift, so the mirror
        //   in .swiftpm/configuration/mirrors.json (tracked) redirects it; CI
        //   runs Tools/verify-mlx-fork.sh. See Docs/mlx-swift-bg-safe-fork.md.
        .package(url: "https://github.com/fil-technology/mlx-audio-swift.git", exact: "0.1.8-tts.4"),
        .package(url: "https://github.com/fil-technology/mlx-swift.git", exact: "0.33.100"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.12.0")
    ],
    targets: [
        .target(
            name: "TTSMLX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
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
