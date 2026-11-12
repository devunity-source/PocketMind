// swift-tools-version: 6.0
import PackageDescription

// Thin Swift wrappers around the official prebuilt XCFrameworks of whisper.cpp and
// llama.cpp. Both are pinned to an exact release build and verified by SwiftPM against
// the SHA-256 below (the same digest GitHub publishes for the release asset).
//
// The two wrappers are separate targets on purpose: each framework ships its own copy
// of the ggml headers, and keeping them in different Swift modules avoids importing
// both sets of declarations into one compilation unit.

let package = Package(
    name: "LocalAI",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "LocalAI", targets: ["WhisperBridge", "LlamaBridge"])
    ],
    dependencies: [
        .package(path: "../PocketMindCore")
    ],
    targets: [
        // whisper.cpp v1.9.5 (release build b5454)
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        // llama.cpp release build b12317
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12317/llama-b12317-xcframework.zip",
            checksum: "db87353dcfed41f2bd6474dd146fbd26ef0630d2f48c4e07a4b269f4646f7ec0"
        ),
        .target(
            name: "WhisperBridge",
            dependencies: ["whisper", .product(name: "PocketMindCore", package: "PocketMindCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "LlamaBridge",
            dependencies: ["llama", .product(name: "PocketMindCore", package: "PocketMindCore")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
