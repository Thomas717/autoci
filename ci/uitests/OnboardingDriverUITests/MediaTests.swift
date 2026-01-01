import XCTest

final class MediaTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m8")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m8-00-modal-\($0)") }
    }

    func testSeeTheCLIImage() throws {
        let caption = try XCTUnwrap(ProcessInfo.processInfo.environment["M8_INBOUND"])

        if !(Driver.inChat(timeout: 3) && Driver.shows(caption, timeout: 5)) {
            Driver.openChatList()
            let found = Driver.cell(containing: [caption], timeout: 90) ?? Driver.cell(containing: ["CI CLI"], timeout: 10)
            attachScreenshot("m8-01-list")
            guard let cell = found else {
                attachTree("m8-01-tree")
                XCTFail("no chat with the CLI's image in the list")
                return
            }
            XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
        }
        XCTAssertTrue(Driver.shows(caption, timeout: 60), "the chat does not show the CLI's image caption")
        sleep(5)
        attachScreenshot("m8-02-received")
        let image = threema.cells.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                       "Image", "Caption: " + caption)).firstMatch
        attachText("m8-02-cell", image.exists ? image.label : "no cell with \"Image\" and the caption in its label")
        XCTAssertTrue(image.exists, "the chat shows no image message with the CLI's caption")
    }

    func testSendImageToCLI() throws {
        let caption = try XCTUnwrap(ProcessInfo.processInfo.environment["M8_OUTBOUND"])

        let picker = threema.buttons["Open Image Picker"]
        let attachments = threema.buttons["Add Attachments"]
        if !picker.waitForExistence(timeout: 5) && !attachments.exists {
            Driver.openChatList()
            guard let cell = Driver.cell(containing: ["CI CLI"], timeout: 30) else {
                attachTree("m8-03-tree")
                XCTFail("no chat with the CLI in the list")
                return
            }
            XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
            _ = picker.waitForExistence(timeout: 10)
        }
        attachScreenshot("m8-03-chat")

        let asset = threema.collectionViews.cells.firstMatch
        let systemAsset = threema.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        for _ in 0..<3 where !asset.exists && !systemAsset.exists {
            if picker.exists && picker.isHittable {
                picker.tap()
            } else {
                XCTAssertTrue(attachments.waitForExistence(timeout: 5), "neither \"Open Image Picker\" nor \"Add Attachments\"")
                attachments.tap()
                let existing = threema.buttons["Choose Existing"]
                if existing.waitForExistence(timeout: 10) {
                    existing.tap()
                }
            }
            handleAlerts(prefix: "m8")
            let deadline = Date().addingTimeInterval(15)
            while !asset.exists && !systemAsset.exists && Date() < deadline {
                sleep(1)
            }
        }
        if asset.exists {
            attachScreenshot("m8-04-picker")
            asset.tap()
            let select = threema.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Select (")).firstMatch
            guard select.waitForExistence(timeout: 10) else {
                attachScreenshot("m8-05-no-select")
                attachTree("m8-05-tree")
                XCTFail("no \"Select (1)\" after tapping an asset")
                return
            }
            select.tap()
        } else if systemAsset.exists {
            attachScreenshot("m8-04-system-picker")
            attachText("m8-04-asset", systemAsset.label)
            tapAt(systemAsset)
            let byBar = threema.navigationBars["Photos"].buttons["Done"]
            let done = byBar.exists ? byBar : threema.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Done", "Add")).firstMatch
            let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: done)
            guard XCTWaiter.wait(for: [enabled], timeout: 10) == .completed else {
                attachScreenshot("m8-05-no-done")
                attachTree("m8-05-tree")
                XCTFail("the system picker's Done does not become enabled after tapping a photo")
                return
            }
            if done.isHittable {
                done.tap()
            } else {
                tapAt(done)
            }
        } else {
            attachScreenshot("m8-04-no-picker")
            attachTree("m8-04-tree")
            XCTFail("no picker grid, neither the app's nor the system's")
            return
        }

        let field = threema.textFields["Add a Caption"]
        guard field.waitForExistence(timeout: 30) else {
            attachScreenshot("m8-06-no-preview")
            attachTree("m8-06-tree")
            XCTFail("no preview with a caption field")
            return
        }
        Driver.focus(field)
        field.typeText(caption)
        attachScreenshot("m8-06-preview")
        let byBar = threema.navigationBars.buttons["Send"]
        let send = byBar.waitForExistence(timeout: 5) ? byBar : threema.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no Send button in the preview")
        send.tap()
        handleAlerts(prefix: "m8")

        XCTAssertTrue(Driver.shows(caption, timeout: 60), "the chat does not show the sent image's caption")
        sleep(3)
        attachScreenshot("m8-07-sent")
        let own = threema.cells.matching(NSPredicate(format: "label CONTAINS %@", caption)).firstMatch
        attachText("m8-07-cell", own.exists ? own.label : "no cell with the caption in its label")
    }

    private func tapAt(_ element: XCUIElement) {
        let frame = element.frame
        threema.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
    }
}

