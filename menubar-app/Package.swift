// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VaultDaemon",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VaultDaemon",
            path: "Sources"
        )
    ]
)
