import Foundation
import CoreGraphics

struct PaneLayoutRect: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var x: Int
    var y: Int
}

struct PaneLayoutLeaf: Identifiable, Equatable, Hashable {
    var paneIndex: Int
    var rect: PaneLayoutRect

    var id: Int { paneIndex }
}

indirect enum PaneLayoutNode: Equatable, Hashable {
    case pane(index: Int, rect: PaneLayoutRect)
    case split(rect: PaneLayoutRect, children: [PaneLayoutNode])

    var rect: PaneLayoutRect {
        switch self {
        case .pane(_, let rect), .split(let rect, _):
            rect
        }
    }

    var leaves: [PaneLayoutLeaf] {
        switch self {
        case .pane(let index, let rect):
            [PaneLayoutLeaf(paneIndex: index, rect: rect)]
        case .split(_, let children):
            children.flatMap(\.leaves)
        }
    }
}

enum PaneLayoutParserError: Error, Equatable {
    case empty
    case invalid
}

struct PaneLayoutParser {
    static func parse(_ layout: String) throws -> PaneLayoutNode {
        guard let comma = layout.firstIndex(of: ",") else {
            throw PaneLayoutParserError.empty
        }

        var parser = Parser(String(layout[layout.index(after: comma)...]))
        guard let node = parser.parseNode() else {
            throw PaneLayoutParserError.invalid
        }
        return node
    }

    static func frame(for rect: PaneLayoutRect, in container: CGSize, root: PaneLayoutRect) -> CGRect {
        guard root.width > 0, root.height > 0 else { return .zero }
        let scaleX = container.width / CGFloat(root.width)
        let scaleY = container.height / CGFloat(root.height)
        return CGRect(
            x: CGFloat(rect.x - root.x) * scaleX,
            y: CGFloat(rect.y - root.y) * scaleY,
            width: max(1, CGFloat(rect.width) * scaleX),
            height: max(1, CGFloat(rect.height) * scaleY)
        )
    }

    private struct Parser {
        var characters: [Character]
        var index = 0

        init(_ input: String) {
            characters = Array(input)
        }

        mutating func parseNode() -> PaneLayoutNode? {
            guard let rect = parseRect() else { return nil }

            if consume("{") || consume("[") {
                var children: [PaneLayoutNode] = []
                repeat {
                    guard let child = parseNode() else { return nil }
                    children.append(child)
                } while consume(",")

                guard consume("}") || consume("]") else { return nil }
                return .split(rect: rect, children: children)
            }

            guard consume(","),
                  let paneIndex = parseInt() else {
                return nil
            }
            return .pane(index: paneIndex, rect: rect)
        }

        mutating func parseRect() -> PaneLayoutRect? {
            guard let width = parseInt(),
                  consume("x"),
                  let height = parseInt(),
                  consume(","),
                  let x = parseInt(),
                  consume(","),
                  let y = parseInt() else {
                return nil
            }
            return PaneLayoutRect(width: width, height: height, x: x, y: y)
        }

        mutating func parseInt() -> Int? {
            let start = index
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
            guard index > start else { return nil }
            return Int(String(characters[start..<index]))
        }

        mutating func consume(_ character: Character) -> Bool {
            guard index < characters.count, characters[index] == character else {
                return false
            }
            index += 1
            return true
        }
    }
}
