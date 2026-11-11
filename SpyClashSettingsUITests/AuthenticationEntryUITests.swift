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
