// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Studio",
            path: "Sources/Studio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
