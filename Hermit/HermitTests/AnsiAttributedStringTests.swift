import XCTest
#if SWIFT_PACKAGE
@testable import HermitCore
#else
@testable import Hermit
#endif

final class AnsiAttributedStringTests: XCTestCase {
    func testStripsSGRForPlainText() {
        let plain = AnsiAttributedStringParser.plainText("normal \u{1B}[31mred\u{1B}[0m done")
        XCTAssertEqual(plain, "normal red done")
    }

    func testSplitsParsedLines() {
        let lines = AnsiAttributedStringParser.parseLines("one\n\u{1B}[1mtwo\u{1B}[0m")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0].text.characters), "one")
        XCTAssertEqual(String(lines[1].text.characters), "two")
    }
}
