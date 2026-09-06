import XCTest

@MainActor
final class AuthenticationEntryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
        app.launchArguments = ["--spyclash-ui-preview", "--spyclash-preview-direct=welcome", "--spyclash-preview-lang=en"]
        app.launch()
        let login = app.buttons["welcome.login"]
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        login.tap()
        XCTAssertTrue(app.buttons["auth.google"].waitForExistence(timeout: 10))
    }

    override func tearDown() async throws { app.terminate() }

    func testWelcomeOpensAvailableAuthenticationControls() {
        XCTAssertTrue(app.buttons["auth.google"].isEnabled)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Apple'")).firstMatch.exists)
        XCTAssertTrue(app.textFields.firstMatch.exists)
    }

    /// Explicit opt-in: starts real OAuth transactions, enters no credentials,
    /// and cancels at the provider form. This is not a successful-account-login test.
    func testLiveGoogleFormCanBeCancelledAndStartedAgain() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SPYCLASH_RUN_LIVE_AUTH_UI"] == "1" || environment["TEST_RUNNER_SPYCLASH_RUN_LIVE_AUTH_UI"] == "1")
        for attempt in 1...2 {
            let google = app.buttons["auth.google"]
            XCTAssertTrue(google.isEnabled)
            google.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
                let continueButton = springboard.alerts.buttons.matching(NSPredicate(format: "label IN {'Continue', 'Продолжить', 'Продовжити', 'Continuar'}")).firstMatch
                XCTAssertTrue(continueButton.exists)
                continueButton.tap()
            }
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 30))
            let accountField = web.textFields.matching(NSPredicate(format: "label CONTAINS[c] 'email' OR label CONTAINS[c] 'почт' OR label CONTAINS[c] 'пошт' OR label CONTAINS[c] 'correo'")).firstMatch
            XCTAssertTrue(accountField.waitForExistence(timeout: 30), "The Google account field must load before cancellation")
            let usableForm = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: accountField)
            XCTAssertEqual(XCTWaiter.wait(for: [usableForm], timeout: 15), .completed)
            accountField.tap()
            // A Simulator hardware keyboard can suppress the software keyboard.
            // Assert focus on the actual provider field, not keyboard visibility.
            let focusedField = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: accountField)
            XCTAssertEqual(XCTWaiter.wait(for: [focusedField], timeout: 10), .completed)
            XCTAssertFalse(web.staticTexts.matching(NSPredicate(format: "label CONTAINS 'invalid_state'")).firstMatch.exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "live-google-form-attempt-\(attempt)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let cancel = app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close', 'Отменить', 'Закрыть', 'Скасувати', 'Закрити', 'Cancelar', 'Cerrar'}")).allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(cancel)
            cancel?.tap()
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: google)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        }
    }
}
