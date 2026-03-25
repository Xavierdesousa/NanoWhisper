// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NanoWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "NanoWhisper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/NanoWhisper"
        ),
        .testTarget(
            name: "NanoWhisperTests",
            dependencies: ["NanoWhisper"]
        ),
    ]
)
