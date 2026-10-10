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

    func add(_ node: AVAudioSourceNode, format: AVAudioFormat) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
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

    private let voiceCount = 12
    private var broadcast: OutputBus?
    private var monitor: OutputBus?
    private var mic: MicCapture?
    private let realtime = RealtimeState()
    private var observers: [NSObjectProtocol] = []

    private var voiceOwner: [String?]
    private var voiceToken: [Int]
    private var nextVoice = 0
    private var playing: [String: Int] = [:]

    init() {
        voiceOwner = Array(repeating: nil, count: voiceCount)
        voiceToken = Array(repeating: 0, count: voiceCount)
    }

    var isCensoring: Bool { realtime.censor.load(ordering: .relaxed) }

    func isPlaying(_ key: String) -> Bool { playing[key] != nil }

    // MARK: Engine lifecycle

    func rebuild(config: Config, micAllowed: Bool) {
        teardown()
        status = Status()

        // Microphone (optional).
        if config.micPassthrough {
            let device = config.micDevice.flatMap { AudioDevices.find($0, output: false) }
                ?? (config.micDevice == nil ? AudioDevices.defaultDevice(output: false) : nil)
            if !micAllowed {
                status.micProblem = "Microphone access not granted"
            } else if let device {
                if device.name.localizedCaseInsensitiveContains(config.outputDevice) {
                    status.micProblem = "Mic is set to the virtual device — pick your real mic"
                } else {
                    do {
                        mic = try MicCapture(device: device.id)
                        status.mic = device.name
                    } catch {
                        status.micProblem = "\(device.name): \(error.localizedDescription)"
                    }
                }
            } else {
                status.micProblem = "Mic “\(config.micDevice ?? "default")” not found"
            }
        }

        // Virtual device Zoom listens to.
        if let device = AudioDevices.find(config.outputDevice, output: true) {
            do {
                let bus = try OutputBus(device: device.id, voiceCount: voiceCount)
                bus.effects.outputVolume = config.soundVolume
                let rate = mic?.sampleRate ?? mixFormat.sampleRate
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                let ring = mic?.ring
                let state = realtime
                var phase = 0.0
                let voice = AVAudioSourceNode(format: format) { isSilence, _, frames, list in
                    let out = UnsafeMutableAudioBufferListPointer(list)
                    guard let data = out[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                    let n = Int(frames)
                    if let ring { ring.read(into: data, count: n) } else { data.update(repeating: 0, count: n) }
                    if state.censor.load(ordering: .relaxed) {
                        bleep(data, count: n, phase: &phase, sampleRate: rate)
                    } else if ring == nil {
                        isSilence.pointee = true
                    }
                    return noErr
                }
                voice.volume = config.micVolume
                bus.add(voice, format: format)
                broadcast = bus
                status.output = device.name
            } catch {
                status.outputProblem = "\(device.name): \(error.localizedDescription)"
            }
        } else {
            status.outputProblem = "“\(config.outputDevice)” not found — is BlackHole installed?"
        }

        // What you hear.
        if config.monitor {
            let device = config.monitorDevice.flatMap { AudioDevices.find($0, output: true) }
                ?? (config.monitorDevice == nil ? AudioDevices.defaultDevice(output: true) : nil)
            if let device, device.name != status.output {
                do {
                    let bus = try OutputBus(device: device.id, voiceCount: voiceCount)
                    bus.effects.outputVolume = config.monitorVolume
                    let format = AVAudioFormat(standardFormatWithSampleRate: mixFormat.sampleRate, channels: 1)!
                    let state = realtime
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
                    tone.volume = config.monitorVolume
                    bus.add(tone, format: format)
                    monitor = bus
                    status.monitor = device.name
                } catch {
                    NSLog("Soundboard: monitor device \(device.name): \(error.localizedDescription)")
                }
            }
        }

        for (bus, label) in [(broadcast, "virtual device"), (monitor, "monitor")] {
            guard let bus else { continue }
            do { try bus.start() } catch {
                NSLog("Soundboard: starting \(label) failed: \(error)")
                if label == "virtual device" {
                    status.outputProblem = "Could not start: \(error.localizedDescription)"
                    broadcast = nil
                } else {
                    monitor = nil
                    status.monitor = nil
                }
            }
        }
        if let mic {
            do { try mic.start() } catch {
                status.micProblem = "Could not start mic: \(error.localizedDescription)"
                status.mic = nil
                self.mic = nil
            }
        }

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
        mic?.engine.stop()
        broadcast?.engine.stop()
        monitor?.engine.stop()
        mic = nil
        broadcast = nil
        monitor = nil
    }

    // MARK: Playback (main thread)

    private var runningBuses: [OutputBus] {
        [broadcast, monitor].compactMap { $0 }.filter { $0.engine.isRunning }
    }

    func play(key: String, sound: AVAudioPCMBuffer, volume: Float, stopOthers: Bool) {
        if playing[key] != nil {
            stop(key)
            return
        }
        if stopOthers { stopAll() }
        let buses = runningBuses
        guard !buses.isEmpty else { return }

        let v = (0..<voiceCount).first { voiceOwner[$0] == nil } ?? nextVoice
        nextVoice = (v + 1) % voiceCount
        if let previous = voiceOwner[v] { stop(previous) }

        voiceToken[v] &+= 1
        let token = voiceToken[v]
        voiceOwner[v] = key
        playing[key] = v

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
        onPlaybackChange?(key, true)
    }

    func stop(_ key: String) {
        guard let v = playing.removeValue(forKey: key) else { return }
        voiceToken[v] &+= 1
        voiceOwner[v] = nil
        for bus in [broadcast, monitor].compactMap({ $0 }) { bus.voices[v].stop() }
        onPlaybackChange?(key, false)
    }

    func stopAll() {
        for key in Array(playing.keys) { stop(key) }
    }

    private func voiceFinished(_ v: Int, token: Int) {
        guard voiceToken[v] == token, let key = voiceOwner[v] else { return }
        voiceOwner[v] = nil
        playing[key] = nil
        onPlaybackChange?(key, false)
    }

    func setCensor(_ on: Bool) {
        realtime.censor.store(on, ordering: .relaxed)
    }
}
