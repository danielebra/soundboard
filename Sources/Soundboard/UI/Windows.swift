import AppKit
import SwiftUI

/// Owns the settings and clip-editor windows. The app stays a menu-bar app, and only
/// shows in the Dock while one of these windows is open.
final class Windows: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var clipWindow: NSWindow?
    private var clipModel: ClipEditorModel?

    init(app: AppController) {
        self.app = app
        super.init()
        installMainMenu()
    }

    func configChanged(_ config: Config) {
        settingsModel?.external(config)
    }

    // MARK: Settings

    func showSettings(select page: Int? = nil, key: Int? = nil) {
        if settingsWindow == nil {
            let layout = app.keyLayout
            let model = SettingsModel(config: app.config, keyCount: layout.keys, columns: layout.columns,
                                      assets: app.assets) { [weak app] config in app?.save(config) }
            model.openClipEditor = { [weak self] target, file in self?.showClipEditor(target: target, file: file) }
            settingsModel = model
            settingsWindow = makeWindow(title: "Soundboard", content: SettingsView(model: model), size: CGSize(width: 1180, height: 680))
        }
        if let page { settingsModel?.page = page }
        if let key { settingsModel?.selection = .key(key) }
        present(settingsWindow!)
    }

    // MARK: Clip editor

    func showClipEditor(target: ClipTarget = .library, file: URL? = nil, link: String? = nil) {
        clipWindow?.close()
        let hasImage: Bool
        switch target {
        case .library: hasImage = false
        case let .replace(id): hasImage = app.config.entry(id)?.image != nil
        case let .key(page, index):
            let button = app.config.pages[safe: page]?[safe: index] ?? nil
            hasImage = app.config.face(button).image != nil
        }
        let model = ClipEditorModel(targetHasImage: hasImage)
        model.onSave = { [weak self] result in
            guard let self else { return }
            self.showSettings()
            self.settingsModel?.addClip(result, to: target)
            self.clipWindow?.close()
        }
        clipModel = model
        let view = ClipEditorView(model: model) { [weak self] in self?.clipWindow?.close() }
        clipWindow = makeWindow(title: "New Sound", content: view, size: CGSize(width: 820, height: 680))
        if let file { model.open(file) }
        if let link {
            model.link = link
            model.fetch()
        }
        present(clipWindow!)
    }

    // MARK: Window plumbing

    private func makeWindow(title: String, content: some View, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            settingsModel = nil
        } else if window === clipWindow {
            clipModel?.cleanUp()
            clipWindow = nil
            clipModel = nil
        }
        if settingsWindow == nil && clipWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Without a main menu, ⌘C/⌘V/⌘A don't work in text fields.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Configure Keys…", action: #selector(AppController.showSettings), keyEquivalent: ",").target = app
        appMenu.addItem(.separator())
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

        NSApp.mainMenu = main
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
