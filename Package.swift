// swift-tools-version:6.0
import PackageDescription

// No dependencies on purpose: everything is Apple frameworks (IOKit, AVFoundation,
// CoreAudio, AppKit), so the whole app is auditable from this repo alone.
let package = Package(
    name: "Soundboard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Soundboard", path: "Sources/Soundboard"),
        // The only networked piece: runs yt-dlp when you fetch a YouTube clip.
        .executableTarget(name: "SoundboardFetch", path: "Sources/SoundboardFetch"),
        .testTarget(name: "SoundboardTests", dependencies: ["Soundboard", "SoundboardFetch"],
                    path: "Tests/SoundboardTests"),
    ],
    swiftLanguageModes: [.v5]
)
