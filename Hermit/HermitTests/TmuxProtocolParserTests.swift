import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import HermitCore
#else
@testable import Hermit
#endif

final class TmuxProtocolParserTests: XCTestCase {
    func testParsesCommandBlocks() {
        var parser = TmuxProtocolParser()
        let input = """
        %begin 1 42 1
        $0|mobile|1|1700000000
        %end 1 42 1

        """
        let messages = parser.append(Data(input.utf8))

        XCTAssertEqual(messages, [
            .commandStarted(commandNumber: 42),
            .commandFinished(TmuxCommandBlock(commandNumber: 42, output: "$0|mobile|1|1700000000", isError: false)),
        ])
    }

    func testParsesCommandErrors() {
        var parser = TmuxProtocolParser()
        let input = """
        %begin 1 43 1
        no such pane
        %error 1 43 1

        """
        let messages = parser.append(Data(input.utf8))

        XCTAssertEqual(messages.last, .commandFinished(TmuxCommandBlock(commandNumber: 43, output: "no such pane", isError: true)))
    }

    func testPreservesEmptyCommandOutputLines() {
        var parser = TmuxProtocolParser()
        let input = "%begin 1 44 1\nfirst\n\nthird\n%end 1 44 1\n"
        let messages = parser.append(Data(input.utf8))

        XCTAssertEqual(messages.last, .commandFinished(TmuxCommandBlock(commandNumber: 44, output: "first\n\nthird", isError: false)))
    }

    func testDecodesOctalOutput() {
        let data = TmuxProtocolParser.decodeOutputBytes("ls /\\015\\012backslash=\\134")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ls /\r\nbackslash=\\")
    }

    func testLaunchCommandUsesDedicatedSocketWhenConfigured() {
        XCTAssertEqual(
            TmuxLaunchCommand.controlMode(sessionName: "hermit-mobile", socketName: "hermit-mobile"),
            "tmux -L 'hermit-mobile' -CC new-session -A -s 'hermit-mobile'"
        )
        XCTAssertEqual(
            TmuxLaunchCommand.interactive(sessionName: "0", socketName: nil),
            "tmux new-session -As '0'"
        )
    }

    func testParsesOutputEventsAcrossChunks() {
        var parser = TmuxProtocolParser()
        let first = parser.append(Data("%output %12 hel".utf8))
        let second = parser.append(Data("lo\\040world\\012\n".utf8))

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [
            .event(.output(paneId: "%12", bytes: Data("hello world\n".utf8)))
        ])
    }
}
