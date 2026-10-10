import AppKit
import AVFoundation
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, StreamDeckDelegate {
    private(set) var config = Config()
    private var configError: String?
    let assets = AssetCache()
    private var keyCache: [String: Data] = [:]
    /// What we last wrote to config.json, so our own saves don't trigger a reload.
    private var lastWritten: Data?
    private var hasLoaded = false
    /// Called after the config changes (from disk or the settings window).
    var onConfigChange: ((Config) -> Void)?

    private var page = 0
    private var nowPlaying: [String] = []
    private var censorKey: String?

    let router = AudioRouter()
    private let decks = StreamDeckManager()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var rebuildWork: DispatchWorkItem?
    private var reloadWork: DispatchWorkItem?
    private var watchers: [DispatchSourceFileSystemObject] = []

    private var mainWindow: MainWindow!

    /// Key grid of the connected deck (Neo layout when none is plugged in).
    var keyLayout: (keys: Int, columns: Int) {
        guard let model = decks.deck?.model else { return (8, 4) }
        return (model.keyCount, model.columns)
    }

    private var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Soundboard")
        statusMenu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        mainWindow = MainWindow(app: self)
        onConfigChange = { [weak self] config in
            self?.mainWindow?.configChanged(config)
            self?.publishStatus()
        }
        Fetcher.clearDownloads()

        router.onPlaybackChange = { [weak self] key, playing in self?.playbackChanged(key, playing) }
        router.onNeedsRebuild = { [weak self] in self?.scheduleRebuild() }
        router.onStatusChange = { [weak self] in
            guard let self else { return }
            let s = self.router.status
            NSLog("Soundboard: output=%@ monitor=%@ mic=%@",
                  s.output ?? "✗ \(s.outputProblem ?? "-")", s.monitor ?? "off", s.mic ?? "✗ \(s.micProblem ?? "off")")
            self.redrawScreen()
            self.publishStatus()
        }
        AudioDevices.observeChanges { [weak self] in self?.scheduleRebuild() }

        reloadConfig()
        watchConfig()
        requestMicIfNeeded()

        decks.delegate = self
        decks.start()

        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--audio") { mainWindow.show(.audio) }
        if let i = CommandLine.arguments.firstIndex(of: "--clip") {
            // `--clip <file or link>` opens the clip editor with it.
            let argument = CommandLine.arguments[safe: i + 1].flatMap { $0.hasPrefix("-") ? nil : $0 }
            if let argument, argument.hasPrefix("http") {
                mainWindow.showEditor(link: argument)
            } else {
                if let argument {
                    mainWindow.showEditor(file: URL(fileURLWithPath: argument))
                } else {
                    mainWindow.showEditor()
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            // Development aid: saves the front window as snapshot.png in the Soundboard folder
            // after `--snapshot <seconds>` (default 2).
            let delay = CommandLine.arguments[safe: i + 1].flatMap(Double.init) ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let view = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: Paths.root.appending(path: "snapshot.png"))
            }
        }
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
        let data: Data
        do {
            try Paths.ensureExists()
            data = try Data(contentsOf: Paths.config)
            if hasLoaded, data == lastWritten { return }
            var loaded = try JSONDecoder().decode(Config.self, from: data)
            configError = nil
            if loaded.upgrade(soundFiles: Paths.soundFiles()) {
                save(loaded) // first run after the library was added, or new files in sounds/
            } else {
                apply(loaded)
            }
        } catch {
            configError = "config.json: \(error.localizedDescription)"
            NSLog("Soundboard: %@", "\(error)")
            if !hasLoaded { apply(Config()) } // otherwise keep running with the last good config
        }
    }

    /// Saves to config.json and applies immediately.
    func save(_ newConfig: Config) {
        var newConfig = newConfig
        _ = newConfig.upgrade(soundFiles: Paths.soundFiles()) // keep files dropped into sounds/ in the library
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(newConfig)
            try data.write(to: Paths.config, options: .atomic)
            lastWritten = data
            configError = nil
        } catch {
            NSLog("Soundboard: saving config failed: %@", error.localizedDescription)
        }
        apply(newConfig)
    }

    private func apply(_ newConfig: Config) {
        let old = config
        config = newConfig
        let routingChanged = !hasLoaded
            || old.outputDevice != newConfig.outputDevice || old.micDevice != newConfig.micDevice
            || old.micPassthrough != newConfig.micPassthrough || old.monitorDevice != newConfig.monitorDevice
            || old.monitor != newConfig.monitor
        hasLoaded = true

        for entry in config.library { _ = assets.sound(entry.file) }
        keyCache.removeAll()
        page = min(page, max(0, config.pages.count - 1))
        if routingChanged {
            rebuildAudio()
        } else {
            router.setVolumes(config)
        }
        decks.deck?.setBrightness(config.brightness)
        redrawDeck()
        onConfigChange?(config)
    }

    /// Editors either rewrite the file in place or replace it, so watch both the file and its folder.
    /// The sounds/icons folders are watched too, so dropping in a missing file fixes its key.
    private func watchConfig() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        for url in [Paths.root, Paths.config, Paths.sounds, Paths.icons] {
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
        publishStatus()
    }

    func deckDidDisconnect(_ deck: StreamDeck) {
        NSLog("Soundboard: disconnected %@", deck.model.name)
        publishStatus()
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
            guard pressed, let entry = config.entry(button.sound),
                  case let .success(sound) = assets.sound(entry.file) else { return }
            router.play(key: key, sound: sound, volume: entry.volume ?? 1, mode: entry.mode ?? .toggle,
                        stopOthers: config.stopOthers)
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
        assets.render(config.face(button(page: page, index: index)), size: size, active: isActive(Self.key(page, index)))
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
            return config.entry(b.sound)?.name ?? b.label ?? "Sound"
        }
        let title = censorKey != nil ? "BLEEP" : playingLabel.map { "▶ \($0)" } ?? "Soundboard"
        var subtitle = config.pages.count > 1 ? "Page \(page + 1) of \(config.pages.count)" : ""
        let status = router.status
        let warning = configError != nil ? "config error"
            : status.connecting != nil ? "connecting audio…"
            : status.outputProblem != nil ? "no output" : nil
        let mic = status.mic != nil ? (status.micLive ? "input on" : "input standby")
            : (config.micPassthrough ? "input off" : nil)
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
        if let device = status.connecting {
            info("⏳ Opening \(device)… (if this stays, the audio driver is stuck — restart your Mac)")
        } else {
            info(status.output.map { "✓ Output: \($0)" } ?? "✗ \(status.outputProblem ?? "No output")")
        }
        if config.micPassthrough, status.mic != nil || status.micProblem != nil {
            info(status.mic.map { "✓ Input: \($0)\(status.micLive ? "" : " (standby until an app listens)")" }
                ?? "✗ \(status.micProblem ?? "Input unavailable")")
        }
        if let monitor = status.monitor { info("✓ Monitor: \(monitor)") }
        if let configError { info("✗ \(configError)") }
        let broken = config.library.filter { assets.isBroken($0.file) }.count
        if broken > 0 { info("⚠︎ \(broken) sound file\(broken == 1 ? "" : "s") couldn't be loaded") }

        menu.addItem(.separator())
        action("Open Soundboard…", #selector(showSettings), key: ",")
        action("New Sound…", #selector(newClip), key: "n")
        action("Stop All Sounds", #selector(stopAll), key: ".")
        action("Route Input to Output", #selector(toggleMic), on: config.micPassthrough)
        action("Monitor Sounds", #selector(toggleMonitor), on: config.monitor)
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

    /// Opening the app again (Finder, Spotlight, `open`) while it runs shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    /// Click opens the window; right-click or Control-click shows the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Attaching the menu only for this click keeps left-click free for the window.
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            mainWindow.show()
        }
    }

    @objc func showSettings() { mainWindow.showPad(page: page) }

    @objc private func newClip() { mainWindow.showEditor() }

    /// Snapshot for the window's status strip.
    var appStatus: AppStatus {
        let s = router.status
        return AppStatus(deck: decks.deck?.model.name, deckBusy: decks.busyDevice != nil,
                         output: s.output, outputProblem: s.outputProblem, connecting: s.connecting,
                         mic: s.mic, micProblem: s.micProblem, micLive: s.micLive, micPassthrough: config.micPassthrough,
                         monitor: s.monitor)
    }

    private func publishStatus() {
        mainWindow?.statusChanged(appStatus)
    }

    @objc private func stopAll() { router.stopAll() }

    @objc private func toggleMic() {
        var updated = config
        updated.micPassthrough.toggle()
        save(updated)
        requestMicIfNeeded()
    }

    @objc private func toggleMonitor() {
        var updated = config
        updated.monitor.toggle()
        save(updated)
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
        lastWritten = nil
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
