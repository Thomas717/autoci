import XCTest

final class SafeTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        cancelPasswordAlert()
        handleAlerts(prefix: "m9")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m9-00-modal-\($0)") }
        cancelPasswordAlert()
    }

    func testSafeDashboard() throws {
        XCTAssertTrue(Driver.selectTab("Profile"), "the Profile tab cannot be selected")
        let backups = threema.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "backupButton", "Backups")).firstMatch
        guard backups.waitForExistence(timeout: 15) else {
            attachScreenshot("m9-01-no-backups")
            attachTree("m9-01-tree")
            XCTFail("no \"Backups\" on the Profile tab")
            return
        }
        if !backups.isHittable {
            threema.swipeUp()
        }
        backups.tap()
        let safe = threema.descendants(matching: .any)["threemaSafeButton"]
        guard safe.waitForExistence(timeout: 15) else {
            attachScreenshot("m9-02-no-safe")
            attachTree("m9-02-tree")
            XCTFail("no \"Threema Safe\" on the Backups page")
            return
        }
        attachScreenshot("m9-02-backups")
        attachText("m9-02-safe-row", safe.label)
        safe.tap()
        cancelPasswordAlert()

        let status = threema.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Status")).firstMatch
        let successful = expectation(for: NSPredicate(format: "value == %@", "Successful"), evaluatedWith: status)
        let result = XCTWaiter.wait(for: [successful], timeout: 90)
        attachScreenshot("m9-03-dashboard")
        attachText("m9-03-status", status.exists ? "Status: \(status.value as? String ?? "?")" : "no Status row")
        XCTAssertEqual(result, .completed, "the Threema Safe status is not \"Successful\"")

        let create = threema.buttons["Create Backup"]
        if create.exists {
            if !create.isHittable {
                threema.swipeUp()
            }
            create.tap()
            sleep(8)
            cancelPasswordAlert()
            attachScreenshot("m9-04-after-create")
            attachText("m9-04-status", status.exists ? "Status: \(status.value as? String ?? "?")" : "no Status row")
        } else {
            attachText("m9-04-status", "no \"Create Backup\" button")
        }
    }

    private func cancelPasswordAlert() {
        let alert = threema.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2), alert.buttons["Accept"].exists else {
            return
        }
        attachScreenshot("m9-alert-password")
        attachText("m9-alert-password-text", alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        let cancel = alert.buttons["Cancel"]
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: cancel)
        _ = XCTWaiter.wait(for: [enabled], timeout: 10)
        sleep(1)
        cancel.tap()
    }
}

