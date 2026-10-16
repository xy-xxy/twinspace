// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TwinSpace",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AppDual", targets: ["AppDual"]),
        .executable(name: "DualProbe", targets: ["DualProbe"])
    ],
    targets: [
        .target(name: "DualCore"),
        .executableTarget(name: "AppDual", dependencies: ["DualCore"]),
        .executableTarget(name: "DualProbe", dependencies: ["DualCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["DualCore"], path: "Tests/DualCoreTests")
    ]
)
