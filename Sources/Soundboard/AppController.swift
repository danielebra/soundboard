import AppKit
import AVFoundation
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, StreamDeckDelegate {
    private(set) var config = Config()
    private var configError: String?
    let assets = AssetCache()
    private var keyCache: [String: Data] = [:]
    /// What we last wrote to config.json and local.json, so our own saves don't trigger a reload.
    private var lastWritten: (shared: Data, local: Data)?
    private var hasLoaded = false
    /// Called after the config changes (from disk or the settings window).
    var onConfigChange: ((Config) -> Void)?

    private(set) var page = 0
    private var nowPlaying: [String] = []
    private var censorKey: String?
    /// Redraws the info screen while it shows something live; nil otherwise.
    private var screenTimer: Timer?
    private var lastScreen: ScreenFrame?
    private var inputLevels: [ScreenFrame.InputLevel] = []
    /// Input chunks not yet graphed (raw, sent), and the raw chunk held back to line up with
    /// the noise removal's latency.
    private var pendingInput: (raw: [Float], sent: [Float]) = ([], [])
    private var delayedRaw: Float = 0

    let router = AudioRouter()
    let sync = SyncService()
    private let decks = StreamDeckManager()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var appearanceObserver: NSKeyValueObservation?
    private var rebuildWork: DispatchWorkItem?
    private var reloadWork: DispatchWorkItem?
    private var watchers: [DispatchSourceFileSystemObject] = []

    private var mainWindow: MainWindow!
    private lazy var palette = Palette(app: self)
    private let corner = CornerTrigger()
    private let hotkeys = Hotkeys()

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
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in self?.updateStatusIcon() }
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
        sync.onChange = { [weak self] in self?.publishStatus() }

        reloadConfig()
        watchConfig()
        requestMicIfNeeded()

        decks.delegate = self
        decks.start()

        corner.onTrigger = { [weak self] screen in
            guard let self else { return }
            self.palette.show(on: screen, corner: self.config.hotCorner)
        }
        palette.onVisibilityChange = { [weak self] visible in self?.corner.isSuspended = visible }
        hotkeys.onCommand = { [weak self] command, pressed in self?.shortcut(command, pressed: pressed) }

        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--audio") { mainWindow.show(.audio) }
        if CommandLine.arguments.contains("--app-settings") { mainWindow.show(.settings) }
        if CommandLine.arguments.contains("--sync") { mainWindow.show(.sync) }
        if CommandLine.arguments.contains("--palette") { palette.show(on: nil, corner: config.hotCorner, stays: true) }
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
                let file = Paths.root.appending(path: "snapshot.png")
                if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }), let png = self.palette.snapshotPNG() {
                    try? png.write(to: file)
                    return
                }
                guard let view = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
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
        do {
            try Paths.ensureExists()
            let shared = try Data(contentsOf: Paths.config)
            let local = try? Data(contentsOf: Paths.local)
            if hasLoaded, let lastWritten, shared == lastWritten.shared, local == lastWritten.local { return }
            var loaded = try Config.decode(shared: shared, local: local)
            configError = nil
            if loaded.upgrade(soundFiles: Paths.soundFiles()) || local == nil {
                // First run after the library or local.json was added, or new files in sounds/.
                save(loaded)
            } else {
                apply(loaded)
            }
        } catch {
            configError = error is AudioError ? error.localizedDescription : "config.json: \(error.localizedDescription)"
            NSLog("Soundboard: %@", "\(error)")
            if !hasLoaded { apply(Config()) } // otherwise keep running with the last good config
        }
    }

    /// Saves to config.json and local.json and applies immediately.
    func save(_ newConfig: Config) {
        var newConfig = newConfig
        _ = newConfig.upgrade(soundFiles: Paths.soundFiles()) // keep files dropped into sounds/ in the library
        do {
            let files = try newConfig.encodedFiles()
            try files.local.write(to: Paths.local, options: .atomic)
            try files.shared.write(to: Paths.config, options: .atomic)
            // Sounds and keys changed (audio settings don't sync).
            if hasLoaded, files.shared != lastWritten?.shared { sync.changed() }
            lastWritten = files
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
        corner.corner = config.hotCorner
        hotkeys.modifiers = config.shortcuts
        redrawDeck()
        sync.configure(remote: config.syncRemote)
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
        lastScreen = nil
        redrawDeck()
        publishStatus()
    }

    func deckDidDisconnect(_ deck: StreamDeck) {
        NSLog("Soundboard: disconnected %@", deck.model.name)
        palette.reload() // back to the Neo layout
        redrawScreen() // stops the screen timer
        publishStatus()
    }

    func deck(_ deck: StreamDeck, button index: Int, pressed: Bool) {
        if index >= deck.model.keyCount {
            if pressed { turnPage(by: index == deck.model.keyCount ? -1 : 1) }
            return
        }
        press(index: index, pressed: pressed)
    }

    /// A key on the current page went down or up, on the deck or the on-screen palette.
    func press(index: Int, pressed: Bool) {
        guard let button = button(page: page, index: index) else { return }
        let key = Self.key(page, index)
        switch button.action {
        case .stop:
            if pressed { router.stopAll() }
        case .censor:
            router.setCensor(pressed)
            censorKey = pressed ? key : nil
            redraw(key: key)
            redrawScreen()
        case nil:
            guard pressed, let entry = config.entry(button.sound),
                  case let .success(sound) = assets.sound(entry.file) else { return }
            router.play(key: key, sound: sound, volume: entry.volume ?? 1, mode: entry.mode ?? .toggle,
                        stopOthers: config.stopOthers)
        }
    }

    /// A global keyboard shortcut went down or up.
    private func shortcut(_ command: ShortcutCommand, pressed: Bool) {
        switch command {
        case let .key(index): press(index: index, pressed: pressed)
        case .previousPage: if pressed { turnPage(by: -1) }
        case .nextPage: if pressed { turnPage(by: 1) }
        case .stopAll: if pressed { router.stopAll() }
        case .palette: if pressed { palette.toggle(corner: config.hotCorner) }
        }
    }

    func turnPage(by delta: Int) {
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

    /// Redraws every key of the current page, on the deck and the palette.
    private func redrawDeck() {
        palette.reload()
        guard let deck = decks.deck else { return }
        for index in 0..<deck.model.keyCount { sendKey(index, to: deck) }
        redrawScreen()
    }

    private func redraw(key: String) {
        let parts = key.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2, parts[0] == page else { return }
        palette.refresh(index: parts[1])
        if let deck = decks.deck, parts[1] < deck.model.keyCount { sendKey(parts[1], to: deck) }
    }

    private func sendKey(_ index: Int, to deck: StreamDeck) {
        let key = Self.key(page, index)
        let cacheKey = "\(key).\(isActive(key))"
        let jpeg = keyCache[cacheKey] ?? KeyRenderer.jpeg(renderKey(page: page, index: index, size: deck.model.keySize))
        keyCache[cacheKey] = jpeg
        deck.setKeyImage(index, jpeg: jpeg)
    }

    // MARK: Info screen

    /// Redraws the screen now, and keeps redrawing it 20 times a second while it shows
    /// something live: a playing sound's progress or the input level.
    private func redrawScreen() {
        let live = decks.deck?.model.screen != nil && censorKey == nil
            && (!nowPlaying.isEmpty || router.status.micLive)
        if live, screenTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.screenTick() }
            timer.tolerance = 0.01 // lets macOS batch the wakeups
            RunLoop.main.add(timer, forMode: .common)
            screenTimer = timer
        } else if !live {
            screenTimer?.invalidate()
            screenTimer = nil
        }
        drawScreen()
    }

    private func screenTick() {
        if let screen = decks.deck?.model.screen {
            sampleInput(bars: KeyRenderer.levelBars(screenWidth: screen.width))
        }
        drawScreen()
    }

    /// Sends the screen's current frame unless it's the one already showing.
    private func drawScreen() {
        guard let deck = decks.deck, let screen = deck.model.screen else { return }
        let frame = screenFrame(width: screen.width)
        guard frame != lastScreen else { return }
        lastScreen = frame
        let image = KeyRenderer.screen(frame, width: screen.width, height: screen.height)
        deck.setScreenImage(KeyRenderer.jpeg(image, quality: 0.85))
    }

    private func screenFrame(width: Int) -> ScreenFrame {
        let status = router.status
        let pageInfo = config.pages.count > 1 ? "Page \(page + 1) of \(config.pages.count)" : ""
        let warning = configError != nil ? "config error"
            : status.connecting != nil ? "connecting audio…"
            : status.outputProblem != nil ? "no output" : nil

        if censorKey == nil, let key = nowPlaying.last, let progress = router.progress(key) {
            let parts = key.split(separator: ".").compactMap { Int($0) }
            let button = parts.count == 2 ? button(page: parts[0], index: parts[1]) : nil
            let entry = config.entry(button?.sound)
            let others = nowPlaying.count - 1
            let title = "▶ \(entry?.name ?? button?.label ?? "Sound")" + (others > 0 ? "  +\(others)" : "")
            let remaining = Int((progress.duration - progress.elapsed).rounded(.up))
            let columns = KeyRenderer.waveformColumns(screenWidth: width)
            let peaks = entry.flatMap { assets.waveform($0.file, columns: columns) } ?? Array(repeating: 0, count: columns)
            let played = progress.duration > 0 ? Int(Double(columns) * progress.elapsed / progress.duration) : 0
            return .playing(title: title, info: String(format: "-%ld:%02ld", remaining / 60, remaining % 60),
                            peaks: peaks, played: played)
        }
        if censorKey == nil, status.micLive {
            // Noise removal runs on the output engine, so it's only on while the output is.
            return .input(title: pageInfo.isEmpty ? "Soundboard" : pageInfo, warning: warning,
                          noiseRemoval: config.noiseSuppression && status.output != nil, levels: inputLevels)
        }
        let mic = status.mic != nil ? "input standby" : (config.micPassthrough ? "input off" : nil)
        let subtitle = [pageInfo, warning ?? mic].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return .message(title: censorKey != nil ? "BLEEP" : "Soundboard", subtitle: subtitle)
    }

    /// Adds the next 50 ms of input to the screen's history, if it has arrived.
    private func sampleInput(bars: Int) {
        let input = router.takeChunks(.input)
        let unprocessed = router.takeChunks(.unprocessed), processed = router.takeChunks(.processed)
        let processing = router.status.output != nil
        if processing {
            pendingInput.raw += unprocessed
            pendingInput.sent += processed
        } else {
            // Without the output there's no processed signal; graph the raw input as sent.
            pendingInput.raw += input
            pendingInput.sent += input
        }
        guard !pendingInput.raw.isEmpty, !pendingInput.sent.isEmpty else { return }
        // Chunks come in pairs every 100 ms and the timer drifts against the audio clock;
        // take one per frame, merging any backlog so the graph never lags.
        func next(_ queue: inout [Float]) -> Float {
            var level = queue.removeFirst()
            while queue.count > 2 { level = max(level, queue.removeFirst()) }
            return level
        }
        var raw = next(&pendingInput.raw)
        let sent = next(&pendingInput.sent)
        if processing && config.noiseSuppression {
            // Noise removal delays its output ~56 ms, about one chunk.
            (raw, delayedRaw) = (delayedRaw, raw)
        }
        let level = ScreenFrame.InputLevel(raw: Self.meterHeight(raw), sent: Self.meterHeight(sent),
                                           clipped: max(raw, sent) >= 0.99)
        // After a stretch of quiet as long as the graph, stop scrolling so nothing is redrawn.
        let quiet = { (level: ScreenFrame.InputLevel) in max(level.raw, level.sent) <= 0.1875 } // about -49 dBFS
        if quiet(level), inputLevels.count == bars, inputLevels.allSatisfy(quiet) { return }
        inputLevels.append(level)
        if inputLevels.count > bars { inputLevels.removeFirst(inputLevels.count - bars) }
    }

    /// A peak level as a share of the graph: -60…0 dBFS, in sixteenths so noise doesn't redraw.
    private static func meterHeight(_ linear: Float) -> Float {
        let db = linear > 0 ? 20 * log10(linear) : -60
        return (max(0, min(1, (db + 60) / 60)) * 16).rounded() / 16
    }

    // MARK: Menu

    /// What's wrong right now, one short line each. Empty when everything works; the menu shows
    /// only these, and the icon gets a dot for them.
    private var problems: [String] {
        let status = router.status
        var lines: [String] = []
        if decks.deck == nil, decks.busyDevice != nil { lines.append("Stream Deck is in use by another app") }
        if let device = status.connecting {
            lines.append("Opening \(device)… (restart your Mac if this stays)")
        } else if status.output == nil {
            lines.append(status.outputProblem ?? "No output device")
        }
        if config.micPassthrough, status.mic == nil, let problem = status.micProblem { lines.append(problem) }
        if let configError { lines.append(configError) }
        let broken = config.library.filter { assets.isBroken($0.file) }.count
        if broken > 0 { lines.append("\(broken) sound file\(broken == 1 ? "" : "s") couldn't be loaded") }
        if case let .failed(message) = sync.state { lines.append("Sync failed: \(message)") }
        return lines
    }

    /// The menu bar icon: always the app's grid, with a yellow dot in the corner while something is
    /// wrong. The dot needs colour, so with a problem the icon isn't a template and the grid is
    /// tinted by hand to match the menu bar.
    private func updateStatusIcon() {
        let symbol = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Soundboard")
        guard !problems.isEmpty, let symbol, let button = statusItem.button else {
            statusItem.button?.image = symbol
            return
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tint = dark ? NSColor.white : NSColor.black
        let base = symbol.withSymbolConfiguration(.init(paletteColors: [tint])) ?? symbol
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 8, y: rect.minY - 1, width: 8, height: 8)
            let context = NSGraphicsContext.current?.cgContext
            context?.setBlendMode(.clear)
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            context?.setBlendMode(.normal)
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Soundboard, needs attention"
        button.image = image
    }

    /// A short menu: the window is where everything happens. Shortcuts shown are the real global
    /// ones, so the menu doubles as a reminder of them.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = router.status

        func add(_ title: String, _ selector: Selector?, key: String = "", mask: NSEvent.ModifierFlags = .command,
                 on: Bool? = nil, to menu: NSMenu = menu) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            item.keyEquivalentModifierMask = mask
            if selector == nil { item.isEnabled = false }
            if let on { item.state = on ? .on : .off }
            menu.addItem(item)
        }
        /// A command with its global shortcut, when shortcuts are on.
        func add(_ title: String, _ selector: Selector, shortcut command: ShortcutCommand) {
            let on = config.shortcuts != .off
            add(title, selector, key: on ? command.keyName.lowercased() : "", mask: config.shortcuts.menuMask)
        }

        let lines = problems
        for line in lines { add("⚠︎ \(line)", nil) }
        if !lines.isEmpty { menu.addItem(.separator()) }

        add("Open Soundboard…", #selector(showSettings), key: ",")
        add("New Sound…", #selector(newClip), key: "n")
        add(palette.isVisible ? "Hide Palette" : "Show Palette", #selector(togglePalette), shortcut: .palette)
        add("Stop All Sounds", #selector(stopAll), shortcut: .stopAll)
        if sync.state != .off { add("Sync Now", #selector(syncNow), key: "") }
        if status.micProblem == "Microphone access not granted" {
            add("Allow Microphone Access…", #selector(openMicSettings), key: "")
        }

        let more = NSMenu()
        add("Route Input to Output", #selector(toggleMic), on: config.micPassthrough, to: more)
        add("Monitor Sounds", #selector(toggleMonitor), on: config.monitor, to: more)
        more.addItem(.separator())
        add("Open Soundboard Folder", #selector(openFolder), to: more)
        add("Edit config.json", #selector(editConfig), to: more)
        add("Reload", #selector(reload), to: more)
        let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(.separator())
        menu.addItem(moreItem)

        menu.addItem(.separator())
        add("Quit Soundboard", #selector(quit), key: "q")
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
                         mic: s.mic, micProblem: s.micProblem, micLive: s.micLive, outputLive: s.outputLive,
                         monitorLive: s.monitorLive, micPassthrough: config.micPassthrough,
                         monitor: s.monitor, sync: sync.state)
    }

    private func publishStatus() {
        mainWindow?.statusChanged(appStatus)
        updateStatusIcon()
    }

    @objc private func stopAll() { router.stopAll() }

    @objc func syncNow() { sync.syncNow() }

    @objc private func togglePalette() { palette.toggle(corner: config.hotCorner) }

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
