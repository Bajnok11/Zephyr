// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zephyr",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ZephyrKit"),
        .executableTarget(name: "ZephyrHelper", dependencies: ["ZephyrKit"]),
        .executableTarget(name: "Zephyr", dependencies: ["ZephyrKit"]),
        .testTarget(name: "ZephyrKitTests", dependencies: ["ZephyrKit"]),
    ]
)
