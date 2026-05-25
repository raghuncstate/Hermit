import CoreGraphics
import XCTest
#if SWIFT_PACKAGE
@testable import HermitCore
#else
@testable import Hermit
#endif

final class PaneLayoutParserTests: XCTestCase {
    func testParsesNestedLayoutLeaves() throws {
        let layout = "bb62,204x53,0,0{101x53,0,0,0,102x53,102,0[102x26,102,0,1,102x26,102,27,2]}"
        let node = try PaneLayoutParser.parse(layout)
        let leaves = node.leaves.sorted { $0.paneIndex < $1.paneIndex }

        XCTAssertEqual(leaves.map(\.paneIndex), [0, 1, 2])
        XCTAssertEqual(node.rect.width, 204)
        XCTAssertEqual(leaves[1].rect.y, 0)
        XCTAssertEqual(leaves[2].rect.y, 27)
    }

    func testScalesFramesIntoContainer() {
        let root = PaneLayoutRect(width: 100, height: 50, x: 0, y: 0)
        let child = PaneLayoutRect(width: 50, height: 25, x: 50, y: 25)
        let frame = PaneLayoutParser.frame(for: child, in: CGSize(width: 200, height: 100), root: root)

        XCTAssertEqual(frame.origin.x, 100)
        XCTAssertEqual(frame.origin.y, 50)
        XCTAssertEqual(frame.width, 100)
        XCTAssertEqual(frame.height, 50)
    }
}
