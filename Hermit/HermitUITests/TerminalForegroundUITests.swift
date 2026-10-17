import XCTest

final class TerminalForegroundUITests: XCTestCase {
    @MainActor func testTypingAndShiftLeftSurviveAppSwitches() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["HERMIT_TERMINAL_TEST_CONFIG"] else {
            throw XCTSkip("Requires the disposable terminal SSH fixture")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let environment = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertTrue(environment["HERMIT_SIM_TMUX_SOCKET"]?.hasPrefix("hermit-test-") == true)
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenAbout", "YES", "-agentMessagingEnabled", "NO"]
        app.launchEnvironment = environment
        app.launch()
        let host = app.staticTexts["Terminal Test"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 15))
        host.tap()
        let session = app.staticTexts["foreground"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.tap()
        let window = app.staticTexts["keys"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        window.tap()

        let input = app.textFields["tmux-command"]
        let output = app.textViews["tmux-output"]
        let shiftLeft = app.buttons["tmux-key-S-Left"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        waitFor(output, valueContaining: "HERMIT_TERMINAL_TEST")
        input.tap()
        input.typeText("abc")
        waitFor(output, valueContaining: "BUFFER=abc")
        screenshot("Terminal keyboard before background")

        var expected = "abc"
        for index in 0..<5 {
            XCUIDevice.shared.press(.home)
            if index == 2 { Thread.sleep(forTimeInterval: 2) }
            app.activate()
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: shiftLeft)
            waitForExpectations(timeout: 15)
            XCTAssertFalse(app.buttons["tmux-input-error"].exists)
            input.tap()
            input.typeText(String(index))
            expected += String(index)
            waitFor(output, valueContaining: "BUFFER=" + expected)
            XCTAssertEqual(input.value as? String, expected)
            XCTAssertTrue((output.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("STATUS") == true)
        }

        shiftLeft.tap()
        waitFor(output, valueContaining: "SHIFT_LEFT=1")
        input.tap()
        input.typeText("\n")
        waitFor(output, valueContaining: "ENTER=1")
        input.typeText("\n")
        waitFor(output, valueContaining: "ENTER=2")
        screenshot("Terminal after five switches and Shift Left")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.press(.home)
        app.activate()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: shiftLeft)
        waitForExpectations(timeout: 15)
        input.tap()
        input.typeText("landscape")
        waitFor(output, valueContaining: "BUFFER=landscape")
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(shiftLeft.isHittable)
        XCTAssertTrue(output.isHittable)
        XCTAssertGreaterThan(output.frame.height, 60)
        screenshot("Landscape foreground keyboard")
        app.buttons["Hide Keyboard"].tap()
        XCTAssertTrue(app.buttons["tmux Windows"].waitForExistence(timeout: 5))
    }

    @MainActor private func waitFor(_ element: XCUIElement, valueContaining text: String) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: element)
        waitForExpectations(timeout: 15)
    }

    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
