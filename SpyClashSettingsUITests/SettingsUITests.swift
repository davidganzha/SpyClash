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

    func testLimitlessDockAndDropdownFollowAccess() {
        app.terminate()
        app.launchArguments = ["--spyclash-ui-preview", "--spyclash-preview-tab=home",
                               "--spyclash-preview-lang=ru", "--spyclash-preview-limitless"]
        app.launch()
        let upgrade = app.buttons["dock.limitless"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dock.'")).count, 4)
        attachScreenshot("free-four-dock-buttons")
        upgrade.tap()
        XCTAssertTrue(app.buttons["limitless.close"].waitForExistence(timeout: 5))
        app.buttons["limitless.close"].tap()
        app.buttons["dock.profile"].tap()
        XCTAssertTrue(app.buttons["dock.profile"].isHittable)
        app.buttons["spy-command-menu-drag-handle"].tap()
        XCTAssertTrue(app.buttons["spy-command-menu.settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["spy-command-menu.limitless"].exists)
        attachScreenshot("dropdown-without-limitless")

        app.terminate()
        // The default preview fixture grants access; no live purchases are made.
        app.launchArguments = ["--spyclash-ui-preview", "--spyclash-preview-tab=home",
                               "--spyclash-preview-lang=ru"]
        app.launch()
        XCTAssertTrue(app.buttons["dock.home"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dock.'")).count, 3)
        XCTAssertFalse(app.buttons["dock.limitless"].exists)
        attachScreenshot("active-access-three-dock-buttons")
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
        let limitless = app.buttons["dock.limitless"]
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

/// Uses only synthetic room and Community previews; no permission prompts,
/// friend mutations, or reports are sent to the backend.
@MainActor
final class LobbyFeedbackUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testLocalNetworkDenialRemovesRadarFromLobbyPagesAndQRSheet() {
        assertRadarHidden(for: "--spyclash-preview-local-network-denied")
    }

    func testNearbyInteractionDenialRemovesRadarFromLobbyPagesAndQRSheet() {
        assertRadarHidden(for: "--spyclash-preview-rangefinder=denied")
    }

    func testLongPressLobbyPlayerOpensTheirProfileWithRelationshipAndReportActions() {
        launchLobby()
        let player = app.staticTexts["CIPHER"].firstMatch
        reveal(player)
        player.press(forDuration: 0.7)

        let profileOpened = app.staticTexts["OPERATIVE NETWORK"].waitForExistence(timeout: 5)
        if !profileOpened {
            attachScreenshot("lobby-long-press-profile-open-failure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "lobby-long-press-accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(profileOpened)
        let report = app.buttons["REPORT"].firstMatch
        reveal(report)
        XCTAssertTrue(report.isEnabled)
        // Cipher is already a friend in CommunityPreview, so Remove is the
        // correct relationship action for this exact lobby player.
        XCTAssertTrue(app.buttons["REMOVE"].firstMatch.isEnabled)
        XCTAssertFalse(app.buttons["ADD OPERATIVE"].exists)
        attachScreenshot("lobby-long-press-cipher-profile-actions")
    }

    private func assertRadarHidden(for deniedPermissionArgument: String) {
        launchLobby(extraArguments: [deniedPermissionArgument, "--spyclash-preview-room-access=radar"])
        let pages = app.descendants(matching: .any)
            .matching(identifier: "onlineRoom.accessPages").firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 10))
        assertValue(pages, "Page 1 of 3")
        XCTAssertFalse(app.descendants(matching: .any)["onlineRoom.radarDirectory"].exists)
        pages.swipeLeft()
        assertValue(pages, "Page 2 of 3")
        pages.swipeLeft()
        assertValue(pages, "Page 3 of 3")
        XCTAssertTrue(app.descendants(matching: .any)["onlineRoom.friendsDirectory"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["onlineRoom.radarDirectory"].exists)
        attachScreenshot("lobby-denied-radar-three-pages")

        launchLobby(extraArguments: [deniedPermissionArgument, "--spyclash-preview-sheet=roomQR"])
        XCTAssertTrue(app.buttons["roomQR.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["roomQR.openFriends"].exists)
        XCTAssertTrue(app.buttons["roomQR.share"].exists)
        XCTAssertFalse(app.buttons["roomQR.openRadar"].exists)
        attachScreenshot("qr-denied-radar-hidden")
    }

    private func launchLobby(extraArguments: [String] = []) {
        app.terminate()
        app.launchArguments = [
            "--spyclash-ui-preview", "--spyclash-preview-tab=game",
            "--spyclash-preview-room=waiting", "--spyclash-preview-lang=en"
        ] + extraArguments
        app.launch()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<10 {
            // SwiftUI can report a row behind the fixed bottom room controls
            // as hittable. Move it into the unobscured viewport before acting.
            if element.isHittable,
               element.frame.maxY < app.frame.maxY - 160 {
                return
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable && element.frame.maxY < app.frame.maxY - 160,
                      "Cannot reach unobscured element \(element.identifier)")
    }

    private func assertValue(_ element: XCUIElement, _ value: String) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Exercises the actual FAN menu and player sheet with synthetic rooms only.
/// Run on both a compact iPhone and a current full-size iPhone.
@MainActor
final class FanVotingUITests: XCTestCase {
    private var app: XCUIApplication!
    private let choiceIDs = ["player", "no_spies", "all_spies"]
    private let choiceLabels = ["Голосовать за игрока", "Шпионов нет", "Все шпионы"]
    private let rowPrefix = "fanMode.vote.players."
    private let selfEmail = "operative.preview@spyclash.local"

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testThreeChoicesStayVisibleAndPlayerListIsSeparateForEveryRosterSize() {
        for playerCount in [3, 4, 8, 12] {
            launchBallot(playerCount: playerCount)
            assertMenuIsVisibleAndUnsubmitted()
            attachScreenshot("fan-\(playerCount)-players-three-choices")

            app.buttons["fanMode.vote.player"].tap()
            let close = app.buttons["fanMode.vote.players.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            let list = app.scrollViews["fanMode.vote.players.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            attachScreenshot("fan-\(playerCount)-players-list-top")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "fan-\(playerCount)-players-list-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)

            let expectedEmails = candidateEmails(playerCount: playerCount)
            let lastCandidate = app.buttons[rowPrefix + expectedEmails.last!]
            var seenEmails = Set<String>()
            for attempt in 0..<12 {
                let rows = app.buttons.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier CONTAINS '@'", rowPrefix
                )).allElementsBoundByIndex
                seenEmails.formUnion(rows.map { String($0.identifier.dropFirst(rowPrefix.count)) })
                XCTAssertFalse(app.buttons[rowPrefix + selfEmail].exists, "The current player must never be a candidate")
                if lastCandidate.exists, lastCandidate.isHittable,
                   // SwiftUI includes the half-point border in the accessibility frame.
                   list.frame.insetBy(dx: -1, dy: -1).contains(lastCandidate.frame) {
                    break
                }
                XCTAssertLessThan(attempt, 11, "The final candidate must be reachable in the player list")
                list.swipeUp()
            }
            XCTAssertEqual(seenEmails, Set(expectedEmails), "The list must contain exactly the other active players")
            XCTAssertEqual(seenEmails.count, playerCount - 1)
            XCTAssertTrue(lastCandidate.isEnabled, "Opening the list must not submit a vote")
            assertFullyVisible(lastCandidate)
            attachScreenshot("fan-\(playerCount)-players-list-last-candidate")

            close.tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: close
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            assertMenuIsVisibleAndUnsubmitted()
        }
    }

    func testRecordedPlayerAndConceptVotesLockAllThreeChoices() {
        for selected in choiceIDs {
            launchBallot(playerCount: 4, recordedVote: selected)
            for id in choiceIDs {
                let choice = app.buttons["fanMode.vote.\(id)"]
                XCTAssertTrue(choice.exists)
                XCTAssertFalse(choice.isEnabled, "A recorded vote must lock every answer")
                XCTAssertEqual(choice.isSelected, id == selected)
                assertFullyVisible(choice)
            }
            XCTAssertFalse(app.buttons["fanMode.vote.players.close"].exists)
            attachScreenshot("fan-recorded-\(selected)-all-choices-locked")
        }
    }

    private func launchBallot(playerCount: Int, recordedVote: String? = nil) {
        app.terminate()
        app.launchArguments = [
            "--spyclash-ui-preview", "--spyclash-preview-tab=game",
            "--spyclash-preview-room=voting", "--spyclash-preview-lang=ru",
            "--spyclash-preview-player-count=\(playerCount)", "--spyclash-preview-fan-mode"
        ]
        if let recordedVote {
            app.launchArguments.append("--spyclash-preview-fan-vote=\(recordedVote)")
        }
        app.launch()
        XCTAssertTrue(app.buttons["fanMode.vote.player"].waitForExistence(timeout: 10))
    }

    private func assertMenuIsVisibleAndUnsubmitted() {
        for (id, label) in zip(choiceIDs, choiceLabels) {
            let choice = app.buttons["fanMode.vote.\(id)"]
            XCTAssertEqual(choice.label, label)
            XCTAssertTrue(choice.isEnabled)
            XCTAssertFalse(choice.isSelected)
            assertFullyVisible(choice)
            XCTAssertTrue(choice.isHittable, "All three choices must be usable without scrolling")
        }
        XCTAssertFalse(app.buttons["fanMode.vote.players.close"].exists)
    }

    private func assertFullyVisible(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44, file: file, line: line)
        XCTAssertTrue(app.frame.contains(frame), "\(element.identifier) is clipped outside the screen: \(frame)", file: file, line: line)
    }

    private func candidateEmails(playerCount: Int) -> [String] {
        ["cipher@spyclash.local", "ghost@spyclash.local"]
            + (playerCount > 3 ? (4...playerCount).map { "operative\($0)@spyclash.local" } : [])
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Exercises the compact header against synthetic rooms, without live mutations.
@MainActor
final class GameHeaderUITests: XCTestCase {
    private var app: XCUIApplication!
    private let leaveID = "onlineExperience.leave"
    private let pauseID = "onlineExperience.pauseResume"
    private let lobbyID = "onlineExperience.returnToLobbyVote"
    private let confirmationID = "onlineExperience.confirmation"

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.spyclash.ios")
    }

    override func tearDown() async throws {
        app.terminate()
    }

    func testHostHeaderHasThreeControlsAndCancelPreservesGame() {
        launchGame(playerCount: 12)
        assertHeaderControls([lobbyID, leaveID, pauseID])
        assertUnsubmittedBallot()
        let initialLobbyValue = app.buttons[lobbyID].value as? String
        let initialPauseLabel = app.buttons[pauseID].label
        attachScreenshot("game-header-host-three-controls")

        app.buttons[lobbyID].tap()
        assertLobbyConfirmation()
        attachScreenshot("game-header-host-lobby-confirmation")
        cancelConfirmation()
        assertUnsubmittedBallot()
        assertHeaderControls([lobbyID, leaveID, pauseID])
        XCTAssertEqual(app.buttons[lobbyID].value as? String, initialLobbyValue)
        XCTAssertEqual(app.buttons[pauseID].label, initialPauseLabel)

        app.buttons[leaveID].tap()
        assertConfirmation(
            title: "Закрыть комнату?",
            message: "Комната закроется для всех игроков. Текущая игра прервётся.",
            confirmLabel: "ЗАКРЫТЬ ИГРУ"
        )
        attachScreenshot("game-header-host-exit-confirmation")
        cancelConfirmation()
        assertUnsubmittedBallot()
        assertHeaderControls([lobbyID, leaveID, pauseID])
        XCTAssertEqual(app.buttons[lobbyID].value as? String, initialLobbyValue)
        XCTAssertEqual(app.buttons[pauseID].label, initialPauseLabel)

        // Pausing is also handled locally by the preview fixture. The header
        // must remain accessible above the pause overlay without duplicate controls.
        app.buttons[pauseID].tap()
        waitForLabel("Продолжить таймер", on: app.buttons[pauseID])
        assertHeaderControls([lobbyID, leaveID, pauseID])
        attachScreenshot("game-header-host-paused-three-controls")
        app.buttons[lobbyID].tap()
        assertLobbyConfirmation()
        cancelConfirmation()
        assertHeaderControls([lobbyID, leaveID, pauseID])
        XCTAssertEqual(app.buttons[pauseID].label, "Продолжить таймер")
        XCTAssertEqual(app.buttons[lobbyID].value as? String, initialLobbyValue)
        app.buttons[pauseID].tap()
        waitForLabel(initialPauseLabel, on: app.buttons[pauseID])
        assertUnsubmittedBallot()
    }

    func testGuestHasOnlyPersonalExitAndCancellationPreservesGame() {
        launchGame(playerCount: 3, guest: true)
        XCTAssertFalse(app.buttons[pauseID].exists)
        XCTAssertFalse(app.buttons[lobbyID].exists)
        assertHeaderControls([leaveID])
        XCTAssertEqual(app.buttons[leaveID].label, "ВЫЙТИ ИЗ ИГРЫ")
        attachScreenshot("game-header-guest-personal-exit-only")

        app.buttons[leaveID].tap()
        assertConfirmation(
            title: "Выйти из игры?",
            message: "Вы покинете эту комнату.",
            confirmLabel: "ВЫЙТИ ИЗ ИГРЫ"
        )
        attachScreenshot("game-header-guest-personal-exit-confirmation")
        cancelConfirmation()
        assertUnsubmittedBallot()
        assertHeaderControls([leaveID])
        XCTAssertFalse(app.buttons[pauseID].exists)
        XCTAssertFalse(app.buttons[lobbyID].exists)
    }

    func testConfirmLobbyReturnLeavesActiveGameInPreview() {
        launchGame(playerCount: 3)
        app.buttons[lobbyID].tap()
        assertLobbyConfirmation()
        // GameView handles this preview action locally through
        // previewActiveLobbyReturnCandidate; no server request is performed.
        app.buttons[confirmationID + ".confirm"].tap()
        XCTAssertTrue(app.buttons["onlineRoom.leave"].waitForExistence(timeout: 5))
        XCTAssertFalse(confirmation.exists)
        XCTAssertFalse(app.buttons["fanMode.vote.player"].exists)
        XCTAssertFalse(app.buttons[leaveID].exists)
        XCTAssertFalse(app.buttons[lobbyID].exists)
        attachScreenshot("game-header-confirmed-return-to-lobby")
    }

    private var confirmation: XCUIElement {
        app.descendants(matching: .any).matching(identifier: confirmationID).firstMatch
    }

    private func launchGame(playerCount: Int, guest: Bool = false) {
        app.launchArguments = [
            "--spyclash-ui-preview", "--spyclash-preview-tab=game",
            "--spyclash-preview-room=voting", "--spyclash-preview-lang=ru",
            "--spyclash-preview-player-count=\(playerCount)", "--spyclash-preview-fan-mode"
        ]
        if guest { app.launchArguments.append("--spyclash-preview-guest") }
        app.launch()
        XCTAssertTrue(app.buttons["fanMode.vote.player"].waitForExistence(timeout: 10))
        XCTAssertFalse(confirmation.exists)
    }

    private func assertHeaderControls(_ identifiers: [String]) {
        let buttons = identifiers.map { app.buttons[$0] }
        for button in buttons {
            XCTAssertTrue(button.exists)
            XCTAssertEqual(app.buttons.matching(identifier: button.identifier).count, 1,
                           "The pause overlay must not duplicate header controls")
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.frame.contains(button.frame), "\(button.identifier) must fit on screen")
            XCTAssertEqual(button.frame.midY, buttons[0].frame.midY, accuracy: 1,
                           "Exit, pause and lobby controls must occupy one row")
        }
        for (left, right) in zip(buttons, buttons.dropFirst()) {
            XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX,
                                     "Header controls must not overlap and must keep their order")
        }
    }

    private func assertLobbyConfirmation() {
        assertConfirmation(
            title: "Вернуть всех в лобби?",
            message: "Текущая игра прервётся. Все игроки вернутся в лобби этой комнаты.",
            confirmLabel: "ВЕРНУТЬСЯ В ЛОББИ"
        )
    }

    private func assertConfirmation(title: String, message: String, confirmLabel: String) {
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts[confirmationID + ".title"].label, title)
        XCTAssertEqual(app.staticTexts[confirmationID + ".message"].label, message)
        XCTAssertEqual(app.buttons[confirmationID + ".confirm"].label, confirmLabel)
        XCTAssertEqual(app.buttons[confirmationID + ".cancel"].label, "ОТМЕНА")
        for suffix in ["cancel", "confirm"] {
            let button = app.buttons[confirmationID + "." + suffix]
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(app.frame.contains(button.frame))
        }
    }

    private func cancelConfirmation() {
        app.buttons[confirmationID + ".cancel"].tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: confirmation
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func waitForLabel(_ label: String, on element: XCUIElement) {
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
    }

    private func assertUnsubmittedBallot() {
        for target in ["player", "no_spies", "all_spies"] {
            let choice = app.buttons["fanMode.vote.\(target)"]
            XCTAssertTrue(choice.exists)
            XCTAssertTrue(choice.isEnabled)
            XCTAssertFalse(choice.isSelected)
        }
        XCTAssertFalse(app.buttons["onlineRoom.leave"].exists,
                       "Cancelling a confirmation must keep the active game")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
