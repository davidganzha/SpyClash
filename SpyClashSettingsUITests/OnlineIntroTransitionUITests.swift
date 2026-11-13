import XCTest

@MainActor
final class OnlineIntroTransitionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testMenuIntroAndPreparedCardRemainOneContinuousFlow() {
        launch(extra: ["--spyclash-preview-intro-transition"])
        let card = app.descendants(matching: .any)["onlineExperience.roleCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        let usable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: card)
        wait(for: [usable], timeout: 4)
        XCTAssertFalse(app.otherElements["onlineExperience.intro"].exists)
        attach("prepared-role-card")
        card.tap()
        XCTAssertTrue(card.isHittable, "The dissolve must release interaction after completion.")
    }

    func testCompletedChoreographyRemainsVisibleWhileDestinationIsPending() {
        // Freeze only the preview clock/destination, so XCTest's launch-idle
        // wait cannot miss the held state on a slow Simulator.
        launch(extra: ["--spyclash-preview-room=roulette", "--spyclash-online-intro-progress=1",
                       "--spyclash-preview-player-count=12", "--spyclash-preview-lang=uk"])
        let intro = app.descendants(matching: .any)["onlineExperience.intro"].firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["onlineExperience.roleCard"].firstMatch.exists)
        XCTAssertTrue(intro.label.contains("Знайдіть шпигуна"))
        attach("held-mission-12-players")
    }

    private func launch(extra: [String]) {
        app.launchArguments = ["--spyclash-ui-preview", "--spyclash-preview-tab=game"] + extra
        if !extra.contains(where: { $0.hasPrefix("--spyclash-preview-lang=") }) {
            app.launchArguments.append("--spyclash-preview-lang=ru")
        }
        app.launch()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
