import XCTest

final class MessagingTests: XCTestCase {
    private var threema: XCUIApplication { XCUIApplication(bundleIdentifier: "ch.threema.onprem.iapp") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    func testAnswerTheCLI() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let inbound = try XCTUnwrap(env["M3_INBOUND"], "no M3_INBOUND in the test runner's environment")
        let reply = try XCTUnwrap(env["M3_REPLY"], "no M3_REPLY in the test runner's environment")

        threema.activate()
        allowSystemPrompts()
        LaunchModals.clear(threema, settle: 3) { snap("m3-00-modal-\($0)") }
        let chatsTab = threema.buttons["TabBarChats"]
        if chatsTab.waitForExistence(timeout: 10) && chatsTab.isHittable {
            chatsTab.tap()
        }

        let holding = NSPredicate(format: "label CONTAINS %@", inbound)
        let byLabel = threema.cells.matching(holding).firstMatch
        let byChild = threema.cells.containing(holding).firstMatch
        let deadline = Date().addingTimeInterval(120)
        while !byLabel.exists && !byChild.exists && Date() < deadline {
            allowSystemPrompts()
            _ = threema.cells.firstMatch.waitForExistence(timeout: 3)
        }
        snap("m3-01-chats")
        let cell = byLabel.exists ? byLabel : byChild
        XCTAssertTrue(cell.exists, "no chat shows the CLI's text within 120 s")
        XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")

        let shown = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", inbound, inbound)).firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 30), "the chat does not show the CLI's text")
        snap("m3-02-chat")

        let composer = composerView()
        XCTAssertNotNil(composer, "no composer in the chat")
        if let composer {
            Driver.focus(composer)
        }
        composer?.typeText(reply)
        let send = threema.buttons["Send Message"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "no Send Message button after typing")
        waitUntilHittable(send, timeout: 10)
        snap("m3-03-typed")
        send.tap()

        let sent = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", reply)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 30), "the answer does not appear in the chat")
        sleep(5)
        snap("m3-04-answered")
    }


    private func composerView() -> XCUIElement? {
        let placeholder = threema.textViews.containing(NSPredicate(format: "label == %@", "New Message")).firstMatch
        if placeholder.waitForExistence(timeout: 10) {
            return placeholder
        }
        return threema.textViews.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .max { $0.frame.maxY < $1.frame.maxY }
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) {
        let ready = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
        _ = XCTWaiter.wait(for: [ready], timeout: timeout)
    }

    private func allowSystemPrompts() {
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1) else { return }
            snap("m3-alert-system")
            var tapped = false
            for title in ["Allow", "Allow While Using App", "OK", "Continue"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                tapped = true
                break
            }
            if !tapped && alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
            }
        }
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

