// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchOrbit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchOrbit",
            path: "Sources/NotchOrbit"
        )
    ]
)
