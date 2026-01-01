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
                if !button.isHittable {
                    app.swipeUp()
                }
                if button.isHittable {
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
}

