import AppKit

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--preview" {
    // Render every key of the current config to PNGs, for checking layouts without a device.
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try Paths.ensureExists()
    let config = try Config.load()
    for (p, keys) in config.pages.enumerated() {
        for (i, button) in keys.enumerated() {
            let image = KeyRenderer.key(size: 96, label: button?.label,
                                        image: button?.image.flatMap { KeyRenderer.loadImage(Paths.resolve($0, in: Paths.icons)) },
                                        background: KeyRenderer.color(hex: button?.color),
                                        active: false, warning: false)
            try KeyRenderer.png(image).write(to: out.appending(path: "page\(p + 1)-key\(i + 1).png"))
        }
    }
    let screen = KeyRenderer.screen(width: 248, height: 58, title: "▶ Sad Trombone", subtitle: "Page 1 of 3 · mic on")
    try KeyRenderer.png(screen).write(to: out.appending(path: "screen.png"))
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
