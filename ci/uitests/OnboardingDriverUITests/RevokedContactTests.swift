import XCTest

final class RevokedContactTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private let refused = "You cannot send a message to this contact because it is invalid."

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m19")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m19-00-modal-\($0)") }
    }

    private func pullContacts(_ tag: String) {
        if !Driver.selectTab("Contacts") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Contacts"), "no Contacts tab")
        }
        sleep(2)
        let list = threema.tables.firstMatch.exists ? threema.tables.firstMatch : threema.collectionViews.firstMatch
        let cell = Driver.cell(containing: ["CI CLI"], timeout: 15) ?? list.cells.firstMatch
        if cell.exists {
            let start = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 8.0))
            start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
        } else {
            list.swipeDown()
        }
        let synced = threema.staticTexts["Contacts synced"].waitForExistence(timeout: 20)
        attachScreenshot("m19-\(tag)-01-pulled")
        attachText("m19-\(tag)-synced", synced ? "\"Contacts synced\" shown" : "no \"Contacts synced\" toast")
        sleep(3)
    }

    private func openColleague(_ text: String, _ tag: String) {
        Driver.openChatList()
        guard let cell = Driver.cell(containing: [text], timeout: 90) else {
            attachTree("m19-\(tag)-02-tree")
            XCTFail("no chat with the colleague's text in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the colleague's chat does not open")
        sleep(2)
    }

    private var invalidMark: XCUIElement {
        threema.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "(invalid)")).firstMatch
    }

    func testSeeTheColleague() throws {
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["M19_TEXT"])
        pullContacts("before")
        openColleague(text, "before")
        XCTAssertTrue(Driver.shows(text, timeout: 30), "the chat does not show the colleague's text")
        attachScreenshot("m19-before-03-chat")
        XCTAssertFalse(invalidMark.exists, "the colleague is marked invalid before the revocation")
    }

    func testRevoked() throws {
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["M19_TEXT"])
        pullContacts("after")
        openColleague(text, "after")
        let marked = invalidMark.waitForExistence(timeout: 20)
        attachScreenshot("m19-after-03-chat")
        attachText("m19-after-header", marked ? invalidMark.label : "no element labelled \"(invalid)\"")
        XCTAssertTrue(marked, "the chat does not mark the colleague invalid")

        if let composer = Driver.composer(), Driver.hittable(composer) {
            composer.tap()
        } else {
            threema.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.925)).tap()
        }
        let alert = threema.alerts[refused]
        let byText = threema.staticTexts[refused]
        let shown = alert.waitForExistence(timeout: 10) || byText.exists
        attachScreenshot("m19-after-04-composer")
        XCTAssertTrue(shown, "no \"\(refused)\" alert on the composer")
        let ok = threema.alerts.buttons["OK"]
        if ok.exists {
            ok.tap()
        }
    }
}

