import XCTest

final class RecoveryTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m26")
    }

    func testRecovered() throws {
        let env = ProcessInfo.processInfo.environment
        let inbound = try XCTUnwrap(env["M26_INBOUND"], "no M26_INBOUND in the test runner's environment")
        let reply = try XCTUnwrap(env["M26_REPLY"], "no M26_REPLY in the test runner's environment")

        let licenceScreen = threema.buttons["ConfirmButton"]
        _ = licenceScreen.waitForExistence(timeout: 5)
        let shown = licenceScreen.exists
        attachText("m26-01-licence", "licence screen after the relaunch: \(shown)")
        if shown {
            attachScreenshot("m26-01-licence")
            if Driver.hittable(licenceScreen) {
                licenceScreen.tap()
            }
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: licenceScreen)
            _ = XCTWaiter.wait(for: [gone], timeout: 60)
            XCTAssertFalse(licenceScreen.exists, "the licence screen stays up after the recovery")
        }
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m26-00-modal-\($0)") }
        Driver.openChatList()
        attachScreenshot("m26-02-list")

        guard let cell = Driver.cell(containing: [inbound], timeout: 120) else {
            attachTree("m26-02-tree")
            XCTFail("no chat shows the CLI's text within 120 s")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
        XCTAssertTrue(Driver.shows(inbound, timeout: 30), "the chat does not show the CLI's text")
        attachScreenshot("m26-03-chat")
        XCTAssertTrue(Driver.send(reply), "the answer does not appear in the chat")
        sleep(3)
        attachScreenshot("m26-04-answered")
    }
}

