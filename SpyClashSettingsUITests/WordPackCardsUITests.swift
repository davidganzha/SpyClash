import XCTest

/// UI acceptance of real editor controls with local preview data. Persistence
/// across HTTP is covered separately by WordPackPersistenceIntegrationTests.
@MainActor
final class WordPackCardsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
        app.launchArguments = [
            "--spyclash-ui-preview", "--spyclash-preview-tab=packs",
            "--spyclash-preview-lang=en", "--spyclash-preview-limitless"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["wordPacks.add"].waitForExistence(timeout: 10))
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testManualCreationSavesCrossedOutSelectionAndPendingInputThenReopens() {
        app.buttons["wordPacks.add"].tap()
        app.buttons["wordPacks.editor.method.manual"].tap()
        let name = app.textFields["wordPacks.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("QA Manual")
        let input = app.textFields["wordPacks.editor.addWordsInput"]
        reveal(input)
        input.tap()
        input.typeText("Harbor; Museum; Airport")
        app.buttons["wordPacks.editor.addWords"].tap()

        let excluded = card("Museum")
        reveal(excluded, upward: false)
        XCTAssertTrue(excluded.isSelected)
        excluded.tap()
        XCTAssertFalse(excluded.isSelected)
        XCTAssertEqual(excluded.value as? String, "Crossed out")

        reveal(input)
        input.tap()
        input.typeText("Vault")
        // Save must flush text still in the add-word field without needing +.
        app.buttons["wordPacks.editor.save"].tap()
        reopenCreatedPack(named: "QA Manual")
        reveal(card("Harbor"))
        XCTAssertTrue(card("Harbor").isSelected)
        XCTAssertTrue(card("Airport").isSelected)
        XCTAssertTrue(card("Vault").isSelected)
        XCTAssertFalse(card("Museum").exists)
        XCTAssertFalse(app.textViews.firstMatch.exists)
        attachScreenshot("manual-cards-saved-and-reopened")
    }

    func testEditingCanCrossOutAndRestoreCardsBeforeSaveAndReopen() {
        let edit = app.buttons["wordPacks.edit.preview-pack-places"]
        reveal(edit)
        edit.tap()
        let embassy = card("Embassy")
        reveal(embassy)
        XCTAssertTrue(embassy.isSelected)
        embassy.tap()
        XCTAssertFalse(embassy.isSelected)
        embassy.tap()
        XCTAssertTrue(embassy.isSelected)
        let harbor = card("Harbor")
        harbor.tap()
        XCTAssertFalse(harbor.isSelected)
        app.buttons["wordPacks.editor.save"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        reveal(edit, upward: false)
        edit.tap()
        reveal(card("Embassy"))
        XCTAssertTrue(card("Embassy").isSelected)
        XCTAssertTrue(card("Casino").isSelected)
        XCTAssertFalse(card("Harbor").exists)
        XCTAssertFalse(app.textViews.firstMatch.exists)
        attachScreenshot("edited-cards-saved-and-reopened")
    }

    func testGeneratedDraftUsesTheSameCardsAndSavedSelection() {
        app.buttons["wordPacks.add"].tap()
        app.buttons["wordPacks.editor.method.ai"].tap()
        let theme = app.textFields["wordPacks.editor.theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        theme.tap()
        theme.typeText("QA Generated")
        app.buttons["wordPacks.editor.generate"].tap()
        XCTAssertTrue(app.buttons["wordPacks.editor.save"].waitForExistence(timeout: 10))
        let cipher = card("Cipher")
        reveal(cipher)
        XCTAssertTrue(cipher.isSelected)
        cipher.tap()
        XCTAssertFalse(cipher.isSelected)
        app.buttons["wordPacks.editor.save"].tap()
        reopenCreatedPack(named: "QA Generated")
        reveal(card("Embassy"))
        XCTAssertTrue(card("Embassy").isSelected)
        XCTAssertFalse(card("Cipher").exists)
        XCTAssertFalse(app.textViews.firstMatch.exists)
        attachScreenshot("generated-cards-saved-and-reopened")
    }

    private func card(_ word: String) -> XCUIElement {
        app.buttons["wordPacks.editor.word.\(word)"]
    }

    private func reopenCreatedPack(named name: String) {
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["wordPacks.editor.save"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        let edit = app.buttons["Edit \(name)"]
        reveal(edit)
        edit.tap()
        XCTAssertTrue(app.buttons["wordPacks.editor.save"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, upward: Bool = true) {
        let editor = app.scrollViews["wordPacks.editor.form"]
        let scroll = editor.exists ? editor : app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            if element.isHittable { return }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: upward ? 0.8 : 0.2))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: upward ? 0.25 : 0.75))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, "Cannot reach \(element.identifier)")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
