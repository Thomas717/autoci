import XCTest

final class GroupCallTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    func testStartGroupCall() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let group = try XCTUnwrap(env["M6_GROUP_NAME"])
        let hold = TimeInterval(env["M6_HOLD"] ?? "") ?? 75

        threema.activate()
        handleAlerts(prefix: "m6")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m6-00-modal-\($0)") }
        Driver.openChatList()
        guard let cell = Driver.cell(containing: [group], timeout: 120) else {
            attachScreenshot("m6-01-list")
            attachTree("m6-01-tree")
            XCTFail("no chat \"\(group)\" in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the group chat does not open")
        LaunchModals.clear(threema, settle: 1) { attachScreenshot("m6-01-modal-\($0)") }
        let call = threema.buttons["ChatViewControllerGroupCallBarButtonItem"]
        guard call.waitForExistence(timeout: 30) else {
            attachScreenshot("m6-02-chat")
            attachTree("m6-02-tree")
            XCTFail("no group call button in the group chat")
            return
        }
        attachScreenshot("m6-02-chat")
        call.tap()

        var n = 3
        let end = Date().addingTimeInterval(hold)
        while Date() < end {
            sleep(15)
            handleAlerts(prefix: "m6")
            attachScreenshot(String(format: "m6-%02d-call", n))
            let header = threema.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "\(group), Participants:")).firstMatch
            if header.exists {
                attachText(String(format: "m6-%02d-header", n), header.label)
            }
            n += 1
        }
        let hangup = threema.buttons["group_call_button_hangup"]
        if hangup.exists && Driver.hittable(hangup) {
            hangup.tap()
        }
        sleep(3)
        attachScreenshot("m6-09-left")
    }
}

