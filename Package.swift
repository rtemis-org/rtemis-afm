// swift-tools-version: 6.2
//
// Package manifest for rtemis-afm.
//
// Swift Package Manager reads this file to learn what to build. There is no
// Xcode project: `swift build`, `swift test` and `swift run` are the whole
// workflow, which keeps the project buildable in CI with nothing but a
// toolchain.
//
// Three targets:
//   - `RtemisAFM`   — a library holding everything that can be unit-tested:
//                     the OpenAI wire types, the converters to and from the
//                     FoundationModels framework, and the HTTP server.
//   - `rtemis-afm`  — the command-line executable. It is deliberately thin:
//                     argument parsing, then a call into the library.
//   - `afm-spike`   — a compatibility probe (milestone M0). It exercises the
//                     FoundationModels behaviors the bridge relies on and
//                     prints what it finds. Re-run it after every macOS or
//                     Xcode update; see `Sources/afm-spike/README.md`.
//
// Compatibility note (September 2026): built and verified with Xcode 27.0 /
// Swift 6.4 on macOS 27.0. The macOS 26 floor is kept per the spec, but
// several APIs used here (token usage, `toolCallingMode`,
// `transcriptErrorHandlingPolicy`, `LanguageModelError`) are macOS 27 only
// and are guarded with `#available(macOS 27, *)` in the code.

import PackageDescription

let package = Package(
    name: "rtemis-afm",
    // The on-device model exists only on Apple silicon Macs running macOS 26
    // or later, so nothing below that is a meaningful target.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "rtemis-afm", targets: ["rtemis-afm"]),
        .library(name: "RtemisAFM", targets: ["RtemisAFM"]),
    ],
    dependencies: [
        // HTTP server. Hummingbird 2 is built on SwiftNIO, uses async/await
        // throughout, and can stream a response body — which is what
        // Server-Sent Events need. Version pins are "from", so any 2.x that
        // keeps the API works; check the changelog on major bumps.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        // Command-line parsing (`--port`, `--verbose`, subcommands).
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // Structured logging; Hummingbird already depends on it.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    ],
    targets: [
        .target(
            name: "RtemisAFM",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "rtemis-afm",
            dependencies: [
                "RtemisAFM",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "afm-spike",
            dependencies: ["RtemisAFM"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "RtemisAFMTests",
            dependencies: [
                "RtemisAFM",
                // In-process HTTP client for exercising the router.
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
