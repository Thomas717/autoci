import XCTest

final class CallTests: XCTestCase {
    private var threema: XCUIApplication { XCUIApplication(bundleIdentifier: "ch.threema.onprem.iapp") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var alertCount = 0

    func testCallTheCLI() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts()
        LaunchModals.clear(threema, settle: 5) { snap("m4-00-modal-\($0)") }
        snap("m4-00-start")

        let call = threema.buttons["ChatViewControllerCallBarButtonItem"]
        if !(call.waitForExistence(timeout: 5) && call.isHittable) {
            let peer = NSPredicate(format: "label CONTAINS %@", "CI CLI")
            let byLabel = threema.cells.matching(peer).firstMatch
            let byChild = threema.cells.containing(peer).firstMatch
            let deadline = Date().addingTimeInterval(45)
            while !(byLabel.exists || byChild.exists) && Date() < deadline {
                LaunchModals.clear(threema, settle: 1) { snap("m4-01-modal-\($0)") }
                _ = byLabel.waitForExistence(timeout: 5) || byChild.waitForExistence(timeout: 2)
            }
            snap("m4-01-list")
            let cell = byLabel.exists ? byLabel : byChild
            XCTAssertTrue(cell.exists && cell.isHittable, "no chat with CI CLI to tap in the list")
            Driver.open(cell)
        }
        LaunchModals.clear(threema, settle: 1) { snap("m4-01-modal-\($0)") }
        XCTAssertTrue(call.waitForExistence(timeout: 30),
                      "no call button: the app does not see the peer as able to take calls")
        snap("m4-01-chat")
        call.tap()

        sleep(3)
        handleAlerts()
        snap("m4-02-calling")
        sleep(10)
        handleAlerts()
        snap("m4-03-in-call")
        sleep(15)
        handleAlerts()
        snap("m4-04-in-call-late")

        let deadline = Date().addingTimeInterval(60)
        while !(call.exists && call.isHittable) && Date() < deadline {
            handleAlerts()
            sleep(2)
        }
        snap("m4-05-ended")
    }


    private func handleAlerts() {
        for _ in 0..<4 {
            let system = springboard.alerts.firstMatch
            if system.waitForExistence(timeout: 1) {
                alertCount += 1
                snap(String(format: "m4-alert-%02d-system", alertCount))
                var tapped = false
                for title in ["Allow", "Allow While Using App", "OK", "Continue"] where system.buttons[title].exists {
                    system.buttons[title].tap()
                    tapped = true
                    break
                }
                if !tapped && system.buttons.firstMatch.exists {
                    system.buttons.firstMatch.tap()
                }
                continue
            }
            let own = threema.alerts.firstMatch
            if own.exists {
                alertCount += 1
                snap(String(format: "m4-alert-%02d-app", alertCount))
                let text = own.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                let note = XCTAttachment(string: text)
                note.name = String(format: "m4-alert-%02d-app-text", alertCount)
                note.lifetime = .keepAlways
                add(note)
                if own.buttons.firstMatch.exists {
                    own.buttons.firstMatch.tap()
                }
                continue
            }
            return
        }
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

