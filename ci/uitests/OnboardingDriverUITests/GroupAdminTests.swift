import XCTest

final class GroupAdminTests: XCTestCase {
    private var app: XCUIApplication { Driver.threema }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
        Quiescence.ignoreAnimations()
        app.activate()
        handleAlerts(prefix: "m28")
        LaunchModals.clear(app, settle: 3) { attachScreenshot("m28-00-modal-\($0)") }
        attachText("m28-00-quiescence", Quiescence.note)
    }

    func testCreateGroup() throws {
        let name = try XCTUnwrap(env["M28_GROUP"])
        let text = try XCTUnwrap(env["M28_TEXT"])
        let memberText = env["M28_MEMBER_TEXT"] ?? "CI Member"

        Driver.openChatList()
        let memberChat = Driver.cell(containing: [memberText], timeout: 120)
        attachScreenshot("m28-01-list")
        XCTAssertNotNil(memberChat, "no chat with CI Member's text: it is no contact of the app yet")

        let addMembers = app.navigationBars["Add Members"]
        let newGroup = app.staticTexts["New Group"]
        XCTAssertTrue(MK.tapFound({ Driver.composeButton.exists && Driver.hittable(Driver.composeButton) ? Driver.composeButton : nil },
                                  until: { newGroup.exists }, attempts: 3, wait: 6), "no \"New Group\" row")
        XCTAssertTrue(MK.tap(newGroup, until: { addMembers.exists }), "no \"Add Members\" list")
        dismissGroupsTip()
        for member in ["CI CLI", "CI Member"] {
            XCTAssertTrue(selectMember(member, tag: "m28-02"), "\"\(member)\" cannot be selected")
        }
        attachScreenshot("m28-02-members")

        let field = groupNameField
        XCTAssertTrue(MK.tapFound({ MK.barButton(["Next"], bar: "Add Members") ?? MK.barButton(["Next"]) },
                                  until: { field.exists }), "no Create screen after Next")
        Driver.focus(field)
        field.typeText(name)
        attachScreenshot("m28-03-create")
        let created = MK.tapFound({ MK.barButton(["Done", "Create", "Save"]) },
                                  until: { !field.exists && Driver.inChat(timeout: 1) }, attempts: 4, wait: 8)
        handleAlerts(prefix: "m28")
        XCTAssertTrue(created, "the group chat does not open after Done")
        XCTAssertTrue(Driver.send(text), "the text does not appear in the new group")
        attachScreenshot("m28-04-written")
    }

    func testRename() throws {
        let name = try XCTUnwrap(env["M28_GROUP"])
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(openEditGroup(name, tag: "m28-05"), "no Edit Group")
        let field = groupNameField
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no group name field")
        let replaced = MK.replaceText(field, with: renamed)
        attachScreenshot("m28-06-renaming")
        attachText("m28-06-field", "the field holds: \(String(describing: field.value))")
        XCTAssertTrue(replaced, "the name field does not hold \"\(renamed)\"")
        XCTAssertTrue(mkSave(bar: "Edit Group", tag: "m28-06"), "Edit Group does not close")
        XCTAssertTrue(mkSeeInChat([renamed], ["Group renamed to", renamed], tag: "m28-07"),
                      "the chat does not say it was renamed to \"\(renamed)\"")
    }

    func testGroupPicture() throws {
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(openEditGroup(renamed, tag: "m28-08"), "no Edit Group")
        XCTAssertTrue(EditPicture.element.waitForExistence(timeout: 10), "no \"Edit picture\" on Edit Group")
        attachScreenshot("m28-08-edit")
        attachTree("m28-08-tree")
        XCTAssertTrue(mkOpenPicker(tag: "m28-09"), "the photo picker does not open from \"Edit picture\"")
        XCTAssertTrue(mkPickNewestPhoto(tag: "m28-10"), "no photo picked and cropped")
        sleep(1)
        attachScreenshot("m28-11-picked")
        XCTAssertTrue(mkSave(bar: "Edit Group", tag: "m28-11"), "Edit Group does not close")
        XCTAssertTrue(mkSeeInChat([renamed], ["Group picture changed"], tag: "m28-12"),
                      "the chat does not say the group picture changed")
    }

    func testRemoveMember() throws {
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(openEditGroup(renamed, tag: "m28-13"), "no Edit Group")
        let member = memberCell("CI Member")
        XCTAssertTrue(member.waitForExistence(timeout: 10), "no \"CI Member\" among the members")
        attachScreenshot("m28-13-edit")
        attachText("m28-13-member", "\(member.label): \(member.frame)")
        let frame = member.frame
        let points: [CGPoint] = [CGPoint(x: frame.maxX - 5, y: frame.minY + 13), CGPoint(x: frame.maxX - 10, y: frame.minY + 9),
                                 CGPoint(x: frame.maxX - 1, y: frame.minY + 17), CGPoint(x: frame.maxX - 13, y: frame.minY + 17)]
        var tapped: [String] = []
        for point in points where member.exists {
            MK.tap(at: point)
            tapped.append("\(Int(point.x)),\(Int(point.y))")
            _ = MK.waitUntil(3) { !member.exists }
        }
        attachScreenshot("m28-14-removed")
        attachText("m28-14-taps", "tapped at \(tapped.joined(separator: "; ")); CI Member still there: \(member.exists)")
        XCTAssertFalse(member.exists, "CI Member's cell is still in Edit Group")
        XCTAssertTrue(mkSave(bar: "Edit Group", tag: "m28-14"), "Edit Group does not close")
        XCTAssertTrue(mkSeeInChat([renamed], ["Member", "was removed from the group"], tag: "m28-15"),
                      "the chat does not say CI Member was removed")
    }

    func testAddMember() throws {
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(openEditGroup(renamed, tag: "m28-16"), "no Edit Group")
        let list = app.navigationBars["Add Members"]
        let add = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Add Contact")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no \"Add Contact\" in Edit Group")
        XCTAssertTrue(MK.tap(add, until: { list.exists }), "\"Add Contact\" opens no contact list")
        dismissGroupsTip()
        XCTAssertTrue(selectMember("CI Member", tag: "m28-16"), "CI Member cannot be selected")
        attachScreenshot("m28-16-selected")
        XCTAssertTrue(MK.tapFound({ MK.barButton(["Next", "Done"], bar: "Add Members") }, until: { !list.exists }),
                      "the contact list does not close")
        XCTAssertTrue(memberCell("CI Member").waitForExistence(timeout: 10), "CI Member is not among the members")
        attachScreenshot("m28-17-added")
        XCTAssertTrue(mkSave(bar: "Edit Group", tag: "m28-17"), "Edit Group does not close")
        XCTAssertTrue(mkSeeInChat([renamed], ["Member", "was added to the group"], tag: "m28-18"),
                      "the chat does not say CI Member was added")
    }

    func testMemberLeft() throws {
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(mkSeeInChat([renamed], ["Member", "left the group"], tag: "m28-19", timeout: 90),
                      "the chat does not say CI Member left the group")
        if mkOpenDetails(renamed, tag: "m28-20", until: { mkGroupDetailsShown }) {
            sleep(1)
            attachScreenshot("m28-20-details")
            let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Members (")).firstMatch
            attachText("m28-20-members", header.exists ? header.label : "no \"Members (n)\" header")
        }
    }

    func testSynchronize() throws {
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(mkOpenChat([renamed], tag: "m28-21"), "the group chat does not open")
        XCTAssertTrue(mkOpenDetails(renamed, tag: "m28-21", until: { mkGroupDetailsShown }), "no group details")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Synchronize Group")).firstMatch
        for _ in 0..<6 where !(row.exists && Driver.hittable(row)) {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(row.exists, "no \"Synchronize Group\" row")
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Group Synced")).firstMatch
        MK.tap(row, until: { toast.exists }, attempts: 2, wait: 10)
        attachScreenshot("m28-21-synced")
        attachText("m28-21-toast", "toast seen: \(toast.exists)")
    }

    func testDissolve() throws {
        let renamed = try XCTUnwrap(env["M28_RENAMED"])
        XCTAssertTrue(mkOpenChat([renamed], tag: "m28-22"), "the group chat does not open")
        XCTAssertTrue(mkOpenDetails(renamed, tag: "m28-22", until: { mkGroupDetailsShown }), "no group details")
        XCTAssertTrue(mkGroupAction("Dissolve Group", sheet: "Dissolve \u{201C}", tag: "m28-22"),
                      "the group is not dissolved (its row, or its sheet's \"Dissolve Group\")")
        XCTAssertTrue(mkSeeInChat([renamed], ["You have left the group"], tag: "m28-23"),
                      "the chat does not say \"You have left the group.\"")
    }


    private var groupNameField: XCUIElement {
        let byPlaceholder = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Group Name")).firstMatch
        return byPlaceholder.exists ? byPlaceholder : app.textFields.firstMatch
    }

    private func memberCell(_ name: String) -> XCUIElement {
        app.collectionViews.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func openEditGroup(_ name: String, tag: String) -> Bool {
        guard mkOpenChat([name], tag: tag) else {
            return false
        }
        guard mkOpenDetails(name, tag: tag, until: { mkGroupDetailsShown || MK.barButton(["Edit"]) != nil }) else {
            return false
        }
        return mkOpenEditGroup(tag: tag)
    }

    private func dismissGroupsTip(wait: TimeInterval = 3) {
        let tip = app.otherElements["TipView"]
        let close = tip.buttons["Close"]
        let dismiss = app.otherElements["PopoverDismissRegion"]
        _ = MK.waitUntil(wait) { tip.exists || dismiss.exists }
        for _ in 0..<3 where tip.exists || dismiss.exists {
            if close.exists && Driver.hittable(close) {
                close.tap()
            } else if dismiss.exists {
                dismiss.tap()
            } else if app.buttons["Close"].exists && Driver.hittable(app.buttons["Close"]) {
                app.buttons["Close"].tap()
            }
            _ = MK.waitUntil(3) { !tip.exists && !dismiss.exists }
        }
    }

    private func selectMember(_ name: String, tag: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", name)
        func count() -> Int {
            max(app.cells.matching(predicate).count, app.cells.containing(predicate).count)
        }
        func row() -> XCUIElement {
            let byLabel = app.tables.cells.matching(predicate).firstMatch
            if byLabel.exists {
                return byLabel
            }
            let byChild = app.tables.cells.containing(predicate).firstMatch
            return byChild.exists ? byChild : app.cells.containing(predicate).firstMatch
        }
        if !row().waitForExistence(timeout: 15) {
            let search = app.searchFields.firstMatch
            if search.exists {
                Driver.focus(search)
                search.typeText(name)
                sleep(2)
            }
        }
        guard row().waitForExistence(timeout: 10) else {
            attachScreenshot("\(tag)-no-\(name.replacingOccurrences(of: " ", with: "-"))")
            attachTree("\(tag)-tree")
            return false
        }
        let before = count()
        func selected() -> Bool { row().isSelected || count() > before }
        if selected() {
            return true
        }
        for _ in 0..<3 where !selected() {
            dismissGroupsTip(wait: 0)
            let target = row()
            if target.exists {
                if Driver.hittable(target) {
                    target.tap()
                } else {
                    MK.tapCentre(target)
                }
            }
            _ = MK.waitUntil(4, selected)
        }
        if !selected() {
            attachScreenshot("\(tag)-not-selected")
            attachTree("\(tag)-tree")
        }
        return selected()
    }
}

