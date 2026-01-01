import XCTest

final class AppConfigTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private let featuresDisabled = "Some features have been disabled by your administrator."
    private let settingsDisabled = "Some settings have been disabled by device policy."

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m16")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m16-00-modal-\($0)") }
    }

    func testApplied() throws {
        let env = ProcessInfo.processInfo.environment
        let on = try XCTUnwrap(env["M16_EXPECT"]) == "on"
        let tag = env["M16_TAG"] ?? (on ? "on" : "off")
        var report = ""

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
        sleep(8)
        attachScreenshot("m16-\(tag)-00-synced")

        Driver.openChatList()
        XCTAssertTrue(Driver.composeButton.waitForExistence(timeout: 10), "no compose button on the chat list")
        let title = threema.navigationBars["New Message"]
        for _ in 0..<3 where !title.exists {
            if Driver.hittable(Driver.composeButton) {
                Driver.composeButton.tap()
            }
            _ = title.waitForExistence(timeout: 7)
        }
        XCTAssertTrue(title.exists, "the compose sheet does not open")
        sleep(2)
        let footer = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", featuresDisabled)).firstMatch
        let footerShown = footer.waitForExistence(timeout: on ? 10 : 3)
        attachScreenshot("m16-\(tag)-01-compose")
        report += "compose footer \"\(featuresDisabled)\": \(footerShown ? "shown" : "not shown")\n"
        let close = threema.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Cancel"))
            .allElementsBoundByIndex.first { Driver.hittable($0) }
        if let close {
            close.tap()
        } else {
            threema.swipeDown(velocity: .fast)
        }
        sleep(1)

        XCTAssertTrue(Driver.selectTab("Settings"), "no Settings tab")
        sleep(2)
        if threema.staticTexts["Send us your beta feedback!"].exists {
            attachScreenshot("m16-\(tag)-02-tip")
            let tipClose = threema.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Dismiss"))
                .allElementsBoundByIndex.first { Driver.hittable($0) }
            if let tipClose {
                tipClose.tap()
            } else {
                threema.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
            }
            sleep(1)
        }
        let privacy = threema.cells.containing(NSPredicate(format: "label == %@", "Privacy")).firstMatch
        let privacyByLabel = threema.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Privacy")).firstMatch
        let toggle = threema.switches["Block Unknown"]
        for _ in 0..<3 where !toggle.exists {
            if privacy.exists && Driver.hittable(privacy) {
                privacy.tap()
            } else if privacyByLabel.exists && Driver.hittable(privacyByLabel) {
                privacyByLabel.tap()
            }
            _ = toggle.waitForExistence(timeout: 7)
        }
        XCTAssertTrue(toggle.exists, "no \"Block Unknown\" switch in Settings > Privacy")
        let value = toggle.value as? String ?? "\(String(describing: toggle.value))"
        let enabled = toggle.isEnabled
        let policyFooter = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", settingsDisabled)).firstMatch.exists
        attachScreenshot("m16-\(tag)-02-privacy")
        report += "Block Unknown: value \(value), \(enabled ? "enabled" : "disabled")\n"
        report += "privacy footer \"\(settingsDisabled)\": \(policyFooter ? "shown" : "not shown")\n"
        attachText("m16-\(tag)-report", report)
        let back = threema.navigationBars.buttons.firstMatch
        if back.exists && Driver.hittable(back) {
            back.tap()
        }

        if on {
            XCTAssertTrue(footerShown, "the compose sheet does not say features are disabled (th_disable_add_contact)")
            XCTAssertEqual(value, "1", "Block Unknown is not on (th_block_unknown true)")
            XCTAssertFalse(enabled, "Block Unknown can still be changed while the server sets it")
        } else {
            XCTAssertFalse(footerShown, "the compose sheet still says features are disabled")
            XCTAssertEqual(value, "0", "Block Unknown is not off (th_block_unknown false)")
        }
    }
}

