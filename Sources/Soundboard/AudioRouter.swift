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

    init(device: AudioDeviceID) throws {
        let input = engine.inputNode
        try select(device: device, on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.message("microphone reported no channels")
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
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }
}

/// Routes sounds (and your microphone) to the virtual device Zoom listens to, and
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
    }

    private(set) var status = Status()
    /// (sound key, isPlaying) — always on the main thread.
    var onPlaybackChange: ((String, Bool) -> Void)?
    /// An engine stopped because a device changed underneath it.
    var onNeedsRebuild: (() -> Void)?
    /// Devices finished opening (or failed) — `status` is up to date.
    var onStatusChange: (() -> Void)?

    private let voiceCount = 12
    private var broadcast: OutputBus?
    private var monitor: OutputBus?
    private var mic: MicCapture?
    private let realtime = RealtimeState()
    private var observers: [NSObjectProtocol] = []
    private var micNode: AVAudioSourceNode?
    private var micFilter: AVAudioUnitEffect?
    private var broadcastTone: AVAudioSourceNode?
    private var monitorTone: AVAudioSourceNode?
    private let setupQueue = DispatchQueue(label: "soundboard.audio.setup")
    private var generation = 0

    private struct Built {
        var broadcast: OutputBus?
        var monitor: OutputBus?
        var mic: MicCapture?
        var micNode: AVAudioSourceNode?
        var micFilter: AVAudioUnitEffect?
        var broadcastTone: AVAudioSourceNode?
        var monitorTone: AVAudioSourceNode?
        var status = Status()
    }

    private var voiceOwner: [String?]
    private var voiceToken: [Int]
    private var voiceIsOverlay: [Bool]
    private var nextVoice = 0

    init() {
        voiceOwner = Array(repeating: nil, count: voiceCount)
        voiceToken = Array(repeating: 0, count: voiceCount)
        voiceIsOverlay = Array(repeating: false, count: voiceCount)
    }

    var isCensoring: Bool { realtime.censor.load(ordering: .relaxed) }

    func isPlaying(_ key: String) -> Bool { voiceOwner.contains(key) }

    // MARK: Engine lifecycle

    func rebuild(config: Config, micAllowed: Bool) {
        teardown()
        generation += 1
        let generation = self.generation
        status = Status(connecting: config.outputDevice)
        let realtime = self.realtime, voiceCount = self.voiceCount
        setupQueue.async { [weak self] in
            let built = Self.build(config: config, micAllowed: micAllowed, realtime: realtime, voiceCount: voiceCount)
            DispatchQueue.main.async {
                guard let self, generation == self.generation else {
                    // A newer rebuild started while this one was stuck; discard it.
                    self?.setupQueue.async { [built.broadcast?.engine, built.monitor?.engine, built.mic?.engine].forEach { $0?.stop() } }
                    return
                }
                self.install(built)
            }
        }
    }

    private func install(_ built: Built) {
        broadcast = built.broadcast
        monitor = built.monitor
        mic = built.mic
        micNode = built.micNode
        micFilter = built.micFilter
        broadcastTone = built.broadcastTone
        monitorTone = built.monitorTone
        status = built.status

        // A device change can stop an engine; rebuild only then. Engines also post this
        // notification harmlessly right after we move them off the default device —
        // rebuilding on those would restart the mic forever.
        let engines = [broadcast?.engine, monitor?.engine, mic?.engine].compactMap { $0 }
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

    /// Everything that talks to audio devices. Runs on `setupQueue` because a stuck driver
    /// can block these calls indefinitely.
    private static func build(config: Config, micAllowed: Bool, realtime: RealtimeState, voiceCount: Int) -> Built {
        var built = Built()

        // Microphone (optional).
        if config.micPassthrough {
            let device = config.micDevice.flatMap { AudioDevices.find($0, output: false) }
                ?? (config.micDevice == nil ? AudioDevices.defaultDevice(output: false) : nil)
            if !micAllowed {
                built.status.micProblem = "Microphone access not granted"
            } else if let device {
                if device.name.localizedCaseInsensitiveContains(config.outputDevice) {
                    built.status.micProblem = "Mic is set to the virtual device — pick your real mic"
                } else {
                    do {
                        built.mic = try MicCapture(device: device.id)
                        built.status.mic = device.name
                    } catch {
                        built.status.micProblem = "\(device.name): \(error.localizedDescription)"
                    }
                }
            } else {
                built.status.micProblem = "Mic “\(config.micDevice ?? "default")” not found"
            }
        }

        // Virtual device Zoom listens to.
        if let device = AudioDevices.find(config.outputDevice, output: true) {
            do {
                let bus = try OutputBus(device: device.id, voiceCount: voiceCount)
                bus.effects.outputVolume = config.soundVolume
                if let mic = built.mic {
                    let format = AVAudioFormat(standardFormatWithSampleRate: mic.sampleRate, channels: 1)!
                    let ring = mic.ring
                    let state = realtime
                    let voice = AVAudioSourceNode(format: format) { _, _, frames, list in
                        let out = UnsafeMutableAudioBufferListPointer(list)
                        guard let data = out[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                        let n = Int(frames)
                        ring.read(into: data, count: n) // keep draining while censored
                        if state.censor.load(ordering: .relaxed) { data.update(repeating: 0, count: n) }
                        return noErr
                    }
                    voice.volume = config.micVolume
                    // Always in the graph so it can be switched without restarting the mic.
                    let filter = makeVoiceIsolation()
                    configure(filter, config)
                    bus.add(voice, format: format, through: filter)
                    built.micNode = voice
                    built.micFilter = filter
                }
                let tone = bus.addCensorTone(realtime)
                tone.volume = config.micVolume
                built.broadcastTone = tone
                built.broadcast = bus
                built.status.output = device.name
            } catch {
                built.status.outputProblem = "\(device.name): \(error.localizedDescription)"
            }
        } else {
            built.status.outputProblem = "“\(config.outputDevice)” not found — is BlackHole installed?"
        }

        // What you hear.
        if config.monitor {
            let device = config.monitorDevice.flatMap { AudioDevices.find($0, output: true) }
                ?? (config.monitorDevice == nil ? AudioDevices.defaultDevice(output: true) : nil)
            if let device, device.name != built.status.output {
                do {
                    let bus = try OutputBus(device: device.id, voiceCount: voiceCount)
                    bus.effects.outputVolume = config.monitorVolume
                    let tone = bus.addCensorTone(realtime)
                    tone.volume = config.monitorVolume
                    built.monitorTone = tone
                    built.monitor = bus
                    built.status.monitor = device.name
                } catch {
                    NSLog("Soundboard: monitor device \(device.name): \(error.localizedDescription)")
                }
            }
        }

        for (bus, label) in [(built.broadcast, "virtual device"), (built.monitor, "monitor")] {
            guard let bus else { continue }
            do { try bus.start() } catch {
                NSLog("Soundboard: starting \(label) failed: \(error)")
                if label == "virtual device" {
                    built.status.outputProblem = "Could not start: \(error.localizedDescription)"
                    built.broadcast = nil
                } else {
                    built.monitor = nil
                    built.status.monitor = nil
                }
            }
        }
        if let mic = built.mic {
            do { try mic.start() } catch {
                built.status.micProblem = "Could not start mic: \(error.localizedDescription)"
                built.status.mic = nil
                built.mic = nil
            }
        }

        return built
    }

    private func needsRebuild(_ engine: AVAudioEngine) -> Bool {
        if !engine.isRunning { return true }
        if let mic, engine === mic.engine {
            // The ring buffer and mixer were set up for the old rate.
            return engine.inputNode.outputFormat(forBus: 0).sampleRate != mic.sampleRate
        }
        return false
    }

    func teardown() {
        stopAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let engines = [mic?.engine, broadcast?.engine, monitor?.engine]
        setupQueue.async { engines.forEach { $0?.stop() } }
        mic = nil
        broadcast = nil
        monitor = nil
        micNode = nil
        micFilter = nil
        broadcastTone = nil
        monitorTone = nil
    }

    // MARK: Playback (main thread)

    private var runningBuses: [OutputBus] {
        [broadcast, monitor].compactMap { $0 }.filter { $0.engine.isRunning }
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
        let buses = runningBuses
        guard !buses.isEmpty else { return }

        let v = (0..<voiceCount).first { voiceOwner[$0] == nil } ?? nextVoice
        nextVoice = (v + 1) % voiceCount
        release(v)

        let wasPlaying = isPlaying(key)
        voiceToken[v] &+= 1
        let token = voiceToken[v]
        voiceOwner[v] = key
        voiceIsOverlay[v] = mode == .overlay

        for (i, bus) in buses.enumerated() {
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
        if !wasPlaying { onPlaybackChange?(key, true) }
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
    }

    private func voiceFinished(_ v: Int, token: Int) {
        guard voiceToken[v] == token, let key = voiceOwner[v] else { return }
        voiceOwner[v] = nil
        if !isPlaying(key) { onPlaybackChange?(key, false) }
    }

    /// Applies volume and noise suppression changes without restarting anything.
    func setVolumes(_ config: Config) {
        broadcast?.effects.outputVolume = config.soundVolume
        micNode?.volume = config.micVolume
        broadcastTone?.volume = config.micVolume
        monitor?.effects.outputVolume = config.monitorVolume
        monitorTone?.volume = config.monitorVolume
        if let micFilter { Self.configure(micFilter, config) }
    }

    private static func configure(_ filter: AVAudioUnitEffect, _ config: Config) {
        filter.bypass = !config.noiseSuppression
        filter.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?
            .value = config.noiseSuppressionStrength * 100
    }

    func setCensor(_ on: Bool) {
        realtime.censor.store(on, ordering: .relaxed)
    }
}
