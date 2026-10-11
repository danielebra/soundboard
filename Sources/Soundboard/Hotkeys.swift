import Carbon
import Foundation

/// What a global keyboard shortcut does. Keys are positions on the current page, like the
/// deck's, so the shortcuts need no setup and follow the pad as it changes.
enum ShortcutCommand: Hashable {
    /// Key 1…10 of the current page (index 0…9), on the number row or the numeric keypad.
    case key(Int)
    case previousPage, nextPage, stopAll, palette

    static let all: [ShortcutCommand] = (0..<10).map(ShortcutCommand.key) + [.previousPage, .nextPage, .stopAll, .palette]

    /// The key that goes with the modifiers, as printed on a US keyboard.
    var keyName: String {
        switch self {
        case let .key(index): index == 9 ? "0" : "\(index + 1)"
        case .previousPage: "["
        case .nextPage: "]"
        case .stopAll: "."
        case .palette: "P"
        }
    }

    /// Physical keys (US positions, so other layouts use the same keys). Digits and the period
    /// work on the numeric keypad too.
    var keyCodes: [Int] {
        switch self {
        case let .key(index):
            [[kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
              kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0][index],
             [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
              kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_Keypad0][index]]
        case .previousPage: [kVK_ANSI_LeftBracket]
        case .nextPage: [kVK_ANSI_RightBracket]
        case .stopAll: [kVK_ANSI_Period, kVK_ANSI_KeypadDecimal]
        case .palette: [kVK_ANSI_P]
        }
    }

    /// Every registered key combination; a hot key's id is its index here.
    static let bindings: [(command: ShortcutCommand, keyCode: Int)] =
        all.flatMap { command in command.keyCodes.map { (command, $0) } }
}

extension ShortcutModifiers {
    var carbonFlags: UInt32 {
        switch self {
        case .off: 0
        case .controlOption: UInt32(controlKey | optionKey)
        case .controlOptionCommand: UInt32(controlKey | optionKey | cmdKey)
        case .hyper: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        }
    }
}

/// Global keyboard shortcuts as Carbon hot keys: unlike key event monitors, they need no
/// Accessibility permission and work from the sandbox. Registering succeeds even when another
/// app holds the same combination (tested), so clashes can't be detected or reported.
final class Hotkeys {
    /// A shortcut went down (`true`) or up (`false`). Called on the main thread.
    var onCommand: ((ShortcutCommand, Bool) -> Void)?

    var modifiers: ShortcutModifiers = .off {
        didSet { if modifiers != oldValue { register() } }
    }

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// Shortcuts being held, so a repeat can't press a key twice.
    private var held: Set<UInt32> = []
    private static let signature: OSType = 0x534E_4442 // "SNDB"
    private let debug = ProcessInfo.processInfo.environment["SOUNDBOARD_DEBUG"] != nil

    private func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        held.removeAll()
        guard modifiers != .off else { return }
        installHandler()
        for (i, binding) in ShortcutCommand.bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i))
            let status = RegisterEventHotKey(UInt32(binding.keyCode), modifiers.carbonFlags, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                NSLog("Soundboard: registering shortcut %@ failed (%d)", modifiers.symbols + binding.command.keyName, status)
            }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            hotkeys.handle(id.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, types.count, &types,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Hot key `id` (an index into `ShortcutCommand.bindings`) went down or up.
    func handle(_ id: UInt32, pressed: Bool) {
        guard ShortcutCommand.bindings.indices.contains(Int(id)) else { return }
        let command = ShortcutCommand.bindings[Int(id)].command
        if debug { NSLog("Soundboard: shortcut %@ %@", command.keyName, pressed ? "down" : "up") }
        if pressed {
            guard held.insert(id).inserted else { return }
        } else {
            guard held.remove(id) != nil else { return }
        }
        onCommand?(command, pressed)
    }
}
