import XCTest

final class MultiDeviceTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m11")
    }

    func testStartLinking() throws {
        let fragment = try XCTUnwrap(ProcessInfo.processInfo.environment["M11_JOIN"])
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m11-00-modal-\($0)") }

        XCTAssertTrue(Driver.selectTab("Settings"), "the Settings tab cannot be selected")
        let desktop = threema.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "for Desktop (Beta)")).firstMatch
        guard reveal(desktop) else {
            attachScreenshot("m11-01-settings")
            attachTree("m11-01-tree")
            XCTFail("no \"… 2.0 for Desktop (Beta)\" row in the Settings: no mediator in the provisioning file?")
            return
        }
        desktop.tap()

        let add = threema.buttons["Add Device"]
        let field = threema.textFields["Join URL"]
        guard add.waitForExistence(timeout: 20) else {
            attachScreenshot("m11-02-linked-devices")
            attachTree("m11-02-tree")
            XCTFail("no \"Add Device\" on the linked devices page")
            return
        }
        attachScreenshot("m11-02-linked-devices")
        for _ in 0..<3 where !field.exists {
            let inFront = threema.buttons.matching(NSPredicate(format: "label == %@", "Add Device"))
                .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.last
            inFront?.tap()
            handleAlerts(prefix: "m11")
            _ = field.waitForExistence(timeout: 10)
        }
        guard field.exists else {
            attachScreenshot("m11-03-no-field")
            attachTree("m11-03-tree")
            XCTFail("no \"Join URL\" field on the scanner: not a simulator build?")
            return
        }
        attachScreenshot("m11-03-scanner")
        Driver.focus(field)
        field.typeText(fragment)
        let connect = threema.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "no Connect button")
        connect.tap()

        let trust = threema.staticTexts["Trust New Device"]
        let shown = trust.waitForExistence(timeout: 60)
        attachScreenshot("m11-04-emoji")
        if !shown {
            attachTree("m11-04-tree")
        }
        XCTAssertTrue(shown, "no \"Trust New Device\" after Connect: the rendezvous did not come up")
    }

    func testTrustTheCLI() throws {
        let env = ProcessInfo.processInfo.environment
        let names = try XCTUnwrap(env["M11_EMOJI"]).split(separator: " ").map(String.init)
        let labels = (env["M11_EMOJI_LABELS"] ?? "").split(separator: "|").map { $0.lowercased() }
        XCTAssertEqual(names.count, 3, "want three emoji names")
        XCTAssertTrue(threema.staticTexts["Trust New Device"].waitForExistence(timeout: 10),
                      "the emoji to compare are no longer in front")

        var tapped = false
        for _ in 0..<3 where !tapped {
            for row in threema.buttons.allElementsBoundByIndex where row.exists {
                let images = row.images.allElementsBoundByIndex
                guard images.count == 3 else { continue }
                let byLabel = labels.count == 3 && zip(images.map { $0.label.lowercased() }, labels).allSatisfy { $0 == $1 }
                let byIdentifier = zip(images.map(\.identifier), names).allSatisfy { $0.hasPrefix("emoji_" + $1) }
                if byLabel || byIdentifier {
                    attachText("m11-05-row", row.label)
                    row.tap()
                    tapped = true
                    break
                }
            }
            if !tapped {
                sleep(2)
            }
        }
        guard tapped else {
            attachScreenshot("m11-05-no-row")
            attachTree("m11-05-tree")
            XCTFail("no row shows the CLI's emoji \(names)")
            return
        }

        let success = threema.staticTexts["Device Linked Successfully"]
        let linked = success.waitForExistence(timeout: 180)
        attachScreenshot("m11-06-linked")
        if !linked {
            attachTree("m11-06-tree")
        }
        XCTAssertTrue(linked, "no \"Device Linked Successfully\"")
        let done = threema.buttons["Continue"]
        if done.waitForExistence(timeout: 5) {
            done.tap()
        }
    }

    func testSendWhileLinked() throws {
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["M11_TEXT"])
        Driver.openChatList()
        guard let cell = Driver.cell(containing: ["CI CLI"], timeout: 30) else {
            attachScreenshot("m11-06-list")
            attachTree("m11-06-tree")
            XCTFail("no chat with the CLI in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
        XCTAssertTrue(Driver.send(text), "the text does not appear in the chat")
        sleep(3)
        attachScreenshot("m11-07-sent")
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

