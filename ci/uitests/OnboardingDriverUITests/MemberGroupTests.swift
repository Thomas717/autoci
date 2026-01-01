import XCTest

final class MemberGroupTests: XCTestCase {
    private var app: XCUIApplication { Driver.threema }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        Quiescence.ignoreAnimations()
        app.activate()
        handleAlerts(prefix: "m30")
        LaunchModals.clear(app, settle: 3) { attachScreenshot("m30-00-modal-\($0)") }
        attachText("m30-00-quiescence", Quiescence.note)
    }

    func testSeeGroup() throws {
        let name = try XCTUnwrap(env["M30_GROUP"])
        XCTAssertTrue(mkOpenChat([name], tag: "m30-01", timeout: 120), "no chat \"\(name)\"")
        sleep(1)
        attachScreenshot("m30-01-group")
    }

    func testSeeRename() throws {
        let renamed = try XCTUnwrap(env["M30_RENAMED"])
        XCTAssertTrue(mkSeeInChat([renamed], ["Group renamed to", renamed], tag: "m30-02", timeout: 90),
                      "the chat does not say it was renamed to \"\(renamed)\"")
    }

    func testSeeGroupPicture() throws {
        let renamed = try XCTUnwrap(env["M30_RENAMED"])
        XCTAssertTrue(mkSeeInChat([renamed], ["Group picture changed"], tag: "m30-03", timeout: 90),
                      "the chat does not say the group picture changed")
        XCTAssertTrue(mkOpenDetails(renamed, tag: "m30-04", until: { mkGroupDetailsShown }), "no group details")
        sleep(4)
        attachScreenshot("m30-05-details")
    }

    func testGroupPoll() throws {
        let renamed = try XCTUnwrap(env["M30_RENAMED"])
        let title = try XCTUnwrap(env["M30_POLL"])
        let first = try XCTUnwrap(env["M30_CHOICE_A"])
        let second = try XCTUnwrap(env["M30_CHOICE_B"])
        XCTAssertTrue(mkOpenChat([renamed], tag: "m30-06"), "the group chat does not open")
        XCTAssertTrue(mkCreatePoll(title: title, choices: [first, second], tag: "m30-06"), "no poll created")
        let shown = MK.messageRow(["Title: \(title)"]).waitForExistence(timeout: 30)
        sleep(1)
        attachScreenshot("m30-07-poll")
        attachText("m30-07-row", shown ? MK.messageRow(["Title: \(title)"]).label : "no message \"Title: \(title)\"")
        XCTAssertTrue(shown, "the group chat shows no poll \"\(title)\"")
    }

    func testCloseGroupPoll() throws {
        let renamed = try XCTUnwrap(env["M30_RENAMED"])
        let title = try XCTUnwrap(env["M30_POLL"])
        let first = try XCTUnwrap(env["M30_CHOICE_A"])
        XCTAssertTrue(mkOpenChat([renamed], tag: "m30-08"), "the group chat does not open")
        let voted = MK.waitUntil(90) { MK.messageRow(["Title: \(title)", "1 of 2 Participants"]).exists }
        attachScreenshot("m30-08-voted")
        attachText("m30-08-row", MK.messageRow(["Title: \(title)"]).label)
        XCTAssertTrue(voted, "the poll's message never says \"1 of 2 Participants.\"")
        XCTAssertTrue(mkClosePoll(["Title: \(title)"], tag: "m30-09"), "the poll is not closed")
        let closed = MK.waitUntil(30) { MK.pollSays(title, "Most votes for", first) }
        sleep(1)
        attachScreenshot("m30-09-closed")
        XCTAssertTrue(closed, "the poll's message does not say \"Most votes for \(first).\"")
    }

    func testGroupLocation() throws {
        let renamed = try XCTUnwrap(env["M30_RENAMED"])
        XCTAssertTrue(mkOpenChat([renamed], tag: "m30-10"), "the group chat does not open")
        XCTAssertTrue(mkSendMyLocation(tag: "m30-10"), "no location sent")
        sleep(3)
        attachScreenshot("m30-10-sent")
    }

    func testLeave() throws {
        let renamed = try XCTUnwrap(env["M30_RENAMED"])
        XCTAssertTrue(mkOpenChat([renamed], tag: "m30-11"), "the group chat does not open")
        XCTAssertTrue(mkOpenDetails(renamed, tag: "m30-11", until: { mkGroupDetailsShown }), "no group details")
        XCTAssertTrue(mkGroupAction("Leave Group", sheet: "Leave \u{201C}", tag: "m30-11"),
                      "the app did not leave (the row, or its sheet's \"Leave Group\")")
        XCTAssertTrue(mkSeeInChat([renamed], ["You have left the group"], tag: "m30-12"),
                      "the chat does not say \"You have left the group.\"")
    }
}

