import XCTest

final class LinkTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private let phoneRow = "Linked Phone Number"
    private let emailRow = "Linked Email"

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m21")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m21-00-modal-\($0)") }
    }


    func testRequestPhoneLink() throws {
        let phone = try XCTUnwrap(env["M21_PHONE"])
        openPage(phoneRow, tag: "m21-01") { self.phoneUnlinked || self.phoneVerifying || self.phoneLinked }
        attachScreenshot("m21-01-page")
        guard phoneUnlinked else {
            attachTree("m21-01-tree")
            XCTFail("the Linked Phone Number page does not offer linking (verifying: \(phoneVerifying), linked: \(phoneLinked))")
            return
        }
        let field = threema.textFields.firstMatch
        XCTAssertTrue(Driver.focus(field), "the number field takes no keyboard focus")
        field.typeText(phone)
        attachText("m21-01-field", "the field holds: \(field.value as? String ?? "?")")

        let confirmed = confirm("Confirm number", tag: "m21-01")
        guard confirmed else {
            return
        }
        let shown = waitFor(timeout: 30) { self.phoneVerifying }
        sleep(1)
        attachScreenshot("m21-02-verify-page")
        if !shown {
            attachAlert("m21-02")
            attachTree("m21-02-tree")
        }
        XCTAssertTrue(shown, "no verify page (\"Code\", \"Request Call\") after the confirmation")
        let call = threema.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Request Call")).firstMatch
        attachText("m21-02-call", call.exists ? "Request Call: enabled \(call.isEnabled), label \(call.label)" : "no Request Call button")
    }

    func testVerifyCode() throws {
        let code = try XCTUnwrap(env["M21_CODE"])
        let last4 = env["M21_LAST4"] ?? ""
        openPage(phoneRow, tag: "m21-03") { self.phoneVerifying || self.phoneLinked }
        attachScreenshot("m21-03-page")
        guard phoneVerifying else {
            attachTree("m21-03-tree")
            XCTFail("the Linked Phone Number page is not waiting for a code (linked: \(phoneLinked))")
            return
        }
        let field = threema.textFields.firstMatch
        XCTAssertTrue(Driver.focus(field), "the code field takes no keyboard focus")
        field.typeText(code)
        let verify = pageButton("Verify")
        for _ in 0..<3 where !phoneLinked && !threema.alerts.firstMatch.exists {
            if let verify, verify.exists && Driver.hittable(verify) {
                verify.tap()
            }
            _ = waitFor(timeout: 15) { self.phoneLinked || self.threema.alerts.firstMatch.exists }
        }
        guard phoneLinked else {
            attachAlert("m21-04")
            dismissAlert()
            if field.exists {
                Driver.focus(field)
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: code.count + 2))
            }
            attachScreenshot("m21-04-not-linked")
            attachTree("m21-04-tree")
            XCTFail("the page does not show the number linked after Verify")
            return
        }
        sleep(2)
        attachScreenshot("m21-04-linked")
        let number = threema.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", last4)).firstMatch
        attachText("m21-04-number", number.exists ? number.label : "no text with \(last4)")
        XCTAssertTrue(number.exists, "the linked page does not show the number (…\(last4))")
        XCTAssertTrue(threema.buttons["Unlink Number"].exists, "no \"Unlink Number\" on the linked page")
    }

    func testRequestEmailLink() throws {
        let email = try XCTUnwrap(env["M21_EMAIL"])
        openPage(emailRow, tag: "m21-05") { self.emailUnlinked || self.emailVerifying || self.emailLinked }
        attachScreenshot("m21-05-page")
        guard emailUnlinked else {
            attachTree("m21-05-tree")
            XCTFail("the Linked Email page does not offer linking (verifying: \(emailVerifying), linked: \(emailLinked))")
            return
        }
        let field = threema.textFields.firstMatch
        XCTAssertTrue(Driver.focus(field), "the address field takes no keyboard focus")
        field.typeText(email)
        guard confirm("Confirm Email", tag: "m21-05") else {
            return
        }
        let toast = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Verification Email Sent")).firstMatch
        let toasted = toast.waitForExistence(timeout: 10)
        let shown = waitFor(timeout: 30) { self.emailVerifying }
        attachScreenshot("m21-06-verify-page")
        attachText("m21-06-toast", toasted ? "\"Verification Email Sent\" shown" : "no \"Verification Email Sent\" toast seen")
        if !shown {
            attachAlert("m21-06")
            attachTree("m21-06-tree")
        }
        XCTAssertTrue(shown, "no \"Stop Verification\" after the confirmation")
    }

    func testEmailLinked() throws {
        let email = env["M21_EMAIL"] ?? "@"
        var linked = false
        for _ in 0..<3 where !linked {
            profileRoot()
            openPage(emailRow, tag: "m21-07") { self.emailVerifying || self.emailLinked }
            linked = waitFor(timeout: 20) { self.emailLinked }
        }
        attachScreenshot("m21-07-linked")
        if !linked {
            attachTree("m21-07-tree")
        }
        XCTAssertTrue(linked, "the Linked Email page does not show the address linked (\"Unlink Email\")")
        XCTAssertTrue(Driver.shows(email, timeout: 5), "the page does not show \(email)")
    }

    func testUnlinkPhone() throws {
        openPage(phoneRow, tag: "m21-08") { self.phoneLinked || self.phoneUnlinked || self.phoneVerifying }
        attachScreenshot("m21-08-phone")
        XCTAssertTrue(phoneLinked, "the phone number is not linked")
        let phoneDone = unlink("Unlink Number") { self.phoneUnlinked }
        attachScreenshot("m21-09-phone-unlinked")
        if !phoneDone {
            attachAlert("m21-09")
            attachTree("m21-09-tree")
        }
        XCTAssertTrue(phoneDone, "the Linked Phone Number page does not offer linking after \"Unlink Number\"")
    }

    func testUnlinkEmail() throws {
        openPage(emailRow, tag: "m21-10") { self.emailLinked || self.emailUnlinked || self.emailVerifying }
        if emailVerifying {
            _ = waitFor(timeout: 20) { self.emailLinked }
        }
        attachScreenshot("m21-10-email")
        XCTAssertTrue(emailLinked, "the e-mail address is not linked (verifying: \(emailVerifying))")
        let emailDone = unlink("Unlink Email") { self.emailUnlinked }
        attachScreenshot("m21-11-email-unlinked")
        if !emailDone {
            attachAlert("m21-11")
            attachTree("m21-11-tree")
        }
        XCTAssertTrue(emailDone, "the Linked Email page does not offer linking after \"Unlink Email\"")

        profileRoot()
        sleep(1)
        attachScreenshot("m21-12-profile")
    }


    private var phoneVerifying: Bool {
        threema.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Request Call")).firstMatch.exists
    }

    private var phoneLinked: Bool { threema.buttons["Unlink Number"].exists }

    private var phoneUnlinked: Bool {
        threema.textFields.firstMatch.exists && !phoneVerifying && !phoneLinked
    }

    private var emailVerifying: Bool { threema.buttons["Stop Verification"].exists }

    private var emailLinked: Bool { threema.buttons["Unlink Email"].exists }

    private var emailUnlinked: Bool {
        threema.textFields.firstMatch.exists && !emailVerifying && !emailLinked
    }


    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            usleep(500_000)
        } while Date() < deadline
        return condition()
    }

    private func profileRoot() {
        if !Driver.selectTab("Profile") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Profile"), "no Profile tab")
        }
        let tab = threema.tabBars.buttons["Profile"]
        let back = threema.navigationBars.buttons["BackButton"]
        for attempt in 0..<4 where back.exists {
            if attempt % 2 == 0 && tab.exists && Driver.hittable(tab) {
                tab.tap()
            } else if back.exists && Driver.hittable(back) {
                back.tap()
            }
            sleep(1)
        }
        closeBetaTip()
    }

    private func row(_ title: String) -> XCUIElement {
        let cell = threema.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
        if cell.exists {
            return cell
        }
        return threema.staticTexts[title]
    }

    private func openPage(_ title: String, tag: String, until shown: @escaping () -> Bool) {
        profileRoot()
        let target = row(title)
        if !target.waitForExistence(timeout: 10) {
            for _ in 0..<6 where !target.exists {
                threema.swipeUp()
            }
        }
        for _ in 0..<6 where target.exists && !Driver.hittable(target) {
            threema.swipeUp()
        }
        guard target.exists else {
            attachScreenshot("\(tag)-profile")
            attachTree("\(tag)-tree")
            XCTFail("no \"\(title)\" row in the profile")
            return
        }
        for _ in 0..<4 where !shown() {
            if target.exists && Driver.hittable(target) {
                target.tap()
            }
            _ = waitFor(timeout: 8, shown)
        }
        handleAlerts(prefix: "m21")
        if !shown() {
            attachScreenshot("\(tag)-no-page")
            attachTree("\(tag)-tree")
            XCTFail("the \"\(title)\" page does not open")
        }
    }

    private func pageButton(_ label: String) -> XCUIElement? {
        threema.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .first { $0.exists && Driver.hittable($0) }
    }

    private func confirm(_ title: String, tag: String) -> Bool {
        let alert = threema.alerts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        let titled = threema.alerts.containing(NSPredicate(format: "label == %@", title)).firstMatch
        func shown() -> Bool { alert.exists || titled.exists }
        for _ in 0..<3 where !shown() {
            var verify = pageButton("Verify")
            if verify == nil {
                threema.collectionViews.firstMatch.swipeDown()
                sleep(1)
                verify = pageButton("Verify")
            }
            verify?.tap()
            _ = waitFor(timeout: 6, shown)
            if !shown() && threema.alerts.firstMatch.exists {
                break
            }
        }
        guard shown() else {
            attachAlert("\(tag)-alert")
            attachScreenshot("\(tag)-no-confirm")
            attachTree("\(tag)-tree")
            XCTFail("no \"\(title)\" alert after Verify")
            return false
        }
        let box = alert.exists ? alert : titled
        attachScreenshot("\(tag)-confirm")
        attachText("\(tag)-confirm-text", box.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        let button = box.buttons["Verify"]
        for _ in 0..<3 where shown() {
            if button.exists && Driver.hittable(button) {
                button.tap()
            }
            _ = waitFor(timeout: 5) { !shown() }
        }
        if shown() {
            attachTree("\(tag)-tree")
            XCTFail("the \"\(title)\" alert stays after its Verify")
            return false
        }
        return true
    }

    private func unlink(_ label: String, done: @escaping () -> Bool) -> Bool {
        for _ in 0..<3 where !done() && !threema.alerts.firstMatch.exists {
            if let button = pageButton(label) {
                button.tap()
            }
            _ = waitFor(timeout: 15) { done() || self.threema.alerts.firstMatch.exists }
        }
        return done()
    }

    private func attachAlert(_ tag: String) {
        let alert = threema.alerts.firstMatch
        guard alert.exists else {
            return
        }
        attachText("\(tag)-alert-text", alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
    }

    private func dismissAlert() {
        let alert = threema.alerts.firstMatch
        for _ in 0..<3 where alert.exists {
            let ok = alert.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "OK", "Cancel")).firstMatch
            if ok.exists {
                ok.tap()
            } else if alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
            }
            sleep(1)
        }
    }

    private func closeBetaTip() {
        guard threema.staticTexts["Send us your beta feedback!"].exists else {
            return
        }
        attachScreenshot("m21-tip")
        let close = threema.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Dismiss"))
            .allElementsBoundByIndex.first { Driver.hittable($0) }
        if let close {
            close.tap()
        } else {
            threema.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        }
        sleep(1)
    }
}

