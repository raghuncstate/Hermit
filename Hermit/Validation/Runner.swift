import Foundation

@main
struct Runner {
    static func main() throws {
        try testCommandBlocks()
        try testCommandErrors()
        try testOctalOutput()
        try testOutputAcrossChunks()
        try testANSIPlainText()
        try testLayoutParser()
        print("HermitCoreValidationRunner: all checks passed")
    }

    private static func testCommandBlocks() throws {
        var parser = TmuxProtocolParser()
        let input = """
        %begin 1 42 1
        $0|mobile|1|1700000000
        %end 1 42 1

        """
        let messages = parser.append(Data(input.utf8))
        precondition(messages == [
            .commandStarted(commandNumber: 42),
            .commandFinished(TmuxCommandBlock(commandNumber: 42, output: "$0|mobile|1|1700000000", isError: false)),
        ])
    }

    private static func testCommandErrors() throws {
        var parser = TmuxProtocolParser()
        let input = """
        %begin 1 43 1
        no such pane
        %error 1 43 1

        """
        let messages = parser.append(Data(input.utf8))
        precondition(messages.last == .commandFinished(TmuxCommandBlock(commandNumber: 43, output: "no such pane", isError: true)))
    }

    private static func testOctalOutput() throws {
        let data = TmuxProtocolParser.decodeOutputBytes("ls /\\015\\012backslash=\\134")
        precondition(String(decoding: data, as: UTF8.self) == "ls /\r\nbackslash=\\")
    }

    private static func testOutputAcrossChunks() throws {
        var parser = TmuxProtocolParser()
        let first = parser.append(Data("%output %12 hel".utf8))
        let second = parser.append(Data("lo\\040world\\012\n".utf8))
        precondition(first.isEmpty)
        precondition(second == [
            .event(.output(paneId: "%12", bytes: Data("hello world\n".utf8)))
        ])
    }

    private static func testANSIPlainText() throws {
        let plain = AnsiAttributedStringParser.plainText("normal \u{1B}[31mred\u{1B}[0m done")
        precondition(plain == "normal red done")
        let lines = AnsiAttributedStringParser.parseLines("one\n\u{1B}[1mtwo\u{1B}[0m")
        precondition(lines.count == 2)
        precondition(String(lines[0].text.characters) == "one")
        precondition(String(lines[1].text.characters) == "two")
    }

    private static func testLayoutParser() throws {
        let layout = "bb62,204x53,0,0{101x53,0,0,0,102x53,102,0[102x26,102,0,1,102x26,102,27,2]}"
        let node = try PaneLayoutParser.parse(layout)
        let leaves = node.leaves.sorted { $0.paneIndex < $1.paneIndex }
        precondition(leaves.map(\.paneIndex) == [0, 1, 2])
        precondition(node.rect.width == 204)
        precondition(leaves[1].rect.y == 0)
        precondition(leaves[2].rect.y == 27)
    }
}
