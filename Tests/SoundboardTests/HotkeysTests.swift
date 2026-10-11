import Carbon
import XCTest
@testable import Soundboard

final class HotkeysTests: XCTestCase {
    private func id(_ command: ShortcutCommand, keyCode: Int) throws -> UInt32 {
        UInt32(try XCTUnwrap(ShortcutCommand.bindings.firstIndex { $0.command == command && $0.keyCode == keyCode }))
    }

    func testEveryCommandHasAKeyAndNoKeyIsUsedTwice() {
        for command in ShortcutCommand.all {
            XCTAssertFalse(command.keyCodes.isEmpty, "\(command)")
        }
        let codes = ShortcutCommand.bindings.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testNumberRowAndKeypadPlayTheSameKeys() {
        let keys = ShortcutCommand.bindings.filter { if case .key = $0.command { true } else { false } }
        XCTAssertEqual(keys.count, 20)
        XCTAssertEqual(ShortcutCommand.key(0).keyCodes, [kVK_ANSI_1, kVK_ANSI_Keypad1])
        XCTAssertEqual(ShortcutCommand.key(9).keyCodes, [kVK_ANSI_0, kVK_ANSI_Keypad0])
        XCTAssertEqual(ShortcutCommand.key(9).keyName, "0")
        XCTAssertEqual(ShortcutCommand.key(2).keyName, "3")
    }

    /// macOS 15 refuses hot keys whose only modifiers are Option (or Option-Shift).
    func testEveryModifierChoiceIncludesControl() {
        for modifiers in ShortcutModifiers.allCases where modifiers != .off {
            XCTAssertNotEqual(modifiers.carbonFlags & UInt32(controlKey), 0, "\(modifiers)")
        }
        let flags = ShortcutModifiers.allCases.map(\.carbonFlags)
        XCTAssertEqual(Set(flags).count, flags.count)
    }

    func testHeldKeyFiresOnceAndUnknownIDsAreIgnored() throws {
        let hotkeys = Hotkeys()
        var events: [String] = []
        hotkeys.onCommand = { command, pressed in events.append("\(command.keyName) \(pressed ? "down" : "up")") }
        let row1 = try id(.key(0), keyCode: kVK_ANSI_1)
        let pad1 = try id(.key(0), keyCode: kVK_ANSI_Keypad1)

        hotkeys.handle(row1, pressed: false) // up without down
        hotkeys.handle(row1, pressed: true)
        hotkeys.handle(row1, pressed: true) // repeat while held
        hotkeys.handle(row1, pressed: false)
        hotkeys.handle(pad1, pressed: true)
        hotkeys.handle(pad1, pressed: false)
        hotkeys.handle(UInt32(ShortcutCommand.bindings.count), pressed: true)

        XCTAssertEqual(events, ["1 down", "1 up", "1 down", "1 up"])
    }
}
