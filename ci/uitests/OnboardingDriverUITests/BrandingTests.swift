import XCTest

final class BrandingTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m14")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m14-00-modal-\($0)") }
    }

    func testLogo() throws {
        let env = ProcessInfo.processInfo.environment
        let tag = env["M14_TAG"] ?? "logo"
        let aspect = Double(env["M14_ASPECT"] ?? "") ?? 4.0

        if !Driver.selectTab("Contacts") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Contacts"), "no Contacts tab")
        }
        sleep(2)
        let list = threema.tables.firstMatch.exists ? threema.tables.firstMatch : threema.collectionViews.firstMatch
        let cell = Driver.cell(containing: ["CI CLI"], timeout: 15) ?? list.cells.firstMatch
        if cell.exists {
            let start = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 8.0))
            start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
        } else {
            list.swipeDown()
        }
        sleep(8)
        attachScreenshot("m14-\(tag)-01-contacts")

        XCTAssertTrue(Driver.selectTab("Chats"), "no Chats tab")
        var report = ""
        var shown = false
        let deadline = Date().addingTimeInterval(30)
        repeat {
            sleep(2)
            report = ""
            shown = false
            for bar in threema.navigationBars.allElementsBoundByIndex {
                for image in bar.images.allElementsBoundByIndex where image.exists {
                    let frame = image.frame
                    let ratio = frame.height > 0 ? Double(frame.width / frame.height) : 0
                    let custom = abs(frame.height - 28) <= 2 && abs(ratio - aspect) <= 0.3
                    shown = shown || custom
                    report += "image \"\(image.identifier)\" \"\(image.label)\" \(Int(frame.width))x\(Int(frame.height))"
                        + " ratio \(String(format: "%.2f", ratio))\(custom ? " (the uploaded logo's size)" : "")\n"
                }
            }
        } while !shown && Date() < deadline
        attachScreenshot("m14-\(tag)-02-chats")
        attachText("m14-\(tag)-images", "uploaded logo shown: \(shown ? "yes" : "no")\n" + report)
        if !shown {
            attachTree("m14-\(tag)-tree")
        }
    }
}

