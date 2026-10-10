import AppKit
import AVFoundation
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, StreamDeckDelegate {
    private var config = Config()
    private var configError: String?
    private var sounds: [String: AVAudioPCMBuffer] = [:]
    private var soundErrors: [String: String] = [:]
    private var icons: [String: CGImage] = [:]
    private var keyCache: [String: Data] = [:]

    private var page = 0
    private var nowPlaying: [String] = []
    private var censorKey: String?

    private let router = AudioRouter()
    private let decks = StreamDeckManager()
    private var statusItem: NSStatusItem!
    private var rebuildWork: DispatchWorkItem?
    private var reloadWork: DispatchWorkItem?
    private var watchers: [DispatchSourceFileSystemObject] = []

    private var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Soundboard")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        router.onPlaybackChange = { [weak self] key, playing in self?.playbackChanged(key, playing) }
        router.onNeedsRebuild = { [weak self] in self?.scheduleRebuild() }
        AudioDevices.observeChanges { [weak self] in self?.scheduleRebuild() }

        reloadConfig()
        watchConfig()
        requestMicIfNeeded()

        decks.delegate = self
        decks.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        router.teardown()
        if let deck = decks.deck {
            deck.reset()
            deck.flush()
        }
    }

    private func requestMicIfNeeded() {
        guard config.micPassthrough, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.rebuildAudio() }
        }
    }

    // MARK: Config

    private func reloadConfig() {
        do {
            try Paths.ensureExists()
            config = try Config.load()
            configError = nil
        } catch {
            configError = "config.json: \(error.localizedDescription)"
            NSLog("Soundboard: %@", "\(error)")
            if sounds.isEmpty { config = Config() } else { return } // keep running with the last good config
        }

        sounds.removeAll()
        soundErrors.removeAll()
        icons.removeAll()
        keyCache.removeAll()
        for button in config.pages.joined().compactMap({ $0 }) {
            if let path = button.sound, sounds[path] == nil, soundErrors[path] == nil {
                do { sounds[path] = try loadSound(Paths.resolve(path, in: Paths.sounds)) } catch {
                    soundErrors[path] = error.localizedDescription
                    NSLog("Soundboard: can't load sound %@: %@", path, error.localizedDescription)
                }
            }
            if let path = button.image, icons[path] == nil,
               let image = KeyRenderer.loadImage(Paths.resolve(path, in: Paths.icons)) {
                icons[path] = image
            }
        }
        page = min(page, max(0, config.pages.count - 1))
        rebuildAudio()
        decks.deck?.setBrightness(config.brightness)
        redrawDeck()
    }

    /// Editors either rewrite the file in place or replace it, so watch both the file and its folder.
    private func watchConfig() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        for url in [Paths.root, Paths.config] {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadConfig()
            self?.watchConfig()
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Audio

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildAudio() }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rebuildAudio() {
        router.rebuild(config: config, micAllowed: micAllowed)
        redrawScreen()
    }

    private func playbackChanged(_ key: String, _ playing: Bool) {
        nowPlaying.removeAll { $0 == key }
        if playing { nowPlaying.append(key) }
        redraw(key: key)
        redrawScreen()
    }

    // MARK: Stream Deck

    func deckDidConnect(_ deck: StreamDeck) {
        NSLog("Soundboard: connected %@", deck.model.name)
        deck.setBrightness(config.brightness)
        redrawDeck()
    }

    func deckDidDisconnect(_ deck: StreamDeck) {
        NSLog("Soundboard: disconnected %@", deck.model.name)
    }

    func deck(_ deck: StreamDeck, button index: Int, pressed: Bool) {
        if index >= deck.model.keyCount {
            if pressed { turnPage(by: index == deck.model.keyCount ? -1 : 1) }
            return
        }
        guard let button = button(page: page, index: index) else { return }
        let key = Self.key(page, index)
        switch button.action {
        case .stop:
            if pressed { router.stopAll() }
        case .censor:
            router.setCensor(pressed)
            censorKey = pressed ? key : nil
            redraw(key: key)
        case nil:
            guard pressed, let path = button.sound, let sound = sounds[path] else { return }
            router.play(key: key, sound: sound, volume: button.volume ?? 1, stopOthers: config.stopOthers)
        }
    }

    private func turnPage(by delta: Int) {
        guard config.pages.count > 1 else { return }
        page = (page + delta + config.pages.count) % config.pages.count
        redrawDeck()
    }

    private static func key(_ page: Int, _ index: Int) -> String { "\(page).\(index)" }

    private func button(page: Int, index: Int) -> ButtonConfig? {
        guard config.pages.indices.contains(page), config.pages[page].indices.contains(index) else { return nil }
        return config.pages[page][index]
    }

    private func isActive(_ key: String) -> Bool { router.isPlaying(key) || censorKey == key }

    func renderKey(page: Int, index: Int, size: Int) -> CGImage {
        let button = button(page: page, index: index)
        let key = Self.key(page, index)
        let missingSound = button?.action == nil && button?.sound != nil && sounds[button!.sound!] == nil
        return KeyRenderer.key(size: size, label: button?.label,
                               image: button?.image.flatMap { icons[$0] },
                               background: button == nil ? CGColor(gray: 0, alpha: 1) : KeyRenderer.color(hex: button?.color),
                               active: isActive(key), warning: missingSound)
    }

    private func redrawDeck() {
        guard let deck = decks.deck else { return }
        for index in 0..<deck.model.keyCount { redraw(key: Self.key(page, index)) }
        redrawScreen()
    }

    private func redraw(key: String) {
        guard let deck = decks.deck else { return }
        let parts = key.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2, parts[0] == page, parts[1] < deck.model.keyCount else { return }
        let cacheKey = "\(key).\(isActive(key))"
        let jpeg = keyCache[cacheKey] ?? KeyRenderer.jpeg(renderKey(page: page, index: parts[1], size: deck.model.keySize))
        keyCache[cacheKey] = jpeg
        deck.setKeyImage(parts[1], jpeg: jpeg)
    }

    private func redrawScreen() {
        guard let deck = decks.deck, let screen = deck.model.screen else { return }
        let playingLabel = nowPlaying.last.flatMap { key -> String? in
            let parts = key.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 2, let b = button(page: parts[0], index: parts[1]) else { return nil }
            return b.name ?? b.label ?? "Sound"
        }
        let title = censorKey != nil ? "BLEEP" : playingLabel.map { "▶ \($0)" } ?? "Soundboard"
        var subtitle = config.pages.count > 1 ? "Page \(page + 1) of \(config.pages.count)" : ""
        let status = router.status
        let warning = configError != nil ? "config error" : status.outputProblem != nil ? "no virtual mic" : nil
        let mic = status.mic != nil ? "mic on" : (config.micPassthrough ? "mic off" : nil)
        subtitle = [subtitle, warning ?? mic].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let image = KeyRenderer.screen(width: screen.width, height: screen.height, title: title, subtitle: subtitle)
        deck.setScreenImage(KeyRenderer.jpeg(image))
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = router.status

        func info(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, key: String = "", on: Bool? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            if let on { item.state = on ? .on : .off }
            menu.addItem(item)
        }

        if let deck = decks.deck {
            info("✓ \(deck.model.name)")
        } else if decks.busyDevice != nil {
            info("✗ Stream Deck is in use by another app")
        } else {
            info("✗ No Stream Deck connected")
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty {
            info("⚠︎ Quit the Elgato Stream Deck app — it locks the device")
        }
        info(status.output.map { "✓ Sending to \($0)" } ?? "✗ \(status.outputProblem ?? "No output")")
        if config.micPassthrough {
            info(status.mic.map { "✓ Mic: \($0)" } ?? "✗ \(status.micProblem ?? "Mic unavailable")")
        }
        if let monitor = status.monitor { info("✓ You hear it on \(monitor)") }
        if let configError { info("✗ \(configError)") }
        let broken = soundErrors.count
        if broken > 0 { info("⚠︎ \(broken) sound file\(broken == 1 ? "" : "s") couldn't be loaded") }

        menu.addItem(.separator())
        action("Stop All Sounds", #selector(stopAll), key: ".")
        action("Send Microphone Through", #selector(toggleMic), on: config.micPassthrough)
        action("Hear Sounds Myself", #selector(toggleMonitor), on: config.monitor)
        if status.micProblem == "Microphone access not granted" {
            action("Allow Microphone Access…", #selector(openMicSettings))
        }

        menu.addItem(.separator())
        action("Open Soundboard Folder", #selector(openFolder), key: "o")
        action("Edit config.json", #selector(editConfig), key: "e")
        action("Reload", #selector(reload), key: "r")
        action("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)

        menu.addItem(.separator())
        action("Quit Soundboard", #selector(quit), key: "q")
    }

    @objc private func stopAll() { router.stopAll() }

    @objc private func toggleMic() {
        config.micPassthrough.toggle()
        requestMicIfNeeded()
        rebuildAudio()
    }

    @objc private func toggleMonitor() {
        config.monitor.toggle()
        rebuildAudio()
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.root) }

    @objc private func editConfig() {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([Paths.config], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reload() {
        reloadConfig()
        watchConfig()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Soundboard: login item: %@", error.localizedDescription)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
