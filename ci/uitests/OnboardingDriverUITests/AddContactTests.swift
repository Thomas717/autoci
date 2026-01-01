import XCTest

final class AddContactTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private var field: XCUIElement { threema.textFields["AddContactViewControllerCTextField"] }
    private var addButton: XCUIElement { threema.buttons["AddContactModalAddButton"] }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m22")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m22-00-modal-\($0)") }
    }

    func testUnknownID() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["M22_ID"])
        XCTAssertTrue(openSheet("m22-04"), "no Add Contact sheet")
        typeID(id, tag: "m22-04")
        let alert = threema.alerts.firstMatch
        for _ in 0..<3 where !alert.exists {
            if addButton.exists && addButton.isHittable && addButton.isEnabled {
                addButton.tap()
            }
            _ = alert.waitForExistence(timeout: 15)
        }
        attachScreenshot("m22-04-unknown")
        guard alert.exists else {
            attachTree("m22-04-tree")
            XCTFail("no alert after adding \(id)")
            return
        }
        let texts = alert.staticTexts.allElementsBoundByIndex.map(\.label)
        attachText("m22-04-alert-text", texts.joined(separator: " | "))
        XCTAssertTrue(alert.label == "Unknown ID" || texts.contains("Unknown ID"),
                      "the alert is not \"Unknown ID\": \(alert.label) | \(texts.joined(separator: " | "))")
        let ok = alert.buttons["OK"]
        for _ in 0..<3 where alert.exists {
            if ok.exists && ok.isHittable {
                ok.tap()
            }
            _ = waitGone(alert, timeout: 5)
        }
        closeSheet(id: id)
        attachScreenshot("m22-05-closed")
        XCTAssertFalse(field.exists, "the Add Contact sheet is still open")
    }

    func testAddByID() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["M22_ID"])
        XCTAssertTrue(openSheet("m22-08"), "no Add Contact sheet")
        typeID(id, tag: "m22-08")
        let alert = threema.alerts.firstMatch
        for _ in 0..<3 where field.exists && !alert.exists {
            if addButton.exists && addButton.isHittable && addButton.isEnabled {
                addButton.tap()
            }
            _ = waitGone(field, timeout: 20)
        }
        if alert.exists {
            attachScreenshot("m22-08-alert")
            attachText("m22-08-alert-text", alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
            XCTFail("an alert instead of the new contact")
            return
        }
        XCTAssertFalse(field.exists, "the Add Contact sheet stays open after adding \(id)")
        let shown = Driver.shows(id, timeout: 30)
        sleep(2)
        attachScreenshot("m22-09-added")
        if !shown {
            attachTree("m22-09-tree")
        }
        XCTAssertTrue(shown, "the new contact's details do not show \(id)")
    }


    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            usleep(300_000)
        }
        return !element.exists
    }

    private func openSheet(_ tag: String) -> Bool {
        if !Driver.selectTab("Contacts") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Contacts"), "no Contacts tab")
        }
        let tab = threema.tabBars.buttons["Contacts"]
        let back = threema.navigationBars.buttons["BackButton"]
        for attempt in 0..<4 where back.exists {
            if attempt % 2 == 0 && tab.exists && tab.isHittable {
                tab.tap()
            } else if back.exists && back.isHittable {
                back.tap()
            }
            sleep(1)
        }
        sleep(1)
        let plus = threema.navigationBars.buttons["Add"]
        let item = threema.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New Contact"))
        for _ in 0..<4 where !field.exists {
            var entry = item.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            if entry == nil {
                if plus.exists && plus.isHittable {
                    plus.tap()
                }
                _ = item.firstMatch.waitForExistence(timeout: 5)
                entry = item.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                attachScreenshot("\(tag)-menu")
            }
            entry?.tap()
            _ = field.waitForExistence(timeout: 8)
        }
        if !field.exists {
            attachScreenshot("\(tag)-no-sheet")
            attachTree("\(tag)-tree")
        }
        return field.exists
    }

    private func typeID(_ id: String, tag: String) {
        XCTAssertTrue(Driver.focus(field), "the ID field takes no keyboard focus")
        field.typeText(id)
        attachScreenshot("\(tag)-typed")
        attachText("\(tag)-field", "the field holds: \(field.value as? String ?? "?"), add enabled: \(addButton.isEnabled)")
    }

    private func closeSheet(id: String) {
        let cancel = threema.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Cancel", "Close")).firstMatch
        for attempt in 0..<4 where field.exists {
            if cancel.exists && cancel.isHittable {
                cancel.tap()
            } else if attempt >= 2 {
                Driver.focus(field)
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: id.count + 2))
                threema.swipeDown(velocity: .fast)
            }
            _ = waitGone(field, timeout: 5)
        }
    }
}

