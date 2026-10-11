import AppKit
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case pad = "Sounds & Keys"
    case editor = "Sound Editor"
    case audio = "Audio"
    case settings = "Settings"
    case sync = "Sync"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .pad: "square.grid.2x2"
        case .editor: "waveform"
        case .audio: "slider.horizontal.3"
        case .settings: "gearshape"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

/// What the status strip at the bottom of the window shows.
struct AppStatus: Equatable {
    var deck: String?
    var deckBusy = false
    var output: String?
    var outputProblem: String?
    var connecting: String?
    var mic: String?
    var micProblem: String?
    var micLive = false
    var outputLive = false
    var monitorLive = false
    var micPassthrough = true
    var monitor: String?
    var sync: SyncService.State = .off
}

final class MainModel: ObservableObject {
    @Published var tab: MainTab = .pad
    @Published var clipTarget: ClipTarget = .library
    @Published var status = AppStatus()
    let settings: SettingsModel
    let editor = ClipEditorModel()
    let audio: AudioMonitor
    var syncNow: () -> Void = {}

    init(settings: SettingsModel, router: AudioRouter) {
        self.settings = settings
        audio = AudioMonitor(router: router)
    }

    var destinationText: String {
        switch clipTarget {
        case .library: "Library"
        case let .key(page, index): "Library + Page \(page + 1) · Key \(index + 1)"
        case let .replace(id): "“\(settings.entry(id)?.name ?? id)” (replaces its audio)"
        }
    }

    var saveTitle: String {
        switch clipTarget {
        case .library: "Save to Library"
        case .key: "Save and Put on Key"
        case .replace: "Replace Audio"
        }
    }
}

/// The one Soundboard window, with a tab for each job.
struct MainView: View {
    @ObservedObject var model: MainModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $model.tab) {
                ForEach(MainTab.allCases) { Label($0.rawValue, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 720)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch model.tab {
                case .pad:
                    PadView(model: model.settings)
                case .editor:
                    ClipEditorView(model: model.editor, destination: model.destinationText, saveTitle: model.saveTitle,
                                   clearDestination: {
                                       if case .library = model.clipTarget { return nil }
                                       return { model.clipTarget = .library; model.editor.targetHasImage = false }
                                   }())
                case .audio:
                    AudioTab(settings: model.settings, monitor: model.audio, status: model.status)
                case .settings:
                    SettingsTab(settings: model.settings)
                case .sync:
                    SyncTab(settings: model.settings, state: model.status.sync, syncNow: model.syncNow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusStrip(status: model.status)
        }
        .frame(minWidth: 1100, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct StatusStrip: View {
    let status: AppStatus

    var body: some View {
        HStack(spacing: 18) {
            item(status.deck.map { "\($0)" } ?? (status.deckBusy ? "Stream Deck in use by another app" : "No Stream Deck"),
                 ok: status.deck != nil, systemImage: "square.grid.3x2")
            if let connecting = status.connecting {
                item("Opening \(connecting)…", ok: nil, systemImage: "hourglass")
            } else {
                item(status.output.map { "Output: \($0)\(status.outputLive ? "" : " · standby")" }
                         ?? (status.outputProblem ?? "No output"),
                     ok: status.output != nil, systemImage: "speaker.wave.2")
            }
            if status.micPassthrough {
                item(status.mic.map { "Input: \($0)\(status.micLive ? "" : " · standby")" } ?? (status.micProblem ?? "Input off"),
                     ok: status.mic != nil, systemImage: "mic")
            }
            if let monitor = status.monitor {
                item("Monitor: \(monitor)\(status.monitorLive ? "" : " · standby")", ok: true, systemImage: "headphones")
            }
            switch status.sync {
            case .off: EmptyView()
            case let .syncing(message): item("Sync: \(message)", ok: nil, systemImage: "arrow.triangle.2.circlepath")
            case let .synced(date):
                item("Synced at \(date.formatted(date: .omitted, time: .shortened))", ok: true,
                     systemImage: "arrow.triangle.2.circlepath")
            case .failed: item("Sync failed", ok: false, systemImage: "arrow.triangle.2.circlepath")
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func item(_ text: String, ok: Bool?, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ok == nil ? Color.orange : ok! ? Color.green : Color.red).frame(width: 7, height: 7)
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text).lineLimit(1)
        }
    }
}

/// Owns the single main window. The app stays a menu-bar app, and only shows in the
/// Dock while the window is open.
final class MainWindow: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private var window: NSWindow?
    private var model: MainModel?

    init(app: AppController) {
        self.app = app
        super.init()
        installMainMenu()
    }

    func configChanged(_ config: Config) {
        model?.settings.external(config)
    }

    func statusChanged(_ status: AppStatus) {
        model?.status = status
    }

    func show(_ tab: MainTab? = nil) {
        let model = self.model ?? makeModel()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Soundboard"
            let host = NSHostingController(rootView: MainView(model: model))
            // By default every SwiftUI update re-measures the whole window to keep its size
            // constraints current, which made each meter frame lay out the entire Audio tab.
            // The window sets its own minimum instead.
            host.sizingOptions = []
            window.contentViewController = host
            window.contentMinSize = NSSize(width: 1100, height: 680)
            window.setContentSize(NSSize(width: 1200, height: 760)) // the autosaved frame, if any, wins below
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("SoundboardMain")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        if let tab { model.tab = tab }
        model.status = app.appStatus
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if model.tab == .audio { model.audio.start() } // reopened on the Audio tab
    }

    func showPad(page: Int? = nil, key: Int? = nil) {
        show(.pad)
        if let page { model?.settings.page = page }
        if let key { model?.settings.selection = .key(key) }
    }

    /// Opens the Sound Editor, aimed at `target`, optionally loading a file or link.
    func showEditor(target: ClipTarget = .library, file: URL? = nil, link: String? = nil) {
        show(.editor)
        guard let model else { return }
        model.clipTarget = target
        switch target {
        case .library: model.editor.targetHasImage = false
        case let .replace(id): model.editor.targetHasImage = app.config.entry(id)?.image != nil
        case let .key(page, index):
            let button = app.config.pages[safe: page]?[safe: index] ?? nil
            model.editor.targetHasImage = app.config.face(button).image != nil
        }
        if let file {
            model.editor.source = .file
            model.editor.open(file)
        } else if let link {
            model.editor.source = link.contains("youtu") ? .youtube : .website
            model.editor.link = link
            model.editor.fetch()
        } else if case let .replace(id) = target, let entry = app.config.entry(id) {
            // Re-clip: start from the sound's current audio, named after the sound.
            model.editor.source = .file
            model.editor.open(Paths.resolve(entry.file, in: Paths.sounds), title: entry.name)
        }
    }

    private func makeModel() -> MainModel {
        let layout = app.keyLayout
        let settings = SettingsModel(config: app.config, keyCount: layout.keys, columns: layout.columns,
                                     assets: app.assets) { [weak app] config in app?.save(config) }
        settings.router = app.router
        let model = MainModel(settings: settings, router: app.router)
        model.syncNow = { [weak app] in app?.syncNow() }
        settings.openClipEditor = { [weak self] target, file in self?.showEditor(target: target, file: file) }
        model.editor.onSave = { [weak self, weak model] result in
            guard let self, let model else { return }
            model.settings.addClip(result, to: model.clipTarget)
            model.clipTarget = .library
            model.editor.reset()
            self.show(.pad)
        }
        self.model = model
        return model
    }

    func windowWillClose(_ notification: Notification) {
        model?.editor.player.pause()
        model?.audio.stop() // a hidden window doesn't always get onDisappear; this frees the input
        NSApp.setActivationPolicy(.accessory)
    }

    /// Without a main menu, ⌘C/⌘V/⌘A don't work in text fields.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Soundboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for (i, tab) in MainTab.allCases.enumerated() {
            let item = NSMenuItem(title: tab.rawValue, action: #selector(switchTab(_:)), keyEquivalent: "\(i + 1)")
            item.tag = i
            item.target = self
            view.addItem(item)
        }
        viewItem.submenu = view
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func switchTab(_ sender: NSMenuItem) {
        show(MainTab.allCases[sender.tag])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
