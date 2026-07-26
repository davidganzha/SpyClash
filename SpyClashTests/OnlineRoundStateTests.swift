import Foundation
import XCTest
@testable import SpyClash

final class OnlineRoundStateTests: XCTestCase {
    func testQuestionAskerConfirmsBeforeAdvance() {
        var room = GameRoom.previewRoom(status: "playing")
        room.questionPhase = "asking"

        XCTAssertEqual(
            room.onlineRoundCommand(
                for: room.currentAskerEmail,
                isHost: true,
                isTransitioning: false
            ),
            .markAnswerHeard
        )
        XCTAssertNil(
            room.onlineRoundCommand(
                for: room.currentAnswererEmail,
                isHost: false,
                isTransitioning: false
            )
        )
    }

    func testCountdownUsesServerTimestampAndOnlyAskerAdvances() {
        var room = GameRoom.previewRoom(status: "playing")
        let startedAt = Date(timeIntervalSince1970: 1_000)
        room.questionPhase = "countdown"
        room.countdownStartedAt = ISO8601DateFormatter().string(from: startedAt)

        XCTAssertEqual(room.countdownRemaining(at: startedAt.addingTimeInterval(2)), 3, accuracy: 0.001)
        XCTAssertTrue(
            room.shouldAdvanceQuestionAfterCountdown(
                for: room.currentAskerEmail,
                at: startedAt.addingTimeInterval(5)
            )
        )
        XCTAssertFalse(
            room.shouldAdvanceQuestionAfterCountdown(
                for: room.currentAnswererEmail,
                at: startedAt.addingTimeInterval(5)
            )
        )
    }

    func testResultsCanContinueFromAnyAuthenticatedPlayer() {
        var room = GameRoom.previewRoom(status: "playing")
        room.questionPhase = "results"
        let participant = try! XCTUnwrap(room.playersList.last)

        XCTAssertEqual(
            room.onlineRoundCommand(
                for: participant.email.uppercased(),
                isHost: false,
                isTransitioning: false
            ),
            .continueRound
        )
    }

    func testAssociationStateAndCommandsMatchServerContract() throws {
        var room = GameRoom.previewRoom(status: "playing")
        room.gameMode = "associations"
        room.currentAskerEmail = nil
        room.currentAnswer = AssociationRoundState.idle.encodedValue

        XCTAssertEqual(
            room.onlineRoundCommand(
                for: room.hostEmail,
                isHost: true,
                isTransitioning: false
            ),
            .startAssociation
        )

        let speaker = try XCTUnwrap(room.playersList.last)
        room.currentAskerEmail = speaker.email
        room.currentAnswer = AssociationRoundState(spoken: [room.playersList[0].email], spinning: false).encodedValue
        XCTAssertEqual(room.associationRoundState.spoken, [room.playersList[0].email])
        XCTAssertEqual(
            room.onlineRoundCommand(
                for: speaker.email,
                isHost: false,
                isTransitioning: false
            ),
            .advanceAssociation
        )

        room.currentAnswer = AssociationRoundState(spoken: [], spinning: true).encodedValue
        XCTAssertNil(
            room.onlineRoundCommand(
                for: speaker.email,
                isHost: false,
                isTransitioning: false
            )
        )
        XCTAssertTrue(room.canStopAssociationSpin(for: speaker.email, isHost: false))
    }

    func testMalformedLegacyAssociationStateFallsBackToIdle() {
        var room = GameRoom.previewRoom(status: "playing")
        room.gameMode = "associations"
        room.currentAnswer = "legacy free-form answer"

        XCTAssertEqual(room.associationRoundState, .idle)
    }

    func testRoomRefreshFailureTrackerWarnsOnceAndRecoversOnce() {
        var tracker = RoomRefreshFailureTracker()

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertTrue(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertEqual(tracker.consecutiveFailures, 4)

        XCTAssertTrue(tracker.recordSuccess())
        XCTAssertFalse(tracker.recordSuccess())
        XCTAssertEqual(tracker.consecutiveFailures, 0)

        XCTAssertFalse(tracker.recordFailure())
        XCTAssertFalse(tracker.recordFailure())
        XCTAssertTrue(tracker.recordFailure())
    }
}
