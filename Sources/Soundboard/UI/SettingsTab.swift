import ServiceManagement
import SwiftUI

/// The Settings tab: how you play the keys (Stream Deck, on-screen palette, keyboard) and app-level
/// options. Everything about the signal itself is on the Audio tab.
struct SettingsTab: View {
    @ObservedObject var settings: SettingsModel
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Stream Deck") {
                LabeledContent("Brightness") {
                    HStack {
                        Slider(value: Binding { Double(settings.config.brightness) } set: { value in
                            settings.update { $0.brightness = Int(value) }
                        }, in: 10...100)
                        Text("\(settings.config.brightness)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                Picker("Screen corner", selection: binding(\.hotCorner)) {
                    ForEach(HotCorner.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("On-Screen Palette")
            } footer: {
                Text("Rest the pointer in this corner of the screen to fan out the pad's keys, so you can play sounds without a Stream Deck. The palette doesn't take focus from your call. Pick a corner macOS isn't using for Hot Corners (System Settings › Desktop & Dock).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Modifier keys", selection: binding(\.shortcuts)) {
                    ForEach(ShortcutModifiers.allCases) { Text($0.title).tag($0) }
                }
                let m = settings.config.shortcuts.symbols
                if settings.config.shortcuts != .off {
                    LabeledContent("Play key 1 to 10", value: "\(m)1 … \(m)0")
                    LabeledContent("Previous / next page", value: "\(m)[  \(m)]")
                    LabeledContent("Stop all sounds", value: "\(m).")
                    LabeledContent("Show or hide the palette", value: "\(m)P")
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Work from any app, without taking focus from it. Keys are numbered like the pad (left to right, top to bottom) on the page the Stream Deck shows. Number-row and numeric-keypad digits both work. A Bleep key bleeps while you hold its shortcut. If they clash with another app's shortcuts, pick other modifier keys.")
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                Toggle(isOn: binding(\.stopOthers)) {
                    Text("New sound stops the previous one")
                    Text("Only for tap-to-start/stop sounds; overlays always layer.")
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding { openAtLogin } set: { setOpenAtLogin($0) })
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            openAtLogin = SMAppService.mainApp.status == .enabled // the menu bar menu can change it too
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding { settings.config[keyPath: keyPath] } set: { value in settings.update { $0[keyPath: keyPath] = value } }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
