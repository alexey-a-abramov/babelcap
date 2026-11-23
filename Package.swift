// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Subveil",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Subveil", targets: ["Subveil"])
    ],
    targets: [
        .target(name: "AudioCapture"),
        .target(name: "SonioxClient"),
        .target(name: "Transcript", dependencies: ["SonioxClient"]),
        .target(name: "AppSettings", dependencies: ["SonioxClient"]),
        .target(name: "CaptionsCore", dependencies: ["AudioCapture", "SonioxClient", "Transcript", "AppSettings"]),
        .target(name: "Overlay", dependencies: ["Transcript", "AppSettings", "SonioxClient"]),
        .target(name: "ControlHUD", dependencies: ["CaptionsCore", "AppSettings", "Transcript", "AudioCapture", "SonioxClient"]),
        .executableTarget(
            name: "Subveil",
            dependencies: ["AudioCapture", "SonioxClient", "Transcript", "AppSettings", "CaptionsCore", "Overlay", "ControlHUD"]
        ),
        .testTarget(name: "TranscriptTests", dependencies: ["Transcript", "SonioxClient"]),
        .testTarget(
            name: "SonioxClientTests",
            dependencies: ["SonioxClient", "AudioCapture", "AppSettings", "CaptionsCore", "Transcript"]
        ),
    ]
)
