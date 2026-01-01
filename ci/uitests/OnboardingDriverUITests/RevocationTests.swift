import XCTest

final class RevocationTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m15")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m15-00-modal-\($0)") }
    }

    private func labelled(_ text: String) -> XCUIElementQuery {
        threema.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text))
    }

    private func hittable(_ text: String, enabled: Bool = false) -> XCUIElement? {
        labelled(text).allElementsBoundByIndex.last { $0.exists && Driver.hittable($0) && (!enabled || $0.isEnabled) }
    }

    func testRevoke() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["M15_ID"])
        if !Driver.selectTab("Profile") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Profile"), "no Profile tab")
        }
        sleep(2)
        attachScreenshot("m15-01-profile")

        var row = hittable("Remove ID and Data")
        for _ in 0..<6 where row == nil {
            threema.swipeUp()
            sleep(1)
            row = hittable("Remove ID and Data")
        }
        guard let row else {
            attachTree("m15-02-tree")
            XCTFail("no \"Remove ID and Data\" row in the profile")
            return
        }

        let link = threema.links["Revoke Threema ID"]
        let linkText = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Revoke Threema ID")).firstMatch
        for _ in 0..<3 where !(link.exists || linkText.exists) {
            if row.exists && Driver.hittable(row) {
                row.tap()
            }
            if labelled("Passcode Enabled").firstMatch.waitForExistence(timeout: 3) {
                attachScreenshot("m15-02-passcode")
                XCTFail("a passcode is set: the app asks to disable it first")
                return
            }
            _ = link.waitForExistence(timeout: 7)
        }
        attachScreenshot("m15-02-overview")

        let field = threema.textFields.matching(
            NSPredicate(format: "placeholderValue ==[c] %@", "Your Threema ID")).firstMatch
        for _ in 0..<3 where !field.exists {
            if link.exists && Driver.hittable(link) {
                link.tap()
            } else if linkText.exists {
                linkText.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
            }
            _ = field.waitForExistence(timeout: 7)
        }
        guard field.exists else {
            attachScreenshot("m15-03-no-field")
            attachTree("m15-03-tree")
            XCTFail("no \"Your Threema ID\" field after the revoke link")
            return
        }
        XCTAssertTrue(Driver.focus(field), "the ID field takes no keyboard focus")
        field.typeText(id)
        attachScreenshot("m15-03-typed")
        for _ in 0..<2 where threema.keyboards.firstMatch.exists {
            let returnKey = threema.keyboards.buttons.matching(
                NSPredicate(format: "label ==[c] %@ OR label ==[c] %@ OR label ==[c] %@", "return", "done", "go")).firstMatch
            if returnKey.exists && Driver.hittable(returnKey) {
                returnKey.tap()
            } else {
                field.typeText("\n")
            }
            sleep(1)
        }

        var revoke = hittable("Remove ID and Data", enabled: true)
        let deadline = Date().addingTimeInterval(10)
        while revoke == nil && Date() < deadline {
            sleep(1)
            revoke = hittable("Remove ID and Data", enabled: true)
        }
        guard let revoke else {
            attachTree("m15-04-tree")
            XCTFail("no enabled \"Remove ID and Data\" on the revoke page")
            return
        }
        revoke.tap()

        let done = Driver.shows("has been revoked", timeout: 60)
        attachScreenshot("m15-05-result")
        if !done {
            attachTree("m15-05-tree")
        }
        XCTAssertTrue(done, "no \"Your Threema ID has been revoked\" (a \"Revocation Failed\" banner?)")
        threema.terminate()
    }
}

