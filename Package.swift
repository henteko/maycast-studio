// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MaycastStudio",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "maycast", targets: ["MaycastCLI"]),
        .executable(name: "MaycastTranscribeService", targets: ["MaycastTranscribeService"]),
        .executable(name: "MaycastSliceService", targets: ["MaycastSliceService"]),
        .executable(name: "MaycastPolishService", targets: ["MaycastPolishService"]),
        .executable(name: "MaycastMixService", targets: ["MaycastMixService"]),
        .library(name: "MaycastCore", targets: ["MaycastCore"]),
        .library(name: "MaycastIPC", targets: ["MaycastIPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MaycastCore"
        ),
        .target(
            name: "MaycastIPC",
            dependencies: ["MaycastCore"]
        ),
        .executableTarget(
            name: "MaycastCLI",
            dependencies: [
                "MaycastCore",
                "MaycastIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MaycastTranscribeService",
            dependencies: ["MaycastCore", "MaycastIPC"]
        ),
        .executableTarget(
            name: "MaycastSliceService",
            dependencies: ["MaycastCore", "MaycastIPC"]
        ),
        .executableTarget(
            name: "MaycastPolishService",
            dependencies: ["MaycastCore", "MaycastIPC"]
        ),
        .executableTarget(
            name: "MaycastMixService",
            dependencies: ["MaycastCore", "MaycastIPC"]
        ),
        .testTarget(
            name: "MaycastCoreTests",
            dependencies: ["MaycastCore"]
        ),
        .testTarget(
            name: "MaycastE2ETests",
            dependencies: ["MaycastCore"]
        ),
    ]
)
