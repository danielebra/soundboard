import XCTest
@testable import SoundboardFetch

final class ConfigMergeTests: XCTestCase {
    private func sound(_ id: String, _ name: String, volume: Double? = nil, file: String? = nil) -> [String: Any] {
        var entry: [String: Any] = ["id": id, "name": name, "file": file ?? "\(id).wav"]
        if let volume { entry["volume"] = volume }
        return entry
    }

    private func config(library: [[String: Any]], pages: [Any] = []) -> [String: Any] {
        ["version": 2, "library": library, "pages": pages]
    }

    private func ids(_ merged: [String: Any]) -> [String] {
        (merged["library"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    func testDifferentSoundsAddedOnEachSideBothSurvive() {
        let base = config(library: [sound("a", "A")])
        let merged = ConfigMerge.merge(base: base,
                                       ours: config(library: [sound("a", "A"), sound("b", "B")]),
                                       theirs: config(library: [sound("a", "A"), sound("c", "C")]))
        XCTAssertEqual(Set(ids(merged)), ["a", "b", "c"])
    }

    func testDifferentFieldsOfTheSameSoundBothSurvive() throws {
        let base = config(library: [sound("a", "A")])
        let merged = ConfigMerge.merge(base: base,
                                       ours: config(library: [sound("a", "A", volume: 0.5)]),
                                       theirs: config(library: [sound("a", "Renamed")]))
        let entry = try XCTUnwrap((merged["library"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["name"] as? String, "Renamed")
        XCTAssertEqual(entry["volume"] as? Double, 0.5)
    }

    func testSameFieldEditedOnBothSidesTakesTheRepository() throws {
        let base = config(library: [sound("a", "A")])
        let merged = ConfigMerge.merge(base: base,
                                       ours: config(library: [sound("a", "Ours")]),
                                       theirs: config(library: [sound("a", "Theirs")]))
        XCTAssertEqual((merged["library"] as? [[String: Any]])?.first?["name"] as? String, "Theirs")
    }

    func testEditBeatsRemoval() {
        let base = config(library: [sound("a", "A")])
        let edited = config(library: [sound("a", "Edited")])
        let removed = config(library: [])
        XCTAssertEqual(ids(ConfigMerge.merge(base: base, ours: edited, theirs: removed)), ["a"])
        XCTAssertEqual(ids(ConfigMerge.merge(base: base, ours: removed, theirs: edited)), ["a"])
    }

    func testRemovalWithoutEditRemoves() {
        let base = config(library: [sound("a", "A")])
        let merged = ConfigMerge.merge(base: base, ours: config(library: []), theirs: base)
        XCTAssertEqual(ids(merged), [])
    }

    func testPagesMergeKeyByKey() throws {
        let base = config(library: [], pages: [[["sound": "a"], NSNull(), NSNull()]])
        let ours = config(library: [], pages: [[["sound": "a"], ["sound": "b"], NSNull()]])
        let theirs = config(library: [], pages: [[["sound": "a"], NSNull(), ["sound": "c"]]])
        let merged = ConfigMerge.merge(base: base, ours: ours, theirs: theirs)
        let keys = try XCTUnwrap((merged["pages"] as? [[Any]])?.first)
        XCTAssertEqual((keys[1] as? [String: String])?["sound"], "b")
        XCTAssertEqual((keys[2] as? [String: String])?["sound"], "c")
    }

    func testJoiningMacDropsUnusedStarterSounds() {
        let starter = sound("ding", "Ding", file: "/System/Library/Sounds/Glass.aiff")
        let ours = config(library: [starter], pages: [[NSNull()]])
        let theirs = config(library: [sound("a", "A")], pages: [[["sound": "a"]]])
        let merged = ConfigMerge.merge(base: [:], ours: ours, theirs: theirs)
        XCTAssertEqual(ids(merged), ["a"])
    }

    func testTidyNumbersKeepsDecimalsAsTyped() throws {
        let data = try JSONSerialization.data(withJSONObject: ConfigMerge.tidyNumbers(["v": 0.8, "flag": true, "n": 3]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("0.8") && !text.contains("0.8000"), text)
        XCTAssertTrue(text.contains("true"), text)
    }
}
