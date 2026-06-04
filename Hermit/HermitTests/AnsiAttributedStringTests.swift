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

    func testDetectsIndentedWrappedTerminalLinks() {
        let fullURL = "https://nvidia.atlassian.net/wiki/spaces/SPS/pages/3535324266/LP30+UDS"
        let wrappedURL = "  https://nvidia.atlassian.net/wiki/spaces/S\n  PS/pages/3535324266/LP30+UDS"
        let text = NSMutableAttributedString(string: wrappedURL)

        TerminalLinkDetector.addDetectedLinks(to: text)

        let nsString = text.string as NSString
        let firstFragment = nsString.range(of: "https://nvidia.atlassian.net")
        let secondFragment = nsString.range(of: "PS/pages/3535324266")
        let skippedIndent = nsString.range(of: "\n  PS")
        let firstLink = text.attribute(.link, at: firstFragment.location, effectiveRange: nil) as? URL
        let secondLink = text.attribute(.link, at: secondFragment.location, effectiveRange: nil) as? URL

        XCTAssertEqual(firstLink?.absoluteString, fullURL)
        XCTAssertEqual(secondLink?.absoluteString, fullURL)
        XCTAssertNil(text.attribute(.link, at: skippedIndent.location + 1, effectiveRange: nil))
        XCTAssertNil(text.attribute(.link, at: skippedIndent.location + 2, effectiveRange: nil))
    }

    func testDoesNotJoinShortLinkToNextIndentedLine() {
        let text = NSMutableAttributedString(string: "Open https://example.com\n  Then continue")

        TerminalLinkDetector.addDetectedLinks(to: text)

        let nsString = text.string as NSString
        let linkFragment = nsString.range(of: "https://example.com")
        let nextLine = nsString.range(of: "Then")
        let link = text.attribute(.link, at: linkFragment.location, effectiveRange: nil) as? URL

        XCTAssertEqual(link?.absoluteString, "https://example.com")
        XCTAssertNil(text.attribute(.link, at: nextLine.location, effectiveRange: nil))
    }
#endif
}
