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
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
    }

    override func tearDown() async throws { app.terminate() }

    func testLoginOffersConfiguredProvidersAndEmailWithoutGoogle() {
        assertAvailableAuthenticationControls()

        enterEmail("login-preview@example.com")
        app.buttons["CONTINUE"].tap()

        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.secureTextFields.count, 1)
        let unlock = app.buttons["UNLOCK"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        XCTAssertFalse(unlock.isEnabled)
        XCTAssertTrue(app.buttons["login-preview@example.com"].exists)
        XCTAssertTrue(app.buttons["FORGOT PASSPHRASE?"].exists)
    }

    func testRegistrationOffersConfiguredProvidersAndEmailWithoutGoogle() {
        app.buttons["REQUEST ACCESS"].tap()
        let joinNetwork = app.buttons["JOIN THE NETWORK"]
        XCTAssertTrue(joinNetwork.waitForExistence(timeout: 10))
        assertAvailableAuthenticationControls()

        enterEmail("registration-preview@example.com")
        joinNetwork.tap()

        XCTAssertTrue(app.secureTextFields.element(boundBy: 1).waitForExistence(timeout: 10))
        XCTAssertEqual(app.secureTextFields.count, 2)
        let createCredentials = app.buttons["CREATE CREDENTIALS"]
        XCTAssertTrue(createCredentials.waitForExistence(timeout: 5))
        XCTAssertFalse(createCredentials.isEnabled)
        XCTAssertTrue(app.buttons["registration-preview@example.com"].exists)
        XCTAssertTrue(app.staticTexts["// CONFIRM PASSPHRASE"].exists)
    }

    func testRussianAppleFailureModalExposesFullCodeAndBothActions() {
        launchAppleFailurePreview()
        let modal = app.descendants(matching: .any)["auth.appleFailure.modal"]
        XCTAssertTrue(modal.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["auth.appleFailure.title"].label, "Вход с Apple")
        XCTAssertEqual(app.staticTexts["auth.appleFailure.message"].label,
                       "Не удалось завершить вход через Apple. Попробуйте ещё раз.")
        let code = app.descendants(matching: .any)["auth.appleFailure.code"]
        XCTAssertTrue(code.exists)
        XCTAssertEqual(code.label, "Код для поддержки")
        XCTAssertEqual(code.value as? String, "SCA177-H34-r6-s0-cN-uOT-q10-pN-fN-dPA-k11")
        let copy = app.buttons["auth.appleFailure.copy"]
        let close = app.buttons["auth.appleFailure.close"]
        XCTAssertEqual(copy.label, "Скопировать код для поддержки")
        XCTAssertEqual(close.label, "Закрыть")
        XCTAssertFalse(app.textFields.firstMatch.exists, "The underlying form must be hidden from the modal accessibility tree")
        // SwiftUI exports .isModal with an alert accessibility role. Identify
        // that element by our own identifier and children; an alert count alone
        // cannot distinguish SwiftUI from a native UIAlertController.
        let alertTree = XCTAttachment(string: app.alerts.debugDescription)
        alertTree.name = "Synthetic-Apple-modal-accessibility-identity"
        alertTree.lifetime = .keepAlways
        add(alertTree)
        XCTAssertEqual(app.alerts.count, 1, "No additional native or app-owned failure dialog may be present")
        let exportedModal = app.alerts.firstMatch
        XCTAssertEqual(exportedModal.identifier, "auth.appleFailure.modal")
        XCTAssertTrue(exportedModal.descendants(matching: .any)["auth.appleFailure.code"].exists)
        XCTAssertTrue(exportedModal.buttons["auth.appleFailure.copy"].exists)
        XCTAssertTrue(exportedModal.buttons["auth.appleFailure.close"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple-support-code-game-font-Russian-normal-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        revealAppleFailureAction(close)
        close.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(modal.exists)

        launchAppleFailurePreview()
        let copyAgain = app.buttons["auth.appleFailure.copy"]
        XCTAssertTrue(copyAgain.waitForExistence(timeout: 10))
        revealAppleFailureAction(copyAgain)
        copyAgain.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["auth.appleFailure.modal"].exists)
    }

    private func launchAppleFailurePreview() {
        app.terminate()
        app.launchArguments = [
            "--spyclash-ui-preview", "--spyclash-preview-direct=auth",
            "--spyclash-preview-lang=ru", "--spyclash-preview-apple-handoff-error"
        ]
        app.launch()
    }

    private func revealAppleFailureAction(_ button: XCUIElement) {
        let scroll = app.scrollViews["auth.appleFailure.scroll"]
        for _ in 0..<8 {
            if button.isHittable { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
    }

    private func assertAvailableAuthenticationControls(file: StaticString = #filePath, line: UInt = #line) {
        let apple = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Apple'")).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(apple.isEnabled, file: file, line: line)
        let gameCenter = app.buttons["auth.gamecenter"]
        // Standard Debug omits Game Center; SupabaseDebug runs set this flag to 1.
        let expectsGameCenter = ProcessInfo.processInfo.environment["SPYCLASH_EXPECT_GAME_CENTER"] == "1"
        XCTAssertEqual(gameCenter.exists, expectsGameCenter, file: file, line: line)
        if expectsGameCenter {
            XCTAssertTrue(gameCenter.isEnabled, file: file, line: line)
        }
        XCTAssertTrue(app.textFields.firstMatch.exists, file: file, line: line)
        XCTAssertFalse(app.buttons["auth.google"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Google'")).firstMatch.exists, file: file, line: line)
    }

    /// Advancing from email to password is local. Neither test submits credentials
    /// or opens a provider, so no live authentication transaction is started.
    private func enterEmail(_ email: String) {
        let field = app.textFields.firstMatch
        field.tap()
        field.typeText(email)
    }
}
