import XCTest

enum Driver {
    static var threema: XCUIApplication { XCUIApplication(bundleIdentifier: "ch.threema.onprem.iapp") }
    static var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    static var composeButton: XCUIElement {
        threema.navigationBars.buttons.matching(NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label CONTAINS[c] %@", "New message", "compose")).firstMatch
    }

    static func openChatList() {
        for _ in 0..<6 {
            if composeButton.exists && composeButton.isHittable {
                return
            }
            let chats = threema.buttons["Chats"]
            let back = threema.navigationBars.buttons["BackButton"]
            let backByLabel = threema.navigationBars.buttons.matching(
                NSPredicate(format: "label ENDSWITH %@ OR label == %@", "unread", "Back")).firstMatch
            if chats.exists && chats.isHittable {
                chats.tap()
            } else if back.exists && back.isHittable {
                back.tap()
            } else if backByLabel.exists && backByLabel.isHittable {
                backByLabel.tap()
            } else {
                threema.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4))
                    .press(forDuration: 0.05, thenDragTo: threema.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
            }
            sleep(2)
        }
    }

    static func cell(containing texts: [String], timeout: TimeInterval) -> XCUIElement? {
        let parts = texts.map { NSPredicate(format: "label CONTAINS %@", $0) }
        let byLabel = threema.cells.matching(NSCompoundPredicate(andPredicateWithSubpredicates: parts)).firstMatch
        var query = threema.cells
        for part in parts {
            query = query.containing(part)
        }
        let byChildren = query.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if byLabel.exists {
                return byLabel
            }
            if byChildren.exists {
                return byChildren
            }
            sleep(2)
        } while Date() < deadline
        return nil
    }

    static func inChat(timeout: TimeInterval) -> Bool {
        let placeholder = threema.textViews.containing(NSPredicate(format: "label == %@", "New Message")).firstMatch
        let back = threema.navigationBars.buttons["BackButton"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if placeholder.exists || back.exists {
                return true
            }
            usleep(500_000)
        } while Date() < deadline
        return false
    }

    @discardableResult
    static func open(_ cell: XCUIElement, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if cell.exists && cell.isHittable {
                cell.tap()
            }
            if inChat(timeout: 10) {
                return true
            }
        }
        return inChat(timeout: 1)
    }

    @discardableResult
    static func selectTab(_ name: String) -> Bool {
        let tab = threema.tabBars.buttons[name]
        guard tab.waitForExistence(timeout: 15) else {
            return false
        }
        for _ in 0..<3 where !tab.isSelected {
            if tab.isHittable {
                tab.tap()
            }
            let deadline = Date().addingTimeInterval(5)
            while !tab.isSelected && Date() < deadline {
                usleep(300_000)
            }
        }
        return tab.isSelected
    }

    @discardableResult
    static func focus(_ element: XCUIElement) -> Bool {
        func focused() -> Bool { (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        for _ in 0..<3 where !focused() {
            if element.exists && element.isHittable {
                element.tap()
            }
            let deadline = Date().addingTimeInterval(3)
            while !focused() && Date() < deadline {
                usleep(200_000)
            }
        }
        return focused()
    }

    static func shows(_ text: String, timeout: TimeInterval) -> Bool {
        threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    static func message(containing text: String) -> XCUIElement {
        threema.tables.children(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    static func composer() -> XCUIElement? {
        let placeholder = threema.textViews.containing(NSPredicate(format: "label == %@", "New Message")).firstMatch
        if placeholder.waitForExistence(timeout: 10) {
            return placeholder
        }
        return threema.textViews.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .max { $0.frame.maxY < $1.frame.maxY }
    }

    static func send(_ text: String) -> Bool {
        guard let composer = composer() else {
            return false
        }
        focus(composer)
        composer.typeText(text)
        let send = threema.buttons["Send Message"]
        guard send.waitForExistence(timeout: 10) else {
            return false
        }
        send.tap()
        return threema.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 30)
    }
}

extension XCTestCase {
    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachText(_ name: String, _ text: String) {
        let note = XCTAttachment(string: text)
        note.name = name
        note.lifetime = .keepAlways
        add(note)
    }

    func handleAlerts(prefix: String) {
        for _ in 0..<4 {
            let system = Driver.springboard.alerts.firstMatch
            if system.waitForExistence(timeout: 1) {
                attachScreenshot("\(prefix)-alert-system")
                var tapped = false
                for title in ["Allow", "Allow While Using App", "Allow Full Access", "OK", "Continue"]
                    where system.buttons[title].exists {
                    system.buttons[title].tap()
                    tapped = true
                    break
                }
                if !tapped && system.buttons.firstMatch.exists {
                    system.buttons.firstMatch.tap()
                }
                continue
            }
            let own = Driver.threema.alerts.firstMatch
            if own.exists {
                attachScreenshot("\(prefix)-alert-app")
                attachText("\(prefix)-alert-app-text",
                           own.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
                if own.buttons.firstMatch.exists {
                    own.buttons.firstMatch.tap()
                }
                continue
            }
            return
        }
    }

    func attachTree(_ name: String) {
        attachText(name, Driver.threema.debugDescription)
    }
}

