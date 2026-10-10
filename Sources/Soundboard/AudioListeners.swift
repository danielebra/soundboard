import CoreAudio
import Foundation

/// Tells whether another app is reading input from a device (Zoom with BlackHole as its mic),
/// so the real mic only needs to be open while someone is listening.
///
/// Uses CoreAudio's per-process objects (macOS 14+): each process reports whether it's running
/// input and which devices it has open. Changes arrive as property notifications; nothing polls.
/// A process's device list covers every device it has open, in each direction the device
/// supports, so an app that only *plays* to BlackHole while recording another mic also counts.
/// That errs on the side of leaving the mic on.
final class AudioListeners {
    /// Called on the main queue when `isListening` changes.
    var onChange: ((Bool) -> Void)?
    /// Main thread.
    private(set) var isListening = false

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// HAL calls stay off the main thread (see `AudioDevices`), and notifications land here too.
    private let queue = DispatchQueue(label: "soundboard.audio.listeners")
    private let ownPID = getpid()
    // Queue only:
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var processes: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var reported: Bool?

    private static let processProperties = [
        address(kAudioProcessPropertyIsRunningInput),
        address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput),
    ]

    init() {
        var list = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(Self.system, &list, queue) { [weak self] _, _ in self?.refresh() }
    }

    /// Starts answering for `device` (nil: nobody is listening).
    func watch(_ device: AudioObjectID?) {
        queue.async {
            self.device = device ?? AudioObjectID(kAudioObjectUnknown)
            self.refresh()
        }
    }

    private func refresh() {
        let current = Self.objects(Self.system, kAudioHardwarePropertyProcessObjectList)
        updateObservers(current ?? [])

        let listening: Bool
        var who: [pid_t] = []
        if device == kAudioObjectUnknown {
            listening = false
        } else if let current {
            who = current.filter { process in
                Self.pid(of: process) != ownPID
                    && Self.isRunningInput(process)
                    && (Self.objects(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput) ?? [])
                        .contains(device)
            }.map(Self.pid(of:))
            listening = !who.isEmpty
        } else {
            listening = true // can't tell: keep the mic on rather than silently drop it from calls
        }
        guard listening != reported else { return }
        reported = listening
        NSLog("Soundboard: output listeners: %@", current == nil ? "unknown (query failed)" : "\(who)")
        DispatchQueue.main.async {
            self.isListening = listening
            self.onChange?(listening)
        }
    }

    /// Follows process objects as apps start and quit.
    private func updateObservers(_ current: [AudioObjectID]) {
        for (process, block) in processes where !current.contains(process) {
            for var address in Self.processProperties {
                AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            }
            processes[process] = nil
        }
        for process in current where processes[process] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            for var address in Self.processProperties {
                AudioObjectAddPropertyListenerBlock(process, &address, queue, block)
            }
            processes[process] = block
        }
    }

    // MARK: HAL helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// nil when the query fails (as opposed to an empty list).
    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard ids.isEmpty || AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid)
        return pid
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running)
        return running != 0
    }
}
