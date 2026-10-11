import AVFoundation
import AudioToolbox
import Synchronization

/// Every sound is converted to this on load, so any voice can play any sound.
let mixFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

enum AudioError: LocalizedError {
    case status(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .status(what, code): return "\(what) failed (\(code))"
        case let .message(text): return text
        }
    }
}

func loadSound(_ url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0,
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw AudioError.message("empty file") }
    try file.read(into: source)
    if source.format == mixFormat { return source }

    guard let converter = AVAudioConverter(from: source.format, to: mixFormat) else {
        throw AudioError.message("unsupported format \(source.format)")
    }
    if source.format.channelCount == 1 {
        converter.channelMap = [0, 0] // mono → both ears
    }
    let ratio = mixFormat.sampleRate / source.format.sampleRate
    let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 4096
    guard let output = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: capacity) else {
        throw AudioError.message("out of memory")
    }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed {
            status.pointee = .endOfStream
            return nil
        }
        fed = true
        status.pointee = .haveData
        return source
    }
    if let error { throw error }
    return output
}

private func select(device: AudioDeviceID, on node: AVAudioIONode) throws {
    guard let unit = node.audioUnit else { throw AudioError.message("no audio unit") }
    var id = device
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    if status != noErr { throw AudioError.status("Selecting audio device", status) }
}

/// Writes a quiet 1 kHz bleep.
private func bleep(_ out: UnsafeMutablePointer<Float>, count: Int, phase: inout Double, sampleRate: Double) {
    let step = 2 * Double.pi * 1000 / sampleRate
    for i in 0..<count {
        out[i] = Float(sin(phase)) * 0.25
        phase += step
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
    }
}

/// Apple's machine-learning voice isolation (the engine behind the Voice Isolation mic mode).
/// Adds ~56 ms when active; bypassed it passes audio straight through.
private func makeVoiceIsolation() -> AVAudioUnitEffect {
    AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
}

/// State shared with the real-time audio threads.
private final class RealtimeState: @unchecked Sendable {
    let censor = Atomic<Bool>(false)
}

/// Peak of the loudest channel in a tap buffer, or in `count` frames of it from `start`.
private func peak(_ buffer: AVAudioPCMBuffer, from start: Int = 0, count: Int? = nil) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    let end = min(Int(buffer.frameLength), start + (count ?? Int(buffer.frameLength)))
    var level: Float = 0
    for c in 0..<Int(buffer.format.channelCount) {
        for i in start..<max(start, end) { level = max(level, abs(channels[c][i])) }
    }
    return level
}

/// A few seconds of raw microphone, for trying settings on.
struct MicClip {
    var samples: [Float]
    var sampleRate: Double
}

/// Meter levels and the mic test recording. Fed by engine taps, which run on an ordinary
/// background thread, so a lock is fine here.
private final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var levels = AudioRouter.Levels()
    /// Peaks of each 50 ms of the signals the deck's screen graphs, oldest first.
    private var chunks: [AudioRouter.Signal: [Float]] = [:]
    private var recording: [Float]?
    private var recordTarget = 0
    private var recordRate = 0.0
    private var finished: MicClip?

    func set(_ keyPath: WritableKeyPath<AudioRouter.Levels, Float>, _ value: Float) {
        lock.withLock { levels[keyPath: keyPath] = value }
    }

    var current: AudioRouter.Levels { lock.withLock { levels } }

    /// Taps arrive in ~100 ms buffers whatever size is asked for, so they're split into
    /// 50 ms chunks here and the screen takes them in order.
    func addChunks(_ signal: AudioRouter.Signal, _ buffer: AVAudioPCMBuffer) {
        let size = max(1, Int(buffer.format.sampleRate * AudioRouter.chunkSeconds))
        let peaks = stride(from: 0, to: Int(buffer.frameLength), by: size).map { peak(buffer, from: $0, count: size) }
        lock.withLock {
            chunks[signal, default: []].append(contentsOf: peaks)
            if chunks[signal]!.count > 40 { chunks[signal]!.removeFirst(chunks[signal]!.count - 40) } // nobody reading
        }
    }

    func takeChunks(_ signal: AudioRouter.Signal) -> [Float] {
        lock.withLock { chunks.removeValue(forKey: signal) ?? [] }
    }

    func reset() { lock.withLock { levels = AudioRouter.Levels(); chunks = [:] } }

    func startRecording(frames: Int) {
        lock.withLock { recording = []; recordTarget = frames; finished = nil }
    }

    func cancelRecording() { lock.withLock { recording = nil } }

    /// Ends the recording early, keeping what was captured.
    func finishRecording() {
        lock.withLock {
            if let recording, !recording.isEmpty { finished = MicClip(samples: recording, sampleRate: recordRate) }
            recording = nil
        }
    }

    /// Seconds recorded so far, nil when not recording.
    var recordedSeconds: Double? {
        lock.withLock { recording.map { recordRate > 0 ? Double($0.count) / recordRate : 0 } }
    }

    func takeFinished() -> MicClip? {
        lock.withLock { defer { finished = nil }; return finished }
    }

    /// Mixes the mic down to mono (like the ring buffer) and appends it while recording.
    func record(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard recording != nil, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.format.channelCount), n = min(Int(buffer.frameLength), recordTarget - recording!.count)
            let scale = 1 / Float(count)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<count { sum += channels[c][i] }
                recording!.append(sum * scale)
            }
            recordRate = buffer.format.sampleRate
            if recording!.count >= recordTarget {
                finished = MicClip(samples: recording!, sampleRate: recordRate)
                recording = nil
            }
        }
    }
}

/// One AVAudioEngine bound to one output device, with a fixed pool of player voices.
private final class OutputBus {
    let engine = AVAudioEngine()
    let effects = AVAudioMixerNode()
    private(set) var voices: [AVAudioPlayerNode] = []

    init(device: AudioDeviceID, voiceCount: Int) throws {
        try select(device: device, on: engine.outputNode)
        engine.attach(effects)
        engine.connect(effects, to: engine.mainMixerNode, format: mixFormat)
        for _ in 0..<voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: effects, format: mixFormat)
            voices.append(player)
        }
    }

    func add(_ node: AVAudioSourceNode, format: AVAudioFormat, through effect: AVAudioUnitEffect? = nil) {
        engine.attach(node)
        if let effect {
            engine.attach(effect)
            engine.connect(node, to: effect, format: format)
            engine.connect(effect, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
    }

    /// The censor bleep, as its own node so noise suppression on the mic can't remove it.
    func addCensorTone(_ state: RealtimeState) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: mixFormat.sampleRate, channels: 1)!
        var phase = 0.0
        let tone = AVAudioSourceNode(format: format) { isSilence, _, frames, list in
            let out = UnsafeMutableAudioBufferListPointer(list)
            guard let data = out[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if state.censor.load(ordering: .relaxed) {
                bleep(data, count: Int(frames), phase: &phase, sampleRate: format.sampleRate)
            } else {
                data.update(repeating: 0, count: Int(frames))
                isSilence.pointee = true
            }
            return noErr
        }
        add(tone, format: format)
        return tone
    }

    /// Plays mic test recordings; skips the sound volume so you hear the mic as the listening app does.
    func addPreviewPlayer() -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: mixFormat)
        return player
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }
}

/// Captures the real microphone into a ring buffer.
private final class MicCapture {
    let engine = AVAudioEngine()
    let ring: RingBuffer
    let sampleRate: Double

    init(device: AudioDeviceID, taps: TapState) throws {
        let input = engine.inputNode
        try select(device: device, on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.message("input device reported no channels")
        }
        sampleRate = format.sampleRate
        let ring = RingBuffer(sampleRate: format.sampleRate)
        self.ring = ring
        let sink = AVAudioSinkNode { _, frames, list in
            ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)), frames: Int(frames))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            taps.set(\.mic, peak(buffer))
            taps.addChunks(.input, buffer)
            taps.record(buffer)
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    /// The device's rate changed since the graph was built (possible while it was paused).
    var rateChanged: Bool { engine.inputNode.outputFormat(forBus: 0).sampleRate != sampleRate }
}

/// Opens the mic off the setup queue and gives up after `timeout`. A USB mic that went away
/// overnight can block the CoreAudio call forever, which would otherwise stall the headphones
/// and the virtual device behind it. A mic that opens after we gave up is stopped and dropped.
private func openMic(device: AudioDeviceID, taps: TapState, timeout: TimeInterval = 5) throws -> MicCapture {
    let lock = NSLock()
    var result: Result<MicCapture, Error>?
    var abandoned = false
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        let made = Result { try MicCapture(device: device, taps: taps) }
        lock.lock()
        let late = abandoned
        if !late { result = made }
        lock.unlock()
        if late, case .success(let mic) = made { mic.engine.stop() }
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        lock.lock()
        let missed = result == nil
        if missed { abandoned = true }
        lock.unlock()
        if missed { throw AudioError.message("didn't respond. Unplug and replug it") }
    }
    lock.lock()
    defer { lock.unlock() }
    return try result!.get()
}

/// Routes sounds (and your microphone) to the virtual device other apps use as a mic, and
/// mirrors the sounds to your own speakers/headphones.
final class AudioRouter {
    struct Status {
        /// Set while devices are being opened; names the virtual device being waited on.
        var connecting: String?
        var output: String?
        var outputProblem: String?
        var monitor: String?
        var mic: String?
        var micProblem: String?
        /// Each engine is built but stopped until something needs it (`Demand`); these say
        /// which are running.
        var micLive = false
        var outputLive = false
        var monitorLive = false
    }

    /// Why audio should be running. With no reason every engine is stopped, so the mic, the
    /// noise removal and the devices (which keep the Mac awake while open) are idle between calls.
    struct Demand: OptionSet {
        let rawValue: Int
        /// Another app reads from the output device (a meeting is on): everything runs.
        static let listener = Demand(rawValue: 1)
        /// The Audio tab's meters and input test: everything runs.
        static let audioTab = Demand(rawValue: 2)
        /// A sound played recently: only the monitor runs, so you hear it.
        static let playback = Demand(rawValue: 4)
    }

    private enum Engine: CaseIterable { case mic, output, monitor }

    /// Peak levels, 0…1.
    struct Levels {
        /// The input device as it arrives.
        var mic: Float = 0
        /// The input after processing (noise removal), before the mix.
        var cleaned: Float = 0
        /// The output mix: processed input plus sounds.
        var output: Float = 0
    }

    /// Signals the deck's screen graphs, in 50 ms chunks.
    enum Signal {
        /// The input device (its own engine; works without the output).
        case input
        /// The input as it enters processing, and as it leaves it. Both on the output engine,
        /// so their chunks line up (apart from the processing's latency).
        case unprocessed, processed
    }

    static let chunkSeconds = 0.05

    private(set) var status = Status()
    /// (sound key, isPlaying), always on the main thread.
    var onPlaybackChange: ((String, Bool) -> Void)?
    /// An engine stopped because a device changed underneath it.
    var onNeedsRebuild: (() -> Void)?
    /// Devices finished opening (or failed); `status` is up to date.
    var onStatusChange: (() -> Void)?

    private let voiceCount = 12
    private var broadcast: OutputBus?
    private var monitor: OutputBus?
    private var mic: MicCapture?
    private let realtime = RealtimeState()
    private let taps = TapState()
    private var previewPlayer: AVAudioPlayerNode?
    private var previewToken = 0
    private var observers: [NSObjectProtocol] = []
    private var micNode: AVAudioSourceNode?
    private var micFilter: AVAudioUnitEffect?
    private var broadcastTone: AVAudioSourceNode?
    private var monitorTone: AVAudioSourceNode?
    private let setupQueue = DispatchQueue(label: "soundboard.audio.setup")
    private var generation = 0
    private let listeners = AudioListeners()
    private var demand: Demand = []
    /// Engines being started or stopped on `setupQueue`.
    private var switching: Set<Engine> = []
    private var pauseWork: DispatchWorkItem?
    private var lingerWork: DispatchWorkItem?
    /// Sounds pressed while their engine was starting: voice and token, scheduled once it runs.
    private var pending: [(voice: Int, token: Int, sound: AVAudioPCMBuffer, volume: Float)] = []
    /// For noise removal, which is bypassed while the input is paused.
    private var settings = Config()

    private struct Built {
        var broadcast: OutputBus?
        var monitor: OutputBus?
        var mic: MicCapture?
        var micNode: AVAudioSourceNode?
        var micFilter: AVAudioUnitEffect?
        var broadcastTone: AVAudioSourceNode?
        var monitorTone: AVAudioSourceNode?
        var previewPlayer: AVAudioPlayerNode?
        var outputDevice: AudioDeviceID?
        var status = Status()
        /// Built by `buildBroadcast` (virtual device) rather than `buildLocal` (mic, headphones).
        var isBroadcastStage = false
    }

    private var voiceOwner: [String?]
    private var voiceToken: [Int]
    private var voiceIsOverlay: [Bool]
    /// Length of the sound on each voice, and when it started (higher is newer).
    private var voiceFrames: [AVAudioFrameCount]
    private var voiceStarted: [Int]
    private var starts = 0
    private var nextVoice = 0

    init() {
        voiceOwner = Array(repeating: nil, count: voiceCount)
        voiceToken = Array(repeating: 0, count: voiceCount)
        voiceIsOverlay = Array(repeating: false, count: voiceCount)
        voiceFrames = Array(repeating: 0, count: voiceCount)
        voiceStarted = Array(repeating: 0, count: voiceCount)
        listeners.onChange = { [weak self] listening in self?.setDemand(.listener, listening) }
    }

    var isCensoring: Bool { realtime.censor.load(ordering: .relaxed) }

    func isPlaying(_ key: String) -> Bool { voiceOwner.contains(key) }

    // MARK: Engine lifecycle

    func rebuild(config: Config, micAllowed: Bool) {
        teardown()
        settings = config
        generation += 1
        let generation = self.generation
        status = Status(connecting: config.outputDevice)
        let realtime = self.realtime, taps = self.taps, voiceCount = self.voiceCount
        setupQueue.async { [weak self] in
            // Mic and headphones first, so they work even if the virtual device's driver hangs.
            let local = Self.buildLocal(config: config, micAllowed: micAllowed, realtime: realtime, taps: taps,
                                        voiceCount: voiceCount)
            self?.deliver(local, generation: generation)
            let broadcast = Self.buildBroadcast(config: config, mic: local.mic, realtime: realtime, taps: taps,
                                                voiceCount: voiceCount)
            self?.deliver(broadcast, generation: generation)
        }
    }

    /// Hands a finished setup stage to the main thread, or stops it if a newer rebuild started.
    private func deliver(_ built: Built, generation: Int) {
        DispatchQueue.main.async {
            guard generation == self.generation else {
                self.setupQueue.async { [built.broadcast?.engine, built.monitor?.engine, built.mic?.engine].forEach { $0?.stop() } }
                return
            }
            self.install(built)
        }
    }

    /// Installs one setup stage: the mic and headphones, or the virtual device.
    private func install(_ built: Built) {
        if let bus = built.broadcast {
            broadcast = bus
            micNode = built.micNode
            micFilter = built.micFilter
            broadcastTone = built.broadcastTone
            applyNoiseRemoval()
        }
        if built.isBroadcastStage {
            status.connecting = nil
            status.output = built.status.output
            status.outputProblem = built.status.outputProblem
            listeners.watch(built.outputDevice)
        } else {
            mic = built.mic
            monitor = built.monitor
            monitorTone = built.monitorTone
            previewPlayer = built.previewPlayer
            status.mic = built.status.mic
            status.micProblem = built.status.micProblem
            status.monitor = built.status.monitor
            taps.reset()
        }
        updateEngines(stopping: false)

        // A device change can stop an engine; rebuild only then. Engines also post this
        // notification harmlessly right after we move them off the default device:
        // rebuilding on those would restart the mic forever.
        let engines = [built.broadcast?.engine, built.monitor?.engine, built.mic?.engine].compactMap { $0 }
        for engine in engines {
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.needsRebuild(engine) { self.onNeedsRebuild?() }
            })
        }
        onStatusChange?()
    }

    /// Everything that talks to audio devices runs on `setupQueue`, because a stuck driver
    /// can block these calls indefinitely. This stage opens your mic and headphones.
    private static func buildLocal(config: Config, micAllowed: Bool, realtime: RealtimeState, taps: TapState,
                                   voiceCount: Int) -> Built {
        var built = Built()

        // Microphone (optional).
        if config.micPassthrough {
            let device = config.micDevice.flatMap { AudioDevices.find($0, output: false) }
                ?? (config.micDevice == nil ? AudioDevices.defaultDevice(output: false) : nil)
            if !micAllowed {
                built.status.micProblem = "Microphone access not granted"
            } else if let device {
                if device.name.localizedCaseInsensitiveContains(config.outputDevice) {
                    built.status.micProblem = "Input is the same device as the output. Pick a different input"
                } else {
                    do {
                        // Started by `updateEngines` once something needs it.
                        let mic = try openMic(device: device.id, taps: taps)
                        built.mic = mic
                        built.status.mic = device.name
                    } catch {
                        built.status.micProblem = "\(device.name): \(error.localizedDescription)"
                    }
                }
            } else {
                built.status.micProblem = "Input “\(config.micDevice ?? "default")” not found"
            }
        }

        // What you hear.
        if config.monitor {
            let device = config.monitorDevice.flatMap { AudioDevices.find($0, output: true) }
                ?? (config.monitorDevice == nil ? AudioDevices.defaultDevice(output: true) : nil)
            let output = AudioDevices.find(config.outputDevice, output: true)
            if let device, device.id != output?.id {
                do {
                    let bus = try OutputBus(device: device.id, voiceCount: voiceCount)
                    bus.effects.outputVolume = config.monitorVolume
                    let tone = bus.addCensorTone(realtime)
                    tone.volume = config.monitorVolume
                    let preview = bus.addPreviewPlayer()
                    built.monitorTone = tone
                    built.previewPlayer = preview
                    built.monitor = bus
                    built.status.monitor = device.name
                } catch {
                    NSLog("Soundboard: monitor device \(device.name): \(error.localizedDescription)")
                }
            }
        }
        return built
    }

    /// Opens the virtual output device and feeds it the mic. This is the call that
    /// hangs when BlackHole's driver is stuck.
    private static func buildBroadcast(config: Config, mic: MicCapture?, realtime: RealtimeState, taps: TapState,
                                       voiceCount: Int) -> Built {
        var built = Built(isBroadcastStage: true)
        guard let device = AudioDevices.find(config.outputDevice, output: true) else {
            built.status.outputProblem = "“\(config.outputDevice)” not found. Is BlackHole installed?"
            return built
        }
        built.outputDevice = device.id
        do {
            let bus = try OutputBus(device: device.id, voiceCount: voiceCount)
            bus.effects.outputVolume = config.soundVolume
            if let mic {
                let format = AVAudioFormat(standardFormatWithSampleRate: mic.sampleRate, channels: 1)!
                let ring = mic.ring
                let state = realtime
                let voice = AVAudioSourceNode(format: format) { isSilence, _, frames, list in
                    let out = UnsafeMutableAudioBufferListPointer(list)
                    guard let data = out[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                    let n = Int(frames)
                    let read = ring.read(into: data, count: n) // keep draining while censored
                    if state.censor.load(ordering: .relaxed) { data.update(repeating: 0, count: n) }
                    if read == 0 || state.censor.load(ordering: .relaxed) { isSilence.pointee = true }
                    return noErr
                }
                voice.volume = config.micVolume
                // Always in the graph so it can be switched without restarting the mic.
                let filter = makeVoiceIsolation()
                configure(filter, config, inputLive: false)
                bus.add(voice, format: format, through: filter)
                voice.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    taps.addChunks(.unprocessed, buffer)
                }
                filter.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    taps.set(\.cleaned, peak(buffer))
                    taps.addChunks(.processed, buffer)
                }
                built.micNode = voice
                built.micFilter = filter
            }
            let tone = bus.addCensorTone(realtime)
            tone.volume = config.micVolume
            built.broadcastTone = tone
            bus.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                taps.set(\.output, peak(buffer))
            }
            bus.engine.prepare() // started by `updateEngines` once something needs it
            built.broadcast = bus
            built.status.output = device.name
        } catch {
            NSLog("Soundboard: virtual device \(device.name): \(error)")
            built.status.outputProblem = "\(device.name): \(error.localizedDescription)"
            built.micNode = nil
            built.micFilter = nil
            built.broadcastTone = nil
        }
        return built
    }

    private func needsRebuild(_ engine: AVAudioEngine) -> Bool {
        // A stopped engine is only a failure while it's meant to be running; idle engines are
        // stopped on purpose (and a rebuild would leave them stopped, then post this again).
        if let mic, engine === mic.engine {
            // The ring buffer and mixer were set up for the old rate.
            return (status.micLive && !engine.isRunning) || mic.rateChanged
        }
        if engine === broadcast?.engine { return status.outputLive && !engine.isRunning }
        if engine === monitor?.engine { return status.monitorLive && !engine.isRunning }
        return false
    }

    // MARK: Engines on demand (main thread)

    /// Starts what's needed right away, and stops the rest a few seconds after the last
    /// reason goes away (so an app that briefly stops listening doesn't bounce the devices).
    func setDemand(_ reason: Demand, _ on: Bool) {
        if on { demand.insert(reason) } else { demand.remove(reason) }
        pauseWork?.cancel()
        pauseWork = nil
        updateEngines(stopping: false)
        if Engine.allCases.contains(where: { isLive($0) && !isWanted($0) }) {
            let work = DispatchWorkItem { [weak self] in
                self?.pauseWork = nil
                self?.updateEngines(stopping: true)
            }
            pauseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func isWanted(_ engine: Engine) -> Bool {
        switch engine {
        case .mic, .output: !demand.isDisjoint(with: [.listener, .audioTab])
        case .monitor: !demand.isEmpty
        }
    }

    private func isLive(_ engine: Engine) -> Bool {
        switch engine {
        case .mic: status.micLive
        case .output: status.outputLive
        case .monitor: status.monitorLive
        }
    }

    private func setLive(_ engine: Engine, _ live: Bool) {
        switch engine {
        case .mic: status.micLive = live
        case .output: status.outputLive = live
        case .monitor: status.monitorLive = live
        }
    }

    private func audioEngine(_ engine: Engine) -> AVAudioEngine? {
        switch engine {
        case .mic: mic?.engine
        case .output: broadcast?.engine
        case .monitor: monitor?.engine
        }
    }

    /// Starts (and with `stopping`, stops) engines to match `demand`. Device calls run on `setupQueue`.
    private func updateEngines(stopping: Bool) {
        for kind in Engine.allCases where !switching.contains(kind) {
            guard let engine = audioEngine(kind) else { continue }
            let wanted = isWanted(kind)
            if wanted == isLive(kind) || (!wanted && !stopping) { continue }
            switching.insert(kind)
            if !wanted {
                setLive(kind, false) // before stopping, so the stop isn't taken for a failure
                if kind == .mic { applyNoiseRemoval() } // bypassed while paused
                if engine === runningBuses.first?.engine { stopAll() } // its completions would be lost
            }
            let mic = kind == .mic ? self.mic : nil
            setupQueue.async { [weak self] in
                var rateChanged = false, failure: String?
                if wanted {
                    rateChanged = mic?.rateChanged ?? false
                    if !rateChanged {
                        engine.prepare()
                        do { try engine.start() } catch { failure = error.localizedDescription }
                    }
                } else {
                    engine.stop()
                }
                DispatchQueue.main.async { self?.switched(kind, engine, wanted: wanted, rateChanged: rateChanged, failure: failure) }
            }
        }
    }

    private func switched(_ kind: Engine, _ engine: AVAudioEngine, wanted: Bool, rateChanged: Bool, failure: String?) {
        switching.remove(kind)
        guard engine === audioEngine(kind) else {
            updateEngines(stopping: false) // rebuilt meanwhile: the new engine may be waiting on this
            return
        }
        if rateChanged {
            // The graph was built for the old rate; a rebuild picks up the new one.
            onNeedsRebuild?()
            return
        }
        if let failure {
            NSLog("Soundboard: %@ didn't start: %@", "\(kind)", failure)
            if kind == .mic {
                status.micProblem = "\(status.mic ?? "Input"): \(failure)"
                status.mic = nil
            }
        } else if wanted {
            setLive(kind, true)
            if kind == .mic { applyNoiseRemoval() }
        }
        NSLog("Soundboard: %@ %@", "\(kind)", isLive(kind) ? "running" : "stopped")
        playPending()
        updateEngines(stopping: pauseWork == nil) // demand may have changed while switching
        onStatusChange?()
    }

    func teardown() {
        stopAll()
        pending.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let engines = [mic?.engine, broadcast?.engine, monitor?.engine]
        setupQueue.async { engines.forEach { $0?.stop() } }
        mic = nil
        broadcast = nil
        monitor = nil
        taps.cancelRecording()
        previewPlayer = nil
        micNode = nil
        micFilter = nil
        broadcastTone = nil
        monitorTone = nil
    }

    // MARK: Playback (main thread)

    /// Monitor first: it keeps running while sounds play, so it carries the completions.
    private var runningBuses: [OutputBus] {
        [monitor, broadcast].compactMap { $0 }.filter { $0.engine.isRunning }
    }

    /// `.toggle`: tap starts, tap again stops; with `stopOthers` it ends other toggle sounds.
    /// `.overlay`: every tap layers another copy on top; never stops or is stopped by others.
    func play(key: String, sound: AVAudioPCMBuffer, volume: Float, mode: ButtonConfig.Mode, stopOthers: Bool) {
        if mode == .toggle {
            if isPlaying(key) {
                stop(key)
                return
            }
            if stopOthers {
                for v in 0..<voiceCount where voiceOwner[v] != nil && !voiceIsOverlay[v] { release(v) }
            }
        }
        setDemand(.playback, true)
        lingerWork?.cancel()
        // The monitor may be starting for this press (it's idle outside calls); play once it runs.
        let starting = switching.contains { $0 != .mic && isWanted($0) }
        guard starting || !runningBuses.isEmpty else { return soundsMayHaveEnded() }

        let v = (0..<voiceCount).first { voiceOwner[$0] == nil } ?? nextVoice
        nextVoice = (v + 1) % voiceCount
        release(v)

        let wasPlaying = isPlaying(key)
        voiceToken[v] &+= 1
        let token = voiceToken[v]
        voiceOwner[v] = key
        voiceIsOverlay[v] = mode == .overlay
        voiceFrames[v] = sound.frameLength
        starts += 1
        voiceStarted[v] = starts

        if starting {
            pending.append((v, token, sound, volume))
        } else {
            schedule(v, token: token, sound: sound, volume: volume)
        }
        if !wasPlaying { onPlaybackChange?(key, true) }
    }

    private func schedule(_ v: Int, token: Int, sound: AVAudioPCMBuffer, volume: Float) {
        for (i, bus) in runningBuses.enumerated() {
            let player = bus.voices[v]
            player.stop()
            player.volume = volume
            if i == 0 {
                player.scheduleBuffer(sound, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { self?.voiceFinished(v, token: token) }
                }
            } else {
                player.scheduleBuffer(sound, at: nil, options: [])
            }
            player.play()
        }
    }

    /// Plays sounds that were pressed while their engine started, once nothing is starting.
    private func playPending() {
        guard !pending.isEmpty, !switching.contains(where: { $0 != .mic }) else { return }
        let ready = pending
        pending.removeAll()
        for press in ready where voiceToken[press.voice] == press.token {
            if runningBuses.isEmpty {
                release(press.voice) // nothing could start
            } else {
                schedule(press.voice, token: press.token, sound: press.sound, volume: press.volume)
            }
        }
    }

    /// Keeps the monitor open a while after the last sound, so the next press plays at once.
    private func soundsMayHaveEnded() {
        guard !voiceOwner.contains(where: { $0 != nil }) else { return }
        lingerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setDemand(.playback, false) }
        lingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func stop(_ key: String) {
        for v in 0..<voiceCount where voiceOwner[v] == key { release(v) }
    }

    func stopAll() {
        for v in 0..<voiceCount { release(v) }
    }

    /// Frees a voice; reports the key stopped once its last copy is gone.
    private func release(_ v: Int) {
        guard let key = voiceOwner[v] else { return }
        voiceToken[v] &+= 1
        voiceOwner[v] = nil
        for bus in [broadcast, monitor].compactMap({ $0 }) { bus.voices[v].stop() }
        if !isPlaying(key) { onPlaybackChange?(key, false) }
        soundsMayHaveEnded()
    }

    /// How far the newest copy of `key` has played, in seconds, and its length.
    func progress(_ key: String) -> (elapsed: Double, duration: Double)? {
        guard let v = (0..<voiceCount).filter({ voiceOwner[$0] == key }).max(by: { voiceStarted[$0] < voiceStarted[$1] })
        else { return nil }
        let duration = Double(voiceFrames[v]) / mixFormat.sampleRate
        // The first running bus is the one `play` scheduled the completion on.
        guard let player = runningBuses.first?.voices[v], let now = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: now), time.sampleRate > 0
        else { return (0, duration) }
        return (min(duration, max(0, Double(time.sampleTime) / time.sampleRate)), duration)
    }

    private func voiceFinished(_ v: Int, token: Int) {
        guard voiceToken[v] == token, let key = voiceOwner[v] else { return }
        voiceOwner[v] = nil
        if !isPlaying(key) { onPlaybackChange?(key, false) }
        soundsMayHaveEnded()
    }

    /// Applies volume and noise suppression changes without restarting anything.
    func setVolumes(_ config: Config) {
        settings = config
        broadcast?.effects.outputVolume = config.soundVolume
        micNode?.volume = config.micVolume
        broadcastTone?.volume = config.micVolume
        monitor?.effects.outputVolume = config.monitorVolume
        monitorTone?.volume = config.monitorVolume
        applyNoiseRemoval()
    }

    private func applyNoiseRemoval() {
        if let micFilter { Self.configure(micFilter, settings, inputLive: status.micLive) }
    }

    /// Noise removal is bypassed while the input is paused, so the model isn't run on silence.
    private static func configure(_ filter: AVAudioUnitEffect, _ config: Config, inputLive: Bool) {
        filter.bypass = !config.noiseSuppression || !inputLive
        filter.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?
            .value = config.noiseSuppressionStrength * 100
    }

    // MARK: Meters and mic test (main thread)

    var levels: Levels { taps.current }

    /// 50 ms peaks of `signal` since the last call, oldest first. For one reader only (the deck's screen).
    func takeChunks(_ signal: Signal) -> [Float] { taps.takeChunks(signal) }

    var canRecordTest: Bool { mic?.engine.isRunning == true }

    var canPlayTest: Bool { previewPlayer != nil && monitor?.engine.isRunning == true }

    /// Records until `finishTestRecording`, or `maxSeconds` at most.
    func startTestRecording(maxSeconds: Double) {
        guard let mic else { return }
        taps.startRecording(frames: Int(maxSeconds * mic.sampleRate))
    }

    func finishTestRecording() { taps.finishRecording() }

    func cancelTestRecording() { taps.cancelRecording() }

    /// Seconds recorded so far, nil when not recording.
    var testRecordedSeconds: Double? { taps.recordedSeconds }

    /// The finished recording, once.
    func takeTestRecording() -> MicClip? { taps.takeFinished() }

    /// Plays `clip` on your headphones only, through the current mic volume and (when `cleaned`)
    /// noise suppression: the same chain the output gets, so you can change settings and replay it.
    func playTest(_ clip: MicClip, cleaned: Bool, config: Config, done: @escaping () -> Void) {
        guard let player = previewPlayer, canPlayTest else { return done() }
        previewToken += 1
        let token = previewToken
        player.stop()
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = try? Self.render(clip, cleaned: cleaned, config: config)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.previewToken, let buffer, self.canPlayTest else { return done() }
                player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                    DispatchQueue.main.async { if token == self.previewToken { done() } }
                }
                player.play()
            }
        }
    }

    func stopTest() {
        previewToken += 1
        previewPlayer?.stop()
    }

    /// Runs a recording through the live mic chain offline: mic volume, then voice isolation.
    private static func render(_ clip: MicClip, cleaned: Bool, config: Config) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: mixFormat, maximumFrameCount: chunk)
        let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1)!
        var position = 0
        let samples = clip.samples
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            guard let data = UnsafeMutableAudioBufferListPointer(list)[0].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            for i in 0..<Int(frames) { data[i] = position + i < samples.count ? samples[position + i] : 0 }
            position += Int(frames)
            return noErr
        }
        source.volume = config.micVolume
        let filter = makeVoiceIsolation()
        var settings = config
        settings.noiseSuppression = cleaned && config.noiseSuppression
        configure(filter, settings, inputLive: true)
        engine.attach(source)
        engine.attach(filter)
        engine.connect(source, to: filter, format: format)
        engine.connect(filter, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }

        // A little extra for the isolation's ~56 ms latency.
        let total = AVAudioFrameCount(Double(samples.count) / clip.sampleRate * mixFormat.sampleRate + 0.1 * mixFormat.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: total),
              let block = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunk)
        else { throw AudioError.message("out of memory") }
        while output.frameLength < total {
            let n = min(chunk, total - output.frameLength)
            guard try engine.renderOffline(n, to: block) == .success else { break }
            for c in 0..<Int(mixFormat.channelCount) {
                (output.floatChannelData![c] + Int(output.frameLength))
                    .update(from: block.floatChannelData![c], count: Int(block.frameLength))
            }
            output.frameLength += block.frameLength
        }
        return output
    }

    func setCensor(_ on: Bool) {
        realtime.censor.store(on, ordering: .relaxed)
    }
}
