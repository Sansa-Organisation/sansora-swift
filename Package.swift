// swift-tools-version:5.9
// Sansora iOS SDK. Zero third-party dependencies.
import PackageDescription

let package = Package(
    name: "SansoraKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SansoraKit", targets: ["SansoraKit"]),
    ],
    targets: [
        .target(name: "SansoraKit", path: "Sources/SansoraKit"),
        .testTarget(name: "SansoraKitTests", dependencies: ["SansoraKit"], path: "Tests/SansoraKitTests"),
        // Replays every shared fixture in ../conformance/fixtures (located via #filePath).
        .testTarget(name: "SansoraConformanceTests", dependencies: ["SansoraKit"], path: "Tests/SansoraConformanceTests"),
    ]
)
