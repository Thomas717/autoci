import XCTest

enum LaunchModals {
    static let buttons = ["Continue", "Do Not Remind Me Again"]

    @discardableResult
    static func clear(_ app: XCUIApplication, settle: TimeInterval, snap: (String) -> Void) -> [String] {
        let any = app.buttons.matching(NSPredicate(format: "label IN %@", buttons)).firstMatch
        _ = any.waitForExistence(timeout: settle)
        var tapped: [String] = []
        for _ in 0..<6 {
            var hit = false
            for title in buttons {
                let button = app.buttons[title]
                guard button.exists else { continue }
                if !Driver.hittable(button) {
                    app.swipeUp()
                }
                if Driver.hittable(button) {
                    snap(title.replacingOccurrences(of: " ", with: "-"))
                    button.tap()
                    tapped.append(title)
                    hit = true
                    break
                }
            }
            if !hit {
                break
            }
            sleep(1)
        }
        return tapped
    }

    static let maxReveals = 8

    static func reveal(_ app: XCUIApplication, count: inout Int) -> Bool {
        guard count < maxReveals else { return false }
        let button = app.buttons.matching(NSPredicate(format: "label == %@", "Continue")).firstMatch
        guard button.exists, !Driver.hittable(button),
              !app.alerts.firstMatch.exists, !Driver.springboard.alerts.firstMatch.exists else {
            return false
        }
        app.swipeUp()
        count += 1
        return true
    }
}

