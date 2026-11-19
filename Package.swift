// swift-tools-version: 6.2
// Tools 6.2+ is required to opt out of FluidAudio's package traits.
import PackageDescription

let package = Package(
    name: "NanoWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // ASR only: disable the default `TTS`, `Diarizer` and `NemoTextProcessing` traits
        // (text-to-speech, speaker diarization, NeMo text normalization) — none are used here.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: []),
        // WhisperKit now ships from the Argmax Open-Source SDK repository (formerly argmaxinc/WhisperKit).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "NanoWhisper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/NanoWhisper"
        ),
        .testTarget(
            name: "NanoWhisperTests",
            dependencies: ["NanoWhisper"]
        ),
    ]
)
