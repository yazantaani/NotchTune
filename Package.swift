// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchTune",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchTune",
            path: "Sources/NotchTune",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
