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
            model.openClipEditor = { [weak self] page, key, file in self?.showClipEditor(page: page, key: key, file: file) }
            settingsModel = model
            settingsWindow = makeWindow(title: "Soundboard", content: SettingsView(model: model), size: CGSize(width: 900, height: 660))
        }
        if let page { settingsModel?.page = page }
        if let key { settingsModel?.selected = key }
        present(settingsWindow!)
    }

    // MARK: Clip editor

    /// `page`/`key` is the key the new sound goes on; nil picks the first empty key.
    func showClipEditor(page: Int? = nil, key: Int? = nil, file: URL? = nil, link: String? = nil) {
        clipWindow?.close()
        let target = page.flatMap { p in key.map { (p, $0) } }
        let existing = target.flatMap { t in app.config.pages[safe: t.0]?[safe: t.1] ?? nil }
        let model = ClipEditorModel(targetHasImage: existing?.image != nil)
        model.onSave = { [weak self] result in
            self?.place(result, at: target)
            self?.clipWindow?.close()
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

    private func place(_ result: ClipEditorModel.Result, at target: (Int, Int)?) {
        let (page, key) = target ?? firstEmptyKey()
        let edit: (inout ButtonConfig) -> Void = { button in
            button.action = nil
            button.sound = result.sound
            button.name = result.name
            if let image = result.image { button.image = image }
            button.label = result.showLabel || button.image == nil ? result.name : nil
        }
        if let settingsModel {
            settingsModel.page = page
            settingsModel.editButton(key, edit)
            settingsModel.selected = key
        } else {
            var config = app.config
            while config.pages.count <= page { config.pages.append([]) }
            while config.pages[page].count <= key { config.pages[page].append(nil) }
            var button = config.pages[page][key] ?? ButtonConfig()
            edit(&button)
            config.pages[page][key] = button
            app.save(config)
        }
        showSettings(select: page, key: key)
    }

    private func firstEmptyKey() -> (Int, Int) {
        let keys = app.keyLayout.keys
        for (p, page) in app.config.pages.enumerated() {
            for k in 0..<keys where k >= page.count || page[k] == nil { return (p, k) }
        }
        return (app.config.pages.count, 0)
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
