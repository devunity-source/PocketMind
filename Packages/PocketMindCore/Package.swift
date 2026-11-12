// swift-tools-version: 6.0
import PackageDescription

// PocketMindCore holds everything that does not need an Apple-only framework:
// persistence, search, retrieval, prompt building, parsing, file encryption.
// On Apple platforms it has zero third-party dependencies (system SQLite + CryptoKit).
// On Linux (used only to run the unit tests without a Mac) it pulls swift-crypto and
// the distro's libsqlite3.

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var extraTargets: [Target] = []

#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
coreDependencies.append("CSQLite")
extraTargets.append(
    .systemLibrary(
        name: "CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    )
)
#endif

let package = Package(
    name: "PocketMindCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "PocketMindCore", targets: ["PocketMindCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "PocketMindCore", dependencies: coreDependencies),
        .testTarget(name: "PocketMindCoreTests", dependencies: ["PocketMindCore"]),
    ] + extraTargets
)
