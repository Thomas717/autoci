import XCTest

final class LinkedDeviceTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private let removeAll = "Remove All Linked Devices"

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m23")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m23-00-modal-\($0)") }
    }

    private var deviceLabel: String {
        ProcessInfo.processInfo.environment["M23_DEVICE"] ?? "Go client"
    }

    private var deviceRow: XCUIElement {
        threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", deviceLabel)).firstMatch
    }

    private var addDevice: XCUIElement {
        threema.buttons.matching(NSPredicate(format: "label == %@", "Add Device")).firstMatch
    }

    func testSeeTheMirroredMessage() throws {
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["M23_TEXT"])
        Driver.openChatList()
        guard let cell = Driver.cell(containing: [text], timeout: 60) ?? Driver.cell(containing: ["CI CLI"], timeout: 10) else {
            attachScreenshot("m23-01-list")
            attachTree("m23-01-tree")
            XCTFail("no chat with the CLI in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
        let bubble = Driver.message(containing: text)
        let shown = bubble.waitForExistence(timeout: 30)
        attachScreenshot("m23-01-chat")
        attachText("m23-01-label", shown ? bubble.label : "no message labelled with the text")
        if !shown {
            attachTree("m23-01-tree")
        }
        XCTAssertTrue(shown, "the chat does not show the CLI device's text")
        XCTAssertTrue(bubble.label.contains("Your Message"),
                      "the text is not the app's own message: \(bubble.label)")
    }

    func testListDevices() throws {
        openLinkedDevices("m23-02")
        let listed = waitForRow(timeout: 60)
        attachScreenshot("m23-02-devices")
        if !listed {
            attachTree("m23-02-tree")
        }
        XCTAssertTrue(listed, "the linked devices page does not list the CLI's device (\(deviceLabel))")
    }

    func testRemoveAll() throws {
        openLinkedDevices("m23-03")
        XCTAssertTrue(waitForRow(timeout: 60), "the linked devices page does not list the CLI's device")

        let edit = threema.navigationBars.buttons["Edit"]
        let section = threema.buttons.matching(NSPredicate(format: "label == %@", removeAll)).firstMatch
        for _ in 0..<3 where !section.exists {
            if edit.exists && edit.isHittable {
                edit.tap()
            }
            _ = section.waitForExistence(timeout: 5)
        }
        attachScreenshot("m23-03-edit")
        guard section.exists else {
            attachTree("m23-03-tree")
            XCTFail("no \"\(removeAll)\" after Edit")
            return
        }
        if !section.isHittable {
            threema.swipeUp()
        }
        let sectionFrame = section.frame
        section.tap()

        let confirm = threema.sheets.buttons[removeAll]
        var taps = 0
        var confirmFrame: CGRect?
        for attempt in 0..<12 {
            if let target = confirmation(confirm, besides: sectionFrame, at: confirmFrame) {
                if taps == 0 {
                    attachScreenshot("m23-04-confirm")
                }
                confirmFrame = target.frame
                target.tap()
                taps += 1
                sleep(2)
                continue
            }
            if taps > 0 {
                break
            }
            if attempt % 4 == 3 && section.exists && section.isHittable {
                section.tap()
            }
            sleep(1)
        }
        guard taps > 0 else {
            attachScreenshot("m23-04-no-confirm")
            attachTree("m23-04-tree")
            XCTFail("no confirmation \"Remove all linked devices?\" to confirm")
            return
        }
        attachText("m23-04-taps", "\(taps) tap(s) on the confirmation")
        if confirmation(confirm, besides: sectionFrame, at: confirmFrame) != nil {
            attachScreenshot("m23-04-still")
            attachTree("m23-04-tree")
            XCTFail("the confirmation is still shown after \(taps) taps")
            return
        }
        handleAlerts(prefix: "m23")

        let deadline = Date().addingTimeInterval(120)
        while (deviceRow.exists || !addDevice.exists) && Date() < deadline {
            sleep(2)
        }
        attachScreenshot("m23-05-removed")
        if deviceRow.exists || !addDevice.exists {
            attachTree("m23-05-tree")
        }
        XCTAssertFalse(deviceRow.exists, "the CLI's device is still listed after \"\(removeAll)\"")
        XCTAssertTrue(addDevice.exists, "no \"Add Device\" after \"\(removeAll)\"")
    }

    func testMultiDeviceOff() throws {
        openLinkedDevices("m23-06")
        let offered = addDevice.waitForExistence(timeout: 30)
        sleep(3)
        attachScreenshot("m23-06-off")
        if !offered {
            attachTree("m23-06-tree")
        }
        XCTAssertTrue(offered, "the linked devices page does not offer \"Add Device\"")
        XCTAssertFalse(deviceRow.exists, "the linked devices page still lists the CLI's device")
        XCTAssertFalse(threema.navigationBars.buttons["Edit"].exists, "the page still has an Edit button")
    }


    private func openLinkedDevices(_ tag: String) {
        Driver.openChatList()
        XCTAssertTrue(Driver.selectTab("Settings"), "the Settings tab cannot be selected")
        sleep(2)
        closeBetaTip(tag)
        let desktop = threema.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "for Desktop (Beta)")).firstMatch
        let tab = threema.tabBars.buttons["Settings"]
        for _ in 0..<2 where !desktop.waitForExistence(timeout: 3) {
            if tab.exists && tab.isHittable {
                tab.tap()
            }
        }
        guard reveal(desktop) else {
            attachScreenshot("\(tag)-settings")
            attachTree("\(tag)-tree")
            XCTFail("no \"… 2.0 for Desktop (Beta)\" row in the Settings")
            return
        }
        for _ in 0..<4 where !onDevicesPage {
            if desktop.exists && desktop.isHittable {
                desktop.tap()
            }
            let deadline = Date().addingTimeInterval(8)
            while !onDevicesPage && Date() < deadline {
                usleep(500_000)
            }
        }
        sleep(2)
        handleAlerts(prefix: "m23")
        if !onDevicesPage {
            attachScreenshot("\(tag)-no-page")
            attachTree("\(tag)-tree")
        }
    }

    private var onDevicesPage: Bool {
        threema.navigationBars.buttons["BackButton"].exists || addDevice.exists || deviceRow.exists
    }

    private func confirmation(_ confirm: XCUIElement, besides sectionFrame: CGRect, at tapped: CGRect?) -> XCUIElement? {
        if confirm.exists && confirm.isHittable {
            return confirm
        }
        return threema.buttons.matching(NSPredicate(format: "label == %@", removeAll)).allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable && $0.frame != sectionFrame && (tapped == nil || $0.frame == tapped) }
            .last
    }

    private func waitForRow(timeout: TimeInterval) -> Bool {
        let failed = threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Failed to load linked devices")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if deviceRow.exists {
                return true
            }
            if failed.exists {
                threema.swipeDown()
            }
            sleep(2)
        } while Date() < deadline
        return deviceRow.exists
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

