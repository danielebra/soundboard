import AppKit
import SwiftUI

/// Polls the router for meter levels and the input test while the Audio tab is visible.
final class AudioMonitor: ObservableObject {
    enum Playback { case cleaned, original }

    /// Displayed levels in dBFS (meters fall back smoothly), plus a held peak for each.
    @Published var mic = Meter()
    @Published var cleaned = Meter()
    @Published var output = Meter()
    /// Seconds recorded so far, nil when not recording.
    @Published var recordElapsed: Double?
    @Published var clip: MicClip?
    @Published var playing: Playback?
    @Published var canRecord = false
    @Published var canPlay = false

    struct Meter: Equatable {
        static let floor: Float = -60
        var level = floor
        var peak = floor
        var peakAge = 0

        mutating func feed(_ linear: Float) {
            let db = max(Self.floor, linear > 0 ? 20 * log10(linear) : Self.floor)
            level = max(db, level - 1.5) // ~45 dB/s fall at 30 fps
            if db >= peak { peak = db; peakAge = 0 } else if peakAge > 45 { peak = max(level, peak - 1) } else { peakAge += 1 }
        }
    }

    let router: AudioRouter
    /// Recording stops on its own after this.
    let maxRecordSeconds = 120.0
    private var timer: Timer?

    init(router: AudioRouter) {
        self.router = router
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
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
        let elapsed = router.testRecordedSeconds
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
            deck
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
            Text("The processed input and the sounds are mixed into this device. Select it as the microphone in your call app (Zoom, Meet, …); in Zoom, also tick **Original sound for musicians** so Zoom doesn't filter the sounds out.")
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

    private var deck: some View {
        Section("Stream Deck") {
            Toggle(isOn: binding(\.stopOthers)) {
                Text("New sound stops the previous one")
                Text("Only for tap-to-start/stop sounds; overlays always layer.")
            }
            LabeledContent("Brightness") {
                HStack {
                    Slider(value: Binding { Double(settings.config.brightness) } set: { value in
                        settings.update { $0.brightness = Int(value) }
                    }, in: 10...100)
                    Text("\(settings.config.brightness)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
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
struct MeterView: View {
    let meter: AudioMonitor.Meter
    var active = true

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat((db - AudioMonitor.Meter.floor) / -AudioMonitor.Meter.floor).clamped(to: 0...1)
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    // -60…-12 green, -12…-3 yellow, -3…0 red.
                    LinearGradient(stops: [
                        .init(color: .green, location: 0), .init(color: .green, location: 0.79),
                        .init(color: .yellow, location: 0.81), .init(color: .yellow, location: 0.94),
                        .init(color: .red, location: 0.96), .init(color: .red, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * fraction(meter.level))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    if meter.peak > AudioMonitor.Meter.floor {
                        Rectangle()
                            .fill(meter.peak > -3 ? Color.red : Color.primary.opacity(0.6))
                            .frame(width: 2)
                            .offset(x: max(0, width * fraction(meter.peak) - 2))
                    }
                }
            }
            .frame(height: 10)
            Text(active ? (meter.peak > AudioMonitor.Meter.floor ? String(format: "%.0f dB", meter.peak) : "silent") : "off")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .opacity(active ? 1 : 0.4)
        .frame(minWidth: 200)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
