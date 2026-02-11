// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RingLauncher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RingLauncher", targets: ["RingLauncher"])
    ],
    targets: [
        .executableTarget(
            name: "RingLauncher",
            path: "RingLauncher"
        )
    ]
)