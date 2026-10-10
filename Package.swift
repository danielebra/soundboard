// swift-tools-version:5.10
import PackageDescription

// No dependencies on purpose: everything is Apple frameworks (IOKit, AVFoundation,
// CoreAudio, AppKit), so the whole app is auditable from this repo alone.
let package = Package(
    name: "Soundboard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Soundboard", path: "Sources/Soundboard")
    ]
)
