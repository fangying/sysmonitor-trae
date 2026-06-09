// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sysmonitor",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "SysMonitorCore", targets: ["SysMonitorCore"]),
        .executable(name: "sysmonitor", targets: ["sysmonitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SysMonitorCore"
        ),
        .executableTarget(
            name: "sysmonitor",
            dependencies: [
                "SysMonitorCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "sysmonitor-tests",
            dependencies: [
                "SysMonitorCore"
            ],
            path: "Tests/sysmonitor-tests",
            sources: ["main.swift"]
        ),
    ]
)
