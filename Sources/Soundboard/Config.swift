import Foundation

struct ButtonConfig: Codable, Equatable {
    enum Action: String, Codable {
        /// Stops every sound that is playing.
        case stop
        /// While held: mutes your mic and sends a bleep instead.
        case censor
    }

    var label: String?
    /// File inside `sounds/`, or an absolute / `~/` path.
    var sound: String?
    /// Image inside `icons/` (png, jpg, webp, gif), or an absolute / `~/` path.
    var image: String?
    /// Background colour as `#RRGGBB`, used when there is no image.
    var color: String?
    /// 0.0 – 1.0, multiplied with `soundVolume`.
    var volume: Float?
    var action: Action?
}

struct Config: Codable {
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
    /// Starting a sound stops whatever else is playing.
    var stopOthers = true
    var brightness = 70
    /// Each page is a row-major list of keys (left→right, top→bottom). `null` = blank key.
    var pages: [[ButtonConfig?]] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
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
        pages = try c.decodeIfPresent([[ButtonConfig?]].self, forKey: .pages) ?? d.pages
    }

    static func load() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: Paths.config))
    }

    static let defaultJSON = """
    {
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
      "pages": [
        [
          { "label": "Ding", "sound": "/System/Library/Sounds/Glass.aiff", "color": "#2563eb" },
          { "label": "Boop", "sound": "/System/Library/Sounds/Submarine.aiff", "color": "#7c3aed" },
          { "label": "Hero", "sound": "/System/Library/Sounds/Hero.aiff", "color": "#059669" },
          { "label": "Funk", "sound": "/System/Library/Sounds/Funk.aiff", "color": "#d97706" },
          { "label": "Frog", "sound": "/System/Library/Sounds/Frog.aiff", "color": "#65a30d" },
          { "label": "Nope", "sound": "/System/Library/Sounds/Basso.aiff", "color": "#9f1239" },
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
