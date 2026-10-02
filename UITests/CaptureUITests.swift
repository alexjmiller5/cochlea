import XCTest

final class CaptureUITests: XCTestCase {
    func testAccidentalCaptureCanBeCanceledAndStartedAgain() throws {
        let app = XCUIApplication()
        app.launch()
        allowSystemPrompts()
        let capture = app.buttons["Capture song"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        // On a fresh simulator the microphone prompt appears after the first tap; answer it
        // before touching the app, or it swallows the Cancel tap.
        allowSystemPrompts()
        if app.staticTexts["No microphone is available to record."].waitForExistence(timeout: 2) {
            throw XCTSkip("This host has no audio input, so the simulator cannot record")
        }
        let cancel = app.buttons["Cancel capture"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Capture canceled."].waitForExistence(timeout: 3))
        XCTAssertTrue(capture.waitForExistence(timeout: 3))
        capture.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        let listening = XCTAttachment(screenshot: app.screenshot())
        listening.name = "Cancellable recording"
        listening.lifetime = .keepAlways
        add(listening)
        cancel.tap()
        XCTAssertTrue(capture.waitForExistence(timeout: 3))
    }

    /// Answers the notification and microphone permission alerts, whichever are showing.
    private func allowSystemPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        for _ in 0..<3 where alert.waitForExistence(timeout: 2) {
            let allow = alert.buttons["Allow"]
            (allow.exists ? allow : alert.buttons.element(boundBy: alert.buttons.count - 1)).tap()
        }
    }

    func testSavedConnectionIsRestoredAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].tap()
        let endpoint = app.textFields["Capture URL"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
        replaceText(in: endpoint, with: "https://example.invalid/capture", app: app)
        let token = app.secureTextFields["Access token"]
        replaceText(in: token, with: "test-token", app: app)
        app.buttons["Save connection"].tap()
        XCTAssertTrue(app.staticTexts["Connection saved on this iPhone."].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
        XCTAssertEqual(endpoint.value as? String, "https://example.invalid/capture")
        XCTAssertTrue(app.staticTexts["Connection saved on this iPhone."].waitForExistence(timeout: 3))
    }

    func testCaptureScreenAndConnectionValidation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Capture song"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let endpoint = app.textFields["Capture URL"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
        replaceText(in: endpoint, with: "http://example.com/capture", app: app)
        let token = app.secureTextFields["Access token"]
        replaceText(in: token, with: "test-token", app: app)
        app.buttons["Save connection"].tap()
        XCTAssertTrue(app.staticTexts["Enter the HTTPS capture URL from Music Sync, without login details or query parameters."].waitForExistence(timeout: 3))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Connection validation"
        settings.lifetime = .keepAlways
        add(settings)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Capture song"].isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Capture screen"
        capture.lifetime = .keepAlways
        add(capture)
    }

    private func replaceText(in field: XCUIElement, with value: String, app: XCUIApplication) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty, existing != field.placeholderValue {
            field.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
            else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
            else { field.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        }
        field.typeText(value)
        if field.elementType == .textField { XCTAssertEqual(field.value as? String, value) }
    }
}
