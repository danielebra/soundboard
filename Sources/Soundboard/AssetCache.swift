import AVFoundation
import CoreGraphics

/// Decoded sounds and key images, reloaded only when the file on disk changes.
final class AssetCache {
    private var sounds: [String: (modified: Date?, result: Result<AVAudioPCMBuffer, Error>)] = [:]
    private var icons: [String: (modified: Date?, image: CGImage?)] = [:]

    func sound(_ path: String) -> Result<AVAudioPCMBuffer, Error> {
        let url = Paths.resolve(path, in: Paths.sounds)
        let modified = Self.modified(url)
        if let cached = sounds[path], cached.modified == modified { return cached.result }
        let result = Result { try loadSound(url) }
        if case let .failure(error) = result {
            NSLog("Soundboard: can't load sound %@: %@", path, error.localizedDescription)
        }
        sounds[path] = (modified, result)
        return result
    }

    func icon(_ path: String) -> CGImage? {
        let url = Paths.resolve(path, in: Paths.icons)
        let modified = Self.modified(url)
        if let cached = icons[path], cached.modified == modified { return cached.image }
        let image = KeyRenderer.loadImage(url)
        icons[path] = (modified, image)
        return image
    }

    func render(_ face: KeyFace, size: Int, active: Bool) -> CGImage {
        var warning = face.dangling
        if let file = face.soundFile, case .failure = sound(file) { warning = true }
        return KeyRenderer.key(size: size, label: face.label,
                               image: face.image.flatMap { icon($0) },
                               background: face.isEmpty ? CGColor(gray: 0, alpha: 1) : KeyRenderer.color(hex: face.color),
                               active: active, warning: warning)
    }

    func isBroken(_ file: String) -> Bool {
        if case .failure = sound(file) { return true }
        return false
    }

    private static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
