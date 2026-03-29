// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryManager",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Shared"),
        .executableTarget(
            name: "BatteryManager",
            dependencies: ["Shared"],
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
    ]
)
