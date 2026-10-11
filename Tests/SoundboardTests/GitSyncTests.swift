import XCTest
@testable import SoundboardFetch

final class GitSyncTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "soundboard-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temp)
    }

    private func folder(_ name: String, library: [[String: Any]]) throws -> URL {
        let url = temp.appending(path: name)
        try FileManager.default.createDirectory(at: url.appending(path: "sounds"), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "library": library, "pages": [Any]()])
        try data.write(to: url.appending(path: "config.json"))
        return url
    }

    private func starter(_ id: String) -> [String: Any] {
        ["id": id, "name": id, "file": "/System/Library/Sounds/Glass.aiff"]
    }

    func testStarterConfigIsUntouched() throws {
        XCTAssertTrue(GitSync.isUntouchedStarter(try folder("a", library: [starter("ding")])))
    }

    func testOwnSoundOrFileIsNotUntouched() throws {
        XCTAssertFalse(GitSync.isUntouchedStarter(try folder("b", library: [starter("ding"), ["id": "x", "name": "x", "file": "x.wav"]])))
        let c = try folder("c", library: [starter("ding")])
        try Data().write(to: c.appending(path: "sounds/x.wav"))
        XCTAssertFalse(GitSync.isUntouchedStarter(c))
    }
}
