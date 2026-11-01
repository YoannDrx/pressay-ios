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
    ],
    targets: [
        .target(name: "PressayShared"),
        .target(name: "PressayCore", dependencies: ["PressayShared"]),
        .target(name: "PressayAccount", dependencies: ["PressayShared"]),
        .testTarget(name: "PressaySharedTests", dependencies: ["PressayShared"]),
        .testTarget(name: "PressayCoreTests", dependencies: ["PressayCore"]),
        .testTarget(name: "PressayAccountTests", dependencies: ["PressayAccount"]),
    ]
)
