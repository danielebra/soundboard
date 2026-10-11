import AppKit
import SwiftUI

/// One level meter. Only its `MeterView` observes it, so a level change redraws the meter
/// and not the whole tab, and it publishes only when what's drawn changes (silence costs nothing).
final class LevelMeter: ObservableObject {
    static let floor: Float = -60
    /// Displayed level in dBFS (falls back smoothly), plus a held peak.
    @Published private(set) var level = floor
    @Published private(set) var peak = floor
    private var peakAge = 0

    func feed(_ linear: Float) {
        let db = max(Self.floor, linear > 0 ? 20 * log10(linear) : Self.floor)
        var level = max(db, self.level - 1.5) // ~45 dB/s fall at 30 fps
        var peak = self.peak
        if db >= peak { peak = db; peakAge = 0 } else if peakAge > 45 { peak = max(level, peak - 1) } else { peakAge += 1 }
        // A tenth of a dB is well under a pixel.
        level = (level * 10).rounded() / 10
        peak = (peak * 10).rounded() / 10
        if level != self.level { self.level = level }
        if peak != self.peak { self.peak = peak }
    }
}

/// Polls the router for meter levels and the input test while the Audio tab is visible.
final class AudioMonitor: ObservableObject {
    enum Playback { case cleaned, original }

    let mic = LevelMeter()
    let cleaned = LevelMeter()
    let output = LevelMeter()
    /// Seconds recorded so far, nil when not recording.
    @Published var recordElapsed: Double?
    @Published var clip: MicClip?
    @Published var playing: Playback?
    @Published var canRecord = false
    @Published var canPlay = false

    let router: AudioRouter
    /// Recording stops on its own after this.
    let maxRecordSeconds = 120.0
    private var timer: Timer?

    init(router: AudioRouter) {
        self.router = router
    }

    func start() {
        guard timer == nil else { return }
        router.setDemand(.audioTab, true) // meters and the input test need the audio running
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        guard timer != nil else { return }
        router.setDemand(.audioTab, false)
        timer?.invalidate()
        timer = nil
        stopPlayback()
        if recordElapsed != nil { router.cancelTestRecording(); recordElapsed = nil }
    }

    private func tick() {
        let levels = router.levels
        mic.feed(levels.mic)
        cleaned.feed(levels.cleaned)
        output.feed(levels.output)
        let elapsed = router.testRecordedSeconds?.rounded(.down) // shown in whole seconds
        if elapsed != recordElapsed { recordElapsed = elapsed }
        if let finished = router.takeTestRecording() { clip = finished }
        if canRecord != router.canRecordTest { canRecord = router.canRecordTest }
        if canPlay != router.canPlayTest { canPlay = router.canPlayTest }
    }

    func record() {
        stopPlayback()
        router.startTestRecording(maxSeconds: maxRecordSeconds)
        recordElapsed = 0
    }

    func finishRecording() {
        router.finishTestRecording()
        recordElapsed = nil
    }

    func play(_ kind: Playback, config: Config) {
        guard let clip else { return }
        playing = kind
        router.playTest(clip, cleaned: kind == .cleaned, config: config) { [weak self] in
            if self?.playing == kind { self?.playing = nil }
        }
    }

    func stopPlayback() {
        router.stopTest()
        playing = nil
    }
}

/// The Audio tab, laid out in signal order: input → processing → output mix → monitor.
struct AudioTab: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var monitor: AudioMonitor
    let status: AppStatus

    var body: some View {
        Form {
            input
            processing
            inputTest
            output
            monitorSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.devices = AudioDevices.all()
        }
    }

    // MARK: Sections

    private var input: some View {
        Section("Input") {
            devicePicker("Input device", \.micDevice, output: false)
            Toggle("Route input to output", isOn: binding(\.micPassthrough))
            LabeledContent("Level") {
                MeterView(meter: monitor.mic, active: status.mic != nil)
            }
            if let problem = status.micProblem, settings.config.micPassthrough {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var processing: some View {
        Section {
            Toggle(isOn: binding(\.noiseSuppression)) {
                Text("Noise removal")
                Text("Apple voice isolation, on this Mac. Adds about 56 ms of delay while on.")
            }
            percentSlider("Strength", \.noiseSuppressionStrength)
                .disabled(!settings.config.noiseSuppression)
            LabeledContent("Level") {
                MeterView(meter: monitor.cleaned, active: status.mic != nil && status.output != nil)
            }
        } header: {
            Text("Input processing")
        } footer: {
            Text("Applies to the input only. Sounds are mixed in afterwards, untouched.")
                .foregroundStyle(.secondary)
        }
    }

    private var inputTest: some View {
        Section {
            HStack(spacing: 10) {
                if let elapsed = monitor.recordElapsed {
                    Button("Stop", systemImage: "stop.fill") { monitor.finishRecording() }
                    Image(systemName: "circle.fill").foregroundStyle(.red).font(.caption)
                    Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)).monospacedDigit()
                    Text("Recording… say something, then press Stop").foregroundStyle(.secondary)
                } else {
                    Button(monitor.clip == nil ? "Record" : "Record again", systemImage: "record.circle") {
                        monitor.record()
                    }
                        .disabled(!monitor.canRecord)
                    Divider().frame(height: 18)
                    playButton("Play processed", .cleaned)
                    playButton("Play unprocessed", .original)
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            if let hint = testHint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Test input")
        } footer: {
            Text("Plays on the monitor device only, never to the output. Change the settings and play again to hear the same recording with them.")
                .foregroundStyle(.secondary)
        }
    }

    private var output: some View {
        Section {
            Picker("Output device", selection: binding(\.outputDevice)) {
                ForEach(settings.devices.filter { $0.outputChannels > 0 }, id: \.id) { Text($0.name).tag($0.name) }
                if !settings.devices.contains(where: { $0.name == settings.config.outputDevice }) {
                    Text("\(settings.config.outputDevice) (missing)").tag(settings.config.outputDevice)
                }
            }
            percentSlider("Input volume", \.micVolume)
            percentSlider("Sounds volume", \.soundVolume)
            LabeledContent("Level") {
                MeterView(meter: monitor.output, active: status.output != nil)
            }
            if let device = status.connecting {
                Label("Opening \(device)… If this doesn't go away, its driver is stuck: restart your Mac.",
                      systemImage: "hourglass").foregroundStyle(.orange)
            } else if let problem = status.outputProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("Output")
        } footer: {
            Text("The processed input and the sounds are mixed into this device. Select it as the microphone in Zoom, Google Meet, Teams, Discord or any other app. Turn off that app's own noise filtering (in Zoom: **Original sound for musicians**) so it doesn't remove the sounds.")
                .foregroundStyle(.secondary)
        }
    }

    private var monitorSection: some View {
        Section {
            devicePicker("Monitor device", \.monitorDevice, output: true)
            Toggle("Monitor sounds", isOn: binding(\.monitor))
            percentSlider("Volume", \.monitorVolume)
                .disabled(!settings.config.monitor)
        } header: {
            Text("Monitor")
        } footer: {
            Text("Where you hear the sounds and input tests. Use headphones so the input doesn't pick the sounds up a second time.")
                .foregroundStyle(.secondary)
        }
    }

    /// Why the input test can't run, if it can't.
    private var testHint: String? {
        if !monitor.canRecord {
            if !settings.config.micPassthrough { return "Turn on “Route input to output” to record." }
            return status.micProblem ?? "The input device isn't running."
        }
        if !monitor.canPlay {
            if !settings.config.monitor { return "Playback uses the monitor device. Turn on “Monitor sounds” below." }
            return "The monitor device isn't available."
        }
        return nil
    }

    // MARK: Controls

    private func playButton(_ title: String, _ kind: AudioMonitor.Playback) -> some View {
        Button {
            if monitor.playing == kind { monitor.stopPlayback() } else { monitor.play(kind, config: settings.config) }
        } label: {
            Label(monitor.playing == kind ? "Stop" : title, systemImage: monitor.playing == kind ? "stop.fill" : "play.fill")
        }
        .disabled(monitor.clip == nil || !monitor.canPlay)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding { settings.config[keyPath: keyPath] } set: { value in settings.update { $0[keyPath: keyPath] = value } }
    }

    private func devicePicker(_ title: String, _ keyPath: WritableKeyPath<Config, String?>, output: Bool) -> some View {
        Picker(title, selection: Binding {
            settings.config[keyPath: keyPath] ?? ""
        } set: { value in
            settings.update { $0[keyPath: keyPath] = value.isEmpty ? nil : value }
        }) {
            Text("System default").tag("")
            ForEach(settings.devices.filter { output ? $0.outputChannels > 0 : $0.inputChannels > 0 }, id: \.id) {
                Text($0.name).tag($0.name)
            }
        }
    }

    private func percentSlider(_ title: String, _ keyPath: WritableKeyPath<Config, Float>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding { Double(settings.config[keyPath: keyPath]) } set: { value in
                    settings.update { $0[keyPath: keyPath] = Float(value) }
                }, in: 0...1)
                Text("\(Int((settings.config[keyPath: keyPath] * 100).rounded()))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// A horizontal level meter from -60 to 0 dBFS, coloured by position, with a peak marker.
/// Drawn in a Canvas, so a new level redraws it without laying out the rest of the window.
struct MeterView: View {
    @ObservedObject var meter: LevelMeter
    var active = true

    /// -60…-12 green, -12…-3 yellow, -3…0 red.
    private static let gradient = Gradient(stops: [
        .init(color: .green, location: 0), .init(color: .green, location: 0.79),
        .init(color: .yellow, location: 0.81), .init(color: .yellow, location: 0.94),
        .init(color: .red, location: 0.96), .init(color: .red, location: 1),
    ])

    private static func fraction(_ db: Float) -> CGFloat {
        CGFloat((db - LevelMeter.floor) / -LevelMeter.floor).clamped(to: 0...1)
    }

    var body: some View {
        let level = meter.level, peak = meter.peak
        let label = active ? (peak > LevelMeter.floor ? String(format: "%.0f dB", peak) : "silent") : "off"
        Canvas { context, size in
            let textWidth: CGFloat = 48, spacing: CGFloat = 8
            let bar = CGRect(x: 0, y: ((size.height - 10) / 2).rounded(), width: max(0, size.width - textWidth - spacing),
                             height: 10)
            let track = Path(roundedRect: bar, cornerRadius: 3)
            context.fill(track, with: .color(.primary.opacity(0.08)))
            let filled = bar.width * Self.fraction(level)
            if filled > 0 {
                var clipped = context
                clipped.clip(to: track)
                clipped.fill(Path(CGRect(x: bar.minX, y: bar.minY, width: filled, height: bar.height)),
                             with: .linearGradient(Self.gradient, startPoint: CGPoint(x: bar.minX, y: 0),
                                                   endPoint: CGPoint(x: bar.maxX, y: 0)))
            }
            if peak > LevelMeter.floor {
                let x = max(0, bar.width * Self.fraction(peak) - 2)
                context.fill(Path(CGRect(x: x, y: bar.minY, width: 2, height: bar.height)),
                             with: .color(peak > -3 ? .red : .primary.opacity(0.6)))
            }
            context.draw(Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: size.width, y: size.height / 2), anchor: .trailing)
        }
        .frame(minWidth: 200)
        .frame(height: 14)
        .opacity(active ? 1 : 0.4)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
