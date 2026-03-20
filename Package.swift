// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NanoWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "NanoWhisper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/NanoWhisper"
        )
    ]
)
