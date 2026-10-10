// swift-tools-version:6.0
import PackageDescription

// No dependencies on purpose: everything is Apple frameworks (IOKit, AVFoundation,
// CoreAudio, AppKit), so the whole app is auditable from this repo alone.
let package = Package(
    name: "Soundboard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Soundboard", path: "Sources/Soundboard")
    ],
    swiftLanguageModes: [.v5]
)
