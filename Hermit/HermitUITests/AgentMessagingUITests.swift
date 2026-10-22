import XCTest

final class AgentMessagingUITests: XCTestCase {
    @MainActor private func launch(extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--agent-chat-demo", "--agent-chat-reset-test-preferences"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["chat-row-demo-0"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor func testSavedHistoryIsCollapsedReadableAndEmptyStateIsExplicit() {
        let app = launch(extraArguments: ["--agent-chat-history-regression"])
        XCTAssertFalse(app.buttons["chat-row-history:demo-0"].exists)
        XCTAssertTrue(app.buttons["chat-row-demo-3"].isHittable)
        screenshot("Collapsed saved history")
        let histories = app.buttons["chat-saved-history"]
        XCTAssertTrue(histories.waitForExistence(timeout: 5))
        histories.tap()
        screenshot("Expanded saved history")
        XCTAssertTrue(app.buttons["chat-row-history:demo-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat-row-history:demo-2"].exists)
        app.buttons["chat-row-history:demo-0"].tap()
        XCTAssertTrue(app.textViews["chat-message-native-answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["chat-composer"].exists)
        screenshot("Readable saved history")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["chat-row-history:demo-1"].tap()
        XCTAssertTrue(app.staticTexts["No recorded messages"].waitForExistence(timeout: 5))
        screenshot("Empty history state")
    }
    @MainActor func testInboxChatSendHostIsolationAndBack() {
        let app = launch()
        screenshot("Inbox")
        app.buttons["chat-row-demo-0"].tap()
        let composer = app.textFields["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Check fixture one")
        app.buttons["chat-send"].tap()
        let reply = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "Fixture reply")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: reply)
        waitForExpectations(timeout: 3)
        screenshot("Conversation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["chat-row-demo-3"].waitForExistence(timeout: 5))
        app.buttons["chat-row-demo-3"].tap()
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "Check fixture one")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Build host"].exists)
    }
    @MainActor func testDraftClearReadOnlyAndBackground() {
        let app = launch()
        app.buttons["chat-row-demo-1"].tap()
        let composer = app.textFields["chat-composer"]
        composer.tap(); composer.typeText("Keep this draft")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["Clear draft"])
        waitForExpectations(timeout: 4)
        screenshot("Draft after foreground")
        app.buttons["Clear draft"].tap()
        XCTAssertEqual(composer.value as? String, "Message")
        app.buttons["Undo clear draft"].tap()
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        app.buttons["Clear draft"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["chat-row-demo-2"].tap()
        XCTAssertFalse(app.textFields["chat-composer"].exists)
        XCTAssertTrue(app.staticTexts["Read-only history"].exists)
    }
    @MainActor func testLandscapeWrappedLinkAndFontMenu() {
        let app = launch()
        app.buttons["chat-row-demo-0"].tap()
        app.buttons["Conversation options"].tap()
        XCTAssertTrue(app.buttons["Larger text"].waitForExistence(timeout: 3))
        app.buttons["Larger text"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.textFields["chat-composer"].waitForExistence(timeout: 5))
        screenshot("Landscape")
        XCUIDevice.shared.orientation = .portrait
        let link = app.links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        link.tap()
        XCTAssertTrue(app.buttons["Open in browser"].waitForExistence(timeout: 3))
        app.buttons["Copy link"].tap()
    }
    @MainActor func testLongHistoryTouchScrollAndFontAnchor() {
        let app = launch()
        app.buttons["chat-row-demo-2"].tap()
        XCTAssertTrue(app.textViews["chat-message-history-300"].waitForExistence(timeout: 5))
        let table = app.tables.firstMatch
        table.swipeDown(velocity: .slow)
        table.swipeDown(velocity: .slow)
        let position = (table.value as? String)?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        XCTAssertNotNil(position)
        let anchorID = "chat-message-history-\(position!)"
        XCTAssertNotEqual(anchorID, "chat-message-history-300")
        app.buttons["Conversation options"].tap()
        app.buttons["Larger text"].tap()
        screenshot("After font change anchor " + anchorID)
        let visible = NSPredicate(format: "hittable == true")
        expectation(for: visible, evaluatedWith: app.textViews[anchorID])
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["Latest"].exists)
        screenshot("Scroll anchor")
        app.buttons["Latest"].tap()
        XCTAssertTrue(app.textViews["chat-message-history-300"].isHittable)
    }
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
