import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static let queryQueue = DispatchQueue(label: "soundboard.audio.devices")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [AudioDevice] = []
    nonisolated(unsafe) private static var querying = false

    /// All audio devices. A misbehaving driver can make CoreAudio queries hang forever, so
    /// the query runs on its own queue and callers get the last known list after 0.5 s
    /// (or immediately while a previous query is still stuck).
    static func all() -> [AudioDevice] {
        lock.lock()
        if querying {
            defer { lock.unlock() }
            return cached
        }
        querying = true
        lock.unlock()

        let done = DispatchSemaphore(value: 0)
        queryQueue.async {
            let devices = query()
            lock.lock()
            cached = devices
            querying = false
            lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private static func query() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map {
            AudioDevice(id: $0, name: name(of: $0),
                        inputChannels: channels(of: $0, scope: kAudioObjectPropertyScopeInput),
                        outputChannels: channels(of: $0, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    static func name(of id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }

    static func channels(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Exact (case-insensitive) name match first, then substring match.
    static func find(_ name: String, output: Bool) -> AudioDevice? {
        let candidates = all().filter { output ? $0.outputChannels > 0 : $0.inputChannels > 0 }
        return candidates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? candidates.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    static func defaultDevice(output: Bool) -> AudioDevice? {
        var addr = address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return all().first { $0.id == id }
    }

    /// Calls `handler` on the main queue when devices are plugged/unplugged or defaults change.
    /// CoreAudio also fires these for no-op updates, so only real changes get through.
    static func observeChanges(_ handler: @escaping () -> Void) {
        var last = snapshot()
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { _, _ in
                let now = snapshot()
                guard now != last else { return }
                last = now
                handler()
            }
        }
    }

    private static func snapshot() -> [String] {
        all().map { "\($0.id):\($0.name):\($0.inputChannels):\($0.outputChannels)" }
            + ["in:\(defaultDevice(output: false)?.id ?? 0)", "out:\(defaultDevice(output: true)?.id ?? 0)"]
    }
}
