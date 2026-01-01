import XCTest

final class OnboardingTests: XCTestCase {
    private var threema: XCUIApplication { XCUIApplication(bundleIdentifier: "ch.threema.onprem.iapp") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var alertCount = 0
    private var skippedSetup = false
    private var lastAppAlert: String?

    private let stepBudget = 40
    private let stepsPerRecovery = 10
    private let maxRecoveries = 3

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
            if skippedSetup || seed.waitForExistence(timeout: 20) || !(setup.exists && Driver.hittable(setup)) {
                break
            }
            snap(String(format: "m2-01-retry-%d", attempt))
            attachTree(String(format: "m2-01-retry-%d-tree", attempt))
            waitUntilEnabled(setup, timeout: 30)
        }

        if seed.waitForExistence(timeout: 30) {
            snap("m2-02-random-seed")
            if !(skippedSetup && waitUntilGone(seed, timeout: 15)) && seed.exists {
                drawSeed(seed)
            }
        } else {
            snap("m2-02-no-random-seed")
        }

        var steps = 0
        var inFront = 0
        var recoveries = 0
        var seedWaitedBefore = false
        var recoveryNotes: [String] = []
        var noneLeftNoted = false
        while inFront < 2 && steps < stepBudget + stepsPerRecovery * recoveries {
            steps += 1
            handleAlerts()
            if chatsVisible() {
                inFront += 1
                seedWaitedBefore = false
                sleep(3)
                continue
            }
            inFront = 0
            let seedWaits = seedWaiting(seed)
            if seedWaits && seedWaitedBefore {
                if recoveries < maxRecoveries {
                    recoveries += 1
                    let before = progressText()
                    snap(String(format: "m2-03-step-%02d-random-seed", steps))
                    let drags = drawSeed(seed)
                    let after = seed.exists ? "the page still there, its progress \(progressText())" : "the page gone"
                    recoveryNotes.append("step \(steps): recovery \(recoveries) of \(maxRecoveries): the random-seed page "
                        + "waited for a finger (progress \(before); the app's last alert: \(lastAppAlert ?? "none")); "
                        + "\(drags) drag(s), then \(after)")
                    seedWaitedBefore = false
                    continue
                }
                if !noneLeftNoted {
                    noneLeftNoted = true
                    snap(String(format: "m2-03-step-%02d-random-seed-again", steps))
                    recoveryNotes.append("step \(steps): the random-seed page waits for a finger again, "
                        + "and all \(maxRecoveries) recoveries are used")
                }
            }
            seedWaitedBefore = seedWaits
            if case let (button, title)? = progressButton() {
                snap(String(format: "m2-03-step-%02d-%@", steps, title.replacingOccurrences(of: " ", with: "-")))
                button.tap()
            } else {
                _ = threema.tabBars.firstMatch.waitForExistence(timeout: 3)
            }
        }
        if recoveryNotes.isEmpty {
            recoveryNotes.append("no recovery: the random-seed page did not wait for a finger in the step loop")
        }
        recoveryNotes.append("\(steps) step(s) of a budget of \(stepBudget + stepsPerRecovery * recoveries), "
            + "\(recoveries) of at most \(maxRecoveries) recoveries")
        attachText("m2-recoveries", recoveryNotes.joined(separator: "\n"))

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
            if button.exists && Driver.hittable(button) {
                return (button, title)
            }
        }
        return nil
    }

    private func chatsVisible() -> Bool {
        let bar = threema.tabBars.firstMatch
        return bar.exists && Driver.hittable(bar) && progressButton() == nil
    }

    @discardableResult
    private func drawSeed(_ seed: XCUIElement) -> Int {
        guard let frame = (try? seed.snapshot())?.frame, !frame.isEmpty else {
            return 0
        }
        let origin = threema.coordinate(withNormalizedOffset: .zero)
        var drags = 0
        while drags < 60 && seed.exists && !threema.alerts.firstMatch.exists && (seedProgress() ?? 0) < 100 {
            let y = 0.15 + Double(drags % 5) * 0.15
            let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.1,
                                                   dy: frame.minY + frame.height * y))
            let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.9,
                                                 dy: frame.minY + frame.height * (1.0 - y)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            drags += 1
        }
        return drags
    }

    private func seedWaiting(_ seed: XCUIElement) -> Bool {
        guard seed.exists, !threema.alerts.firstMatch.exists, Driver.hittable(seed) else {
            return false
        }
        return (seedProgress() ?? 0) < 100
    }

    private func seedProgress() -> Int? {
        guard let bar = try? threema.progressIndicators.firstMatch.snapshot() else {
            return nil
        }
        if let text = bar.value as? String {
            return Int(text.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber }))
        }
        if let number = bar.value as? NSNumber {
            let value = number.doubleValue
            return Int((value <= 1 ? value * 100 : value).rounded())
        }
        return nil
    }

    private func progressText() -> String {
        seedProgress().map { "\($0)%" } ?? "unknown"
    }

    private func control(id: String, label: String) -> XCUIElement {
        threema.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label))
            .firstMatch
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        _ = MK.waitUntil(timeout) { ((try? element.snapshot())?.isEnabled ?? false) && Driver.hittable(element) }
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
                lastAppAlert = text
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

