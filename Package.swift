// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stackshot",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything lives in StackshotKit so the tests can import it; the app is a one-line main.
        .target(name: "StackshotKit", path: "Sources/StackshotKit"),
        .executableTarget(name: "Stackshot", dependencies: ["StackshotKit"], path: "Sources/Stackshot"),
        .testTarget(name: "StackshotKitTests", dependencies: ["StackshotKit"], path: "Tests/StackshotKitTests"),
    ]
)
