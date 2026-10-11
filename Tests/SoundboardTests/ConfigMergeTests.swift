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

final class ConfigMergeRunTests: XCTestCase {
    private func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    func testRunMergesFilesAndWritesTheResultOverOurs() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appending(path: "base.json"), ours = dir.appending(path: "ours.json"), theirs = dir.appending(path: "theirs.json")
        try write(["version": 2, "library": [["id": "a", "name": "A", "file": "a.wav"]], "pages": []], to: base)
        try write(["version": 2, "library": [["id": "a", "name": "A", "file": "a.wav", "volume": 0.8]], "pages": []], to: ours)
        try write(["version": 2, "library": [["id": "a", "name": "A", "file": "a.wav"], ["id": "b", "name": "B", "file": "b.wav"]],
                   "pages": []], to: theirs)

        XCTAssertEqual(ConfigMerge.run(base: base.path, ours: ours.path, theirs: theirs.path), 0)

        let text = try String(contentsOf: ours, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"volume\" : 0.8"), text)
        let merged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((merged["library"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["a", "b"])
    }

    func testRunFailsWhenAFileIsMissingOrInvalid() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appending(path: "bad.json")
        try Data("not json".utf8).write(to: bad)
        XCTAssertEqual(ConfigMerge.run(base: bad.path, ours: bad.path, theirs: dir.appending(path: "missing.json").path), 1)
        XCTAssertEqual(ConfigMerge.run(base: "", ours: bad.path, theirs: bad.path), 1)
    }
}
