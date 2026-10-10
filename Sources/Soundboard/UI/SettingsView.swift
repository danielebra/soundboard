import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Bridges the app's config to SwiftUI. Edits are applied (and saved) shortly after they stop.
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var page = 0
    @Published var selected: Int? = 0
    @Published var devices: [AudioDevice] = AudioDevices.all()
    /// Bumped when key images may have changed on disk.
    @Published var revision = 0

    let keyCount: Int
    let columns: Int
    let assets: AssetCache
    private let commit: (Config) -> Void
    private var pending: DispatchWorkItem?
    private var previewPlayer: AVAudioPlayer?
    var openClipEditor: ((_ page: Int, _ key: Int, _ file: URL?) -> Void)?

    init(config: Config, keyCount: Int, columns: Int, assets: AssetCache, commit: @escaping (Config) -> Void) {
        self.config = config
        self.keyCount = keyCount
        self.columns = columns
        self.assets = assets
        self.commit = commit
        normalizePages()
        if self.config.pages != config.pages { commit(self.config) }
    }

    /// Called when the config changed elsewhere (file edited by hand).
    func external(_ config: Config) {
        guard config != self.config else { return }
        self.config = config
        normalizePages()
        page = min(page, config.pages.count - 1)
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
            self.commit(self.config)
            self.revision += 1
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func button(_ index: Int) -> ButtonConfig? {
        guard config.pages.indices.contains(page), config.pages[page].indices.contains(index) else { return nil }
        return config.pages[page][index]
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
        selected = b
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
        selected = slot
    }

    func addPage() {
        update { $0.pages.append(Array(repeating: nil, count: keyCount)) }
        page = config.pages.count - 1
        selected = 0
    }

    func deletePage() {
        guard config.pages.count > 1 else { return }
        let page = self.page
        update { $0.pages.remove(at: page) }
        self.page = max(0, page - 1)
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

    /// Handles a file dropped or chosen for a key: audio → sound, image → key cap, video → clip editor.
    func useFile(_ url: URL, for index: Int) {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let name = importFile(url, into: Paths.icons) else { return }
            editButton(index) { $0.image = name }
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            openClipEditor?(page, index, url)
        } else if type.conforms(to: .audio) {
            guard let name = importFile(url, into: Paths.sounds) else { return }
            editButton(index) {
                $0.sound = name
                $0.action = nil
                if $0.name == nil { $0.name = url.deletingPathExtension().lastPathComponent }
                if $0.label == nil && $0.image == nil { $0.label = $0.name }
            }
        }
        selected = index
    }

    func choose(_ types: [UTType], for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFile(url, for: index)
    }

    func preview(_ index: Int) {
        guard let path = button(index)?.sound else { return }
        if previewPlayer?.isPlaying == true {
            previewPlayer?.stop()
            previewPlayer = nil
            return
        }
        previewPlayer = try? AVAudioPlayer(contentsOf: Paths.resolve(path, in: Paths.sounds))
        previewPlayer?.volume = button(index)?.volume ?? 1
        previewPlayer?.play()
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageBar(model: model)
                KeyGrid(model: model)
                Divider()
                AudioSettings(model: model)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 480)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                if let index = model.selected {
                    KeyInspector(model: model, index: index)
                } else {
                    Text("Select a key to customise it").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 320)
        }
        .frame(minHeight: 620)
    }
}

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
        .help("The touch buttons under the Neo's screen switch pages. Drop a key on an arrow to move it there.")
    }

    /// A key dragged onto an arrow moves to the previous/next page (next past the end makes a new page).
    private func moveDropped(_ providers: [NSItemProvider], by delta: Int) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let text = text as? String, text.hasPrefix("soundboard-key:"),
                  let index = Int(text.dropFirst("soundboard-key:".count)) else { return }
            DispatchQueue.main.async {
                let target = model.page + delta
                if target >= 0 { model.move(index, toPage: target) }
            }
        }
        return true
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
        Text("Click a key to edit it. Drop a sound, image or video on a key. Drag keys to swap them, or onto the page arrows to move them to another page.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct KeyCell: View {
    @ObservedObject var model: SettingsModel
    let index: Int
    @State private var targeted = false

    var body: some View {
        let _ = model.revision
        let image = model.assets.render(model.button(index), size: 192, active: false)
        let selected = model.selected == index
        Image(decorative: image, scale: 2)
            .resizable()
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if model.button(index)?.mode == .overlay {
                    Image(systemName: "square.2.layers.3d.fill")
                        .font(.system(size: 11)).padding(4)
                        .background(Circle().fill(.black.opacity(0.6))).foregroundStyle(.white)
                        .padding(4)
                        .help("Overlay: plays on top of other sounds")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(targeted ? Color.green : selected ? Color.accentColor : Color.white.opacity(0.15),
                        lineWidth: selected || targeted ? 3 : 1))
            .contentShape(Rectangle())
            .onTapGesture { model.selected = index }
            .onDrag { NSItemProvider(object: "soundboard-key:\(index)" as NSString) }
            .onDrop(of: [.fileURL, .plainText], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                if provider.canLoadObject(ofClass: URL.self), provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { model.useFile(url, for: index) }
                    }
                    return true
                }
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String, text.hasPrefix("soundboard-key:"),
                          let from = Int(text.dropFirst("soundboard-key:".count)) else { return }
                    DispatchQueue.main.async { model.swap(from, index) }
                }
                return true
            }
    }
}

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
            case .sound: model.editButton(index) { $0.action = nil }
            case .stop: model.editButton(index) { $0.action = .stop; if $0.label == nil { $0.label = "STOP"; $0.color = "#dc2626" } }
            case .censor: model.editButton(index) { $0.action = .censor; if $0.label == nil { $0.label = "BLEEP"; $0.color = "#111827" } }
            }
        }
    }

    private func text(_ keyPath: WritableKeyPath<ButtonConfig, String?>) -> Binding<String> {
        Binding {
            model.button(index)?[keyPath: keyPath] ?? ""
        } set: { value in
            model.editButton(index) { $0[keyPath: keyPath] = value.isEmpty ? nil : value }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Key does", selection: kind) {
                    ForEach(KeyKind.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Key \(index + 1) · Page \(model.page + 1)").font(.headline)
            }

            if button != nil {
                Section("Key cap") {
                    TextField("Label", text: text(\.label), prompt: Text("Text on the key"))
                    HStack {
                        Text("Image")
                        Spacer()
                        if let image = button?.image {
                            Text(image).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Remove", systemImage: "xmark.circle.fill") { model.editButton(index) { $0.image = nil } }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        Button("Choose…") { model.choose([.image], for: index) }
                    }
                    ColorPicker("Background", selection: Binding {
                        Color(cgColor: KeyRenderer.color(hex: model.button(index)?.color))
                    } set: { color in
                        model.editButton(index) { $0.color = Self.hex(color) }
                    }, supportsOpacity: false)
                    .disabled(button?.image != nil)
                    .help(button?.image != nil ? "The image covers the background" : "")
                }
            }

            if kind.wrappedValue == .sound {
                Section("Sound") {
                    HStack {
                        Text(button?.sound ?? "No sound").lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(button?.sound == nil ? .secondary : .primary)
                        Spacer()
                        Button("Preview", systemImage: "play.fill") { model.preview(index) }
                            .labelStyle(.iconOnly).disabled(button?.sound == nil)
                            .help("Plays on this Mac only, not into Zoom")
                    }
                    HStack {
                        Button("Choose File…") { model.choose([.audio, .movie], for: index) }
                        Button("Clip from YouTube…") { model.openClipEditor?(model.page, index, nil) }
                    }
                    TextField("Screen name", text: text(\.name), prompt: Text("Shown on the Neo's screen"))
                    Picker("When pressed", selection: Binding {
                        model.button(index)?.mode ?? .toggle
                    } set: { mode in
                        model.editButton(index) { $0.mode = mode == .toggle ? nil : mode }
                    }) {
                        Text("Tap to start / stop").tag(ButtonConfig.Mode.toggle)
                        Text("Overlay on top").tag(ButtonConfig.Mode.overlay)
                    }
                    .pickerStyle(.radioGroup)
                    LabeledContent("Volume") {
                        Slider(value: Binding {
                            Double(model.button(index)?.volume ?? 1)
                        } set: { value in
                            model.editButton(index) { $0.volume = value >= 0.995 ? nil : Float(value) }
                        }, in: 0...1)
                    }
                }
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
                        Button("Clear Key", role: .destructive) { model.setButton(index, nil) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

private struct AudioSettings: View {
    @ObservedObject var model: SettingsModel

    private func devicePicker(_ title: String, _ keyPath: WritableKeyPath<Config, String?>, output: Bool) -> some View {
        Picker(title, selection: Binding {
            model.config[keyPath: keyPath] ?? ""
        } set: { value in
            model.update { $0[keyPath: keyPath] = value.isEmpty ? nil : value }
        }) {
            Text("System default").tag("")
            ForEach(model.devices.filter { output ? $0.outputChannels > 0 : $0.inputChannels > 0 }, id: \.id) {
                Text($0.name).tag($0.name)
            }
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<Config, Float>) -> some View {
        LabeledContent(title) {
            Slider(value: Binding { Double(model.config[keyPath: keyPath]) } set: { value in
                model.update { $0[keyPath: keyPath] = Float(value) }
            }, in: 0...1)
        }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Picker("Zoom hears", selection: Binding { model.config.outputDevice } set: { value in
                    model.update { $0.outputDevice = value }
                }) {
                    ForEach(model.devices.filter { $0.outputChannels > 0 }, id: \.id) { Text($0.name).tag($0.name) }
                    if !model.devices.contains(where: { $0.name == model.config.outputDevice }) {
                        Text("\(model.config.outputDevice) (missing)").tag(model.config.outputDevice)
                    }
                }
                slider("Sounds", \.soundVolume)
            }
            GridRow {
                devicePicker("Microphone", \.micDevice, output: false)
                slider("Mic", \.micVolume)
            }
            GridRow {
                devicePicker("You hear on", \.monitorDevice, output: true)
                slider("Monitor", \.monitorVolume)
            }
            GridRow {
                Toggle("Send microphone through", isOn: Binding { model.config.micPassthrough } set: { value in
                    model.update { $0.micPassthrough = value }
                })
                Toggle("Hear sounds myself", isOn: Binding { model.config.monitor } set: { value in
                    model.update { $0.monitor = value }
                })
            }
            GridRow {
                Toggle("New sound stops the previous one", isOn: Binding { model.config.stopOthers } set: { value in
                    model.update { $0.stopOthers = value }
                })
                .help("Only applies to tap-to-start/stop keys; overlays always layer")
                LabeledContent("Brightness") {
                    Slider(value: Binding { Double(model.config.brightness) } set: { value in
                        model.update { $0.brightness = Int(value) }
                    }, in: 10...100)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.devices = AudioDevices.all()
        }
    }
}
