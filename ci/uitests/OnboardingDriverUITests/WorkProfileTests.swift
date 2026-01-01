import XCTest

final class WorkProfileTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m24")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m24-00-modal-\($0)") }
    }

    private func openContacts() {
        if !Driver.selectTab("Contacts") {
            Driver.openChatList()
            XCTAssertTrue(Driver.selectTab("Contacts"), "no Contacts tab")
        }
        sleep(2)
    }

    private var list: XCUIElement {
        threema.tables.firstMatch.exists ? threema.tables.firstMatch : threema.collectionViews.firstMatch
    }

    private var shots: String {
        ProcessInfo.processInfo.environment["M24_SHOTS"] ?? "m24-0"
    }

    func testSyncProfile() throws {
        openContacts()
        let cell = Driver.cell(containing: ["CI CLI"], timeout: 30)
        attachScreenshot("\(shots)1-contacts")
        guard let cell else {
            attachTree("\(shots)1-tree")
            XCTFail("the Contacts tab does not list the CLI")
            return
        }
        var pulls = 0
        var synced = false
        var current: XCUIElement? = cell
        while !synced, pulls < 3, let row = current {
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 8.0))
            start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
            pulls += 1
            synced = threema.staticTexts["Contacts synced"].waitForExistence(timeout: 20)
            if !synced {
                current = Driver.cell(containing: ["CI CLI"], timeout: 10)
            }
        }
        attachScreenshot("\(shots)2-pulled")
        attachText("\(shots)2-synced", synced ? "\"Contacts synced\" shown after \(pulls) pull(s)" :
            "no \"Contacts synced\" toast after \(pulls) pull(s)")
        sleep(5)
        XCTAssertNotNil(Driver.cell(containing: ["CI CLI"], timeout: 10), "the CLI is gone after the pull")
    }

    func testCategoryFilter() throws {
        let env = ProcessInfo.processInfo.environment
        let hit = try XCTUnwrap(env["M24_HIT"])
        let empty = try XCTUnwrap(env["M24_EMPTY"])
        let name = try XCTUnwrap(env["M24_NAME"])
        openContacts()
        let listed = namedCells(name)
        attachText("m24-03-listed", "\(listed) row(s) named \"\(name)\" before the search")
        addTeardownBlock { [self] in
            if closeButton != nil {
                cancelSearch()
            }
        }

        if let problem = searchByCategory(hit, tag: "m24-03") {
            XCTFail(problem)
            return
        }
        var found = false
        let deadline = Date().addingTimeInterval(30)
        repeat {
            found = visibleCell(name) || namedCells(name) > listed
            if !found {
                sleep(2)
            }
        } while !found && Date() < deadline
        attachScreenshot("m24-04-hit")
        attachTree("m24-04-tree")
        XCTAssertTrue(found, "the directory search by \"\(hit)\" does not find \"\(name)\"")

        cancelSearch()
        if let problem = searchByCategory(empty, tag: "m24-05") {
            XCTFail(problem)
            return
        }
        sleep(8)
        let shown = visibleCell(name)
        let rows = namedCells(name)
        attachScreenshot("m24-06-empty")
        attachTree("m24-06-tree")
        attachText("m24-06-rows", "\(rows) row(s) named \"\(name)\" (\(listed) before the search), one that can be tapped: \(shown)")
        XCTAssertFalse(shown || rows > listed, "the directory search by \"\(empty)\" still finds \"\(name)\"")
        cancelSearch()
    }

    private func namedCells(_ name: String) -> Int {
        let predicate = NSPredicate(format: "label CONTAINS %@", name)
        return max(threema.cells.matching(predicate).count, threema.cells.containing(predicate).count)
    }

    private func visibleCell(_ name: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", name)
        let cells = threema.cells.matching(predicate).allElementsBoundByIndex +
            threema.cells.containing(predicate).allElementsBoundByIndex
        return cells.contains { $0.exists && $0.isHittable }
    }


    private let directoryTitle = "Company Directory"

    private func searchByCategory(_ category: String, tag: String) -> String? {
        guard let problem = trySearchByCategory(category, tag: tag) else {
            return nil
        }
        attachText("\(tag)-retry", "first try: \(problem); the search closed and tried again")
        cancelSearch()
        return trySearchByCategory(category, tag: "\(tag)-again")
    }

    private func trySearchByCategory(_ category: String, tag: String) -> String? {
        var search = threema.searchFields.firstMatch
        if !(search.waitForExistence(timeout: 5) && search.isHittable) {
            list.swipeDown()
            search = threema.searchFields.firstMatch
        }
        guard search.waitForExistence(timeout: 10) else {
            attachScreenshot("\(tag)-nosearch")
            attachTree("\(tag)-tree")
            return "no search field"
        }
        Driver.focus(search)
        if !row(directoryTitle).waitForExistence(timeout: 10) {
            nudge(search)
        }
        guard row(directoryTitle).waitForExistence(timeout: 10) else {
            attachScreenshot("\(tag)-no-directory")
            attachTree("\(tag)-tree")
            return "no \"\(directoryTitle)\" token offered"
        }
        attachScreenshot("\(tag)-tokens")
        switch choose(directoryTitle, in: search, timeout: 45, until: { self.row(category).exists }) {
        case .done:
            break
        case .twice:
            attachScreenshot("\(tag)-twice")
            attachTree("\(tag)-tree")
            return "two \"\(directoryTitle)\" tokens in the search field"
        case .timeout:
            attachScreenshot("\(tag)-no-category")
            attachTree("\(tag)-tree")
            return "no \"\(category)\" token after \"\(directoryTitle)\""
        }
        attachScreenshot("\(tag)-categories")
        guard choose(category, in: search, timeout: 30, until: { self.tokens(category, in: search) > 0 }) == .done else {
            attachScreenshot("\(tag)-no-token")
            attachTree("\(tag)-tree")
            return "the search field took no \"\(category)\" token"
        }
        if !gone(row(category), timeout: 30) {
            nudge(search)
            if !gone(row(category), timeout: 15) {
                attachText("\(tag)-still-offered", "\"\(category)\" still offered 45 s after its token")
            }
        }
        return nil
    }

    private enum Choice { case done, twice, timeout }

    private func choose(_ title: String, in search: XCUIElement, timeout: TimeInterval,
                        until done: () -> Bool) -> Choice {
        let deadline = Date().addingTimeInterval(timeout)
        var last = Date.distantPast
        while Date() < deadline {
            if done() {
                return .done
            }
            switch tokens(title, in: search) {
            case 0:
                let offered = row(title)
                if offered.exists && offered.isHittable {
                    offered.tap()
                    last = Date()
                }
            case 1:
                if Date().timeIntervalSince(last) >= 10 {
                    nudge(search)
                    last = Date()
                }
            default:
                return .twice
            }
            sleep(1)
        }
        return done() ? .done : .timeout
    }

    private func row(_ title: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", title)
        let cell = threema.cells.containing(predicate).firstMatch
        if cell.exists {
            return cell
        }
        return threema.tables.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func tokens(_ title: String, in search: XCUIElement) -> Int {
        search.descendants(matching: .other).matching(NSPredicate(format: "label == %@", title)).count
    }

    private func nudge(_ search: XCUIElement) {
        guard (search.value(forKey: "hasKeyboardFocus") as? Bool) ?? false else {
            return
        }
        search.typeText("C")
        search.typeText(XCUIKeyboardKey.delete.rawValue)
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            usleep(500_000)
        }
        return !element.exists
    }

    private var closeButton: XCUIElement? {
        threema.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Cancel", "Close"))
            .allElementsBoundByIndex.first { $0.isHittable }
    }

    private func cancelSearch() {
        if let cancel = closeButton {
            cancel.tap()
        } else {
            let clear = threema.searchFields.firstMatch.buttons.firstMatch
            if clear.exists {
                clear.tap()
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while closeButton != nil && Date() < deadline {
            usleep(500_000)
        }
        sleep(2)
    }
}

