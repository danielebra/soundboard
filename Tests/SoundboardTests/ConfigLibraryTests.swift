import XCTest
@testable import Soundboard

final class ConfigLibraryTests: XCTestCase {
    private func config() -> Config {
        var config = Config()
        config.library = [
            SoundEntry(id: "ding", name: "Ding", file: "ding.wav", label: "Ding", image: "ding.png", color: "#2563eb"),
            SoundEntry(id: "boop", name: "Boop", file: "boop.wav"),
        ]
        config.pages = [
            [ButtonConfig(sound: "ding"), nil, ButtonConfig(action: .stop, label: "STOP", color: "#dc2626")],
            [ButtonConfig(sound: "boop"), ButtonConfig(sound: "ding"), ButtonConfig(sound: "gone")],
        ]
        return config
    }

    func testSlug() {
        XCTAssertEqual(Config.slug("Hello, World!"), "hello-world")
        XCTAssertEqual(Config.slug("  --A__b  "), "a-b")
        XCTAssertEqual(Config.slug("!!!"), "sound")
        XCTAssertEqual(Config.slug(String(repeating: "a", count: 100)).count, 40)
    }

    func testUniqueIDAddsASuffixOnCollision() {
        var config = config()
        XCTAssertEqual(config.uniqueID(for: "Ding"), "ding-2")
        config.library.append(SoundEntry(id: "ding-2", name: "Ding", file: "x.wav"))
        XCTAssertEqual(config.uniqueID(for: "Ding"), "ding-3")
        XCTAssertEqual(config.uniqueID(for: "Fresh"), "fresh")
    }

    func testDisplayNameDropsExtensionAndSeparators() {
        XCTAssertEqual(Config.displayName(forFile: "/a/b/air-horn_loud.mp3"), "air horn loud")
    }

    func testFaceForEachKeyKind() {
        let config = config()
        XCTAssertTrue(config.face(nil).isEmpty)

        let sound = config.face(config.pages[0][0])
        XCTAssertEqual(sound.label, "Ding")
        XCTAssertEqual(sound.image, "ding.png")
        XCTAssertEqual(sound.soundFile, "ding.wav")
        XCTAssertFalse(sound.dangling)

        let stop = config.face(config.pages[0][2])
        XCTAssertEqual(stop.label, "STOP")
        XCTAssertNil(stop.soundFile)

        let missing = config.face(config.pages[1][2])
        XCTAssertTrue(missing.dangling)
        XCTAssertEqual(missing.label, "?")
    }

    func testUsagesFindsOnlySoundKeys() {
        let config = config()
        XCTAssertEqual(config.usages(of: "ding").map { [$0.page, $0.key] }, [[0, 0], [1, 1]])
        XCTAssertEqual(config.usages(of: "boop").map { [$0.page, $0.key] }, [[1, 0]])
        XCTAssertTrue(config.usages(of: "nothing").isEmpty)
        XCTAssertEqual(config.entry("boop")?.name, "Boop")
        XCTAssertNil(config.entry(nil))
    }

    func testUpgradeReusesIdenticalVersion1Sounds() throws {
        let v1 = """
        { "version": 1, "pages": [[ { "sound": "a.wav", "label": "A" }, { "sound": "a.wav", "label": "A" },
                                    { "sound": "a.wav", "label": "Other" } ]] }
        """
        var config = try JSONDecoder().decode(Config.self, from: Data(v1.utf8))
        XCTAssertTrue(config.upgrade(soundFiles: []))
        XCTAssertEqual(config.library.count, 2)
        XCTAssertEqual(config.pages[0][0]?.sound, config.pages[0][1]?.sound)
        XCTAssertNotEqual(config.pages[0][0]?.sound, config.pages[0][2]?.sound)
    }

    func testDecodeWithoutLocalUsesSettingsFromConfigJSON() throws {
        let legacy = #"{ "version": 2, "micVolume": 0.25, "library": [], "pages": [] }"#
        let config = try Config.decode(shared: Data(legacy.utf8), local: nil)
        XCTAssertEqual(config.micVolume, 0.25)
    }

    func testDecodeIgnoresAudioKeysInConfigJSONWhenLocalExists() throws {
        let shared = #"{ "version": 2, "micVolume": 0.25, "library": [], "pages": [] }"#
        let local = #"{ "micVolume": 0.5 }"#
        let config = try Config.decode(shared: Data(shared.utf8), local: Data(local.utf8))
        XCTAssertEqual(config.micVolume, 0.5)
    }

    func testHotCornerPoints() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(HotCorner.bottomLeft.point(of: rect), NSPoint(x: 0, y: 0))
        XCTAssertEqual(HotCorner.topRight.point(of: rect), NSPoint(x: 100, y: 50))
        XCTAssertEqual(HotCorner.topLeft.point(of: rect), NSPoint(x: 0, y: 50))
        XCTAssertEqual(HotCorner.bottomRight.point(of: rect), NSPoint(x: 100, y: 0))
    }
}
