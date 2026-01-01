import XCTest

final class ContactSyncTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m22")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m22-00-modal-\($0)") }
    }

    func testSyncFindsTheMatch() throws {
        let name = ProcessInfo.processInfo.environment["M22_NAME"] ?? "CI Match"
        let part = name.components(separatedBy: " ").last ?? name
        XCTAssertTrue(setSyncContacts(true, tag: "m22-01"), "\"Sync Contacts\" does not turn on")
        handleAlerts(prefix: "m22")

        if !Driver.selectTab("Contacts") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Contacts"), "no Contacts tab")
        }
        sleep(2)
        attachScreenshot("m22-02-contacts")
        var found = Driver.cell(containing: [part], timeout: 5)
        var pulls = 0
        var toasts = 0
        while found == nil && pulls < 4 {
            pull()
            pulls += 1
            if threema.staticTexts["Contacts synced"].waitForExistence(timeout: 20) {
                toasts += 1
            }
            handleAlerts(prefix: "m22")
            found = Driver.cell(containing: [part], timeout: 15)
        }
        attachScreenshot("m22-03-synced")
        attachText("m22-03-pulls", "\(pulls) pull(s), \"Contacts synced\" seen \(toasts) time(s); row: \(found?.label ?? "none")")
        if found == nil {
            attachTree("m22-03-tree")
        }
        XCTAssertNotNil(found, "no \"\(name)\" row on the Contacts list after \(pulls) pull(s)")
    }

    func testSyncOff() throws {
        XCTAssertTrue(setSyncContacts(false, tag: "m22-07"), "\"Sync Contacts\" does not turn off")
    }


    private func setSyncContacts(_ on: Bool, tag: String) -> Bool {
        openPrivacy(tag)
        let toggle = threema.switches["Sync Contacts"]
        guard toggle.waitForExistence(timeout: 10) else {
            attachScreenshot("\(tag)-no-switch")
            attachTree("\(tag)-tree")
            return false
        }
        let want = on ? "1" : "0"
        func value() -> String { toggle.value as? String ?? "?" }
        attachText("\(tag)-before", "Sync Contacts: \(value())")
        for _ in 0..<3 where value() != want {
            let inner = toggle.switches.firstMatch
            if inner.exists && inner.isHittable {
                inner.tap()
            } else if toggle.isHittable {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            let deadline = Date().addingTimeInterval(5)
            while value() != want && Date() < deadline {
                usleep(300_000)
            }
            handleAlerts(prefix: "m22")
        }
        sleep(2)
        attachScreenshot("\(tag)-privacy")
        attachText("\(tag)-after", "Sync Contacts: \(value())")
        return value() == want
    }

    private func openPrivacy(_ tag: String) {
        if !Driver.selectTab("Settings") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Settings"), "the Settings tab cannot be selected")
        }
        let tab = threema.tabBars.buttons["Settings"]
        let back = threema.navigationBars.buttons["BackButton"]
        for attempt in 0..<4 where back.exists {
            if attempt % 2 == 0 && tab.exists && tab.isHittable {
                tab.tap()
            } else if back.exists && back.isHittable {
                back.tap()
            }
            sleep(1)
        }
        closeBetaTip(tag)
        let row = threema.cells.containing(NSPredicate(format: "label == %@", "Privacy")).firstMatch
        let text = threema.staticTexts.matching(NSPredicate(format: "label == %@", "Privacy")).firstMatch
        let target = row.waitForExistence(timeout: 10) ? row : text
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            threema.swipeUp()
        }
        let toggle = threema.switches["Sync Contacts"]
        for _ in 0..<4 where !toggle.exists {
            if target.exists && target.isHittable {
                target.tap()
            }
            _ = toggle.waitForExistence(timeout: 8)
        }
        if !toggle.exists {
            attachScreenshot("\(tag)-settings")
            attachTree("\(tag)-settings-tree")
        }
    }

    private func pull() {
        let anchor = Driver.cell(containing: ["CI CLI"], timeout: 10) ?? threema.cells.firstMatch
        guard anchor.exists else {
            threema.swipeDown()
            return
        }
        let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 8.0))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
    }

    private func closeBetaTip(_ tag: String) {
        guard threema.staticTexts["Send us your beta feedback!"].exists else {
            return
        }
        attachScreenshot("\(tag)-tip")
        let close = threema.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Dismiss"))
            .allElementsBoundByIndex.first { $0.isHittable }
        if let close {
            close.tap()
        } else {
            threema.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        }
        sleep(1)
    }
}

