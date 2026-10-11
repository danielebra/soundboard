import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Where a clip from the clip editor should go.
enum ClipTarget {
    /// Just add it to the library.
    case library
    /// Add it to the library and put it on this key.
    case key(page: Int, index: Int)
    /// Swap the audio of an existing library sound.
    case replace(soundID: String)
}

/// Bridges the app's config to SwiftUI. Edits are applied (and saved) shortly after they stop.
final class SettingsModel: ObservableObject {
    enum Selection: Equatable {
        case key(Int)
        case sound(String)
    }

    @Published var config: Config
    @Published var page = 0
    @Published var selection: Selection? = .key(0)
    @Published var search = ""
    @Published var devices: [AudioDevice] = AudioDevices.all()
    /// Bumped when key images may have changed on disk.
    @Published var revision = 0

    let keyCount: Int
    let columns: Int
    let assets: AssetCache
    private let commit: (Config) -> Void
    private var pending: DispatchWorkItem?
    private var previewPlayer: AVAudioPlayer?
    var openClipEditor: ((ClipTarget, URL?) -> Void)?

    init(config: Config, keyCount: Int, columns: Int, assets: AssetCache, commit: @escaping (Config) -> Void) {
        self.config = config
        self.keyCount = keyCount
        self.columns = columns
        self.assets = assets
        self.commit = commit
        normalizePages()
        if self.config.pages != config.pages { commit(self.config) }
    }

    /// Called when the config changed elsewhere (file edited by hand, files added).
    func external(_ config: Config) {
        guard pending == nil, config != self.config else { return }
        self.config = config
        normalizePages()
        page = min(page, self.config.pages.count - 1)
        if case let .sound(id) = selection, config.entry(id) == nil { selection = nil }
        revision += 1
    }

    private func normalizePages() {
        if config.pages.isEmpty { config.pages = [[]] }
        for p in config.pages.indices where config.pages[p].count < keyCount {
            config.pages[p] += Array(repeating: nil, count: keyCount - config.pages[p].count)
        }
    }

    func update(_ change: (inout Config) -> Void) {
        change(&config)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.commit(self.config)
            self.revision += 1
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Keys

    func button(_ index: Int) -> ButtonConfig? {
        config.pages[safe: page]?[safe: index] ?? nil
    }

    func setButton(_ index: Int, _ button: ButtonConfig?) {
        let page = self.page
        update { $0.pages[page][index] = button }
    }

    func editButton(_ index: Int, _ change: (inout ButtonConfig) -> Void) {
        var button = self.button(index) ?? ButtonConfig()
        change(&button)
        setButton(index, button)
    }

    func swap(_ a: Int, _ b: Int) {
        guard a != b else { return }
        let page = self.page
        update { $0.pages[page].swapAt(a, b) }
        selection = .key(b)
    }

    func firstEmptySlot(onPage target: Int) -> Int? {
        guard config.pages.indices.contains(target) else { return 0 }
        return config.pages[target].firstIndex { $0 == nil }
    }

    /// Moves a key from the current page into the first empty slot of `target`
    /// (a new page when `target` is past the end).
    func move(_ index: Int, toPage target: Int) {
        guard let button = button(index), target != page, let slot = firstEmptySlot(onPage: target) else {
            NSSound.beep()
            return
        }
        let from = page
        let keyCount = self.keyCount
        update { config in
            if target >= config.pages.count { config.pages.append(Array(repeating: nil, count: keyCount)) }
            config.pages[target][slot] = button
            config.pages[from][index] = nil
        }
        page = min(target, config.pages.count - 1)
        selection = .key(slot)
    }

    func addPage() {
        update { $0.pages.append(Array(repeating: nil, count: keyCount)) }
        page = config.pages.count - 1
        selection = .key(0)
    }

    func deletePage() {
        guard config.pages.count > 1 else { return }
        let page = self.page
        update { $0.pages.remove(at: page) }
        self.page = max(0, page - 1)
    }

    // MARK: Library

    func entry(_ id: String) -> SoundEntry? { config.entry(id) }

    func editEntry(_ id: String, _ change: (inout SoundEntry) -> Void) {
        update { config in
            guard let i = config.library.firstIndex(where: { $0.id == id }) else { return }
            change(&config.library[i])
        }
    }

    var filteredLibrary: [SoundEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let sorted = config.library.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return query.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func place(_ id: String, on index: Int) {
        setButton(index, ButtonConfig(sound: id))
        selection = .key(index)
    }

    /// Puts a sound on the first empty key, starting from the page you're looking at.
    func placeOnFirstEmptyKey(_ id: String) {
        let order = Array(page..<config.pages.count) + Array(0..<page)
        if let target = order.first(where: { firstEmptySlot(onPage: $0) != nil }), let slot = firstEmptySlot(onPage: target) {
            page = target
            place(id, on: slot)
        } else {
            addPage()
            place(id, on: 0)
        }
    }

    /// Adds a sound (or updates the one already using `file`). Returns its id.
    @discardableResult
    func addSound(file: String, name: String, label: String?, image: String?) -> String {
        if let existing = config.library.first(where: { $0.file == file }) {
            editEntry(existing.id) {
                $0.name = name
                $0.label = label
                if let image { $0.image = image }
            }
            return existing.id
        }
        let id = config.uniqueID(for: name)
        update { $0.library.append(SoundEntry(id: id, name: name, file: file, label: label, image: image)) }
        return id
    }

    func addClip(_ clip: ClipEditorModel.Result, to target: ClipTarget) {
        let label = clip.showLabel || clip.image == nil ? clip.name : nil
        switch target {
        case let .replace(id):
            editEntry(id) { entry in
                entry.file = clip.sound
                if let image = clip.image { entry.image = image }
            }
            selection = .sound(id)
        case .library:
            selection = .sound(addSound(file: clip.sound, name: clip.name, label: label, image: clip.image))
        case let .key(page, index):
            let id = addSound(file: clip.sound, name: clip.name, label: label, image: clip.image)
            self.page = page
            place(id, on: index)
        }
    }

    /// Removes a sound from the library and every key, and moves its files to the Trash.
    func deleteSound(_ id: String) {
        guard let entry = entry(id) else { return }
        update { config in
            config.library.removeAll { $0.id == id }
            for p in config.pages.indices {
                for k in config.pages[p].indices where config.pages[p][k]?.sound == id && config.pages[p][k]?.action == nil {
                    config.pages[p][k] = nil
                }
            }
        }
        let others = config.library
        if !others.contains(where: { $0.file == entry.file }) { discard(entry.file, in: Paths.sounds) }
        if let image = entry.image, !others.contains(where: { $0.image == image }) { discard(image, in: Paths.icons) }
        selection = nil
    }

    /// Only files inside our own folders are removed; Trash first, else a "Deleted" subfolder
    /// (which the library doesn't scan) so nothing is ever destroyed outright.
    private func discard(_ name: String, in dir: URL) {
        let url = Paths.resolve(name, in: dir)
        guard url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else { return }
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        let deleted = dir.appending(path: "Deleted", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: url, to: deleted.appending(path: url.lastPathComponent))
    }

    func duration(_ entry: SoundEntry) -> Double? {
        guard case let .success(buffer) = assets.sound(entry.file) else { return nil }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    // MARK: Files

    /// Copies a file into the Soundboard folder (so it keeps working if the original moves).
    func importFile(_ url: URL, into dir: URL) -> String? {
        let fm = FileManager.default
        if url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            return url.lastPathComponent
        }
        let base = url.deletingPathExtension().lastPathComponent
        var name = url.lastPathComponent
        var n = 2
        while fm.fileExists(atPath: dir.appending(path: name).path) {
            name = "\(base) \(n).\(url.pathExtension)"
            n += 1
        }
        do {
            try fm.copyItem(at: url, to: dir.appending(path: name))
            return name
        } catch {
            NSLog("Soundboard: import failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func kind(_ url: URL) -> UTType {
        UTType(filenameExtension: url.pathExtension) ?? .data
    }

    /// Adds audio files to the library; videos open in the clip editor. Returns new sound ids.
    @discardableResult
    func importSounds(_ urls: [URL]) -> [String] {
        var ids: [String] = []
        for url in urls {
            let type = Self.kind(url)
            if type.conforms(to: .audio), let file = importFile(url, into: Paths.sounds) {
                let name = url.deletingPathExtension().lastPathComponent
                ids.append(addSound(file: file, name: name, label: name, image: nil))
            } else if type.conforms(to: .movie) {
                openClipEditor?(.library, url)
            }
        }
        if let last = ids.last { selection = .sound(last) }
        return ids
    }

    /// A file dropped on (or chosen for) a key.
    func useFile(_ url: URL, forKey index: Int) {
        let type = Self.kind(url)
        if type.conforms(to: .image) {
            guard let name = importFile(url, into: Paths.icons) else { return }
            if let id = button(index)?.sound, button(index)?.action == nil, entry(id) != nil {
                editEntry(id) { $0.image = name }
            } else if button(index)?.action != nil {
                editButton(index) { $0.image = name }
            }
        } else if type.conforms(to: .movie) {
            openClipEditor?(.key(page: page, index: index), url)
        } else if type.conforms(to: .audio), let id = importSounds([url]).first {
            place(id, on: index)
        }
        selection = .key(index)
    }

    /// A file dropped on (or chosen for) a library sound.
    func useFile(_ url: URL, forSound id: String) {
        let type = Self.kind(url)
        if type.conforms(to: .image), let name = importFile(url, into: Paths.icons) {
            editEntry(id) { $0.image = name }
        } else if type.conforms(to: .movie) {
            openClipEditor?(.replace(soundID: id), url)
        } else if type.conforms(to: .audio), let file = importFile(url, into: Paths.sounds) {
            editEntry(id) { $0.file = file }
        }
    }

    func choose(_ types: [UTType], multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    func preview(_ entry: SoundEntry) {
        if previewPlayer?.isPlaying == true {
            previewPlayer?.stop()
            previewPlayer = nil
            return
        }
        previewPlayer = try? AVAudioPlayer(contentsOf: Paths.resolve(entry.file, in: Paths.sounds))
        previewPlayer?.volume = entry.volume ?? 1
        previewPlayer?.play()
    }
}

// MARK: - Drag payloads

private enum Payload {
    static let key = "soundboard-key:"
    static let sound = "soundboard-sound:"

    /// Calls back on the main queue with dropped file URLs, or a key index / sound id.
    static func receive(_ providers: [NSItemProvider], files: @escaping ([URL]) -> Void,
                        key: ((Int) -> Void)? = nil, sound: ((String) -> Void)? = nil) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in fileProviders {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { files(urls) }
            return true
        }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let text = text as? String else { return }
            DispatchQueue.main.async {
                if text.hasPrefix(Payload.key), let index = Int(text.dropFirst(Payload.key.count)) {
                    key?(index)
                } else if text.hasPrefix(Payload.sound) {
                    sound?(String(text.dropFirst(Payload.sound.count)))
                }
            }
        }
        return true
    }
}

// MARK: - Window

/// The "Sounds & Keys" tab: library, pad and inspector.
struct PadView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            LibraryPanel(model: model)
                .frame(width: 260)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                PageBar(model: model)
                KeyGrid(model: model)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 480)

            Divider()

            Group {
                switch model.selection {
                case let .key(index):
                    KeyInspector(model: model, index: index)
                case let .sound(id) where model.entry(id) != nil:
                    SoundInspector(model: model, id: id)
                default:
                    Text("Select a sound or a key").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 330)
        }
    }
}

// MARK: - Library

private struct LibraryPanel: View {
    @ObservedObject var model: SettingsModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sounds").font(.headline)
                Text("\(model.config.library.count)").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Import Audio Files…") {
                        model.importSounds(model.choose([.audio, .movie], multiple: true))
                    }
                    Button("New Sound from YouTube or a Website…") { model.openClipEditor?(.library, nil) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add sounds to the library")
            }
            TextField("Search", text: $model.search, prompt: Text("Search sounds"))
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.filteredLibrary) { entry in
                        LibraryRow(model: model, entry: entry)
                    }
                }
            }
            .overlay {
                if model.config.library.isEmpty {
                    Text("Drop audio files here, or use + to make one from YouTube or a website.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }

            Text("Drag a sound onto a key. Drag a key back here to take it off the pad; the sound stays in your library.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(targeted ? 0.6 : 0.35))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.green, lineWidth: targeted ? 2 : 0))
        .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
            Payload.receive(providers, files: { model.importSounds($0) },
                            key: { index in
                                let id = model.button(index)?.sound
                                model.setButton(index, nil)
                                if let id, model.entry(id) != nil { model.selection = .sound(id) }
                            })
        }
    }
}

private struct LibraryRow: View {
    @ObservedObject var model: SettingsModel
    let entry: SoundEntry
    @State private var confirmDelete = false

    var body: some View {
        let _ = model.revision
        let selected = model.selection == .sound(entry.id)
        let face = KeyFace(label: entry.label, image: entry.image, color: entry.color, soundFile: entry.file)
        let uses = model.config.usages(of: entry.id).count
        HStack(spacing: 10) {
            Image(decorative: model.assets.render(face, size: 96, active: false), scale: 2)
                .resizable().frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? "Untitled" : entry.name).lineLimit(1)
                HStack(spacing: 6) {
                    if let duration = model.duration(entry) {
                        Text(String(format: "%.1fs", duration)).monospacedDigit()
                    } else {
                        Label("Missing file", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    if entry.mode == .overlay { Image(systemName: "square.2.layers.3d") }
                    Text(uses == 0 ? "not on pad" : uses == 1 ? "on pad" : "on \(uses) keys")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .sound(entry.id) }
        // Simultaneous, so a single click still selects without waiting out the double-click interval.
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.preview(entry) })
        .onDrag { NSItemProvider(object: (Payload.sound + entry.id) as NSString) }
        .contextMenu {
            Button("Place on First Empty Key") { model.placeOnFirstEmptyKey(entry.id) }
            Button("Preview") { model.preview(entry) }
            Divider()
            Button("Delete from Library…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(entry.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteSound(entry.id) }
        } message: {
            Text("It's removed from every key, and its audio file goes to the Trash.")
        }
    }
}

// MARK: - Pad

private struct PageBar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack {
            Button { model.page = max(0, model.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.page == 0)
                .onDrop(of: [.plainText], isTargeted: nil) { moveDropped($0, by: -1) }
            Text("Page \(model.page + 1) of \(model.config.pages.count)")
                .font(.headline).monospacedDigit().frame(minWidth: 110)
            Button { model.page = min(model.config.pages.count - 1, model.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.page >= model.config.pages.count - 1)
                .onDrop(of: [.plainText], isTargeted: nil) { moveDropped($0, by: 1) }
            Spacer()
            Button("Add Page", systemImage: "plus") { model.addPage() }
            Button("Delete Page", systemImage: "trash") { model.deletePage() }
                .disabled(model.config.pages.count <= 1)
        }
        .labelStyle(.iconOnly)
        .help(pageHelp)
    }

    private var pageHelp: String {
        let m = model.config.shortcuts.symbols
        let shortcuts = model.config.shortcuts == .off ? "" : " (or \(m)[ and \(m)])"
        return "The touch buttons under the Neo's screen\(shortcuts) switch pages. Drop a key on an arrow to move it there."
    }

    private func moveDropped(_ providers: [NSItemProvider], by delta: Int) -> Bool {
        Payload.receive(providers, files: { _ in }, key: { index in
            let target = model.page + delta
            if target >= 0 { model.move(index, toPage: target) }
        })
    }
}

private struct KeyGrid: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let rows = (model.keyCount + model.columns - 1) / model.columns
        VStack(spacing: 10) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(0..<model.columns, id: \.self) { col in
                        let index = row * model.columns + col
                        if index < model.keyCount { KeyCell(model: model, index: index) }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.85)))
        Text("Drag keys to swap them, or onto the page arrows to move them to another page.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct KeyCell: View {
    @ObservedObject var model: SettingsModel
    let index: Int
    @State private var targeted = false

    var body: some View {
        let _ = model.revision
        let button = model.button(index)
        let image = model.assets.render(model.config.face(button), size: 224, active: false)
        let selected = model.selection == .key(index)
        let highlighted: Bool = {
            if case let .sound(id) = model.selection { return button?.sound == id && button?.action == nil }
            return false
        }()
        Image(decorative: image, scale: 2)
            .resizable()
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if button?.action == nil, model.config.entry(button?.sound)?.mode == .overlay {
                    Image(systemName: "square.2.layers.3d.fill")
                        .font(.system(size: 11)).padding(4)
                        .background(Circle().fill(.black.opacity(0.6))).foregroundStyle(.white)
                        .padding(4)
                        .help("Overlay: plays on top of other sounds")
                }
            }
            .overlay(alignment: .topTrailing) {
                if button != nil, model.config.shortcuts != .off, index < 10 {
                    Text(model.config.shortcuts.symbols + ShortcutCommand.key(index).keyName)
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white)
                        .padding(4)
                        .help("Keyboard shortcut, on the page the Stream Deck shows (Settings tab)")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(targeted ? Color.green : selected || highlighted ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: selected || targeted ? 3 : highlighted ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { model.selection = .key(index) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if button?.action == nil, let entry = model.config.entry(button?.sound) { model.preview(entry) }
            })
            .onDrag { NSItemProvider(object: (Payload.key + String(index)) as NSString) }
            .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
                Payload.receive(providers,
                                files: { urls in urls.first.map { model.useFile($0, forKey: index) } },
                                key: { from in model.swap(from, index) },
                                sound: { id in model.place(id, on: index) })
            }
    }
}

// MARK: - Inspectors

private enum KeyKind: String, CaseIterable, Identifiable {
    case empty = "Empty", sound = "Sound", stop = "Stop All", censor = "Bleep (hold)"
    var id: String { rawValue }
}

private struct KeyInspector: View {
    @ObservedObject var model: SettingsModel
    let index: Int

    private var button: ButtonConfig? { model.button(index) }

    private var kind: Binding<KeyKind> {
        Binding {
            guard let button = model.button(index) else { return .empty }
            switch button.action {
            case .stop: return .stop
            case .censor: return .censor
            case nil: return .sound
            }
        } set: { kind in
            switch kind {
            case .empty: model.setButton(index, nil)
            case .sound: model.setButton(index, ButtonConfig())
            case .stop: model.setButton(index, ButtonConfig(action: .stop, label: "STOP", color: "#dc2626"))
            case .censor: model.setButton(index, ButtonConfig(action: .censor, label: "BLEEP", color: "#111827"))
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Key does", selection: kind) {
                    ForEach(KeyKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if kind.wrappedValue == .sound {
                    Picker("Sound", selection: Binding {
                        model.button(index)?.sound ?? ""
                    } set: { id in
                        model.setButton(index, id.isEmpty ? ButtonConfig() : ButtonConfig(sound: id))
                    }) {
                        Text("Choose…").tag("")
                        ForEach(model.config.library.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                            Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.id)
                        }
                    }
                    if button?.sound == nil {
                        Text("Or drag a sound from the library onto the key.").font(.caption).foregroundStyle(.secondary)
                        Button("Make a New Sound for This Key…") { model.openClipEditor?(.key(page: model.page, index: index), nil) }
                    }
                }
            } header: {
                Text("Key \(index + 1) · Page \(model.page + 1)").font(.headline)
            }

            if let button, button.action != nil {
                KeyCapFields(label: Binding { model.button(index)?.label } set: { v in model.editButton(index) { $0.label = v } },
                             image: Binding { model.button(index)?.image } set: { v in model.editButton(index) { $0.image = v } },
                             color: Binding { model.button(index)?.color } set: { v in model.editButton(index) { $0.color = v } },
                             chooseImage: {
                                 if let url = model.choose([.image]).first { model.useFile(url, forKey: index) }
                             })
            }

            if let id = button?.sound, button?.action == nil, model.entry(id) != nil {
                let uses = model.config.usages(of: id).count
                if uses > 1 {
                    Text("This sound is on \(uses) keys. Changes below apply to all of them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SoundFields(model: model, id: id)
            }

            if button != nil {
                Section {
                    HStack {
                        Menu("Move to Page") {
                            ForEach(model.config.pages.indices.filter { $0 != model.page }, id: \.self) { target in
                                let full = model.firstEmptySlot(onPage: target) == nil
                                Button(full ? "Page \(target + 1) (full)" : "Page \(target + 1)") {
                                    model.move(index, toPage: target)
                                }
                                .disabled(full)
                            }
                            Divider()
                            Button("New Page") { model.move(index, toPage: model.config.pages.count) }
                        }
                        .fixedSize()
                        Spacer()
                        Button("Take Off Pad") { model.setButton(index, nil) }
                            .help("Clears this key. The sound stays in your library.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundInspector: View {
    @ObservedObject var model: SettingsModel
    let id: String
    @State private var confirmDelete = false

    var body: some View {
        let entry = model.entry(id)
        let uses = model.config.usages(of: id)
        Form {
            Section {
                Text(entry?.name ?? "").font(.headline)
            }
            SoundFields(model: model, id: id)
            Section("On the pad") {
                if uses.isEmpty {
                    Text("Not on any key").foregroundStyle(.secondary)
                } else {
                    ForEach(uses, id: \.key) { use in
                        Button("Page \(use.page + 1) · Key \(use.key + 1)") {
                            model.page = use.page
                            model.selection = .key(use.key)
                        }
                        .buttonStyle(.link)
                    }
                }
                Button("Place on First Empty Key") { model.placeOnFirstEmptyKey(id) }
            }
            Section {
                Button("Delete from Library…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete “\(entry?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteSound(id) }
        } message: {
            Text("It's removed from every key, and its audio file goes to the Trash.")
        }
    }
}

/// Settings stored on the library sound (shared by every key that plays it).
private struct SoundFields: View {
    @ObservedObject var model: SettingsModel
    let id: String

    private var entry: SoundEntry? { model.entry(id) }

    var body: some View {
        Section("Sound") {
            TextField("Name", text: Binding { entry?.name ?? "" } set: { v in model.editEntry(id) { $0.name = v } },
                      prompt: Text("Shown in the library and on the Neo's screen"))
            HStack {
                Text(entry?.file ?? "").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Preview", systemImage: "play.fill") { if let entry { model.preview(entry) } }
                    .labelStyle(.iconOnly)
                    .help("Plays on this Mac only, not to the output")
            }
            HStack {
                Button("Replace Audio…") {
                    if let url = model.choose([.audio, .movie]).first { model.useFile(url, forSound: id) }
                }
                Button("Re-clip in Sound Editor…") { model.openClipEditor?(.replace(soundID: id), nil) }
            }
            Picker("When pressed", selection: Binding { entry?.mode ?? .toggle } set: { mode in
                model.editEntry(id) { $0.mode = mode == .toggle ? nil : mode }
            }) {
                Text("Tap to start / stop").tag(ButtonConfig.Mode.toggle)
                Text("Overlay on top").tag(ButtonConfig.Mode.overlay)
            }
            .pickerStyle(.radioGroup)
            LabeledContent("Volume") {
                Slider(value: Binding { Double(entry?.volume ?? 1) } set: { value in
                    model.editEntry(id) { $0.volume = value >= 0.995 ? nil : Float(value) }
                }, in: 0...1)
            }
        }
        KeyCapFields(label: Binding { entry?.label } set: { v in model.editEntry(id) { $0.label = v } },
                     image: Binding { entry?.image } set: { v in model.editEntry(id) { $0.image = v } },
                     color: Binding { entry?.color } set: { v in model.editEntry(id) { $0.color = v } },
                     chooseImage: {
                         if let url = model.choose([.image]).first { model.useFile(url, forSound: id) }
                     })
    }
}

private struct KeyCapFields: View {
    @Binding var label: String?
    @Binding var image: String?
    @Binding var color: String?
    let chooseImage: () -> Void

    var body: some View {
        Section("Key cap") {
            TextField("Label", text: Binding { label ?? "" } set: { label = $0.isEmpty ? nil : $0 },
                      prompt: Text("Text on the key"))
            HStack {
                Text("Image")
                Spacer()
                if let image {
                    Text(image).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Remove", systemImage: "xmark.circle.fill") { self.image = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                Button("Choose…", action: chooseImage)
            }
            ColorPicker("Background", selection: Binding {
                Color(cgColor: KeyRenderer.color(hex: color))
            } set: { newColor in
                color = Self.hex(newColor)
            }, supportsOpacity: false)
            .disabled(image != nil)
            .help(image != nil ? "The image covers the background" : "")
        }
    }

    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
