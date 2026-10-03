import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class AcquisitionSurveyIntegrationTests: XCTestCase {
    func testActiveRoomUpdatesCountThreeDistinctFinishedMatchesOnlyOnce() throws {
        let user = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user]) }
        var room = try makeRoom(for: user)

        for count in 1...AcquisitionSurveyStore.requiredCompletedGames {
            // Rematches share the room but have a new match identity.
            room.matchID = UUID().uuidString
            state.activeRoom = room
            XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), count)
            XCTAssertFalse(state.canPresentAcquisitionSurvey, "Never interrupt the results screen.")

            state.activeRoom = room
            XCTAssertEqual(
                state.acquisitionSurveyStore.completedGameCount(for: user.id), count,
                "A repeated room snapshot must not count another completed game."
            )
            state.activeRoom = nil
            XCTAssertEqual(state.canPresentAcquisitionSurvey, count == 3)
        }

        state.activeRoom = room
        state.activeRoom = nil
        XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), 3)
    }

    func testUnfinishedIncompleteAndNonmemberOnlineMatchesDoNotCount() throws {
        let user = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user]) }
        let finished = try makeRoom(for: user)

        var waiting = finished
        waiting.status = "waiting"
        var playing = finished
        playing.status = "playing"
        var missingMatch = finished
        missingMatch.matchID = nil
        var blankMatch = finished
        blankMatch.matchID = " \n "
        var missingWinner = finished
        missingWinner.winner = nil
        var unknownWinner = finished
        unknownWinner.winner = "cancelled"
        var nonmember = finished
        nonmember.players = [Player(email: "another@example.test", name: "Another", avatar: "🕵️")]

        state.recordCompletedOnlineGameForAcquisitionSurvey(nil)
        for room in [waiting, playing, missingMatch, blankMatch, missingWinner, unknownWinner, nonmember] {
            state.recordCompletedOnlineGameForAcquisitionSurvey(room)
            XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), 0)
        }

        var normalizedMember = finished
        normalizedMember.status = "FINISHED"
        normalizedMember.winner = "DETECTIVES"
        normalizedMember.players = [Player(
            email: " \(user.email.uppercased())\n", name: "Player", avatar: "🕵️"
        )]
        state.recordCompletedOnlineGameForAcquisitionSurvey(normalizedMember)
        XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), 1)
    }

    func testLocalCompletionRejectsWrongAccountAndIncompleteOnboarding() throws {
        let user = try makeUser()
        let otherUser = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user, otherUser]) }

        state.recordCompletedGameForAcquisitionSurvey(id: "local:stale-game", userID: otherUser.id)
        XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), 0)
        XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: otherUser.id), 0)

        var onboardingUser = user
        onboardingUser.onboardingCompleted = false
        state.user = onboardingUser
        state.recordCompletedGameForAcquisitionSurvey(id: "local:before-onboarding", userID: user.id)
        XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), 0)

        state.user = user
        state.recordCompletedGameForAcquisitionSurvey(id: "local:completed", userID: user.id)
        state.recordCompletedGameForAcquisitionSurvey(id: "local:completed", userID: user.id)
        XCTAssertEqual(state.acquisitionSurveyStore.completedGameCount(for: user.id), 1)
    }

    func testPresentationRequiresIdleHomeAfterOnboarding() throws {
        let user = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user]) }
        completeThreeLocalGames(in: state, for: user)
        XCTAssertTrue(state.canPresentAcquisitionSurvey)

        state.selectedTab = .game
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.selectedTab = .home
        XCTAssertTrue(state.canPresentAcquisitionSurvey)

        state.activeRoom = try makeRoom(for: user, status: "waiting")
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.activeRoom = nil
        XCTAssertTrue(state.canPresentAcquisitionSurvey)

        var onboardingUser = user
        onboardingUser.onboardingCompleted = false
        state.user = onboardingUser
        XCTAssertTrue(state.requiresOnboarding)
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.user = user
        XCTAssertTrue(state.canPresentAcquisitionSurvey)

        state.presentedSheet = .settings
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.presentedSheet = nil
        state.shellRoute = .notifications
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.shellRoute = .main
        state.isBusy = true
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.isBusy = false
        state.pendingJoinCode = "JOINME"
        XCTAssertFalse(state.canPresentAcquisitionSurvey, "An incoming room route takes priority over the survey.")
        state.pendingJoinCode = nil
        state.isRestoring = true
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        state.isRestoring = false
        XCTAssertTrue(state.canPresentAcquisitionSurvey)
    }

    func testPresentationClaimIsAccountScopedAndSucceedsOnlyOnce() throws {
        let user = try makeUser()
        let otherUser = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user, otherUser]) }
        completeThreeLocalGames(in: state, for: user)

        XCTAssertFalse(state.claimAcquisitionSurveyPresentation(for: otherUser.id))
        XCTAssertTrue(state.canPresentAcquisitionSurvey)
        XCTAssertTrue(state.claimAcquisitionSurveyPresentation(for: user.id))
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        XCTAssertFalse(state.claimAcquisitionSurveyPresentation(for: user.id))
        XCTAssertNil(state.acquisitionSurveyStore.pendingAnswer(for: user.id))

        state.user = otherUser
        completeThreeLocalGames(in: state, for: otherUser)
        XCTAssertTrue(state.canPresentAcquisitionSurvey)
        XCTAssertTrue(state.claimAcquisitionSurveyPresentation(for: otherUser.id))
        state.user = user
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
        XCTAssertFalse(state.claimAcquisitionSurveyPresentation(for: user.id))
    }

    func testAnswerFromDismissedPreviousAccountSurveyIsIgnored() throws {
        let user = try makeUser()
        let replacement = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user, replacement]) }
        completeThreeLocalGames(in: state, for: user)
        XCTAssertTrue(state.claimAcquisitionSurveyPresentation(for: user.id))

        state.user = replacement
        state.answerAcquisitionSurvey(.socialMedia, userID: user.id)

        XCTAssertEqual(state.user?.id, replacement.id)
        XCTAssertNil(state.user?.acquisitionSource)
        XCTAssertNil(state.acquisitionSurveyStore.pendingAnswer(for: user.id))
        XCTAssertNil(state.acquisitionSurveyStore.pendingAnswer(for: replacement.id))
        XCTAssertNil(state.acquisitionSurveySyncTask)
    }

    func testPendingOfflineAnswersSurviveAccountSwitchWithoutCrossAccountSync() throws {
        let user = try makeUser()
        let replacement = try makeUser()
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user, replacement]) }
        XCTAssertFalse(state.client.hasSessionToken)

        state.answerAcquisitionSurvey(.friendsOrFamily, userID: user.id)
        XCTAssertEqual(state.acquisitionSurveyStore.pendingAnswer(for: user.id), .friendsOrFamily)
        XCTAssertNil(state.acquisitionSurveySyncTask)
        XCTAssertNil(state.user?.acquisitionSource, "An offline answer is not a server acknowledgement.")

        state.user = replacement
        state.queuePendingAcquisitionSurveySync()
        XCTAssertNil(state.acquisitionSurveyStore.pendingAnswer(for: replacement.id))
        XCTAssertNil(state.acquisitionSurveySyncTask)
        state.answerAcquisitionSurvey(.webSearch, userID: replacement.id)

        state.user = user
        state.queuePendingAcquisitionSurveySync()
        XCTAssertEqual(state.acquisitionSurveyStore.pendingAnswer(for: user.id), .friendsOrFamily)
        XCTAssertEqual(state.acquisitionSurveyStore.pendingAnswer(for: replacement.id), .webSearch)
        XCTAssertNil(state.acquisitionSurveySyncTask)
        XCTAssertNil(state.acquisitionSurveySyncID)
        XCTAssertFalse(state.canPresentAcquisitionSurvey)
    }

    func testRadarUpgradeRetainsPendingVersionOneSourceWhenCompletionIsDeferred() async throws {
        var user = try makeUser()
        user.onboardingCompleted = nil
        user.onboardingVersion = nil
        let state = makeState(user: user)
        defer { cleanUp(state, users: [user]) }
        OnboardingProgressStore.savePending(OnboardingSubmission(
            language: .ru,
            acquisitionSource: .friendsOrFamily,
            version: 1
        ), for: user.id)

        XCTAssertTrue(state.requiresLocalNetworkOnboardingUpgrade)
        XCTAssertEqual(state.preservedOnboardingAcquisitionSource, .friendsOrFamily)

        // A fake token reaches the injected offline transport. The real
        // completion path must replace pending v1 with v2 without losing its answer.
        state.client.setToken("acquisition-survey-offline-test-token")
        await state.finishOnboarding()

        let migrated = try XCTUnwrap(OnboardingProgressStore.pendingSubmission(for: user.id))
        XCTAssertEqual(migrated.version, OnboardingSubmission.currentVersion)
        XCTAssertEqual(migrated.acquisitionSource, .friendsOrFamily)
        XCTAssertEqual(state.preservedOnboardingAcquisitionSource, .friendsOrFamily)
        XCTAssertFalse(state.requiresOnboarding)
        XCTAssertNil(state.user?.acquisitionSource, "Offline migration must not claim a remote acknowledgement.")
    }

    private func makeState(user: SpyUser) -> AppState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AcquisitionSurveyNoNetworkURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.clearToken()
        let state = AppState(
            client: client,
            readStoredToken: { nil },
            saveStoredToken: { _ in },
            clearStoredToken: {}
        )
        state.isRestoring = false
        state.user = user
        return state
    }

    private func makeUser() throws -> SpyUser {
        let id = "acquisition-integration-\(UUID().uuidString)"
        return try JSONDecoder().decode(SpyUser.self, from: JSONSerialization.data(withJSONObject: [
            "id": id,
            "email": "\(id)@example.test",
            "onboarding_completed": true,
            "onboarding_version": OnboardingSubmission.currentVersion
        ]))
    }

    private func makeRoom(for user: SpyUser, status: String = "finished") throws -> GameRoom {
        try JSONDecoder().decode(GameRoom.self, from: JSONSerialization.data(withJSONObject: [
            "id": "acquisition-room-\(UUID().uuidString)",
            "code": "SURVEY",
            "host_email": user.email,
            "match_id": UUID().uuidString,
            "status": status,
            "winner": "detectives",
            "players": [["email": user.email, "name": "Player", "avatar": "🕵️"]]
        ]))
    }

    private func completeThreeLocalGames(in state: AppState, for user: SpyUser) {
        for index in 1...AcquisitionSurveyStore.requiredCompletedGames {
            state.recordCompletedGameForAcquisitionSurvey(id: "local:\(index)", userID: user.id)
        }
    }

    private func cleanUp(_ state: AppState, users: [SpyUser]) {
        state.setRadarApplicationActive(false)
        state.logout()
        for user in users {
            state.acquisitionSurveyStore.clear(for: user.id)
            OnboardingProgressStore.clear(for: user.id)
        }
    }
}

private final class AcquisitionSurveyNoNetworkURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
