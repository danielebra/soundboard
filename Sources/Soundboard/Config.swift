import Foundation

/// A sound in the library. Keys point at these by `id`, so a sound keeps its settings
/// when it's taken off the pad or moved.
struct SoundEntry: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// File inside `sounds/`, or an absolute / `~/` path.
    var file: String
    /// Text drawn on the key.
    var label: String?
    /// Image inside `icons/` (png, jpg, webp, gif), or an absolute / `~/` path.
    var image: String?
    /// Background colour as `#RRGGBB`, used when there is no image.
    var color: String?
    /// 0.0 – 1.0, multiplied with `soundVolume`.
    var volume: Float?
    var mode: ButtonConfig.Mode?
}

/// One key on the pad: a library sound, or a Stop / Bleep key.
struct ButtonConfig: Codable, Equatable {
    enum Action: String, Codable {
        /// Stops every sound that is playing.
        case stop
        /// While held: mutes your mic and sends a bleep instead.
        case censor
    }

    enum Mode: String, Codable {
        /// Tap to start, tap again to stop (default).
        case toggle
        /// Every tap plays another copy on top of whatever is playing.
        case overlay
    }

    /// Library sound id (in version 1 configs: the sound file itself).
    var sound: String?
    var action: Action?
    /// Key cap for Stop / Bleep keys. Sound keys take theirs from the library.
    var label: String?
    var image: String?
    var color: String?

    /// Version 1 only — moved into the library by `Config.upgrade`.
    var name: String?
    var volume: Float?
    var mode: Mode?

    init(sound: String? = nil, action: Action? = nil, label: String? = nil, image: String? = nil, color: String? = nil) {
        self.sound = sound
        self.action = action
        self.label = label
        self.image = image
        self.color = color
    }
}

/// How a key looks, resolved through the library.
struct KeyFace {
    var label: String?
    var image: String?
    var color: String?
    var isEmpty = false
    /// The sound file this key plays, if any (checked for load errors).
    var soundFile: String?
    /// Points at a sound that's no longer in the library.
    var dangling = false
}

struct Config: Codable, Equatable {
    var version = 2
    /// Virtual device Zoom listens to. Sounds + your mic are mixed into it.
    var outputDevice = "BlackHole 2ch"
    /// Your real microphone. `nil` uses the macOS default input.
    var micDevice: String?
    var micPassthrough = true
    var micVolume: Float = 1.0
    /// Where *you* hear the sounds. `nil` uses the macOS default output.
    var monitorDevice: String?
    var monitor = true
    var monitorVolume: Float = 0.5
    var soundVolume: Float = 0.8
    /// Starting a toggle sound stops other toggle sounds (overlays keep playing).
    var stopOthers = true
    var brightness = 70
    /// Every sound you've added, whether or not it's on a key.
    var library: [SoundEntry] = []
    /// Each page is a row-major list of keys (left→right, top→bottom). `null` = blank key.
    var pages: [[ButtonConfig?]] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        outputDevice = try c.decodeIfPresent(String.self, forKey: .outputDevice) ?? d.outputDevice
        micDevice = try c.decodeIfPresent(String.self, forKey: .micDevice)
        micPassthrough = try c.decodeIfPresent(Bool.self, forKey: .micPassthrough) ?? d.micPassthrough
        micVolume = try c.decodeIfPresent(Float.self, forKey: .micVolume) ?? d.micVolume
        monitorDevice = try c.decodeIfPresent(String.self, forKey: .monitorDevice)
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? d.monitor
        monitorVolume = try c.decodeIfPresent(Float.self, forKey: .monitorVolume) ?? d.monitorVolume
        soundVolume = try c.decodeIfPresent(Float.self, forKey: .soundVolume) ?? d.soundVolume
        stopOthers = try c.decodeIfPresent(Bool.self, forKey: .stopOthers) ?? d.stopOthers
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? d.brightness
        library = try c.decodeIfPresent([SoundEntry].self, forKey: .library) ?? d.library
        pages = try c.decodeIfPresent([[ButtonConfig?]].self, forKey: .pages) ?? d.pages
    }

    static func load() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: Paths.config))
    }

    // MARK: Library

    func entry(_ id: String?) -> SoundEntry? {
        guard let id else { return nil }
        return library.first { $0.id == id }
    }

    func face(_ button: ButtonConfig?) -> KeyFace {
        guard let button else { return KeyFace(isEmpty: true) }
        if button.action != nil {
            return KeyFace(label: button.label, image: button.image, color: button.color)
        }
        guard let entry = entry(button.sound) else {
            return KeyFace(label: button.sound == nil ? nil : "?", dangling: button.sound != nil)
        }
        return KeyFace(label: entry.label, image: entry.image, color: entry.color, soundFile: entry.file)
    }

    /// Keys (page, index) that play this sound.
    func usages(of id: String) -> [(page: Int, key: Int)] {
        pages.enumerated().flatMap { p, keys in
            keys.enumerated().compactMap { k, button in button?.sound == id && button?.action == nil ? (p, k) : nil }
        }
    }

    func uniqueID(for name: String) -> String {
        let base = Config.slug(name)
        var candidate = base
        var n = 2
        while library.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    static func slug(_ text: String) -> String {
        let cleaned = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let slug = cleaned.split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "sound" : String(slug.prefix(40))
    }

    static func displayName(forFile file: String) -> String {
        URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// Moves version 1 per-key sounds into the library, and adds any audio files dropped
    /// into `sounds/` that the library doesn't know yet. Returns whether anything changed.
    mutating func upgrade(soundFiles: [String]) -> Bool {
        var changed = false
        if version < 2 {
            for p in pages.indices {
                for k in pages[p].indices {
                    guard let old = pages[p][k], old.action == nil, let file = old.sound else { continue }
                    let id: String
                    if let same = library.first(where: {
                        $0.file == file && $0.label == old.label && $0.image == old.image
                            && $0.color == old.color && $0.volume == old.volume && $0.mode == old.mode
                    }) {
                        id = same.id
                    } else {
                        let name = old.name ?? old.label ?? Config.displayName(forFile: file)
                        id = uniqueID(for: name)
                        library.append(SoundEntry(id: id, name: name, file: file, label: old.label, image: old.image,
                                                  color: old.color, volume: old.volume, mode: old.mode))
                    }
                    pages[p][k] = ButtonConfig(sound: id)
                }
            }
            version = 2
            changed = true
        }
        for file in soundFiles where !library.contains(where: { $0.file == file }) {
            let name = Config.displayName(forFile: file)
            library.append(SoundEntry(id: uniqueID(for: name), name: name, file: file, label: name))
            changed = true
        }
        return changed
    }

    static let defaultJSON = """
    {
      "version": 2,
      "outputDevice": "BlackHole 2ch",
      "micDevice": null,
      "micPassthrough": true,
      "micVolume": 1.0,
      "monitorDevice": null,
      "monitor": true,
      "monitorVolume": 0.5,
      "soundVolume": 0.8,
      "stopOthers": true,
      "brightness": 70,
      "library": [
        { "id": "ding", "name": "Ding", "label": "Ding", "file": "/System/Library/Sounds/Glass.aiff", "color": "#2563eb" },
        { "id": "boop", "name": "Boop", "label": "Boop", "file": "/System/Library/Sounds/Submarine.aiff", "color": "#7c3aed" },
        { "id": "hero", "name": "Hero", "label": "Hero", "file": "/System/Library/Sounds/Hero.aiff", "color": "#059669" },
        { "id": "funk", "name": "Funk", "label": "Funk", "file": "/System/Library/Sounds/Funk.aiff", "color": "#d97706" },
        { "id": "frog", "name": "Frog", "label": "Frog", "file": "/System/Library/Sounds/Frog.aiff", "color": "#65a30d" },
        { "id": "nope", "name": "Nope", "label": "Nope", "file": "/System/Library/Sounds/Basso.aiff", "color": "#9f1239" }
      ],
      "pages": [
        [
          { "sound": "ding" }, { "sound": "boop" }, { "sound": "hero" }, { "sound": "funk" },
          { "sound": "frog" }, { "sound": "nope" },
          { "label": "STOP", "action": "stop", "color": "#dc2626" },
          { "label": "BLEEP", "action": "censor", "color": "#111827" }
        ]
      ]
    }

    """
}

enum Paths {
    /// The real home folder (not a sandbox container), so the config is easy to find and edit.
    static let home: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static let root = home.appending(path: "Library/Application Support/Soundboard", directoryHint: .isDirectory)
    static let config = root.appending(path: "config.json")
    static let sounds = root.appending(path: "sounds", directoryHint: .isDirectory)
    static let icons = root.appending(path: "icons", directoryHint: .isDirectory)

    static func resolve(_ path: String, in dir: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        return dir.appending(path: path)
    }

    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac", "aac"]

    /// Audio files sitting in `sounds/` (names relative to it).
    static func soundFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sounds.path)) ?? []
        return names.filter { audioExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }.sorted()
    }

    static func ensureExists() throws {
        let fm = FileManager.default
        for dir in [root, sounds, icons] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: config.path) {
            try Config.defaultJSON.write(to: config, atomically: true, encoding: .utf8)
        }
    }
}
