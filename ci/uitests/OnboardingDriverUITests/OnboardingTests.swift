import XCTest

final class OnboardingTests: XCTestCase {
    private var threema: XCUIApplication { XCUIApplication(bundleIdentifier: "ch.threema.onprem.iapp") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var alertCount = 0
    private var skippedSetup = false

    func testCreateIDAndReachTheChats() {
        continueAfterFailure = false
        threema.activate()
        snap("m2-01-splash")
        handleAlerts()

        let setup = control(id: "SplashViewControllerSetupButton", label: "Start setup")
        XCTAssertTrue(setup.waitForExistence(timeout: 90), "no Start setup button")
        waitUntilEnabled(setup, timeout: 60)

        let seed = threema.descendants(matching: .any)["randomDataView"]

        for attempt in 1...3 {
            setup.tap()
            handleAlerts()
            if skippedSetup || seed.waitForExistence(timeout: 20) || !(setup.exists && setup.isHittable) {
                break
            }
            snap(String(format: "m2-01-retry-%d", attempt))
            attachTree(String(format: "m2-01-retry-%d-tree", attempt))
            waitUntilEnabled(setup, timeout: 30)
        }

        if seed.waitForExistence(timeout: 30) {
            snap("m2-02-random-seed")
            if !(skippedSetup && waitUntilGone(seed, timeout: 15)) && seed.exists {
                let frame = seed.frame
                let origin = threema.coordinate(withNormalizedOffset: .zero)
                var drags = 0
                while seed.exists && drags < 60 {
                    let y = 0.15 + Double(drags % 5) * 0.15
                    let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.1,
                                                           dy: frame.minY + frame.height * y))
                    let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.9,
                                                         dy: frame.minY + frame.height * (1.0 - y)))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
                    drags += 1
                }
            }
        } else {
            snap("m2-02-no-random-seed")
        }

        var steps = 0
        var inFront = 0
        while inFront < 2 && steps < 40 {
            steps += 1
            handleAlerts()
            if chatsVisible() {
                inFront += 1
                sleep(3)
                continue
            }
            inFront = 0
            if case let (button, title)? = progressButton() {
                snap(String(format: "m2-03-step-%02d-%@", steps, title.replacingOccurrences(of: " ", with: "-")))
                button.tap()
            } else {
                _ = threema.tabBars.firstMatch.waitForExistence(timeout: 3)
            }
        }

        XCTAssertTrue(chatsVisible(), "the chat list is not in front after \(steps) onboarding steps")
        handleAlerts()
        snap("m2-04-chats")
    }


    private let progressTitles = ["SetupFinishButton", "Finish", "Continue", "Next", "Done", "Skip",
                                  "Not Now", "Not now", "Later", "OK", "Start"]

    private func progressButton() -> (XCUIElement, String)? {
        for title in progressTitles {
            let button = threema.buttons.matching(
                NSPredicate(format: "identifier == %@ OR label == %@", title, title)).firstMatch
            if button.exists && button.isHittable {
                return (button, title)
            }
        }
        return nil
    }

    private func chatsVisible() -> Bool {
        let bar = threema.tabBars.firstMatch
        return bar.exists && bar.isHittable && progressButton() == nil
    }

    private func control(id: String, label: String) -> XCUIElement {
        threema.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label))
            .firstMatch
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let ready = expectation(for: NSPredicate(format: "enabled == true AND hittable == true"),
                                evaluatedWith: element)
        _ = XCTWaiter.wait(for: [ready], timeout: timeout)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func handleAlerts() {
        for _ in 0..<4 {
            let system = springboard.alerts.firstMatch
            if system.waitForExistence(timeout: 2) {
                alertCount += 1
                snap(String(format: "m2-alert-%02d-system", alertCount))
                tapFirst(of: ["Allow", "Allow While Using App", "Allow Full Access", "OK", "Continue"], in: system)
                continue
            }
            let own = threema.alerts.firstMatch
            if own.exists {
                alertCount += 1
                snap(String(format: "m2-alert-%02d-app", alertCount))
                let text = own.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                let note = XCTAttachment(string: text)
                note.name = String(format: "m2-alert-%02d-app-text", alertCount)
                note.lifetime = .keepAlways
                add(note)
                let yes = own.buttons["Yes"]
                if yes.exists {
                    if text.contains("Skip setup") { skippedSetup = true }
                    yes.tap()
                } else if own.buttons.firstMatch.exists {
                    own.buttons.firstMatch.tap()
                }
                continue
            }
            return
        }
    }

    private func tapFirst(of titles: [String], in alert: XCUIElement) {
        for title in titles where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return
        }
        let first = alert.buttons.firstMatch
        if first.exists { first.tap() }
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

