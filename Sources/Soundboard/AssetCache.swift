import Accelerate
import AVFoundation
import CoreGraphics

/// Decoded sounds and key images, reloaded only when the file on disk changes.
final class AssetCache {
    private var sounds: [String: (modified: Date?, result: Result<AVAudioPCMBuffer, Error>)] = [:]
    private var icons: [String: (modified: Date?, image: CGImage?)] = [:]
    private var waveforms: [String: (sound: AVAudioPCMBuffer, columns: Int, peaks: [Float])] = [:]

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

    /// The loudest sample in each of `columns` slices of the sound, scaled so the loudest slice is 1.
    func waveform(_ path: String, columns: Int) -> [Float]? {
        guard columns > 0, case let .success(sound) = sound(path) else { return nil }
        if let cached = waveforms[path], cached.sound === sound, cached.columns == columns { return cached.peaks }
        let peaks = Self.peaks(sound, columns: columns)
        waveforms[path] = (sound, columns, peaks)
        return peaks
    }

    private static func peaks(_ sound: AVAudioPCMBuffer, columns: Int) -> [Float] {
        guard let channels = sound.floatChannelData else { return [] }
        let frames = Int(sound.frameLength)
        var peaks = [Float](repeating: 0, count: columns)
        for column in 0..<columns {
            let start = frames * column / columns
            let count = frames * (column + 1) / columns - start
            guard count > 0 else { continue }
            for c in 0..<Int(sound.format.channelCount) {
                var peak: Float = 0
                vDSP_maxmgv(channels[c] + start, 1, &peak, vDSP_Length(count))
                peaks[column] = max(peaks[column], peak)
            }
        }
        if let loudest = peaks.max(), loudest > 0 {
            peaks = peaks.map { $0 / loudest }
        }
        return peaks
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
