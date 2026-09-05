import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
        app.launchArguments = ["--spyclash-ui-preview", "--spyclash-preview-tab=profile",
                               "--spyclash-preview-lang=ru", "--spyclash-preview-limitless",
                               "--spyclash-preview-sheet=settings"]
        app.launch()
        XCTAssertTrue(app.buttons["interface-settings.close"].waitForExistence(timeout: 10))
        app.buttons["interface-settings.preset.original"].tap()
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testScaleResizesControlsPersistsAndResets() {
        let close = app.buttons["interface-settings.close"]
        let originalWidth = close.frame.width
        let slider = app.sliders["interface-settings.scale"]
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 1)
        assertLabel(app.staticTexts["interface-settings.scale-value"], "120%")
        XCTAssertEqual(close.frame.width, originalWidth * 1.2, accuracy: 2)
        XCTAssertTrue(close.isHittable)
        attachScreenshot("settings-120-percent")

        let motion = app.switches["interface-settings.reduce-motion"]
        reveal(motion)
        motion.tap()
        XCTAssertEqual(motion.value as? String, "1")
        close.tap()
        XCTAssertTrue(app.buttons["spy-command-menu-drag-handle"].isHittable)
        attachScreenshot("profile-120-percent")
        app.buttons["spy-command-menu-drag-handle"].tap()
        let limitless = app.buttons["spy-command-menu.limitless"]
        XCTAssertTrue(limitless.waitForExistence(timeout: 5))
        limitless.tap()
        let pricingClose = app.buttons["limitless.close"]
        XCTAssertTrue(pricingClose.waitForExistence(timeout: 5))
        XCTAssertTrue(pricingClose.isHittable)
        attachScreenshot("limitless-120-percent")
        pricingClose.tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        assertLabel(app.staticTexts["interface-settings.scale-value"], "120%")
        XCTAssertEqual(close.frame.width, originalWidth * 1.2, accuracy: 2)
        app.buttons["interface-settings.preset.original"].tap()
        assertLabel(app.staticTexts["interface-settings.scale-value"], "100%")
        XCTAssertEqual(close.frame.width, originalWidth, accuracy: 2)
    }

    func testLanguageAndRadarMovedOutOfProfileAndSurviveInterfaceReset() {
        let english = app.buttons["settings.language.en"]
        reveal(english)
        english.tap()
        XCTAssertTrue(english.isSelected)
        XCTAssertTrue(app.buttons["interface-settings.close"].label.contains("Close"))

        let automatic = app.buttons["settings.radarPolicy.automatic"]
        reveal(automatic)
        automatic.tap()
        XCTAssertTrue(automatic.isSelected)
        attachScreenshot("language-and-radar-in-settings")
        let reset = app.buttons["interface-settings.reset"]
        reveal(reset)
        reset.tap()
        app.buttons["interface-settings.reset-confirm"].tap()
        XCTAssertTrue(automatic.isSelected)
        XCTAssertTrue(english.isSelected)
        app.buttons["settings.radarPolicy.ask"].tap()
        reveal(app.buttons["settings.language.ru"], direction: .down)
        app.buttons["settings.language.ru"].tap()
        app.buttons["interface-settings.close"].tap()

        XCTAssertFalse(app.buttons["settings.language.en"].exists)
        XCTAssertFalse(app.buttons["settings.radarPolicy.ask"].exists)
        XCTAssertFalse(app.buttons["profile.radarPolicy.ask"].exists)
        XCTAssertFalse(app.staticTexts["ЖИВОЙ ПРИМЕР"].exists)
    }

    private enum ScrollDirection { case up, down }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, direction: ScrollDirection = .up) {
        let scroll = app.scrollViews["interface-settings.form"]
        for _ in 0..<12 {
            if element.isHittable { return }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: direction == .up ? 0.8 : 0.2))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: direction == .up ? 0.25 : 0.75))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func assertLabel(_ element: XCUIElement, _ text: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
