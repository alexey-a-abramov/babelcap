// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Babelcap",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Babelcap", targets: ["Babelcap"]),
        .executable(name: "babelcap-bench", targets: ["BabelcapBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.33.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.4.0"),
        .package(url: "https://github.com/microsoft/speech-sdk-spm.git", exact: "1.53.1"),
    ],
    targets: [
        .target(name: "AudioCapture"),
        .target(name: "SonioxClient"),
        .target(name: "Transcript", dependencies: ["SonioxClient"]),
        .target(name: "AppSettings", dependencies: ["SonioxClient"]),
        .target(name: "LocalEngines", dependencies: ["SonioxClient", .product(name: "WhisperKit", package: "WhisperKit")]),
        .target(name: "LocalLLM", dependencies: [
            "SonioxClient", "LocalEngines",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "CloudEngines", dependencies: ["SonioxClient", "LocalEngines"]),
        .target(name: "AzureEngine", dependencies: [
            "SonioxClient",
            .product(name: "MicrosoftCognitiveServicesSpeech-macOS", package: "speech-sdk-spm"),
        ]),
        .target(name: "ModelHub", dependencies: ["SonioxClient", "LocalEngines", "LocalLLM", "CloudEngines", "AzureEngine"]),
        .target(name: "CaptionsCore", dependencies: ["AudioCapture", "SonioxClient", "Transcript", "AppSettings", "ModelHub", "LocalEngines"]),
        .target(name: "SharedUI"),
        .target(name: "Overlay", dependencies: ["Transcript", "AppSettings", "SonioxClient", "SharedUI"]),
        .target(name: "ControlHUD", dependencies: ["CaptionsCore", "AppSettings", "Transcript", "AudioCapture", "SonioxClient", "SharedUI", "ModelHub"]),
        .target(name: "CatalogUI", dependencies: ["AppSettings", "CaptionsCore", "ModelHub", "SonioxClient", "SharedUI", "LocalEngines", "LocalLLM"]),
        .executableTarget(
            name: "Babelcap",
            dependencies: ["AudioCapture", "SonioxClient", "Transcript", "AppSettings", "CaptionsCore", "Overlay", "ControlHUD", "ModelHub", "CatalogUI", "LocalEngines"]
        ),
        .executableTarget(name: "BabelcapBench", dependencies: ["ModelHub", "LocalEngines", "SonioxClient"]),
        .testTarget(name: "TranscriptTests", dependencies: ["Transcript", "SonioxClient"]),
        .testTarget(
            name: "SonioxClientTests",
            dependencies: ["SonioxClient", "AudioCapture", "AppSettings", "CaptionsCore", "Transcript", "ControlHUD", "Overlay", "SharedUI", "ModelHub", "LocalEngines", "CatalogUI", "CloudEngines", "AzureEngine"]
        ),
    ]
)
