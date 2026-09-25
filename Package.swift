// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stackling",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything lives in StacklingKit so the tests can import it; the app is a one-line main.
        .target(name: "StacklingKit", path: "Sources/StacklingKit"),
        .executableTarget(name: "Stackling", dependencies: ["StacklingKit"], path: "Sources/Stackling"),
        .testTarget(name: "StacklingKitTests", dependencies: ["StacklingKit"], path: "Tests/StacklingKitTests"),
    ]
)
