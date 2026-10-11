import Foundation
import XCTest
@testable import SpyClash

final class AcquisitionSurveyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: AcquisitionSurveyStore!

    override func setUpWithError() throws {
        suiteName = "AcquisitionSurveyTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        store = AcquisitionSurveyStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
    }

    func testSurveyWaitsForThreeDistinctCompletedGamesAndCapsStorage() {
        XCTAssertFalse(store.isEligible(for: "player", remoteSource: nil))
        XCTAssertTrue(store.recordCompletedGame(id: "local:1", for: "player"))
        XCTAssertFalse(store.recordCompletedGame(id: "local:1", for: "player"))
        XCTAssertTrue(store.recordCompletedGame(id: "online:2", for: "player"))
        XCTAssertEqual(store.completedGameCount(for: "player"), 2)
        XCTAssertFalse(store.isEligible(for: "player", remoteSource: nil))

        XCTAssertTrue(store.recordCompletedGame(id: "online:3", for: "player"))
        XCTAssertTrue(store.isEligible(for: "player", remoteSource: nil))
        for index in 4...100 {
            XCTAssertFalse(store.recordCompletedGame(id: "online:\(index)", for: "player"))
        }
        XCTAssertEqual(store.completedGameCount(for: "player"), 3)
    }

    func testProgressPresentationAndPendingAnswerAreAccountScoped() {
        completeThreeGames(for: "player-a")
        store.recordCompletedGame(id: "local:1", for: "player-b")
        store.markPresented(for: "player-a")
        store.saveAnswer(source: .friendsOrFamily, for: "player-a")

        XCTAssertEqual(store.completedGameCount(for: "player-b"), 1)
        XCTAssertNil(store.pendingAnswer(for: "player-b"))
        completeThreeGames(for: "player-b")
        XCTAssertTrue(store.isEligible(for: "player-b", remoteSource: nil))
        XCTAssertFalse(store.isEligible(for: "player-a", remoteSource: nil))
    }

    func testCompletedProgressSurvivesRecreatingDefaultsAndStore() throws {
        store.recordCompletedGame(id: "online:1", for: "player")
        store.recordCompletedGame(id: "online:2", for: "player")

        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restoredStore = AcquisitionSurveyStore(defaults: restoredDefaults)
        XCTAssertEqual(restoredStore.completedGameCount(for: "player"), 2)
        XCTAssertFalse(restoredStore.recordCompletedGame(id: "online:1", for: "player"))
        restoredStore.recordCompletedGame(id: "local:3", for: "player")
        XCTAssertTrue(restoredStore.isEligible(for: "player", remoteSource: nil))
    }

    func testSkippingAfterPresentationNeverCreatesAnswerOrRepeatsSurvey() throws {
        completeThreeGames(for: "player")
        store.markPresented(for: "player")

        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restoredStore = AcquisitionSurveyStore(defaults: restoredDefaults)
        XCTAssertNil(restoredStore.pendingAnswer(for: "player"))
        XCTAssertFalse(restoredStore.isEligible(for: "player", remoteSource: nil))
        restoredStore.recordCompletedGame(id: "later-game", for: "player")
        XCTAssertFalse(restoredStore.isEligible(for: "player", remoteSource: nil))
    }

    func testPendingAnswerSurvivesRelaunchUntilMatchingAcknowledgement() throws {
        completeThreeGames(for: "player")
        store.saveAnswer(source: .socialMedia, for: "player")

        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restoredStore = AcquisitionSurveyStore(defaults: restoredDefaults)
        XCTAssertEqual(restoredStore.pendingAnswer(for: "player"), .socialMedia)
        XCTAssertFalse(restoredStore.isEligible(for: "player", remoteSource: nil))
        restoredStore.markSynced(source: .socialMedia, for: "player")
        XCTAssertNil(store.pendingAnswer(for: "player"))
        XCTAssertFalse(store.isEligible(for: "player", remoteSource: nil))
    }

    func testStaleAcknowledgementDoesNotDeleteNewerAnswerOrOtherAccountsAnswer() {
        store.saveAnswer(source: .webSearch, for: "player-a")
        store.saveAnswer(source: .friendsOrFamily, for: "player-a")
        store.saveAnswer(source: .webSearch, for: "player-b")

        store.markSynced(source: .webSearch, for: "player-a")
        XCTAssertEqual(store.pendingAnswer(for: "player-a"), .friendsOrFamily)
        XCTAssertEqual(store.pendingAnswer(for: "player-b"), .webSearch)

        store.markSynced(source: .friendsOrFamily, for: "player-a")
        XCTAssertNil(store.pendingAnswer(for: "player-a"))
        XCTAssertEqual(store.pendingAnswer(for: "player-b"), .webSearch)
    }

    func testExistingRemoteAnswerSuppressesSurveyWithoutDiscardingPendingAnswer() {
        completeThreeGames(for: "player")
        XCTAssertFalse(store.isEligible(for: "player", remoteSource: "friends_or_family"))
        XCTAssertFalse(store.isEligible(for: "player", remoteSource: "unknown_future_source"))
        XCTAssertTrue(store.isEligible(for: "player", remoteSource: " \n "))

        store.saveAnswer(source: .socialMedia, for: "player")
        XCTAssertFalse(store.isEligible(for: "player", remoteSource: "web_search"))
        XCTAssertEqual(store.pendingAnswer(for: "player"), .socialMedia)
    }

    func testBlankIdentitiesAreIgnoredAndWhitespaceDoesNotBypassDeduplication() {
        XCTAssertFalse(store.recordCompletedGame(id: " \n ", for: "player"))
        XCTAssertFalse(store.recordCompletedGame(id: "match", for: " \n "))
        XCTAssertTrue(store.recordCompletedGame(id: " match \n", for: " player "))
        XCTAssertFalse(store.recordCompletedGame(id: "match", for: "player"))
        XCTAssertEqual(store.completedGameCount(for: "player"), 1)

        store.markPresented(for: " ")
        store.saveAnswer(source: .other, for: " ")
        XCTAssertEqual(store.completedGameCount(for: " "), 0)
        XCTAssertNil(store.pendingAnswer(for: " "))
        XCTAssertFalse(store.isEligible(for: " ", remoteSource: nil))
    }

    func testClearRemovesOnlyRequestedAccountsProgressAndPendingAnswer() {
        completeThreeGames(for: "player-a")
        completeThreeGames(for: "player-b")
        store.saveAnswer(source: .webSearch, for: "player-a")
        store.saveAnswer(source: .socialMedia, for: "player-b")

        store.clear(for: "player-a")
        XCTAssertEqual(store.completedGameCount(for: "player-a"), 0)
        XCTAssertNil(store.pendingAnswer(for: "player-a"))
        XCTAssertFalse(store.isEligible(for: "player-a", remoteSource: nil))
        completeThreeGames(for: "player-a")
        XCTAssertTrue(store.isEligible(for: "player-a", remoteSource: nil))
        XCTAssertEqual(store.completedGameCount(for: "player-b"), 3)
        XCTAssertEqual(store.pendingAnswer(for: "player-b"), .socialMedia)
    }

    private func completeThreeGames(for userID: String) {
        for index in 1...3 {
            store.recordCompletedGame(id: "local:\(index)", for: userID)
        }
    }
}
