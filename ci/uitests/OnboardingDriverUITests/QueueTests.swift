import XCTest

final class QueueTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m18")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m18-00-modal-\($0)") }
    }

    func testSeeTheQueuedTexts() throws {
        let texts = try XCTUnwrap(ProcessInfo.processInfo.environment["M18_TEXTS"]).components(separatedBy: "|")
        let last = try XCTUnwrap(texts.last)
        Driver.openChatList()
        let found = Driver.cell(containing: [last], timeout: 90) ?? Driver.cell(containing: ["CI CLI"], timeout: 10)
        attachScreenshot("m18-01-list")
        guard let cell = found else {
            attachTree("m18-01-tree")
            XCTFail("no chat with the CLI's queued texts in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
        var missing: [String] = []
        for text in texts where !Driver.shows(text, timeout: 20) {
            missing.append(text)
        }
        attachScreenshot("m18-02-chat")
        let frames = texts.map { text -> CGFloat in
            let cell = threema.cells.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            return cell.exists ? cell.frame.minY : -1
        }
        attachText("m18-02-order", zip(texts, frames).map { "\($0.1)\t\($0.0)" }.joined(separator: "\n"))
        XCTAssertTrue(missing.isEmpty, "the chat does not show \(missing)")
        let shown = frames.filter { $0 >= 0 }
        XCTAssertEqual(shown, shown.sorted(), "the queued texts are not in the order sent")
    }
}

