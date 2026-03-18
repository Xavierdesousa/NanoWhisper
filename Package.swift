// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NanoWhisper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NanoWhisper",
            path: "Sources/NanoWhisper"
        )
    ]
)
