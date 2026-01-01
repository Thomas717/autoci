import XCTest

final class ChatFlagsTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m25")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m25-00-modal-\($0)") }
        closeMenu()
        closeForwardSheet()
    }

    func testTypeWhilePeerOnline() throws {
        let typing = try XCTUnwrap(ProcessInfo.processInfo.environment["M25_TYPING"])
        openCLIChat("m25-01")
        let composer = try XCTUnwrap(Driver.composer(), "no composer in the chat")
        Driver.focus(composer)
        typeSlowly(composer, typing)
        sleep(3)
        attachScreenshot("m25-01-typing")
        clear(composer, typing.count)
        sleep(3)
        attachScreenshot("m25-02-cleared")
    }

    func testTypeWhilePeerOffline() throws {
        let env = ProcessInfo.processInfo.environment
        let typing = try XCTUnwrap(env["M25_TYPING"])
        let text = try XCTUnwrap(env["M25_TEXT"])
        openCLIChat("m25-03")
        let composer = try XCTUnwrap(Driver.composer(), "no composer in the chat")
        Driver.focus(composer)
        typeSlowly(composer, typing)
        sleep(3)
        clear(composer, typing.count)
        sleep(2)
        attachScreenshot("m25-03-cleared")
        XCTAssertTrue(Driver.send(text), "the text does not appear in the chat")
        sleep(3)
        attachScreenshot("m25-04-sent")
    }

    func testEdit() throws {
        let env = ProcessInfo.processInfo.environment
        let text = try XCTUnwrap(env["M25_TEXT"])
        let edited = try XCTUnwrap(env["M25_EDITED"])
        openCLIChat("m25-05")
        let confirm = threema.buttons["Confirm Edit"]
        XCTAssertTrue(chooseFromMenu(of: text, own: true, action: "Edit", tag: "m25-05", until: confirm),
                      "no \"Edit\" in the text's menu")
        XCTAssertTrue(confirm.exists, "no \"Confirm Edit\": the chat bar is not editing the text")
        let composer = try XCTUnwrap(Driver.composer(), "no composer while editing")
        Driver.focus(composer)
        clear(composer, text.count)
        if ((composer.value as? String) ?? "").contains(text) {
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            clear(composer, text.count)
        }
        composer.typeText(edited)
        attachScreenshot("m25-06-editing")
        for _ in 0..<3 where confirm.exists {
            if confirm.isHittable {
                confirm.tap()
            }
            sleep(2)
        }
        let shown = bubble(edited).waitForExistence(timeout: 30)
        attachScreenshot("m25-07-edited")
        if shown {
            attachText("m25-07-label", bubble(edited).label)
        } else {
            attachTree("m25-07-tree")
        }
        XCTAssertTrue(shown, "the chat does not show the edited text")
    }

    func testDeleteForEveryone() throws {
        let edited = try XCTUnwrap(ProcessInfo.processInfo.environment["M25_EDITED"])
        openCLIChat("m25-08")
        let everyone = threema.buttons.matching(NSPredicate(format: "label == %@", "Delete for Everyone")).firstMatch
        XCTAssertTrue(chooseFromMenu(of: edited, own: true, action: "Delete", tag: "m25-08", also: "trash", until: everyone),
                      "no \"Delete\" in the text's menu")
        guard everyone.exists else {
            attachScreenshot("m25-09-no-sheet")
            attachTree("m25-09-tree")
            XCTFail("no \"Delete for Everyone\" in the delete sheet")
            return
        }
        attachScreenshot("m25-09-sheet")
        var taps = 0
        for _ in 0..<4 where everyone.exists {
            if everyone.isHittable {
                everyone.tap()
                taps += 1
            }
            let gone = Date().addingTimeInterval(4)
            while everyone.exists && Date() < gone {
                usleep(300_000)
            }
        }
        attachText("m25-09-taps", "\(taps) tap(s) on \"Delete for Everyone\"")
        let deadline = Date().addingTimeInterval(30)
        while bubble(edited).exists && Date() < deadline {
            sleep(1)
        }
        attachScreenshot("m25-10-deleted")
        XCTAssertFalse(bubble(edited).exists, "the edited text is still in the chat")
    }

    func testReact() throws {
        let text = try XCTUnwrap(ProcessInfo.processInfo.environment["M25_REACT"])
        openCLIChat("m25-11")
        let target = bubble(text)
        XCTAssertTrue(target.waitForExistence(timeout: 60), "the chat does not show the CLI's text")
        let thumbs = NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label CONTAINS[c] %@", "👍", "👍", "thumbs up")
        var taps = 0
        for attempt in 0..<3 where !reacted(text) {
            guard openMenu(on: target, own: false, tag: "m25-11", attempt: attempt) else {
                continue
            }
            var tapped = false
            let deadline = Date().addingTimeInterval(5)
            while !tapped && Date() < deadline {
                let candidates = threema.buttons.matching(thumbs).allElementsBoundByIndex +
                    threema.descendants(matching: .any).matching(thumbs).allElementsBoundByIndex
                if let button = candidates.first(where: { $0.exists && $0.isHittable }) {
                    if taps == 0 {
                        attachScreenshot("m25-11-menu")
                    }
                    button.tap()
                    tapped = true
                    taps += 1
                }
                usleep(300_000)
            }
            let shown = Date().addingTimeInterval(10)
            while tapped && !reacted(text) && Date() < shown {
                usleep(500_000)
            }
        }
        guard taps > 0 else {
            attachScreenshot("m25-11-no-reaction")
            attachTree("m25-11-tree")
            closeMenu()
            XCTFail("no thumbs up in the reaction bar of the CLI's text")
            return
        }
        handleAlerts(prefix: "m25")
        sleep(2)
        attachScreenshot("m25-12-reacted")
        attachText("m25-12-label", "\(taps) tap(s) on the thumbs up; the message: \(bubble(text).label)")
        XCTAssertTrue(reacted(text), "the CLI's text shows no reaction of the app after \(taps) tap(s)")
    }

    private func reacted(_ text: String) -> Bool {
        let message = bubble(text)
        guard message.exists else {
            return false
        }
        let label = message.label
        return label.contains("reacted by you") || label.contains("Current reactions")
    }


    private func openCLIChat(_ tag: String) {
        Driver.openChatList()
        guard let cell = Driver.cell(containing: ["CI CLI"], timeout: 30) else {
            attachScreenshot("\(tag)-list")
            attachTree("\(tag)-tree")
            XCTFail("no chat with the CLI in the list")
            return
        }
        XCTAssertTrue(Driver.open(cell), "the chat with the CLI does not open")
        sleep(1)
    }

    private func bubble(_ text: String) -> XCUIElement {
        Driver.message(containing: text)
    }

    private func typeSlowly(_ element: XCUIElement, _ text: String) {
        for character in text {
            element.typeText(String(character))
            usleep(150_000)
        }
    }

    private func clear(_ element: XCUIElement, _ count: Int) {
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 4))
    }

    private func longPress(_ row: XCUIElement, own: Bool) {
        row.coordinate(withNormalizedOffset: CGVector(dx: own ? 0.8 : 0.25, dy: 0.5)).press(forDuration: 1.2)
    }

    private var menuItem: XCUIElement {
        threema.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@", ["Copy", "Forward", "Details", "Select", "Reply"])).firstMatch
    }

    private func openMenu(on row: XCUIElement, own: Bool, tag: String, attempt: Int) -> Bool {
        if attempt > 0 {
            closeMenu()
        }
        longPress(row, own: own)
        let open = menuItem.waitForExistence(timeout: 5)
        if attempt == 0 {
            attachScreenshot("\(tag)-menu-\(open ? "open" : "none")")
            attachTree("\(tag)-menu-tree")
        }
        return open
    }

    private func hittable(_ labels: [String]) -> XCUIElement? {
        let predicate = NSPredicate(format: "label IN %@", labels)
        let candidates = threema.buttons.matching(predicate).allElementsBoundByIndex +
            threema.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
        return candidates.last { $0.exists && $0.isHittable }
    }

    private func chooseFromMenu(of text: String, own: Bool, action: String, tag: String, also: String? = nil,
                                until effect: XCUIElement) -> Bool {
        let target = bubble(text)
        guard target.waitForExistence(timeout: 30) else {
            attachScreenshot("\(tag)-no-message")
            attachTree("\(tag)-tree")
            return false
        }
        let labels = [action] + (also.map { [$0] } ?? [])
        var taps = 0
        for attempt in 0..<3 where !effect.exists {
            guard openMenu(on: target, own: own, tag: tag, attempt: attempt) else {
                continue
            }
            var tapped = false
            let deadline = Date().addingTimeInterval(5)
            while !tapped && Date() < deadline {
                if let item = hittable(labels) {
                    if taps == 0 {
                        attachScreenshot("\(tag)-menu")
                    }
                    item.tap()
                    tapped = true
                    taps += 1
                }
                usleep(300_000)
            }
            if tapped && effect.waitForExistence(timeout: 10) {
                break
            }
        }
        if effect.exists {
            if taps > 1 {
                attachText("\(tag)-taps", "\(taps) tap(s) on \"\(action)\"")
            }
            return true
        }
        attachScreenshot("\(tag)-no-menu")
        attachTree("\(tag)-tree")
        closeMenu()
        return false
    }

    private var menuTable: XCUIElement {
        threema.tables.containing(NSPredicate(format: "label == %@", "Copy")).firstMatch
    }

    private func closeMenu() {
        let screen = threema.frame
        let deadline = Date().addingTimeInterval(12)
        while menuTable.exists && Date() < deadline {
            let menu = menuTable.frame
            let x = menu.minX >= 60 ? menu.minX / 2 : (menu.maxX + screen.width) / 2
            threema.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: menu.midY)).tap()
            sleep(1)
        }
    }

    private func closeForwardSheet() {
        let bar = threema.navigationBars["Forward to"]
        guard bar.exists else {
            return
        }
        attachScreenshot("m25-00-forward-sheet")
        let cancel = bar.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
            sleep(2)
        }
    }
}

