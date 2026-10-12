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
        // mlx-swift: UPSTREAM ml-explore/mlx-swift 0.32.x — no fork. The old
        //   fil-technology/mlx-swift fork (0.31.3 + an iOS background check_error
        //   swallow) and its SwiftPM mirror were REMOVED here: mlx 0.32.x
        //   refactored the Metal command path so command-buffer errors are
        //   stored on the callback thread and thrown on the calling thread
        //   (Swift-catchable), not thrown from the Metal callback thread — so the
        //   iOS background crash the patch fixed is structurally gone upstream.
        //   See esh docs/research/ios-background-safety-mlx-0.32.md. iOS
        //   background safety is PENDING device validation.
        .package(url: "https://github.com/fil-technology/mlx-audio-swift.git", exact: "0.1.10-tts.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", "0.31.6"..<"0.33.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", "0.9.0"..<"2.0.0")
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
