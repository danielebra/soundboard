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

    func render(_ button: ButtonConfig?, size: Int, active: Bool) -> CGImage {
        var missingSound = false
        if let button, button.action == nil, let path = button.sound, case .failure = sound(path) {
            missingSound = true
        }
        return KeyRenderer.key(size: size, label: button?.label,
                               image: button?.image.flatMap { icon($0) },
                               background: button == nil ? CGColor(gray: 0, alpha: 1) : KeyRenderer.color(hex: button?.color),
                               active: active, warning: missingSound)
    }

    private static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
