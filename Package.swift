// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stackshot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Stackshot", path: "Sources/Stackshot")
    ]
)
