import XCTest
@testable import Soundboard

final class ConfigTests: XCTestCase {
    func testDefaultJSONDecodes() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(Config.defaultJSON.utf8))
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.library.count, 6)
        XCTAssertEqual(config.pages.first?.count, 8)
    }

    func testUpgradeMovesVersion1SoundsIntoLibrary() throws {
        let v1 = """
        { "version": 1, "pages": [[ { "sound": "airhorn.wav", "label": "Horn" }, null ]] }
        """
        var config = try JSONDecoder().decode(Config.self, from: Data(v1.utf8))
        XCTAssertTrue(config.upgrade(soundFiles: []))
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.library.count, 1)
        XCTAssertEqual(config.library[0].file, "airhorn.wav")
        XCTAssertEqual(config.pages[0][0]?.sound, config.library[0].id)
        XCTAssertNil(config.pages[0][1])
    }

    func testUpgradeAddsDroppedFilesOnce() {
        var config = Config()
        XCTAssertTrue(config.upgrade(soundFiles: ["new-sound.wav"]))
        XCTAssertEqual(config.library.map(\.file), ["new-sound.wav"])
        XCTAssertEqual(config.library[0].name, "new sound")
        XCTAssertFalse(config.upgrade(soundFiles: ["new-sound.wav"]))
        XCTAssertEqual(config.library.count, 1)
    }

    func testFilesSplitSharedFromLocalAndRoundTrip() throws {
        var config = Config()
        config.micVolume = 0.5
        config.library = [SoundEntry(id: "a", name: "A", file: "a.wav")]
        let (shared, local) = try config.encodedFiles()
        let sharedKeys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: shared) as? [String: Any]).keys)
        let localKeys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: local) as? [String: Any]).keys)
        XCTAssertTrue(sharedKeys.isSubset(of: Config.sharedKeys))
        XCTAssertTrue(localKeys.isDisjoint(with: Config.sharedKeys))
        XCTAssertTrue(localKeys.contains("micVolume"))
        XCTAssertEqual(try Config.decode(shared: shared, local: local), config)
    }

    func testShortcutsAreLocalAndFallBackToTheDefault() throws {
        var config = Config()
        config.shortcuts = .hyper
        let (shared, local) = try config.encodedFiles()
        XCTAssertFalse(String(decoding: shared, as: UTF8.self).contains("shortcuts"))
        XCTAssertEqual(try Config.decode(shared: shared, local: local).shortcuts, .hyper)

        let unknown = try Config.decode(shared: shared, local: Data(#"{ "shortcuts": "meta" }"#.utf8))
        XCTAssertEqual(unknown.shortcuts, .controlOption)
        XCTAssertEqual(try Config.decode(shared: shared, local: Data("{}".utf8)).shortcuts, .controlOption)
    }
}
