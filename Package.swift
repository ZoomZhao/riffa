// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Riffa",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RiffaCore", targets: ["RiffaCore"]),
        .executable(name: "RiffaDesktop", targets: ["RiffaApp"]),
        .executable(name: "riffa", targets: ["RiffaCLI"])
    ],
    targets: [
        .target(
            name: "RiffaCore",
            path: "Sources/RiffaCore"
        ),
        .executableTarget(
            name: "RiffaApp",
            dependencies: ["RiffaCore"],
            path: "Sources/RiffaApp",
            exclude: ["Resources"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "RiffaCLI",
            dependencies: ["RiffaCore"],
            path: "Sources/RiffaCLI"
        ),
        .testTarget(
            name: "RiffaCoreTests",
            dependencies: ["RiffaCore"],
            path: "Tests/RiffaCoreTests"
        ),
        .testTarget(
            name: "RiffaAppTests",
            dependencies: ["RiffaApp"],
            path: "Tests/RiffaAppTests"
        )
    ]
)
