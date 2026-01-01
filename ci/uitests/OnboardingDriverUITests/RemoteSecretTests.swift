import XCTest

final class RemoteSecretTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private let progressTitles = ["SetupFinishButton", "Finish", "Continue", "Next", "Done", "Skip",
                                  "Not Now", "Not now", "OK", "Start"]

    func testRestoredWithDualLock() throws {
        continueAfterFailure = false
        threema.activate()
        attachScreenshot("m12-01-start")
        guard followToTheChats(prefix: "m12-02") else {
            attachScreenshot("m12-03-not-chats")
            attachTree("m12-03-tree")
            XCTFail("the chat list is not in front after the restore")
            return
        }
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m12-00-modal-\($0)") }
        XCTAssertTrue(Driver.selectTab("Settings"), "the Settings tab cannot be selected")
        let row = threema.cells.containing(NSPredicate(format: "label == %@", "DualLock")).firstMatch
        let byLabel = threema.cells.matching(NSPredicate(format: "label CONTAINS %@", "DualLock")).firstMatch
        var found = row.waitForExistence(timeout: 5) || byLabel.exists
        for _ in 0..<6 where !found {
            threema.swipeUp()
            found = row.waitForExistence(timeout: 2) || byLabel.exists
        }
        attachScreenshot("m12-04-settings")
        guard found else {
            attachTree("m12-04-tree")
            XCTFail("no DualLock row in the Settings")
            return
        }
        let cell = row.exists ? row : byLabel
        let value = (cell.value as? String) ?? ""
        let texts = cell.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        attachText("m12-04-row", "label: \(cell.label)\nvalue: \(value)\ntexts: \(texts)")
        XCTAssertTrue(cell.label.contains("Active") || value.contains("Active") || texts.contains("Active"),
                      "the DualLock row does not say Active")
    }

    func testLocked() throws {
        threema.activate()
        let locked = threema.staticTexts["App Locked"]
        let shown = locked.waitForExistence(timeout: 90)
        attachScreenshot("m12-05-locked")
        if !shown {
            attachTree("m12-05-tree")
        }
        XCTAssertTrue(shown, "the app does not show \"App Locked\"")
    }

    func testUnlocked() throws {
        threema.activate()
        let open = followToTheChats(prefix: "m12-06")
        attachScreenshot("m12-07-unlocked")
        XCTAssertTrue(open, "the chat list is not in front after the unblock")
    }

    private func followToTheChats(prefix: String) -> Bool {
        var steps = 0
        var inFront = 0
        while inFront < 2 && steps < 60 {
            steps += 1
            handleAlerts(prefix: "m12")
            if chatsVisible() {
                inFront += 1
                sleep(3)
                continue
            }
            inFront = 0
            if case let (button, title)? = progressButton() {
                attachScreenshot(String(format: "%@-step-%02d-%@", prefix, steps, title.replacingOccurrences(of: " ", with: "-")))
                button.tap()
            } else {
                _ = threema.tabBars.firstMatch.waitForExistence(timeout: 5)
            }
        }
        return chatsVisible()
    }

    private func progressButton() -> (XCUIElement, String)? {
        for title in progressTitles {
            let button = threema.buttons.matching(
                NSPredicate(format: "identifier == %@ OR label == %@", title, title)).firstMatch
            if button.exists && button.isHittable {
                return (button, title)
            }
        }
        return nil
    }

    private func chatsVisible() -> Bool {
        let bar = threema.tabBars.firstMatch
        return bar.exists && bar.isHittable && progressButton() == nil
    }
}

