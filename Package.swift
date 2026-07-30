// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OrbitLauncher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OrbitLauncher", targets: ["OrbitLauncher"])
    ],
    targets: [
        .executableTarget(
            name: "OrbitLauncher",
            path: "Sources/OrbitLauncher"
        )
    ]
)
