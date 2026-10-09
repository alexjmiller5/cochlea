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

    func testCaptureLinkStartsCaptureAndARepeatedLinkLeavesItRunning() throws {
        let app = XCUIApplication()
        app.launch()
        allowSystemPrompts()
        XCTAssertTrue(app.buttons["Capture song"].waitForExistence(timeout: 5))
        app.open(URL(string: "cochlea://capture")!)
        allowSystemPrompts()
        if app.staticTexts["No microphone is available to record."].waitForExistence(timeout: 3) {
            attach(app, "Capture link - started, no audio input on this host")
            throw XCTSkip("This host has no audio input, so the simulator cannot record")
        }
        let cancel = app.buttons["Cancel capture"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.open(URL(string: "offlineshazam://capture")!)
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "A repeated link leaves the capture running")
        attach(app, "Capture link - recording")
        cancel.tap()
        XCTAssertTrue(app.buttons["Capture song"].waitForExistence(timeout: 3))
    }

    func testSettingsExportsEveryCaptureThroughTheShareSheet() {
        let app = XCUIApplication()
        app.launch()
        allowSystemPrompts()
        app.buttons["Settings"].tap()
        let export = app.buttons["Export captures"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        attach(app, "Settings - export captures")
        export.tap()
        let shareSheet = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.otherElements["ActivityListView"].exists || app.buttons["Save to Files"].exists || app.cells["Save to Files"].exists
        }, object: nil)
        wait(for: [shareSheet], timeout: 15)
        attach(app, "Export captures - share sheet")
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

    func testEnrollmentLinkConnectsSurvivesRelaunchAndDisconnects() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Capture song"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let disconnect = app.buttons["Disconnect"]
        if disconnect.waitForExistence(timeout: 2) { disconnect.tap() }
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields.firstMatch.exists, "the connection is never typed in")
        attach(app, "Settings - not connected")
        app.buttons["Done"].tap()

        app.open(URL(string: "offlineshazam://enroll?url=https%3A%2F%2Fexample.invalid%2Fcapture&token=test-token")!)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connected to example.invalid"].waitForExistence(timeout: 5))
        attach(app, "Settings - connected")
        app.buttons["Done"].tap()

        app.terminate()
        app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connected to example.invalid"].waitForExistence(timeout: 5))
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Capture song"].isHittable)
        attach(app, "Capture screen")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
