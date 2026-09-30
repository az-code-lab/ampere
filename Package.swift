// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ampere",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "Shared"),
        .executableTarget(
            name: "Ampere",
            dependencies: ["Shared"],
            path: "Sources/Ampere",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "SMCWriter",
            dependencies: ["Shared"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "AmpereTests",
            dependencies: ["Ampere", "Shared"],
            path: "Tests/AmpereTests"
        ),
    ]
)
