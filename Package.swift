// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SoftLive",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SoftLive",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "SoftLiveTests",
            dependencies: ["SoftLive"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
