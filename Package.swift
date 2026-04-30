// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacNoSleep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "mac-nosleep", targets: ["MacNoSleep"]),
        .executable(name: "MacNoSleepBar", targets: ["MacNoSleepMenuBar"])
    ],
    targets: [
        .target(
            name: "MacNoSleepCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MacNoSleep",
            dependencies: ["MacNoSleepCore"]
        ),
        .executableTarget(
            name: "MacNoSleepMenuBar",
            dependencies: ["MacNoSleepCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
    ]
)
