import XCTest

final class ThreemaWebTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m20")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m20-00-modal-\($0)") }
    }

    func testConnect() throws {
        let payload = try XCTUnwrap(ProcessInfo.processInfo.environment["M20_PAYLOAD"])
        var report = ""

        if !Driver.selectTab("Settings") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Settings"), "the Settings tab cannot be selected")
        }
        sleep(2)
        closeBetaTip()
        let row = threema.staticTexts["Desktop/Web"].firstMatch
        let screen = threema.navigationBars["Desktop/Web"]
        let field = threema.secureTextFields["SimulatorWebQRPayload"]
        guard screen.exists || reveal(row) else {
            attachScreenshot("m20-01-settings")
            attachTree("m20-01-tree")
            XCTFail("no \"Desktop/Web\" row in the Settings")
            return
        }
        for _ in 0..<3 where !field.exists && !screen.exists {
            if row.exists && row.isHittable {
                row.tap()
            }
            _ = field.waitForExistence(timeout: 10)
        }
        if !field.exists && screen.exists {
            _ = reveal(field)
        }
        attachScreenshot("m20-01-web")
        guard field.exists else {
            attachTree("m20-01-tree")
            XCTFail("no \"Web QR payload\" field on the Desktop/Web screen: an app built without ci/build/patches?")
            return
        }
        let toggle = threema.switches["Desktop/Web"]
        report += "Desktop/Web switch before: \(state(of: toggle))\n"
        XCTAssertTrue(field.isEnabled, "the payload field is disabled: Threema Web disabled by MDM?")

        Driver.focus(field)
        field.typeText(payload)
        let connect = threema.buttons["SimulatorWebQRConnect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no Connect button")
        if !connect.isHittable {
            field.typeText("\n")
        }
        connect.tap()
        sleep(2)
        hideKeyboard()
        let alert = threema.alerts.firstMatch
        if alert.exists {
            let texts = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            attachScreenshot("m20-02-alert")
            attachText("m20-02-alert", texts)
            XCTAssertFalse(texts.contains("could not be recognized"), "the app did not take the payload: \(texts)")
            if alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
            }
        }

        let stop = threema.buttons["Stop Session"]
        let start = threema.buttons["Start Session"]
        var active = false
        var rowLabel = ""
        var crashed = false
        let deadline = Date().addingTimeInterval(90)
        while !active && Date() < deadline {
            if threema.state == .notRunning {
                crashed = true
                break
            }
            guard let session = sessionRow(timeout: 5) else {
                continue
            }
            if !session.isHittable {
                hideKeyboard()
                threema.swipeUp()
                sleep(2)
                continue
            }
            if rowLabel.isEmpty {
                rowLabel = session.label
                report += "session row: \(rowLabel)\n"
                report += "Desktop/Web switch after Connect: \(state(of: toggle))\n"
                attachScreenshot("m20-02-session")
            }
            session.tap()
            if stop.waitForExistence(timeout: 5) {
                active = true
                break
            }
            if start.exists {
                report += "its actions offered \"Start Session\": not active yet\n"
            }
            closeActions()
            sleep(3)
        }
        if rowLabel.isEmpty {
            report += "no session row\n"
        }
        if crashed {
            report += "the app stopped running after Connect\n"
        }
        if active {
            report += "its actions offer \"Stop Session\": the session is active\n"
            attachScreenshot("m20-03-active")
        }
        else {
            attachScreenshot("m20-03-not-active")
            if !crashed {
                attachTree("m20-03-tree")
            }
        }
        guard !crashed, active else {
            attachText("m20-session", report)
            XCTAssertFalse(crashed, "the app stopped running after Connect (a crash? crashes/ in the results)")
            XCTFail("the session never showed as active (\"Stop Session\" in its actions)")
            return
        }

        var alive = true
        for _ in 0..<15 {
            sleep(1)
            if threema.state == .notRunning {
                alive = false
                break
            }
        }
        report += alive ? "the app still ran 15 s after the session showed active\n"
            : "the app stopped running after the session showed active\n"
        if alive && !stop.exists, let session = sessionRow(timeout: 5), session.isHittable {
            session.tap()
        }
        let stillActive = alive && stop.waitForExistence(timeout: 5)
        if alive && !stillActive {
            report += "its actions no longer offer \"Stop Session\"\n"
            attachScreenshot("m20-04-not-active")
        }
        attachText("m20-session", report)
        XCTAssertTrue(alive, "the app stopped running after the session showed active (a crash? crashes/ in the results)")
        XCTAssertTrue(stillActive, "the session showed active, but 15 s later its actions no longer offer \"Stop Session\"")

        stop.tap()
        sleep(3)
        attachScreenshot("m20-05-stopped")
    }

    private func sessionRow(timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Untitled session", "Not saved")
        let candidates = [
            threema.buttons.matching(predicate).firstMatch,
            threema.cells.matching(predicate).firstMatch,
            threema.staticTexts.matching(predicate).firstMatch,
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = candidates.first(where: { $0.exists }) {
                return found
            }
            sleep(1)
        } while Date() < deadline
        return nil
    }

    private func hideKeyboard() {
        let keyboard = threema.keyboards.firstMatch
        guard keyboard.exists else {
            return
        }
        for key in ["return", "Return", "done", "Done"] where keyboard.buttons[key].exists {
            keyboard.buttons[key].tap()
            break
        }
        sleep(1)
    }

    private func closeActions() {
        let cancel = threema.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        }
        else {
            threema.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        sleep(1)
    }

    private func closeBetaTip() {
        guard threema.staticTexts["Send us your beta feedback!"].exists else {
            return
        }
        attachScreenshot("m20-01-tip")
        let close = threema.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Dismiss"))
            .allElementsBoundByIndex.first { $0.isHittable }
        if let close {
            close.tap()
        }
        else {
            threema.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        }
        sleep(1)
    }

    private func state(of toggle: XCUIElement) -> String {
        guard toggle.exists else {
            return "no switch"
        }
        let value = toggle.value as? String ?? "\(String(describing: toggle.value))"
        return "\(value == "1" ? "on" : value == "0" ? "off" : value)\(toggle.isEnabled ? "" : ", disabled")"
    }

    private func reveal(_ element: XCUIElement) -> Bool {
        if !element.waitForExistence(timeout: 10) {
            for _ in 0..<8 where !element.exists {
                threema.swipeUp()
            }
        }
        for _ in 0..<8 where element.exists && !element.isHittable {
            threema.swipeUp()
        }
        return element.exists && element.isHittable
    }
}

