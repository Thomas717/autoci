import ObjectiveC
import XCTest

enum Quiescence {
    private(set) static var note = "not installed"

    static func ignoreAnimations() {
        guard note == "not installed" else {
            return
        }
        guard let process = NSClassFromString("XCUIApplicationProcess") else {
            note = "no XCUIApplicationProcess"
            return
        }
        var done: [String] = []
        let twoArgs = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        if let method = class_getInstanceMethod(process, twoArgs) {
            let found = shape(method)
            if ["v@:BB", "v@:cc"].contains(found) {
                typealias Original = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
                let replacement: @convention(block) (AnyObject, Bool, Bool) -> Void = { this, _, preEvent in
                    original(this, twoArgs, false, preEvent)
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
                done.append("isPreEvent: \(found)")
            } else {
                done.append("isPreEvent: \(found), left")
            }
        }
        let threeArgs = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:")
        if let method = class_getInstanceMethod(process, threeArgs) {
            let found = shape(method)
            if ["v@:BBB", "v@:ccc"].contains(found) {
                typealias Original = @convention(c) (AnyObject, Selector, Bool, Bool, Bool) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
                let replacement: @convention(block) (AnyObject, Bool, Bool, Bool) -> Void = { this, _, activity, preEvent in
                    original(this, threeArgs, false, activity, preEvent)
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
                done.append("usingActivity:isPreEvent: \(found)")
            } else if ["v@:B@B", "v@:c@c"].contains(found) {
                typealias Original = @convention(c) (AnyObject, Selector, Bool, AnyObject?, Bool) -> Void
                let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
                let replacement: @convention(block) (AnyObject, Bool, AnyObject?, Bool) -> Void = { this, _, activity, preEvent in
                    original(this, threeArgs, false, activity, preEvent)
                }
                method_setImplementation(method, imp_implementationWithBlock(replacement))
                done.append("usingActivity:isPreEvent: \(found)")
            } else {
                done.append("usingActivity:isPreEvent: \(found), left")
            }
        }
        note = done.isEmpty ? "no waitForQuiescenceIncludingAnimationsIdle: at all" : done.joined(separator: "; ")
    }

    private static func shape(_ method: Method) -> String {
        guard let encoding = method_getTypeEncoding(method) else {
            return "?"
        }
        return String(cString: encoding).filter { !$0.isNumber }
    }
}

enum MK {
    static var app: XCUIApplication { Driver.threema }

    static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() {
                return true
            }
            usleep(300_000)
        } while Date() < deadline
        return condition()
    }

    static func hittable(_ element: XCUIElement) -> Bool {
        Driver.hittable(element)
    }

    static func tap(at point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    static func tapCentre(_ element: XCUIElement) {
        tap(middleOf: element.frame)
    }

    static func tap(middleOf frame: CGRect) {
        tap(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    @discardableResult
    static func tap(_ element: XCUIElement, until effect: () -> Bool, attempts: Int = 4,
                    wait seconds: TimeInterval = 6) -> Bool {
        for _ in 0..<attempts where !effect() {
            if element.exists {
                if MK.hittable(element) {
                    element.tap()
                } else {
                    tapCentre(element)
                }
            }
            _ = waitUntil(seconds, effect)
        }
        return effect()
    }

    @discardableResult
    static func tapFound(_ find: () -> XCUIElement?, until effect: () -> Bool, attempts: Int = 4,
                         wait seconds: TimeInterval = 6) -> Bool {
        for _ in 0..<attempts where !effect() {
            if let element = find() {
                element.tap()
            }
            _ = waitUntil(seconds, effect)
        }
        return effect()
    }

    @discardableResult
    static func tapFrame(_ find: () -> CGRect?, until effect: () -> Bool, attempts: Int = 4,
                         wait seconds: TimeInterval = 6) -> Bool {
        for _ in 0..<attempts where !effect() {
            if let frame = find() {
                tap(middleOf: frame)
            }
            _ = waitUntil(seconds, effect)
        }
        return effect()
    }

    static func enabledFrame(_ labels: [String], in tree: [any XCUIElementSnapshot]) -> CGRect? {
        guard let screen = tree.first?.frame else {
            return nil
        }
        let found = tree.filter { labels.contains($0.label) && $0.isEnabled && !$0.frame.isEmpty &&
            (screen.isEmpty || screen.intersects($0.frame)) }
        return (found.first { $0.elementType == .button } ?? found.first)?.frame
    }

    static func element(_ labels: [String], enabled: Bool = false) -> XCUIElement? {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels))
            .allElementsBoundByIndex.first { $0.exists && MK.hittable($0) && (!enabled || $0.isEnabled) }
    }

    static func barButton(_ labels: [String], bar: String? = nil, enabled: Bool = true) -> XCUIElement? {
        let bars = bar.map { app.navigationBars.matching(identifier: $0) } ?? app.navigationBars
        return bars.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex
            .first { $0.exists && MK.hittable($0) && (!enabled || $0.isEnabled) }
    }

    static func confirmButton(bar: String) -> XCUIElement? {
        let navigationBar = app.navigationBars.matching(identifier: bar).firstMatch
        guard navigationBar.exists else {
            return nil
        }
        let buttons = navigationBar.buttons.allElementsBoundByIndex.filter { $0.exists && MK.hittable($0) && $0.isEnabled }
        if let named = buttons.first(where: { ["Vote", "Done", "Confirm", "OK"].contains($0.label) }) {
            return named
        }
        let cancel = ["Cancel", "Close", "Back", "BackButton", "Discard"]
        let middle = navigationBar.frame.midX
        return buttons.filter { !cancel.contains($0.label) && !cancel.contains($0.identifier) && $0.frame.midX > middle }
            .max { $0.frame.midX < $1.frame.midX }
    }

    static func messageRow(_ texts: [String]) -> XCUIElement {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates:
            texts.map { NSPredicate(format: "label CONTAINS %@", $0) })
        let row = app.tables.children(matching: .any).matching(predicate).firstMatch
        return row.exists ? row : app.descendants(matching: .any).matching(predicate).firstMatch
    }

    static func pollSays(_ title: String, _ what: String, _ choice: String) -> Bool {
        messageRow(["Title: \(title)", "\(what) \u{201C}\(choice)\u{201D}"]).exists ||
            messageRow(["Title: \(title)", "\(what) \(choice)"]).exists
    }

    static func snapshotFrame(_ element: XCUIElement) -> CGRect? {
        guard let shot = try? element.snapshot(), !shot.frame.isEmpty else {
            return nil
        }
        return shot.frame
    }

    static func chatBand() -> (top: CGFloat, bottom: CGFloat) {
        let screen = app.frame
        let top = snapshotFrame(app.navigationBars.firstMatch)?.maxY ?? screen.minY + screen.height / 8
        let bottom = snapshotFrame(app.buttons["Add Attachments"])?.minY ?? screen.maxY - screen.height / 8
        return (top + 8, bottom - 8)
    }

    static func inChatBand(_ element: XCUIElement) -> Bool {
        guard let rect = snapshotFrame(element) else {
            return false
        }
        let band = chatBand()
        return rect.midY > band.top && rect.midY < band.bottom
    }

    static func dragChat(up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.6 : 0.35))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.6))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @discardableResult
    static func bringIntoView(_ find: () -> XCUIElement, drags: Int = 8, moves: inout [String]) -> Bool {
        for _ in 0..<drags {
            let element = find()
            if element.exists && MK.hittable(element) && inChatBand(element) {
                return true
            }
            let band = chatBand()
            let up = snapshotFrame(element).map { $0.midY > (band.top + band.bottom) / 2 } ?? true
            dragChat(up: up)
            moves.append(up ? "up" : "down")
            usleep(800_000)
        }
        let element = find()
        return element.exists && MK.hittable(element) && inChatBand(element)
    }

    static func replaceText(_ field: XCUIElement, with text: String) -> Bool {
        Driver.focus(field)
        let old = (field.value as? String) ?? ""
        let clear = field.buttons["Clear text"]
        if clear.exists && MK.hittable(clear) {
            clear.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 4))
        }
        if !old.isEmpty && ((field.value as? String) ?? "").contains(old) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 4))
        }
        field.typeText(text)
        return ((field.value as? String) ?? "") == text
    }
}

enum SystemPicker {
    static var assets: XCUIElementQuery { MK.app.images.matching(identifier: "PXGGridLayout-Info") }

    static var shows: Bool { assets.firstMatch.exists }

    static func images(in tree: [any XCUIElementSnapshot]) -> [any XCUIElementSnapshot] {
        tree.filter { $0.elementType == .image && $0.identifier == "PXGGridLayout-Info" }
    }

    static func shows(in tree: [any XCUIElementSnapshot]) -> Bool {
        !images(in: tree).isEmpty
    }

    static func sheet(in tree: [any XCUIElementSnapshot]) -> Bool {
        tree.contains { $0.identifier.hasPrefix("PXG") || sheetIdentifiers.contains($0.identifier) }
    }

    private static let sheetIdentifiers: Set<String> = [
        "photosView_content_scroll_view", "photos_layout", "PickerOnboardingHeaderViewIcon", "Sort and Filter",
    ]

    static func newest() -> (asset: XCUIElement, labels: [String])? {
        let all = assets.allElementsBoundByIndex.filter { $0.exists }
        guard !all.isEmpty else {
            return nil
        }
        let labels = all.map(\.label)
        var best: (index: Int, date: Date)?
        for (index, label) in labels.enumerated() {
            guard let found = date(of: label) else {
                continue
            }
            if best == nil || found > best!.date {
                best = (index, found)
            }
        }
        if let best {
            return (all[best.index], labels)
        }
        let year = try? NSRegularExpression(pattern: "\\b(19|20)[0-9]{2}\\b")
        if let index = labels.firstIndex(where: { label in
            year?.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) == nil
        }) {
            return (all[index], labels)
        }
        let first = all.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) } ?? all[0]
        return (first, labels)
    }

    static func date(of label: String) -> Date? {
        let text = label.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        var parts = text.components(separatedBy: ", ")
        if parts.first?.hasPrefix("Photo") == true {
            parts.removeFirst()
        }
        if parts.first == "Today" {
            parts.removeFirst()
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.defaultDate = Date()
        formatter.isLenient = false
        var formats: [String] = []
        for time in ["h:mm a", "HH:mm"] {
            for day in ["MMMM d", "MMMM d, yyyy", "MMM d", "MMM d, yyyy", "d MMMM", "d MMMM yyyy", "d MMM", "d MMM yyyy"] {
                formats.append("\(day), \(time)")
                formats.append("\(day) 'at' \(time)")
            }
            formats.append(time)
        }
        var count = parts.count
        while count > 0 {
            let candidate = parts[0..<count].joined(separator: ", ")
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
            count -= 1
        }
        return nil
    }
}

enum EditPicture {
    static var element: XCUIElement {
        MK.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Edit picture")).firstMatch
    }

    static func choosePoints() -> [CGPoint] {
        let frame = element.frame
        let offsets: [CGFloat] = [-42, -34, -50, -26]
        return offsets.map { CGPoint(x: frame.midX, y: frame.maxY + $0) }
    }

    static func deletePoints() -> [CGPoint] {
        let frame = element.frame
        let offsets: [(dx: CGFloat, dy: CGFloat)] = [(38, 14), (44, 10), (32, 20), (48, 20)]
        return offsets.map { CGPoint(x: frame.midX + $0.dx, y: frame.minY + $0.dy) }
    }
}

extension XCTestCase {
    func mkCloseDetails() {
        let close = MK.app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["GroupDetailsViewControllerDoneButton", "SingleDetailsViewControllerDoneButton"])).firstMatch
        MK.tap(close, until: { !close.exists }, attempts: 3, wait: 4)
    }

    @discardableResult
    func mkOpenChat(_ texts: [String], tag: String, timeout: TimeInterval = 60) -> Bool {
        mkCloseDetails()
        Driver.openChatList()
        guard let cell = Driver.cell(containing: texts, timeout: timeout) else {
            attachScreenshot("\(tag)-list")
            attachTree("\(tag)-tree")
            return false
        }
        let opened = Driver.open(cell)
        if !opened {
            attachScreenshot("\(tag)-not-open")
        }
        return opened
    }

    func mkSeeInChat(_ chat: [String], _ texts: [String], tag: String, timeout: TimeInterval = 60) -> Bool {
        guard mkOpenChat(chat, tag: tag) else {
            return false
        }
        let shown = MK.waitUntil(timeout) { MK.messageRow(texts).exists }
        sleep(1)
        attachScreenshot("\(tag)-chat")
        if shown {
            attachText("\(tag)-row", MK.messageRow(texts).label)
        } else {
            attachTree("\(tag)-tree")
        }
        return shown
    }

    var mkGroupDetailsShown: Bool {
        let app = MK.app
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Members (")).firstMatch.exists {
            return true
        }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@",
            ["Leave Group", "Dissolve Group", "Delete Group", "Synchronize Group", "Clone Group"])).firstMatch.exists
    }

    func mkOpenDetails(_ name: String, tag: String, until shown: () -> Bool) -> Bool {
        let app = MK.app
        let header = app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@", name, "ChatProfileViewViewButton")).firstMatch
        var how: [String] = []
        for _ in 0..<4 where !shown() {
            if header.exists && MK.hittable(header) {
                header.tap()
                how.append("header")
            } else if let bar = app.navigationBars.allElementsBoundByIndex.first(where: { $0.exists && MK.hittable($0) }) {
                MK.tapCentre(bar)
                how.append("bar")
            }
            _ = MK.waitUntil(6, shown)
        }
        if !shown() {
            attachScreenshot("\(tag)-no-details")
            attachTree("\(tag)-tree")
            attachText("\(tag)-taps", how.joined(separator: ", "))
        }
        return shown()
    }

    func mkOpenEditGroup(tag: String) -> Bool {
        let sheet = MK.app.navigationBars["Edit Group"]
        let shown = MK.tapFound({ MK.barButton(["Edit"]) }, until: { sheet.exists })
        if shown {
            sleep(1)
        } else {
            attachScreenshot("\(tag)-no-edit")
            attachTree("\(tag)-tree")
        }
        return shown
    }

    func mkSave(bar: String, tag: String) -> Bool {
        let sheet = MK.app.navigationBars[bar]
        let saved = MK.tapFound({ MK.barButton(["Done", "Save"], bar: bar) }, until: { !sheet.exists }, attempts: 4, wait: 8)
        handleAlerts(prefix: String(tag.prefix(3)))
        if !saved {
            attachScreenshot("\(tag)-not-saved")
            attachTree("\(tag)-tree")
        }
        return saved
    }

    func mkOpenPicker(tag: String) -> Bool {
        let picture = EditPicture.element
        guard picture.waitForExistence(timeout: 10) else {
            attachScreenshot("\(tag)-no-picture")
            attachTree("\(tag)-tree")
            return false
        }
        attachText("\(tag)-picture", "Edit picture: \(picture.frame)")
        var tapped: [String] = []
        for point in EditPicture.choosePoints() where !SystemPicker.shows {
            MK.tap(at: point)
            tapped.append("\(Int(point.x)),\(Int(point.y))")
            handleAlerts(prefix: String(tag.prefix(3)))
            _ = MK.waitUntil(10) { SystemPicker.shows }
        }
        attachText("\(tag)-taps", "tapped at \(tapped.joined(separator: "; ")); picker: \(SystemPicker.shows)")
        if !SystemPicker.shows {
            attachScreenshot("\(tag)-no-picker")
            attachTree("\(tag)-tree")
        }
        return SystemPicker.shows
    }

    func mkPickNewestPhoto(tag: String) -> Bool {
        _ = MK.waitUntil(10) { SystemPicker.shows }
        sleep(2)
        guard let found = SystemPicker.newest() else {
            attachScreenshot("\(tag)-no-assets")
            attachTree("\(tag)-tree")
            return false
        }
        let chosen = found.asset.label
        let chosenFrame = found.asset.frame
        let held = Driver.tree().map { "\(SystemPicker.images(in: $0).count) of the picker's images" } ?? "none taken"
        attachText("\(tag)-assets", "chose: \(chosen)\n" + found.labels.joined(separator: "\n") + "\none snapshot: \(held)")
        attachScreenshot("\(tag)-picker")
        let crop = { Driver.tree().flatMap { MK.enabledFrame(["Choose"], in: $0) } }
        var cropFrame = crop()
        var taps: [String] = []
        for attempt in 0..<3 where cropFrame == nil {
            var photo: CGRect? = chosenFrame
            if attempt > 0 {
                photo = Driver.tree().flatMap { tree in
                    SystemPicker.images(in: tree).first { $0.label == chosen }?.frame ??
                        (SystemPicker.shows(in: tree) ? chosenFrame : nil)
                }
            }
            if let photo {
                MK.tap(middleOf: photo)
                taps.append("\(Int(photo.midX)),\(Int(photo.midY))")
            } else {
                taps.append("none (no picker in a snapshot)")
            }
            _ = MK.waitUntil(10) {
                cropFrame = crop()
                return cropFrame != nil
            }
        }
        attachText("\(tag)-photo-taps", "\(taps.joined(separator: "; ")); Choose: \(cropFrame.map { "\($0)" } ?? "not found")")
        guard cropFrame != nil else {
            attachScreenshot("\(tag)-no-crop")
            attachTree("\(tag)-tree")
            return false
        }
        sleep(1)
        attachScreenshot("\(tag)-crop")
        let gone: () -> Bool = {
            guard let tree = Driver.tree() else {
                return false
            }
            return MK.enabledFrame(["Choose"], in: tree) == nil && !SystemPicker.shows(in: tree)
        }
        let done = MK.tapFrame(crop, until: gone, attempts: 4, wait: 6)
        if !done {
            attachScreenshot("\(tag)-crop-stays")
            attachTree("\(tag)-tree")
        }
        return done
    }

    func mkAttachment(_ option: String, tag: String, until effect: () -> Bool) -> Bool {
        let attach = MK.app.buttons["Add Attachments"]
        var shot = false
        for _ in 0..<3 where !effect() {
            if MK.element([option]) == nil && attach.waitForExistence(timeout: 5) {
                MK.tap(attach, until: { MK.element([option]) != nil }, attempts: 2, wait: 5)
            }
            if let item = MK.element([option]) {
                if !shot {
                    attachScreenshot("\(tag)-sheet")
                    shot = true
                }
                item.tap()
            }
            _ = MK.waitUntil(8, effect)
        }
        if !effect() {
            attachScreenshot("\(tag)-no-\(option.replacingOccurrences(of: " ", with: "-"))")
            attachTree("\(tag)-tree")
        }
        return effect()
    }

    func mkCreatePoll(title: String, choices: [String], tag: String) -> Bool {
        let app = MK.app
        let form = app.navigationBars["Create Poll"]
        guard mkAttachment("Create Poll", tag: tag, until: { form.exists }) else {
            return false
        }
        sleep(1)
        attachScreenshot("\(tag)-form")
        let placeholder = "Title, e.g. Where do you want to go today?"
        let byPlaceholder = NSPredicate(format: "placeholderValue == %@ OR label == %@ OR value == %@",
                                        placeholder, placeholder, placeholder)
        let inputs = (app.textViews.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
            .filter { $0.exists }.sorted { $0.frame.minY < $1.frame.minY }
        var titleField = app.textViews.matching(byPlaceholder).firstMatch
        if !titleField.exists {
            titleField = app.textFields.matching(byPlaceholder).firstMatch
        }
        if !titleField.exists, let top = inputs.first {
            titleField = top
        }
        guard titleField.exists else {
            attachTree("\(tag)-tree")
            return false
        }
        let titleFrame = titleField.frame
        Driver.focus(titleField)
        titleField.typeText(title)
        for (index, choice) in choices.enumerated() {
            var fields = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Choice"))
                .allElementsBoundByIndex.filter { $0.exists }.sorted { $0.frame.minY < $1.frame.minY }
            if fields.count <= index {
                fields = app.textFields.allElementsBoundByIndex
                    .filter { $0.exists && $0.frame != titleFrame && $0.frame.minY > titleFrame.minY }
                    .sorted { $0.frame.minY < $1.frame.minY }
            }
            guard index < fields.count else {
                attachScreenshot("\(tag)-no-choice")
                attachTree("\(tag)-tree")
                return false
            }
            Driver.focus(fields[index])
            fields[index].typeText(choice)
        }
        attachScreenshot("\(tag)-filled")
        let values = (app.textViews.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
            .filter { $0.exists }.map { "\($0.value ?? "")" }
        attachText("\(tag)-fields", values.joined(separator: " | "))
        let sent = MK.tapFound({ MK.barButton(["Send"], bar: "Create Poll") }, until: { !form.exists }, attempts: 4, wait: 8)
        if !sent {
            attachScreenshot("\(tag)-not-sent")
            attachTree("\(tag)-tree")
        }
        return sent
    }

    func mkOpenPoll(_ texts: [String], own: Bool, tag: String) -> Bool {
        let sheet = MK.app.navigationBars["Poll"]
        for _ in 0..<4 where !sheet.exists {
            let row = MK.messageRow(texts)
            if row.exists {
                row.coordinate(withNormalizedOffset: CGVector(dx: own ? 0.75 : 0.3, dy: 0.5)).tap()
            }
            _ = sheet.waitForExistence(timeout: 6)
        }
        if !sheet.exists {
            attachScreenshot("\(tag)-no-poll")
            attachTree("\(tag)-tree")
        }
        return sheet.exists
    }

    func mkClosePoll(_ texts: [String], tag: String) -> Bool {
        let app = MK.app
        guard mkOpenPoll(texts, own: true, tag: tag) else {
            return false
        }
        sleep(1)
        attachScreenshot("\(tag)-poll")
        let close = app.buttons.matching(NSPredicate(format: "label == %@", "Close Poll"))
        for _ in 0..<4 where !(close.firstMatch.exists && MK.hittable(close.firstMatch)) {
            app.swipeUp()
            sleep(1)
        }
        let alert = app.alerts.firstMatch
        let asked = MK.tapFound({ close.allElementsBoundByIndex.first { $0.exists && MK.hittable($0) } },
                                until: { alert.exists }, attempts: 3, wait: 6)
        guard asked else {
            attachScreenshot("\(tag)-no-alert")
            attachTree("\(tag)-tree")
            return false
        }
        attachScreenshot("\(tag)-alert")
        attachText("\(tag)-alert-text", alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        let closed = MK.tap(alert.buttons["OK"], until: { !alert.exists })
        let gone = MK.waitUntil(15) { !app.navigationBars["Poll"].exists }
        if !(closed && gone) {
            attachScreenshot("\(tag)-not-closed")
            attachTree("\(tag)-tree")
        }
        return closed && gone
    }

    func mkVote(_ texts: [String], choice: String, tag: String) -> Bool {
        let app = MK.app
        guard mkOpenPoll(texts, own: false, tag: tag) else {
            return false
        }
        let option = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", choice)).firstMatch
        guard option.waitForExistence(timeout: 10) else {
            attachScreenshot("\(tag)-no-choice")
            attachTree("\(tag)-tree")
            return false
        }
        sleep(1)
        attachScreenshot("\(tag)-poll")
        attachTree("\(tag)-poll-tree")
        let confirm = { MK.confirmButton(bar: "Poll") }
        MK.tap(option, until: { confirm() != nil }, attempts: 3, wait: 4)
        guard let button = confirm() else {
            attachScreenshot("\(tag)-no-confirm")
            attachTree("\(tag)-tree")
            return false
        }
        attachScreenshot("\(tag)-chosen")
        attachText("\(tag)-confirm", "the confirmation: label \"\(button.label)\", identifier \"\(button.identifier)\"")
        let voted = MK.tapFound(confirm, until: { !app.navigationBars["Poll"].exists }, attempts: 4, wait: 8)
        if !voted {
            attachScreenshot("\(tag)-not-voted")
            attachTree("\(tag)-tree")
        }
        return voted
    }

    func mkSendMyLocation(tag: String) -> Bool {
        let app = MK.app
        let sheet = app.navigationBars["Send Location"]
        guard mkAttachment("Send Location", tag: tag, until: { sheet.exists }) else {
            return false
        }
        handleAlerts(prefix: String(tag.prefix(3)))
        let send = { MK.barButton(["Send"], bar: "Send Location") }
        var how = "My Location, selected at the first fix"
        if !MK.waitUntil(20, { send() != nil }) {
            handleAlerts(prefix: String(tag.prefix(3)))
            let mine = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", "My Location")).firstMatch
            let row = mine.exists ? mine : app.staticTexts["My Location"]
            if row.exists {
                MK.tap(row, until: { send() != nil }, attempts: 2, wait: 8)
                how = "the My Location row, tapped"
            }
            if send() == nil {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.5)
                how = "a dropped pin"
                _ = MK.waitUntil(15, { send() != nil })
            }
        }
        sleep(1)
        attachScreenshot("\(tag)-location")
        attachText("\(tag)-how", how)
        guard send() != nil else {
            attachTree("\(tag)-tree")
            return false
        }
        let sent = MK.tapFound(send, until: { !sheet.exists }, attempts: 4, wait: 8)
        if !sent {
            attachScreenshot("\(tag)-not-sent")
            attachTree("\(tag)-tree")
        }
        return sent
    }

    func mkGroupAction(_ action: String, sheet titlePrefix: String, tag: String) -> Bool {
        let app = MK.app
        let label = NSPredicate(format: "label == %@", action)
        func row() -> XCUIElement? {
            let byLabel = app.cells.matching(label).firstMatch
            if byLabel.exists {
                return byLabel
            }
            let byChild = app.cells.containing(label).firstMatch
            return byChild.exists ? byChild : nil
        }
        for _ in 0..<8 where !(row().map(MK.hittable) ?? false) {
            app.swipeUp()
            usleep(800_000)
        }
        guard let target = row() else {
            attachScreenshot("\(tag)-no-row")
            attachTree("\(tag)-tree")
            return false
        }
        let rowFrame = target.frame
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", titlePrefix)).firstMatch
        func sheetButton() -> XCUIElement? {
            let inSheet = (app.sheets.buttons.matching(label).allElementsBoundByIndex +
                app.alerts.buttons.matching(label).allElementsBoundByIndex).first { $0.exists && MK.hittable($0) }
            if let inSheet {
                return inSheet
            }
            return app.buttons.matching(label).allElementsBoundByIndex
                .first { $0.exists && MK.hittable($0) && !rowFrame.contains($0.frame) }
        }
        MK.tap(target, until: { title.exists || sheetButton() != nil }, attempts: 3, wait: 6)
        sleep(1)
        attachScreenshot("\(tag)-sheet")
        guard sheetButton() != nil else {
            attachTree("\(tag)-tree")
            return false
        }
        if title.exists {
            attachText("\(tag)-sheet-title", title.label)
        }
        let gone = MK.tapFound({ sheetButton() }, until: { !title.exists && sheetButton() == nil }, attempts: 4, wait: 6)
        if !gone {
            attachScreenshot("\(tag)-sheet-stays")
            attachTree("\(tag)-tree")
        }
        return gone
    }
}

