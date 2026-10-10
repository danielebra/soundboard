import AVFoundation
import AVKit
import SwiftUI

/// Loads a video/audio file, lets you pick a range on a waveform, and saves it as a sound.
final class ClipEditorModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case fetching(progress: Double, message: String)
        case loading
        case ready
        case failed(String)
    }

    struct Result {
        let sound: String
        let name: String
        let image: String?
        let showLabel: Bool
    }

    @Published var phase: Phase = .empty
    @Published var link = ""
    @Published var name = ""
    @Published var duration = 0.0
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var playhead = 0.0
    @Published var zoomRange: ClosedRange<Double>?
    @Published var normalize = true
    @Published var useFrame = true
    @Published var showLabel = true
    @Published var saving = false

    /// Peak amplitude per 1/`peaksPerSecond` s of audio.
    private(set) var peaks: [Float] = []
    static let peaksPerSecond = 200.0

    let player = AVPlayer()
    private var asset: AVURLAsset?
    private var source: URL?
    private var downloaded: URL?
    private var timeObserver: Any?
    private var stopObserver: Any?
    private var fetchTask: Task<Void, Never>?
    let targetHasImage: Bool
    var onSave: ((Result) -> Void)?

    init(targetHasImage: Bool) {
        self.targetHasImage = targetHasImage
        useFrame = !targetHasImage
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            self?.playhead = time.seconds
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        fetchTask?.cancel()
        cleanUp()
    }

    var visibleRange: ClosedRange<Double> { zoomRange ?? 0...max(duration, 0.001) }
    var selectionLength: Double { max(0, end - start) }

    // MARK: Loading

    func fetch() {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true else {
            phase = .failed("Paste a YouTube link, like https://www.youtube.com/watch?v=…")
            return
        }
        cleanUp()
        phase = .fetching(progress: 0, message: "Starting download…")
        fetchTask = Task { @MainActor [weak self] in
            do {
                for try await status in Fetcher.fetch(url) {
                    guard let self else { return }
                    switch status {
                    case let .progress(fraction, message):
                        self.phase = .fetching(progress: fraction, message: message)
                    case let .done(file, title):
                        self.downloaded = file
                        if self.name.isEmpty { self.name = title }
                        self.open(file)
                    }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelFetch() {
        fetchTask?.cancel()
        phase = .empty
    }

    func open(_ url: URL) {
        source = url
        phase = .loading
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        let asset = AVURLAsset(url: url)
        self.asset = asset
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        Task { @MainActor in
            do {
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw AudioError.message("This file has no length.") }
                let peaks = try await Task.detached { try Self.computePeaks(asset) }.value
                self.duration = duration
                self.peaks = peaks
                self.start = 0
                self.end = min(duration, 3)
                self.zoomRange = nil
                self.phase = .ready
            } catch {
                self.phase = .failed("Couldn't read audio: \(error.localizedDescription)")
            }
        }
    }

    static func computePeaks(_ asset: AVURLAsset) throws -> [Float] {
        let semaphore = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else { throw AudioError.message("no audio track") }

        let rate = 8000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()

        let perPeak = Int(rate / peaksPerSecond)
        var peaks: [Float] = []
        var current: Float = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for i in 0..<(length / 4) {
                    current = max(current, abs(floats[i]))
                    count += 1
                    if count == perPeak {
                        peaks.append(current)
                        current = 0
                        count = 0
                    }
                }
            }
        }
        if count > 0 { peaks.append(current) }
        if reader.status == .failed { throw reader.error ?? AudioError.message("read failed") }
        return peaks
    }

    // MARK: Playback

    func seek(_ time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = time
    }

    func playSelection() {
        if let stopObserver { player.removeTimeObserver(stopObserver) }
        seek(start)
        stopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
                                                      queue: .main) { [weak self] in self?.player.pause() }
        player.play()
    }

    func toggleZoom() {
        if zoomRange != nil {
            zoomRange = nil
        } else {
            let pad = max(0.5, selectionLength * 0.25)
            zoomRange = max(0, start - pad)...min(duration, end + pad)
        }
    }

    func nudge(start delta: Double) { start = min(max(0, start + delta), end - 0.05) }
    func nudge(end delta: Double) { end = max(min(duration, end + delta), start + 0.05) }

    // MARK: Saving

    func save() {
        guard let asset, selectionLength > 0.05 else { return }
        saving = true
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Clip" : name.trimmingCharacters(in: .whitespaces)
        let normalize = normalize, useFrame = useFrame, showLabel = showLabel, frameTime = start + min(0.2, selectionLength / 2)
        Task { @MainActor in
            do {
                let base = Self.uniqueBase(Self.slug(name))
                let soundFile = "\(base).wav"
                try await Task.detached {
                    try Self.export(asset, range: range, normalize: normalize, to: Paths.sounds.appending(path: soundFile))
                }.value
                var imageFile: String?
                if useFrame {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 480, height: 480)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
                    if let frame = try? await generator.image(at: CMTime(seconds: frameTime, preferredTimescale: 600)).image {
                        imageFile = "\(base).jpg"
                        try KeyRenderer.jpeg(frame, rotate: false).write(to: Paths.icons.appending(path: imageFile!))
                    }
                }
                self.saving = false
                self.onSave?(Result(sound: soundFile, name: name, image: imageFile, showLabel: showLabel))
            } catch {
                self.saving = false
                self.phase = .failed("Saving failed: \(error.localizedDescription)")
            }
        }
    }

    static func export(_ asset: AVURLAsset, range: CMTimeRange, normalize: Bool, to url: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .audio).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else { throw AudioError.message("no audio track") }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()

        var samples: [Float] = [] // interleaved stereo
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        if reader.status == .failed { throw reader.error ?? AudioError.message("read failed") }
        let frames = samples.count / 2
        guard frames > 0 else { throw AudioError.message("selection has no audio") }

        // Short fades so the cut points don't click; optional peak normalise to -1 dBFS.
        let fade = min(frames / 2, 240)
        for i in 0..<fade {
            let gain = Float(i) / Float(fade)
            samples[i * 2] *= gain; samples[i * 2 + 1] *= gain
            let j = frames - 1 - i
            samples[j * 2] *= gain; samples[j * 2 + 1] *= gain
        }
        if normalize, let peak = samples.map(abs).max(), peak > 0.0001 {
            let gain = 0.89 / peak
            for i in samples.indices { samples[i] *= gain }
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = samples[i * 2]
            buffer.floatChannelData![1][i] = samples[i * 2 + 1]
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func slug(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-")
        return String(slug.prefix(40)).isEmpty ? "clip" : String(slug.prefix(40))
    }

    private static func uniqueBase(_ base: String) -> String {
        var candidate = base
        var n = 2
        while FileManager.default.fileExists(atPath: Paths.sounds.appending(path: "\(candidate).wav").path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Downloaded videos are only needed while editing.
    func cleanUp() {
        player.pause()
        if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
        downloaded = nil
    }
}

// MARK: - Views

struct ClipEditorView: View {
    @ObservedObject var model: ClipEditorModel
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("YouTube link", text: $model.link, prompt: Text("Paste a YouTube link"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.fetch() }
                Button("Fetch") { model.fetch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.link.isEmpty || isFetching)
                Button("Open File…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.movie, .audio]
                    if panel.runModal() == .OK, let url = panel.url { model.open(url) }
                }
            }

            switch model.phase {
            case .empty:
                placeholder("Paste a YouTube link and press Fetch, or open a video or audio file from your Mac.")
            case let .fetching(progress, message):
                VStack(alignment: .leading) {
                    ProgressView(value: progress)
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelFetch() }
                    }
                }
                placeholder("Downloading… only this step uses the internet.")
            case .loading:
                ProgressView("Reading audio…").frame(maxWidth: .infinity, minHeight: 300)
            case let .failed(message):
                placeholder(message, systemImage: "exclamationmark.triangle")
            case .ready:
                editor
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(model.saving ? "Saving…" : "Save Sound") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.phase != .ready || model.saving || model.selectionLength < 0.05)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isFetching: Bool {
        if case .fetching = model.phase { return true }
        return false
    }

    private func placeholder(_ text: String, systemImage: String = "film") -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerView(player: model.player)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            WaveformView(model: model)
                .frame(height: 96)

            HStack(spacing: 18) {
                TimeNudger(title: "Start", value: model.start, minus: { model.nudge(start: -0.05) }, plus: { model.nudge(start: 0.05) })
                TimeNudger(title: "End", value: model.end, minus: { model.nudge(end: -0.05) }, plus: { model.nudge(end: 0.05) })
                Text(String(format: "%.2fs", model.selectionLength)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(model.zoomRange == nil ? "Zoom In" : "Zoom Out",
                       systemImage: model.zoomRange == nil ? "plus.magnifyingglass" : "minus.magnifyingglass") { model.toggleZoom() }
                    .help("Zoom the timeline around the selection for fine adjustment")
                Button("Play Selection", systemImage: "play.fill") { model.playSelection() }
                    .keyboardShortcut("p", modifiers: [])
            }

            HStack(spacing: 18) {
                TextField("Name", text: $model.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Show name on key", isOn: $model.showLabel)
                Toggle("Even out volume", isOn: $model.normalize)
                    .help("Makes quiet and loud clips play at a similar level")
                Toggle(model.targetHasImage ? "Replace key image with video frame" : "Use video frame as key image",
                       isOn: $model.useFrame)
            }
            .toggleStyle(.checkbox)
        }
    }
}

private struct TimeNudger: View {
    let title: String
    let value: Double
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Button(action: minus) { Image(systemName: "minus") }.buttonStyle(.borderless)
            Text(formatTime(value)).monospacedDigit().frame(minWidth: 64)
            Button(action: plus) { Image(systemName: "plus") }.buttonStyle(.borderless)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = max(0, seconds)
    return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct WaveformView: View {
    @ObservedObject var model: ClipEditorModel
    @State private var drag: DragKind?

    private enum DragKind { case start, end, create(anchor: Double), click }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let range = model.visibleRange
            let span = range.upperBound - range.lowerBound
            let x = { (t: Double) in CGFloat((t - range.lowerBound) / span) * width }
            let time = { (px: CGFloat) in min(model.duration, max(0, range.lowerBound + Double(px / width) * span)) }

            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.black.opacity(0.85)))
                let selection = CGRect(x: x(model.start), y: 0, width: x(model.end) - x(model.start), height: size.height)
                ctx.fill(Path(selection), with: .color(.accentColor.opacity(0.3)))

                let mid = size.height / 2
                var wave = Path()
                for px in stride(from: 0, to: Int(size.width), by: 1) {
                    let t0 = range.lowerBound + Double(px) / Double(size.width) * span
                    let t1 = range.lowerBound + Double(px + 1) / Double(size.width) * span
                    let i0 = max(0, Int(t0 * ClipEditorModel.peaksPerSecond))
                    let i1 = min(model.peaks.count, max(i0 + 1, Int(t1 * ClipEditorModel.peaksPerSecond)))
                    guard i0 < i1 else { continue }
                    let peak = CGFloat(model.peaks[i0..<i1].max() ?? 0)
                    let h = max(1, min(1, peak) * (mid - 4))
                    wave.addRect(CGRect(x: CGFloat(px), y: mid - h, width: 1, height: h * 2))
                }
                ctx.fill(wave, with: .color(.white.opacity(0.75)))

                for t in [model.start, model.end] {
                    ctx.fill(Path(CGRect(x: x(t) - 1.5, y: 0, width: 3, height: size.height)), with: .color(.accentColor))
                    ctx.fill(Path(roundedRect: CGRect(x: x(t) - 6, y: size.height / 2 - 12, width: 12, height: 24), cornerRadius: 3),
                             with: .color(.accentColor))
                }
                let p = x(model.playhead)
                if p >= 0 && p <= size.width {
                    ctx.fill(Path(CGRect(x: p - 0.5, y: 0, width: 1, height: size.height)), with: .color(.yellow))
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let t = time(value.location.x)
                if drag == nil {
                    let startX = value.startLocation.x
                    if abs(startX - x(model.start)) < 10 { drag = .start }
                    else if abs(startX - x(model.end)) < 10 { drag = .end }
                    else { drag = .click }
                }
                switch drag {
                case .start: model.start = min(t, model.end - 0.05)
                case .end: model.end = max(t, model.start + 0.05)
                case .click:
                    if abs(value.translation.width) > 3 { drag = .create(anchor: time(value.startLocation.x)) }
                case let .create(anchor):
                    model.start = min(anchor, t)
                    model.end = max(anchor, t)
                case nil: break
                }
            }.onEnded { value in
                if case .click = drag { model.seek(time(value.location.x)) }
                drag = nil
            })
            .help("Drag across the waveform to select. Drag the handles to adjust. Click to move the playhead.")
        }
    }
}
