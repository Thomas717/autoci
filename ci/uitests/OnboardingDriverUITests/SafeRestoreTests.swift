import XCTest

final class SafeRestoreTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private let progressTitles = ["SetupFinishButton", "Finish", "Continue", "Next", "Done", "Skip",
                                  "Not Now", "Not now", "Later", "OK", "Start"]

    func testRestoredByMDM() throws {
        continueAfterFailure = false
        threema.activate()
        attachScreenshot("m10-01-start")

        var steps = 0
        var inFront = 0
        while inFront < 2 && steps < 60 {
            steps += 1
            handleAlerts(prefix: "m10")
            if chatsVisible() {
                inFront += 1
                sleep(3)
                continue
            }
            inFront = 0
            if case let (button, title)? = progressButton() {
                attachScreenshot(String(format: "m10-02-step-%02d-%@", steps, title.replacingOccurrences(of: " ", with: "-")))
                button.tap()
            } else {
                _ = threema.tabBars.firstMatch.waitForExistence(timeout: 5)
            }
        }
        attachScreenshot("m10-03-after-restore")
        guard chatsVisible() else {
            attachTree("m10-03-tree")
            XCTFail("the chat list is not in front after \(steps) steps of the restore")
            return
        }
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m10-00-modal-\($0)") }

        XCTAssertTrue(Driver.selectTab("Contacts"), "the Contacts tab cannot be selected")
        let cli = Driver.cell(containing: ["CI CLI"], timeout: 60)
        attachScreenshot("m10-04-contacts")
        if cli == nil {
            attachTree("m10-04-tree")
        }
        XCTAssertNotNil(cli, "the restored app does not list the CLI among its contacts")
    }

    private func progressButton() -> (XCUIElement, String)? {
        for title in progressTitles {
            let button = threema.buttons.matching(
                NSPredicate(format: "identifier == %@ OR label == %@", title, title)).firstMatch
            if button.exists && Driver.hittable(button) {
                return (button, title)
            }
        }
        return nil
    }

    private func chatsVisible() -> Bool {
        let bar = threema.tabBars.firstMatch
        return bar.exists && Driver.hittable(bar) && progressButton() == nil
    }
}

