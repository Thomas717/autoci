import XCTest

final class PollLocationTests: XCTestCase {
    private var app: XCUIApplication { Driver.threema }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        Quiescence.ignoreAnimations()
        app.activate()
        handleAlerts(prefix: "m29")
        LaunchModals.clear(app, settle: 3) { attachScreenshot("m29-00-modal-\($0)") }
        attachText("m29-00-quiescence", Quiescence.note)
    }

    func testCreatePoll() throws {
        let title = try XCTUnwrap(env["M29_POLL"])
        let first = try XCTUnwrap(env["M29_CHOICE_A"])
        let second = try XCTUnwrap(env["M29_CHOICE_B"])
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m29-01"), "the chat with the CLI does not open")
        XCTAssertTrue(mkCreatePoll(title: title, choices: [first, second], tag: "m29-02"), "no poll created")
        let row = MK.messageRow(["Title: \(title)"])
        let shown = row.waitForExistence(timeout: 30)
        sleep(1)
        attachScreenshot("m29-03-poll")
        attachText("m29-03-row", shown ? row.label : "no message \"Title: \(title)\"")
        XCTAssertTrue(shown, "the chat shows no poll \"\(title)\"")
    }

    func testCloseAfterVote() throws {
        let title = try XCTUnwrap(env["M29_POLL"])
        let first = try XCTUnwrap(env["M29_CHOICE_A"])
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m29-04"), "the chat with the CLI does not open")
        let voted = MK.waitUntil(90) { MK.messageRow(["Title: \(title)", "1 of 2 Participants"]).exists }
        attachScreenshot("m29-04-voted")
        attachText("m29-04-row", MK.messageRow(["Title: \(title)"]).label)
        let message = MK.messageRow(["vote", title])
        attachText("m29-04-vote-message", message.exists && !message.label.contains("Title:") ? message.label : "no vote system message seen")
        XCTAssertTrue(voted, "the poll's message never says \"1 of 2 Participants.\"")
        XCTAssertTrue(mkClosePoll(["Title: \(title)"], tag: "m29-05"), "the poll is not closed")
        let closed = MK.waitUntil(30) { MK.pollSays(title, "Most votes for", first) }
        sleep(1)
        attachScreenshot("m29-06-closed")
        attachText("m29-06-row", MK.messageRow(["Title: \(title)", "Closed"]).label)
        XCTAssertTrue(closed, "the poll's message does not say \"Most votes for \(first).\"")
    }

    func testVoteOnCLIPoll() throws {
        let title = try XCTUnwrap(env["M29_CLI_POLL"])
        let choice = try XCTUnwrap(env["M29_CLI_CHOICE"])
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m29-07"), "the chat with the CLI does not open")
        let row = MK.messageRow(["Title: \(title)"])
        XCTAssertTrue(MK.waitUntil(90) { MK.messageRow(["Title: \(title)"]).exists }, "the chat shows no poll \"\(title)\"")
        attachText("m29-07-row", row.label)
        XCTAssertTrue(mkVote(["Title: \(title)"], choice: choice, tag: "m29-08"), "no vote")
        let voted = MK.waitUntil(30) { MK.pollSays(title, "You voted for", choice) }
        sleep(1)
        attachScreenshot("m29-09-voted")
        attachText("m29-09-row", MK.messageRow(["Title: \(title)"]).label)
        XCTAssertTrue(voted, "the poll's message does not say \"You voted for \(choice).\"")
    }

    func testSeeClosedCLIPoll() throws {
        let title = try XCTUnwrap(env["M29_CLI_POLL"])
        let choice = try XCTUnwrap(env["M29_CLI_CHOICE"])
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m29-10"), "the chat with the CLI does not open")
        let closed = MK.waitUntil(90) { MK.pollSays(title, "Most votes for", choice) }
        sleep(1)
        attachScreenshot("m29-10-closed")
        attachText("m29-10-row", MK.messageRow(["Title: \(title)"]).label)
        XCTAssertTrue(closed, "the CLI's poll does not say \"Most votes for \(choice).\"")
        XCTAssertTrue(MK.messageRow(["Title: \(title)", "Closed"]).exists, "the CLI's poll does not say \"Closed\"")
    }

    func testSendLocation() throws {
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m29-11"), "the chat with the CLI does not open")
        XCTAssertTrue(mkSendMyLocation(tag: "m29-11"), "no location sent")
        sleep(3)
        attachScreenshot("m29-11-sent")
    }

    func testSeeCLILocation() throws {
        let place = try XCTUnwrap(env["M29_PLACE"])
        XCTAssertTrue(mkOpenChat(["CI CLI"], tag: "m29-12"), "the chat with the CLI does not open")
        XCTAssertTrue(MK.waitUntil(90) { MK.messageRow([place]).exists }, "the chat shows no location \"\(place)\"")
        sleep(1)
        attachScreenshot("m29-12-chat")
        attachText("m29-12-row", MK.messageRow([place]).label)
        let view = app.navigationBars["Location"]
        var moves: [String] = []
        for _ in 0..<4 where !view.exists {
            let ready = MK.bringIntoView({ MK.messageRow([place]) }, moves: &moves)
            let row = MK.messageRow([place])
            if row.exists && (ready || MK.inChatBand(row)) {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                moves.append(ready ? "tap" : "tap, not hittable")
            } else {
                moves.append("no tap, the row out of the band")
            }
            _ = view.waitForExistence(timeout: 6)
        }
        attachText("m29-12-moves", moves.isEmpty ? "none" : moves.joined(separator: ", "))
        sleep(3)
        attachScreenshot("m29-13-location")
        XCTAssertTrue(view.exists, "the location's message does not open \"Location\"")
        if let close = MK.barButton(["Done", "Close"], bar: "Location") {
            close.tap()
        }
        Driver.openChatList()
    }
}

