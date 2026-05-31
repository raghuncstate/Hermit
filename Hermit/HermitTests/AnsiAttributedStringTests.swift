import XCTest
#if canImport(UIKit)
import UIKit
#endif
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

#if canImport(UIKit)
    func testPreservesSGRForegroundInAttributedText() {
        let paragraphStyle = NSMutableParagraphStyle()
        let text = AnsiAttributedStringParser.attributedText(
            "normal \u{1B}[31mred\u{1B}[0m done",
            fontSize: 14,
            paragraphStyle: paragraphStyle
        )

        XCTAssertEqual(text.string, "normal red done")
        let range = (text.string as NSString).range(of: "red")
        let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        XCTAssertNotNil(color)

        let resolved = color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(resolved?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true)
        XCTAssertGreaterThan(red, 0.7)
        XCTAssertLessThan(green, 0.3)
        XCTAssertLessThan(blue, 0.3)
    }

    func testPreservesTrueColorBackgroundInAttributedText() {
        let paragraphStyle = NSMutableParagraphStyle()
        let text = AnsiAttributedStringParser.attributedText(
            "\u{1B}[48;2;10;20;30mblock\u{1B}[0m",
            fontSize: 14,
            paragraphStyle: paragraphStyle
        )

        XCTAssertEqual(text.string, "block")
        let color = text.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertNotNil(color)

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true)
        XCTAssertEqual(red, 10.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(green, 20.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(blue, 30.0 / 255.0, accuracy: 0.01)
    }
#endif
}
