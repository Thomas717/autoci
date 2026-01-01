import XCTest

final class ProfilePictureTests: XCTestCase {
    private var app: XCUIApplication { Driver.threema }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        Quiescence.ignoreAnimations()
        app.activate()
        handleAlerts(prefix: "m27")
        LaunchModals.clear(app, settle: 3) { attachScreenshot("m27-00-modal-\($0)") }
        attachText("m27-00-quiescence", Quiescence.note)
    }

    func testSetOwnPicture() throws {
        XCTAssertTrue(openEditProfile(tag: "m27-01"), "no Edit Profile sheet")
        XCTAssertTrue(EditPicture.element.waitForExistence(timeout: 10), "no \"Edit picture\" on Edit Profile")
        attachScreenshot("m27-01-edit")
        attachTree("m27-01-tree")
        XCTAssertTrue(mkOpenPicker(tag: "m27-02"), "the photo picker does not open from \"Edit picture\"")
        XCTAssertTrue(mkPickNewestPhoto(tag: "m27-03"), "no photo picked and cropped")
        sleep(1)
        attachScreenshot("m27-04-picked")
        everyoneYouWrite(tag: "m27-04")
        XCTAssertTrue(mkSave(bar: "Edit Profile", tag: "m27-05"), "Edit Profile does not close with the picture saved")
        sleep(2)
        attachScreenshot("m27-06-profile")
    }

    func testWriteToCLI() throws {
        let text = try XCTUnwrap(env["M27_TEXT"])
        let tag = env["M27_TAG"] ?? "text"
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m27-07-\(tag)"), "the chat with the CLI does not open")
        XCTAssertTrue(Driver.send(text), "the text does not appear in the chat with the CLI")
        sleep(2)
        attachScreenshot("m27-07-\(tag)")
    }

    func testSendPictureNow() throws {
        let cliID = try XCTUnwrap(env["M27_CLI_ID"])
        XCTAssertTrue(openCLIDetails(cliID, tag: "m27-08"), "no details of the CLI")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Send Profile Picture Now")).firstMatch
        for _ in 0..<8 where !(row.exists && Driver.hittable(row)) {
            app.swipeUp()
            sleep(1)
        }
        guard row.exists else {
            attachScreenshot("m27-08-no-row")
            attachTree("m27-08-tree")
            XCTFail("no \"Send Profile Picture Now\" in the CLI's details (does the app send its picture to everyone it writes to?)")
            return
        }
        attachScreenshot("m27-08-row")
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Profile Picture Sent")).firstMatch
        var taps = 0
        for _ in 0..<3 where !toast.exists {
            if row.exists && Driver.hittable(row) {
                row.tap()
                taps += 1
            }
            _ = toast.waitForExistence(timeout: 6)
        }
        attachScreenshot("m27-09-sent")
        attachText("m27-09-taps", "\(taps) tap(s) on \"Send Profile Picture Now\"; toast seen: \(toast.exists)")
        XCTAssertGreaterThan(taps, 0, "\"Send Profile Picture Now\" could not be tapped")
    }

    func testSeeCLIPicture() throws {
        let cliID = try XCTUnwrap(env["M27_CLI_ID"])
        XCTAssertTrue(openCLIDetails(cliID, tag: "m27-10"), "no details of the CLI")
        sleep(4)
        attachScreenshot("m27-10-cli-picture")
    }

    func testDeleteOwnPicture() throws {
        XCTAssertTrue(openEditProfile(tag: "m27-11"), "no Edit Profile sheet")
        XCTAssertTrue(EditPicture.element.waitForExistence(timeout: 10), "no \"Edit picture\" on Edit Profile")
        attachScreenshot("m27-11-edit")
        attachText("m27-11-picture", "Edit picture: \(EditPicture.element.frame)")
        let save = { MK.barButton(["Done", "Save"], bar: "Edit Profile") }
        var tapped: [String] = []
        for point in EditPicture.deletePoints() where save() == nil {
            MK.tap(at: point)
            tapped.append("\(Int(point.x)),\(Int(point.y))")
            _ = MK.waitUntil(3) { save() != nil }
        }
        attachScreenshot("m27-12-deleted")
        attachText("m27-12-taps", "tapped at \(tapped.joined(separator: "; ")); Done enabled: \(save() != nil)")
        guard save() != nil else {
            attachTree("m27-12-tree")
            if env["M27_RETRY"] == "1" {
                let sheet = app.navigationBars["Edit Profile"]
                MK.tapFound({ MK.barButton(["Cancel", "Close"], bar: "Edit Profile") }, until: { !sheet.exists })
                attachText("m27-12-none", "second try: the delete badge changed nothing, so no picture was left to " +
                           "delete; Edit Profile closed: \(!sheet.exists)")
                return
            }
            XCTFail("the delete badge changed nothing (Done stays disabled): no picture to delete?")
            return
        }
        XCTAssertTrue(mkSave(bar: "Edit Profile", tag: "m27-12"), "Edit Profile does not close with the picture deleted")
        sleep(2)
        attachScreenshot("m27-13-profile")
    }


    private func openEditProfile(tag: String) -> Bool {
        mkCloseDetails()
        if !Driver.selectTab("Profile") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Profile"), "no Profile tab")
        }
        let tab = app.tabBars.buttons["Profile"]
        let back = app.navigationBars.buttons["BackButton"]
        for attempt in 0..<4 where back.exists {
            if attempt % 2 == 0 && tab.exists && Driver.hittable(tab) {
                tab.tap()
            } else if back.exists && Driver.hittable(back) {
                back.tap()
            }
            sleep(1)
        }
        let sheet = app.navigationBars["Edit Profile"]
        let shown = MK.tapFound({ MK.barButton(["Edit"]) }, until: { sheet.exists }, attempts: 4, wait: 6)
        if shown {
            sleep(1)
        } else {
            attachScreenshot("\(tag)-no-sheet")
            attachTree("\(tag)-tree")
        }
        return shown
    }

    private func everyoneYouWrite(tag: String) {
        let row = app.cells.containing(NSPredicate(format: "label == %@", "Recipients")).firstMatch
        for _ in 0..<3 where !(row.exists && Driver.hittable(row)) {
            app.swipeUp()
            sleep(1)
        }
        guard row.exists else {
            attachText("\(tag)-recipients", "no Recipients row")
            return
        }
        let texts = row.staticTexts.allElementsBoundByIndex.map(\.label)
        attachText("\(tag)-recipients", "Recipients: \(row.label) | \(texts.joined(separator: " | "))")
        if texts.contains("Everyone You Write") || row.label.contains("Everyone You Write") {
            return
        }
        let page = app.navigationBars["Profile Picture Recipients"]
        MK.tap(row, until: { page.exists })
        let everyone = app.cells.containing(NSPredicate(format: "label == %@", "Everyone You Write")).firstMatch
        if everyone.waitForExistence(timeout: 5) {
            everyone.tap()
        }
        attachScreenshot("\(tag)-recipients-page")
        _ = mkSave(bar: "Profile Picture Recipients", tag: "\(tag)-recipients")
    }

    private func openCLIDetails(_ cliID: String, tag: String) -> Bool {
        guard mkOpenChat(["CI CLI"], tag: tag) else {
            return false
        }
        let idShown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@ OR label ENDSWITH %@ OR label IN %@", cliID, cliID,
                                  " ID, \(cliID)", ["Send Profile Picture Now", "Profile Picture Recipient", "Do Not Disturb"]))
            .firstMatch
        let shown = mkOpenDetails("CI CLI", tag: tag) { idShown.exists }
        if shown {
            attachText("\(tag)-details", "the ID row: \(idShown.label) | \(String(describing: idShown.value))")
        }
        return shown
    }
}

