import XCTest

final class GroupTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m5")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m5-00-modal-\($0)") }
    }

    func testAnswerInTheCLIGroup() throws {
        let env = ProcessInfo.processInfo.environment
        let group = try XCTUnwrap(env["M5_GROUP_NAME"])
        let inbound = try XCTUnwrap(env["M5_INBOUND"])
        let reply = try XCTUnwrap(env["M5_REPLY"])

        Driver.openChatList()
        let found = Driver.cell(containing: [group, inbound], timeout: 120)
        attachScreenshot("m5-01-list")
        guard let cell = found else {
            attachTree("m5-01-tree")
            XCTFail("no chat \"\(group)\" with the CLI's text in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the group chat does not open")
        XCTAssertTrue(Driver.shows(inbound, timeout: 30), "the group chat does not show the CLI's text")
        attachScreenshot("m5-02-group")
        XCTAssertTrue(Driver.send(reply), "the answer does not appear in the group chat")
        attachScreenshot("m5-03-answered")
    }

    func testCreateGroupWithTheCLI() throws {
        let env = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(env["M5_APP_GROUP_NAME"])
        let text = try XCTUnwrap(env["M5_APP_TEXT"])

        Driver.openChatList()
        XCTAssertTrue(Driver.composeButton.waitForExistence(timeout: 10), "no compose button on the chat list")
        Driver.composeButton.tap()
        let newGroup = threema.staticTexts["New Group"]
        guard newGroup.waitForExistence(timeout: 10) else {
            attachTree("m5-04-tree")
            XCTFail("no \"New Group\" row")
            return
        }
        newGroup.tap()
        _ = threema.navigationBars["Add Members"].waitForExistence(timeout: 10)
        attachScreenshot("m5-04-members")

        let dismiss = threema.otherElements["PopoverDismissRegion"]
        if dismiss.waitForExistence(timeout: 3) {
            dismiss.tap()
        } else if threema.buttons["Close"].exists {
            threema.buttons["Close"].tap()
        }
        guard let contact = Driver.cell(containing: ["CI CLI"], timeout: 15) else {
            attachTree("m5-05-tree")
            XCTFail("no contact \"CI CLI\" to add")
            return
        }
        contact.tap()
        let next = threema.navigationBars.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "no Next button")
        next.tap()
        XCTAssertTrue(Driver.shows("CI CLI", timeout: 10), "the CLI is not a member on the Create screen")
        attachScreenshot("m5-05-create")

        let byPlaceholder = threema.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Group Name")).firstMatch
        let field = byPlaceholder.waitForExistence(timeout: 5) ? byPlaceholder : threema.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no group name field")
        Driver.focus(field)
        field.typeText(name)
        let done = threema.navigationBars.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no Done button")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
        _ = XCTWaiter.wait(for: [enabled], timeout: 10)
        done.tap()
        handleAlerts(prefix: "m5")
        attachScreenshot("m5-06-group")

        XCTAssertTrue(Driver.send(text), "the text does not appear in the new group")
        attachScreenshot("m5-07-written")
    }

    func testSeeTheCLIAnswer() throws {
        let env = ProcessInfo.processInfo.environment
        let name = try XCTUnwrap(env["M5_APP_GROUP_NAME"])
        let answer = try XCTUnwrap(env["M5_CLI_REPLY"])

        if !(Driver.inChat(timeout: 3) && Driver.shows(answer, timeout: 30)) {
            Driver.openChatList()
            guard let cell = Driver.cell(containing: [name, answer], timeout: 60) else {
                attachScreenshot("m5-08-list")
                attachTree("m5-08-tree")
                XCTFail("no chat \"\(name)\" with the CLI's answer")
                return
            }
            XCTAssertTrue(Driver.open(cell), "the group chat does not open")
            XCTAssertTrue(Driver.shows(answer, timeout: 30), "the group chat does not show the CLI's answer")
        }
        attachScreenshot("m5-08-answer")
    }
}

