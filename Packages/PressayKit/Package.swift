// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PressayKit",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        // The keyboard extension links only this product: it must stay small and engine-free.
        .library(name: "PressayShared", targets: ["PressayShared"]),
        .library(name: "PressayCore", targets: ["PressayCore"]),
        // Account, Pro rights, encrypted sync, dictionary and AI modes. The app alone links it.
        .library(name: "PressayAccount", targets: ["PressayAccount"]),
        // End-to-end encrypted sync with the Mac. Not linked by any shipped target: its HChaCha20
        // is encryption outside the OS, which needs an App Store export compliance key first.
        // See "Encrypted sync" in the README.
        .library(name: "PressaySync", targets: ["PressaySync"]),
    ],
    targets: [
        .target(name: "PressayShared"),
        .target(name: "PressayCore", dependencies: ["PressayShared"]),
        .target(name: "PressayAccount", dependencies: ["PressayShared"]),
        .target(name: "PressaySync", dependencies: ["PressayAccount", "PressayShared"]),
        .testTarget(name: "PressaySharedTests", dependencies: ["PressayShared"]),
        .testTarget(name: "PressayCoreTests", dependencies: ["PressayCore"]),
        .testTarget(name: "PressayAccountTests", dependencies: ["PressayAccount"]),
        .testTarget(name: "PressaySyncTests", dependencies: ["PressaySync", "PressayAccount"]),
    ]
)
