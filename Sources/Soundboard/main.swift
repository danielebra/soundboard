import AppKit

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--preview" {
    // Render every key of the current config to PNGs, for checking layouts without a device.
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try Paths.ensureExists()
    var config = try Config.load()
    _ = config.upgrade(soundFiles: Paths.soundFiles())
    let assets = AssetCache()
    for (p, keys) in config.pages.enumerated() {
        for (i, button) in keys.enumerated() {
            let image = assets.render(config.face(button), size: 96, active: false)
            try KeyRenderer.png(image).write(to: out.appending(path: "page\(p + 1)-key\(i + 1).png"))
        }
    }
    // The info screen in each mode, with a real sound's waveform and a made-up voice.
    let columns = KeyRenderer.waveformColumns(screenWidth: 248)
    let sound = config.library.first { assets.waveform($0.file, columns: columns) != nil }
    let voice = (0..<KeyRenderer.levelBars(screenWidth: 248)).map { i -> ScreenFrame.InputLevel in
        let speech = i > 20 ? Float(0.45 + 0.4 * abs(sin(Double(i) * 0.7))) : 0
        return ScreenFrame.InputLevel(raw: max(speech, 0.3), sent: speech, clipped: i == 50)
    }
    let frames: [String: ScreenFrame] = [
        "message": .message(title: "Soundboard", subtitle: "Page 1 of 3 · input off"),
        "playing": .playing(title: "▶ \(sound?.name ?? "Sound")  +1", info: "-0:03",
                            peaks: sound.flatMap { assets.waveform($0.file, columns: columns) } ?? [], played: columns / 3),
        "input": .input(title: "Page 1 of 3", warning: nil, noiseRemoval: true, levels: voice),
        "input-warning": .input(title: "Page 1 of 3", warning: "connecting audio…", noiseRemoval: true, levels: voice),
    ]
    for (name, frame) in frames {
        try KeyRenderer.png(KeyRenderer.screen(frame, width: 248, height: 58)).write(to: out.appending(path: "screen-\(name).png"))
    }
    exit(0)
}

if arguments.count >= 2, arguments[1] == "--devices" {
    for device in AudioDevices.all() {
        print("\(device.name)  (in: \(device.inputChannels), out: \(device.outputChannels))")
    }
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
