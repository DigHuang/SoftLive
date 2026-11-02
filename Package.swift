// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftLive",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "SoftLive"),
        .testTarget(name: "SoftLiveTests", dependencies: ["SoftLive"]),
    ]
)
