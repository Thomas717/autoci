import XCTest

final class LicenseTests: XCTestCase {
    private var threema: XCUIApplication { Driver.threema }

    private let prompt = "Please enter the Threema OnPrem credentials provided by your company"

    override func setUp() {
        continueAfterFailure = false
        threema.activate()
        handleAlerts(prefix: "m17")
    }

    private var licenceScreen: XCUIElement {
        threema.buttons["ConfirmButton"]
    }

    func testLocked() throws {
        let password = threema.secureTextFields["licensePassword"]
        let deadline = Date().addingTimeInterval(90)
        while !licenceScreen.exists && !password.exists && Date() < deadline {
            sleep(2)
        }
        attachScreenshot("m17-01-locked")
        guard licenceScreen.exists || password.exists else {
            attachTree("m17-01-tree")
            XCTFail("no licence screen within 90 s of the relaunch")
            return
        }
        let shown = Driver.shows(prompt, timeout: 5)
        let username = threema.textFields["licenseUsername"]
        attachText("m17-01-screen", "prompt shown: \(shown)\nusername field: "
            + "\(username.exists ? String(describing: username.value) : "none")")
        XCTAssertTrue(shown, "the licence screen does not ask for the credentials")
    }

    func testBack() throws {
        sleep(10)
        if licenceScreen.exists {
            attachScreenshot("m17-02-still-locked")
            if Driver.hittable(licenceScreen) {
                licenceScreen.tap()
            }
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: licenceScreen)
            _ = XCTWaiter.wait(for: [gone], timeout: 60)
        }
        XCTAssertFalse(licenceScreen.exists, "the licence screen stays up with the seat enabled again")
        LaunchModals.clear(threema, settle: 3) { attachScreenshot("m17-00-modal-\($0)") }
        Driver.openChatList()
        attachScreenshot("m17-03-back")
        XCTAssertTrue(Driver.composeButton.waitForExistence(timeout: 15), "the chat list is not back")
    }
}

