import XCTest
@testable import SoundboardFetch

final class FetchHelpersTests: XCTestCase {
    func testUnescapeDecodesEntitiesAndAngularMarkers() {
        XCTAssertEqual(unescape("&q;a&q; &amp; &s;b&s; &lt;x&g;"), "\"a\" & 'b' &lt;x>")
        XCTAssertEqual(unescape("https:\\/\\/x.com\\u002Fa.mp3"), "https://x.com/a.mp3")
        XCTAssertEqual(unescape("&#x27;&#39;&quot;"), "''\"")
    }

    func testIsMediaIgnoresCaseAndRejectsOtherFiles() {
        XCTAssertTrue(isMedia(URL(string: "https://x.com/a.MP3")!))
        XCTAssertTrue(isMedia(URL(string: "https://x.com/a.webm?x=1")!))
        XCTAssertFalse(isMedia(URL(string: "https://x.com/a.html")!))
        XCTAssertFalse(isMedia(URL(string: "https://x.com/a")!))
    }

    func testNiceNameCleansTheFileName() {
        XCTAssertEqual(niceName(URL(string: "https://x.com/air-horn_loud%20one.mp3")!), "air horn loud one")
    }
}
