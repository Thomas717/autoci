import XCTest

final class WorkContactsTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m7")
        LaunchModals.clear(threema, settle: 5) { attachScreenshot("m7-00-modal-\($0)") }
    }

    private func openContacts() {
        if !Driver.selectTab("Contacts") {
            Driver.openChatList()
            Driver.selectTab("Contacts")
        }
        sleep(2)
    }

    private var list: XCUIElement {
        threema.tables.firstMatch.exists ? threema.tables.firstMatch : threema.collectionViews.firstMatch
    }

    func testWorkSync() throws {
        let cliID = try XCTUnwrap(ProcessInfo.processInfo.environment["M7_CLI_ID"])
        openContacts()
        attachScreenshot("m7-01-contacts")
        guard let cell = Driver.cell(containing: ["CI CLI"], timeout: 30) else {
            attachTree("m7-01-tree")
            XCTFail("the Contacts tab does not list the CLI")
            return
        }
        attachText("m7-01-cli", "label: \(cell.label)\nvalue: \(String(describing: cell.value))")
        let start = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 8.0))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(2)
        attachScreenshot("m7-02-refreshing")
        sleep(6)
        XCUIDevice.shared.press(.home)
        sleep(3)
        threema.activate()
        sleep(8)
        handleAlerts(prefix: "m7")
        attachScreenshot("m7-03-refreshed")
        XCTAssertNotNil(Driver.cell(containing: ["CI CLI"], timeout: 10), "the CLI is gone after the refresh")
        _ = cliID
    }

    func testDirectorySearch() throws {
        let env = ProcessInfo.processInfo.environment
        let query = try XCTUnwrap(env["M7_QUERY"])
        let dirID = try XCTUnwrap(env["M7_DIR_ID"])
        openContacts()
        var search = threema.searchFields.firstMatch
        if !(search.waitForExistence(timeout: 5) && search.isHittable) {
            list.swipeDown()
            search = threema.searchFields.firstMatch
        }
        guard search.waitForExistence(timeout: 10) else {
            attachScreenshot("m7-04-nosearch")
            attachTree("m7-04-tree")
            XCTFail("no search field on the Contacts tab")
            return
        }
        Driver.focus(search)
        search.typeText(query)
        let scope = threema.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Company Directory")).firstMatch
        if scope.waitForExistence(timeout: 10) && scope.isHittable {
            attachScreenshot("m7-04-scopes")
            scope.tap()
            let field = threema.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                Driver.focus(field)
                if !((field.value as? String) ?? "").contains(query) {
                    field.typeText(query)
                }
                if Driver.cell(containing: ["CI Colleague"], timeout: 10) == nil {
                    field.typeText("\n")
                }
            }
        }
        guard let hit = Driver.cell(containing: ["CI Colleague"], timeout: 30) else {
            attachScreenshot("m7-05-search")
            attachTree("m7-05-tree")
            XCTFail("the directory search does not find \"CI Colleague\"")
            return
        }
        attachScreenshot("m7-05-search")
        attachText("m7-05-hit", "label: \(hit.label)\nvalue: \(String(describing: hit.value))")
        hit.tap()
        sleep(2)
        handleAlerts(prefix: "m7")
        attachScreenshot("m7-06-colleague")
        XCTAssertTrue(Driver.shows(dirID, timeout: 15), "the colleague's details do not show \(dirID)")
    }

    func testAvailability() throws {
        let status = try XCTUnwrap(ProcessInfo.processInfo.environment["M7_STATUS"])
        Driver.openChatList()
        let found = Driver.cell(containing: ["CI CLI", "Status: \(status)"], timeout: 30)
        attachScreenshot("m7-07-status")
        if let cell = Driver.cell(containing: ["CI CLI"], timeout: 5) {
            attachText("m7-07-cli", "label: \(cell.label)\nvalue: \(String(describing: cell.value))")
        }
        XCTAssertNotNil(found, "the CLI's chat does not say \"Status: \(status)\"")
    }
}

