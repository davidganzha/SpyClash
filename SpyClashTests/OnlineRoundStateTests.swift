import Foundation
import AVFoundation
import XCTest
@testable import SpyClash

final class OnlineRoundStateTests: XCTestCase {
    func testConfirmedPlayerCanReopenRoleCardWhileWaitingForOthers() {
        XCTAssertTrue(
            OnlineRoleRevealInteractionPolicy.canToggleRoleCard(
                isConfirmed: true,
                isConfirming: false
            )
        )
    }

    func testRoleCardDoesNotToggleWhileConfirmationIsInFlight() {
        XCTAssertFalse(
            OnlineRoleRevealInteractionPolicy.canToggleRoleCard(
                isConfirmed: false,
                isConfirming: true
            )
        )
    }

    func testPreviewRoomUsesCurrentSixCharacterRoomCodeContract() {
        let room = GameRoom.previewRoom(status: "waiting")

        XCTAssertEqual(room.code.count, 6)
        XCTAssertTrue(room.code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

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

    func testLegacyCountdownAdvancesImmediatelyAndOnlyAskerAdvances() {
        var room = GameRoom.previewRoom(status: "playing")
        let startedAt = Date(timeIntervalSince1970: 1_000)
        room.questionPhase = "countdown"
        room.countdownStartedAt = ISO8601DateFormatter().string(from: startedAt)

        XCTAssertEqual(room.countdownRemaining(at: startedAt.addingTimeInterval(2)), 0, accuracy: 0.001)
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
        XCTAssertEqual(room.associationSpinSettlementDelay(for: speaker.email), 0.5)
        XCTAssertTrue(
            room.canStopAssociationSpin(
                for: room.playersList[0].email,
                isHost: false
            ),
            "Every active client must be able to recover a stuck spin."
        )
        XCTAssertEqual(room.associationSpinSettlementDelay(for: room.playersList[0].email), 1.0)
        XCTAssertEqual(room.associationSpinSettlementDelay(for: room.playersList[1].email), 1.5)
        XCTAssertFalse(room.canStopAssociationSpin(for: "outside@example.com", isHost: false))
        XCTAssertNil(room.associationSpinSettlementDelay(for: "outside@example.com"))

        room.spectators = [room.playersList[0].email]
        XCTAssertFalse(
            room.canStopAssociationSpin(
                for: room.playersList[0].email,
                isHost: true
            ),
            "Spectators cannot mutate the round."
        )
        XCTAssertNil(room.associationSpinSettlementDelay(for: room.playersList[0].email))
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

    func testRoomMonitorDiscardsInFlightSnapshotWithoutStoppingDuringLocalOperation() {
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: true,
                fetchedRoomExists: true
            ),
            .discardAndContinue
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: false,
                isLatestRefreshRequest: false,
                fetchedRoomExists: true
            ),
            .discardAndContinue
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-2",
                isCancelled: false,
                hasActiveOperation: false,
                fetchedRoomExists: true
            ),
            .stop
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: false,
                fetchedRoomExists: false
            ),
            .close
        )
        XCTAssertEqual(
            RoomPollPolicy.disposition(
                monitoredRoomID: "room-1",
                activeRoomID: "room-1",
                isCancelled: false,
                hasActiveOperation: false,
                didRoomSyncRevisionChange: true,
                fetchedRoomExists: true
            ),
            .discardAndContinue
        )
    }

    func testRoomPollPolicyUsesRealtimeFallbackCadenceAndBoundedFailureBackoff() {
        XCTAssertEqual(
            RoomPollPolicy.delaySeconds(
                roomStatus: "waiting",
                consecutiveFailures: 0,
                isApplicationActive: true
            ),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RoomPollPolicy.delaySeconds(
                roomStatus: "playing",
                consecutiveFailures: 0,
                isApplicationActive: true
            ),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 1, isApplicationActive: true), 16)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 2, isApplicationActive: true), 30)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 8, isApplicationActive: true), 30)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 0, isApplicationActive: false), 20)
    }

    func testRoomPollPolicyRejectsLobbySnapshotOlderThanCurrentRevision() {
        XCTAssertFalse(
            RoomPollPolicy.acceptsSnapshot(
                currentLobbyRevision: 9,
                fetchedLobbyRevision: 8
            )
        )
        XCTAssertTrue(
            RoomPollPolicy.acceptsSnapshot(
                currentLobbyRevision: 9,
                fetchedLobbyRevision: 9
            )
        )
        XCTAssertTrue(
            RoomPollPolicy.acceptsSnapshot(
                currentLobbyRevision: nil,
                fetchedLobbyRevision: nil
            )
        )
    }
}

final class ShellSupplementaryRefreshPolicyTests: XCTestCase {
    func testSupplementaryNetworkTrafficStopsForRealtimeGameplay() {
        XCTAssertFalse(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: "roulette")
        )
        XCTAssertFalse(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: "PLAYING")
        )
        XCTAssertTrue(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: "waiting")
        )
        XCTAssertTrue(
            ShellSupplementaryRefreshPolicy.shouldRun(activeRoomStatus: nil)
        )
    }
}

final class LobbyLatestWinsStateTests: XCTestCase {
    func testNewDurationIntentDoesNotWaitForPriorRequestToFinish() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 4)
        state.enqueue(roomID: "room-1", state: payload(duration: 480))
        let first = try XCTUnwrap(state.beginNext())

        state.enqueue(roomID: "room-1", state: payload(duration: 720))

        XCTAssertTrue(state.hasOptimisticChanges)
        XCTAssertFalse(state.finish(first, confirmedRevision: 5))
        let second = try XCTUnwrap(state.beginNext())
        XCTAssertEqual(second.expectedRevision, 5)
        XCTAssertEqual(second.intent.state.gameDurationSeconds, 720)
        XCTAssertTrue(state.finish(second, confirmedRevision: 6))
        XCTAssertFalse(state.hasOptimisticChanges)
    }

    func testSuccessfulRequestRecordsServerConfirmedMutation() throws {
        var state = LobbyLatestWinsState()
        let mutationID = UUID()
        state.reset(confirmedRevision: 4)
        state.enqueue(
            roomID: "room-1",
            state: payload(duration: 480),
            mutationID: mutationID
        )
        let request = try XCTUnwrap(state.beginNext())

        XCTAssertTrue(state.finish(request, confirmedRevision: 5))
        XCTAssertEqual(state.lastServerConfirmedMutationID, mutationID)
    }

    func testFailedRequestDoesNotRecordServerConfirmation() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 4)
        state.enqueue(roomID: "room-1", state: payload(duration: 480))
        let request = try XCTUnwrap(state.beginNext())

        XCTAssertFalse(state.fail(request, retry: false))
        XCTAssertNil(state.lastServerConfirmedMutationID)
    }

    func testUnadvancedRevisionDoesNotRecordServerConfirmation() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 4)
        state.enqueue(roomID: "room-1", state: payload(duration: 480))
        let request = try XCTUnwrap(state.beginNext())

        XCTAssertFalse(state.finish(request, confirmedRevision: 4))
        XCTAssertFalse(state.hasOptimisticChanges)
        XCTAssertNil(state.lastServerConfirmedMutationID)
    }

    func testRecoveredCommittedRequestRecordsServerConfirmation() throws {
        var state = LobbyLatestWinsState()
        let mutationID = UUID()
        state.reset(confirmedRevision: 4)
        state.enqueue(
            roomID: "room-1",
            state: payload(duration: 480),
            mutationID: mutationID
        )
        let request = try XCTUnwrap(state.beginNext())
        _ = state.fail(request, retry: false)

        XCTAssertTrue(
            state.recordRecoveredServerConfirmation(
                request,
                confirmedRevision: 5
            )
        )
        XCTAssertEqual(state.lastServerConfirmedMutationID, mutationID)
    }

    func testPendingIntentCoalescesToLatestModeAndDuration() throws {
        var state = LobbyLatestWinsState()
        state.enqueue(roomID: "room-1", state: payload(duration: 300))
        state.enqueue(
            roomID: "room-1",
            state: payload(duration: 600, mode: .associations)
        )

        let request = try XCTUnwrap(state.beginNext())
        XCTAssertEqual(request.intent.state.gameDurationSeconds, 600)
        XCTAssertEqual(request.intent.state.gameMode, .associations)
    }

    func testIdenticalLatestPayloadIsRecognizedWithoutCreatingRevisionChurn() throws {
        var state = LobbyLatestWinsState()
        let current = payload(duration: 300)

        state.enqueue(roomID: "room-1", state: current)
        XCTAssertTrue(state.latestStateMatches(roomID: "room-1", state: current))

        _ = try XCTUnwrap(state.beginNext())
        XCTAssertTrue(state.latestStateMatches(roomID: "room-1", state: current))
        XCTAssertFalse(
            state.latestStateMatches(
                roomID: "room-1",
                state: payload(duration: 360)
            )
        )
    }

    func testConflictRetryKeepsMutationIdentityAndUsesFreshRevision() throws {
        var state = LobbyLatestWinsState()
        state.reset(confirmedRevision: 7)
        state.enqueue(roomID: "room-1", state: payload(duration: 360))
        let first = try XCTUnwrap(state.beginNext())

        XCTAssertTrue(state.fail(first, retry: true))
        state.reconcile(confirmedRevision: 9)
        let retry = try XCTUnwrap(state.beginNext())

        XCTAssertEqual(retry.intent.mutationID, first.intent.mutationID)
        XCTAssertEqual(retry.expectedRevision, 9)
        XCTAssertEqual(retry.intent.retryCount, 1)
    }

    func testPendingIntentClearsWhenUserReturnsToConfirmedState() {
        var state = LobbyLatestWinsState()
        let confirmed = payload(duration: 300)

        XCTAssertTrue(
            state.enqueueLatest(
                roomID: "room-1",
                state: payload(duration: 600),
                confirmedState: confirmed
            )
        )
        XCTAssertFalse(
            state.enqueueLatest(
                roomID: "room-1",
                state: confirmed,
                confirmedState: confirmed
            )
        )
        XCTAssertFalse(state.hasOptimisticChanges)
    }

    func testReturningToInflightStateDropsNewerPendingIntent() throws {
        var state = LobbyLatestWinsState()
        let inflightState = payload(duration: 300)
        state.enqueue(roomID: "room-1", state: inflightState)
        _ = try XCTUnwrap(state.beginNext())

        _ = state.enqueueLatest(
            roomID: "room-1",
            state: payload(duration: 600),
            confirmedState: payload(duration: 900)
        )
        XCTAssertTrue(state.hasPendingIntent)

        XCTAssertFalse(
            state.enqueueLatest(
                roomID: "room-1",
                state: inflightState,
                confirmedState: payload(duration: 900)
            )
        )
        XCTAssertFalse(state.hasPendingIntent)
        XCTAssertTrue(state.hasOptimisticChanges)
    }

    func testServerWordIDsDoNotCreateSemanticLobbyChange() {
        var local = payload(duration: 300)
        local.lobbyWordSource = .manual
        local.lobbyWordCount = 2
        local.lobbyWordPool = [
            LobbyWordPoolEntry(word: "  Cafe\u{301}   Noir ", enabled: true),
            LobbyWordPoolEntry(word: "Cipher", enabled: false)
        ]
        var server = local
        server.lobbyWordPool = [
            LobbyWordPoolEntry(id: "lw_1", word: "Café Noir", enabled: true),
            LobbyWordPoolEntry(id: "lw_2", word: "Cipher", enabled: false)
        ]

        XCTAssertTrue(local.equivalentForLobbySync(to: server))
    }

    private func payload(
        duration: Int,
        mode: SpyGameMode = .questions
    ) -> LobbyStatePayload {
        LobbyStatePayload(
            gameMode: mode,
            gameDurationSeconds: duration,
            lobbyWordSource: .none,
            lobbySourcePackID: nil,
            lobbySourceName: nil,
            lobbyTheme: nil,
            lobbyCategory: nil,
            lobbyWordCount: 0,
            lobbyWordCountMode: .recommended,
            lobbyWordPool: []
        )
    }
}

final class LobbySyncFeedbackStateTests: XCTestCase {
    func testPendingThenConfirmedShowsServerConfirmation() {
        let mutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        XCTAssertEqual(state.phase, .syncing)

        state.update(snapshot(pending: false, confirmationID: mutationID))
        XCTAssertEqual(state.phase, .serverConfirmed(mutationID))
    }

    func testPendingThenFailureDoesNotShowConfirmation() {
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: false, confirmationID: nil))

        XCTAssertEqual(state.phase, .hidden)
    }

    func testNewEditReplacesConfirmationAndFailedEditDoesNotRestoreIt() {
        let firstMutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: false, confirmationID: firstMutationID))
        XCTAssertEqual(state.phase, .serverConfirmed(firstMutationID))

        state.update(snapshot(pending: true, confirmationID: firstMutationID))
        XCTAssertEqual(state.phase, .syncing)

        state.update(snapshot(pending: false, confirmationID: firstMutationID))
        XCTAssertEqual(state.phase, .hidden)
    }

    func testIntermediateConfirmationDoesNotBecomeSuccessAfterNewerEditFails() {
        let intermediateMutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: intermediateMutationID))
        state.update(snapshot(pending: false, confirmationID: intermediateMutationID))

        XCTAssertEqual(state.phase, .hidden)
    }

    func testOldDismissalCannotHideNewerServerConfirmation() {
        let firstMutationID = UUID()
        let secondMutationID = UUID()
        var state = LobbySyncFeedbackState()

        state.update(snapshot(pending: false, confirmationID: nil))
        state.update(snapshot(pending: true, confirmationID: nil))
        state.update(snapshot(pending: false, confirmationID: firstMutationID))
        state.update(snapshot(pending: true, confirmationID: firstMutationID))
        state.update(snapshot(pending: false, confirmationID: secondMutationID))

        state.dismissServerConfirmation(firstMutationID)

        XCTAssertEqual(state.phase, .serverConfirmed(secondMutationID))
    }

    private func snapshot(
        pending: Bool,
        confirmationID: UUID?
    ) -> LobbySyncFeedbackSnapshot {
        LobbySyncFeedbackSnapshot(
            roomID: "room-1",
            hasOptimisticChanges: pending,
            lastServerConfirmedMutationID: confirmationID
        )
    }
}

final class WaitingStartActionModeTests: XCTestCase {
    func testSyncSequenceBlocksStartUntilConfirmationDwellEnds() {
        let confirmationID = UUID()

        XCTAssertEqual(
            mode(feedbackPhase: .hidden),
            .action
        )
        XCTAssertEqual(
            mode(feedbackPhase: .syncing, hasOptimisticChanges: true),
            .syncing
        )
        XCTAssertEqual(
            mode(feedbackPhase: .serverConfirmed(confirmationID)),
            .serverConfirmed(confirmationID)
        )
        XCTAssertTrue(WaitingStartActionMode.syncing.blocksStart)
        XCTAssertTrue(WaitingStartActionMode.serverConfirmed(confirmationID).blocksStart)
        XCTAssertFalse(WaitingStartActionMode.action.blocksStart)
    }

    func testNewEditImmediatelyReplacesSavedStateWithSyncing() {
        let resolved = mode(
            feedbackPhase: .serverConfirmed(UUID()),
            isEditingLobbySlider: true
        )

        XCTAssertEqual(resolved, .syncing)
        XCTAssertTrue(resolved.blocksStart)
    }

    func testFailureReplacesStartAndRemainsBlocked() {
        let resolved = mode(
            feedbackPhase: .syncing,
            hasSyncFailure: true
        )

        XCTAssertEqual(resolved, .failed)
        XCTAssertTrue(resolved.blocksStart)
    }

    func testReadyLobbyWithoutAuthoritativeConfirmationShowsSyncing() {
        XCTAssertEqual(
            mode(
                feedbackPhase: .hidden,
                requiresServerConfirmation: true,
                isServerConfirmed: false
            ),
            .syncing
        )
        XCTAssertEqual(
            mode(
                feedbackPhase: .serverConfirmed(UUID()),
                requiresServerConfirmation: true,
                isServerConfirmed: false
            ),
            .syncing
        )
    }

    private func mode(
        feedbackPhase: LobbySyncFeedbackPhase,
        isEditingLobbySlider: Bool = false,
        hasOptimisticChanges: Bool = false,
        hasSyncFailure: Bool = false,
        requiresServerConfirmation: Bool = false,
        isServerConfirmed: Bool = true
    ) -> WaitingStartActionMode {
        WaitingStartActionMode.resolve(
            feedbackPhase: feedbackPhase,
            isEditingLobbySlider: isEditingLobbySlider,
            hasOptimisticChanges: hasOptimisticChanges,
            hasSyncFailure: hasSyncFailure,
            requiresServerConfirmation: requiresServerConfirmation,
            isServerConfirmed: isServerConfirmed
        )
    }
}

final class LobbyStartGateTests: XCTestCase {
    func testAvailableAppearanceRequiresAllStartPrerequisites() {
        XCTAssertFalse(
            LobbyStartGate.hasPrerequisites(
                playerCount: 2,
                isThemeSelectionReady: true,
                isGeneratingRoomTheme: false
            )
        )
        XCTAssertFalse(
            LobbyStartGate.hasPrerequisites(
                playerCount: 3,
                isThemeSelectionReady: false,
                isGeneratingRoomTheme: false
            )
        )
        XCTAssertFalse(
            LobbyStartGate.hasPrerequisites(
                playerCount: 3,
                isThemeSelectionReady: true,
                isGeneratingRoomTheme: true
            )
        )
        XCTAssertTrue(
            LobbyStartGate.hasPrerequisites(
                playerCount: 3,
                isThemeSelectionReady: true,
                isGeneratingRoomTheme: false
            )
        )
    }

    func testRequiresPositiveRevisionAndMatchingAuthoritativeState() {
        let confirmed = payload(duration: 600)

        XCTAssertFalse(isConfirmed(revision: 0, authoritative: confirmed, local: confirmed))
        XCTAssertTrue(isConfirmed(revision: 4, authoritative: confirmed, local: confirmed))
        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: payload(duration: 720)
            )
        )
    }

    func testEditingPendingAndFailureEachBlockStart() {
        let confirmed = payload(duration: 600)

        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: confirmed,
                isEditingLobbySlider: true
            )
        )
        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: confirmed,
                hasOptimisticChanges: true
            )
        )
        XCTAssertFalse(
            isConfirmed(
                revision: 4,
                authoritative: confirmed,
                local: confirmed,
                hasSyncFailure: true
            )
        )
    }

    private func isConfirmed(
        revision: Int,
        authoritative: LobbyStatePayload?,
        local: LobbyStatePayload,
        isEditingLobbySlider: Bool = false,
        hasOptimisticChanges: Bool = false,
        hasSyncFailure: Bool = false
    ) -> Bool {
        LobbyStartGate.isServerConfirmed(
            roomRevision: revision,
            authoritativeState: authoritative,
            localState: local,
            hasOptimisticChanges: hasOptimisticChanges,
            hasSyncFailure: hasSyncFailure,
            isEditingLobbySlider: isEditingLobbySlider
        )
    }

    private func payload(duration: Int) -> LobbyStatePayload {
        LobbyStatePayload(
            gameMode: .questions,
            gameDurationSeconds: duration,
            lobbyWordSource: .manual,
            lobbySourcePackID: nil,
            lobbySourceName: "Manual",
            lobbyTheme: "Cities",
            lobbyCategory: "Cities",
            lobbyWordCount: 2,
            lobbyWordCountMode: .custom,
            lobbyWordPool: [
                LobbyWordPoolEntry(word: "Kyiv", enabled: true),
                LobbyWordPoolEntry(word: "London", enabled: true)
            ]
        )
    }
}

final class LobbyPresentationPolicyTests: XCTestCase {
    func testPoolPreviewIsHiddenOnlyWhenTotalPoolIsEmpty() {
        XCTAssertFalse(
            LobbyPresentationPolicy.shouldShowPoolPreview(totalWordCount: 0)
        )
        XCTAssertTrue(
            LobbyPresentationPolicy.shouldShowPoolPreview(totalWordCount: 4)
        )
    }

    func testOnlyNewRemoteGuestRevisionAnimates() {
        XCTAssertTrue(
            shouldAnimate(appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(isHost: true, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(reduceMotion: true, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(isConfiguredRoom: false, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(isEditingLobbySlider: true, appliedRevision: 7, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(appliedRevision: -1, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(appliedRevision: 8, incomingRevision: 8)
        )
        XCTAssertFalse(
            shouldAnimate(appliedRevision: 9, incomingRevision: 8)
        )
    }

    func testAnyActiveSliderDefersWholeAuthoritativeSnapshot() {
        XCTAssertFalse(
            LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
                isDraggingDuration: false,
                isDraggingWordCount: false
            )
        )
        XCTAssertTrue(
            LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
                isDraggingDuration: true,
                isDraggingWordCount: false
            )
        )
        XCTAssertTrue(
            LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
                isDraggingDuration: false,
                isDraggingWordCount: true
            )
        )
    }

    func testDeferredAuthoritativeUpdateLatchesForcedRollbackUntilApplied() {
        var deferred = DeferredLobbyUpdateState()

        deferred.record(force: false)
        XCTAssertTrue(deferred.isPending)
        XCTAssertFalse(deferred.requiresForce)

        deferred.record(force: true)
        XCTAssertTrue(deferred.isPending)
        XCTAssertTrue(deferred.requiresForce)

        deferred.record(force: false)
        XCTAssertTrue(deferred.requiresForce)

        deferred.clear()
        XCTAssertFalse(deferred.isPending)
        XCTAssertFalse(deferred.requiresForce)
    }

    func testUnrelatedModeAndDurationUpdateDoesNotCollapseExpandedPool() {
        let original = payload(
            mode: .questions,
            duration: 300,
            theme: "Cities"
        )
        let settingsOnlyUpdate = payload(
            mode: .associations,
            duration: 600,
            theme: "Cities"
        )
        let differentPool = payload(
            mode: .associations,
            duration: 600,
            theme: "Marvel"
        )

        XCTAssertFalse(shouldResetExpandedPool(from: original, to: settingsOnlyUpdate))
        XCTAssertTrue(shouldResetExpandedPool(from: original, to: differentPool))
    }

    func testPoolExpansionStaysOpenButSameThemeReplacementCollapses() {
        let original = payload(
            mode: .questions,
            duration: 300,
            theme: "Cities"
        )
        var expanded = original
        expanded.lobbyWordPool.append(
            LobbyWordPoolEntry(word: "Bratislava", enabled: true)
        )
        var replacement = original
        replacement.lobbyWordPool = [
            LobbyWordPoolEntry(word: "Paris", enabled: true),
            LobbyWordPoolEntry(word: "Madrid", enabled: true)
        ]

        XCTAssertFalse(shouldResetExpandedPool(from: original, to: expanded))
        XCTAssertTrue(shouldResetExpandedPool(from: original, to: replacement))
    }

    func testSavedPackAndGeneratedSourceChangesCollapseExpandedPool() {
        var savedA = payload(
            mode: .questions,
            duration: 300,
            theme: "Cities"
        )
        savedA.lobbyWordSource = .saved
        savedA.lobbySourcePackID = "pack-a"
        var savedB = savedA
        savedB.lobbySourcePackID = "pack-b"
        var ai = savedA
        ai.lobbyWordSource = .ai
        ai.lobbySourcePackID = nil

        XCTAssertTrue(shouldResetExpandedPool(from: savedA, to: savedB))
        XCTAssertTrue(shouldResetExpandedPool(from: savedA, to: ai))
    }

    func testPresentationSnapshotCarriesWholeLobbyRevision() {
        let state = payload(
            mode: .associations,
            duration: 720,
            theme: "Marvel"
        )
        let snapshot = LobbyPresentationSnapshot(
            roomID: "room-1",
            revision: 12,
            state: state
        )

        XCTAssertEqual(snapshot.revision, 12)
        XCTAssertEqual(snapshot.state.gameMode, .associations)
        XCTAssertEqual(snapshot.state.gameDurationSeconds, 720)
        XCTAssertEqual(snapshot.state.lobbyWordCount, 2)
        XCTAssertEqual(snapshot.state.lobbyWordPool.map(\.word), ["Kyiv", "London"])
    }

    private func shouldAnimate(
        isHost: Bool = false,
        reduceMotion: Bool = false,
        isConfiguredRoom: Bool = true,
        isEditingLobbySlider: Bool = false,
        appliedRevision: Int,
        incomingRevision: Int
    ) -> Bool {
        LobbyPresentationPolicy.shouldAnimateRemoteUpdate(
            isHost: isHost,
            reduceMotion: reduceMotion,
            isConfiguredRoom: isConfiguredRoom,
            isEditingLobbySlider: isEditingLobbySlider,
            appliedRevision: appliedRevision,
            incomingRevision: incomingRevision
        )
    }

    private func payload(
        mode: SpyGameMode,
        duration: Int,
        theme: String
    ) -> LobbyStatePayload {
        LobbyStatePayload(
            gameMode: mode,
            gameDurationSeconds: duration,
            lobbyWordSource: .manual,
            lobbySourcePackID: nil,
            lobbySourceName: theme,
            lobbyTheme: theme,
            lobbyCategory: theme,
            lobbyWordCount: 2,
            lobbyWordCountMode: .custom,
            lobbyWordPool: [
                LobbyWordPoolEntry(word: "Kyiv", enabled: true),
                LobbyWordPoolEntry(word: "London", enabled: false)
            ]
        )
    }

    private func shouldResetExpandedPool(
        from current: LobbyStatePayload,
        to incoming: LobbyStatePayload
    ) -> Bool {
        LobbyPresentationPolicy.shouldResetExpandedPool(
            current: LobbyPoolIdentity(state: current),
            incoming: LobbyPoolIdentity(state: incoming),
            currentWordKeys: Set(current.lobbyWordPool.map { $0.word.lowercased() }),
            incomingWordKeys: Set(incoming.lobbyWordPool.map { $0.word.lowercased() })
        )
    }
}

final class LobbySyncRetryPolicyTests: XCTestCase {
    func testOnlyTypedPreActionLeaseConflictsRetryRoomActions() {
        XCTAssertTrue(
            Base44Error(
                message: "Account identity is being updated.",
                statusCode: 409,
                code: "active_lease",
                retryable: true
            ).isRetryableRoomActionConflict
        )
        XCTAssertFalse(
            Base44Error(
                message: "Account identity is being updated.",
                statusCode: 409
            ).isRetryableRoomActionConflict
        )
        XCTAssertFalse(
            Base44Error(
                message: "Room changed",
                statusCode: 409,
                code: "lobby_revision_conflict",
                retryable: true
            ).isRetryableRoomActionConflict
        )
    }

    func testOnlyTypedLobbyConflictTriggersRevisionRefresh() {
        XCTAssertTrue(
            LobbySyncRetryPolicy.isRevisionConflict(
                Base44Error(
                    message: "Room changed",
                    statusCode: 409,
                    code: "lobby_revision_conflict"
                )
            )
        )
        XCTAssertFalse(
            LobbySyncRetryPolicy.isRevisionConflict(
                Base44Error(
                    message: "Ready voting started",
                    statusCode: 409,
                    code: "room_status_conflict"
                )
            )
        )
    }

    func testTransientNetworkLossAndServerFailureAreRetryable() {
        XCTAssertTrue(
            LobbySyncRetryPolicy.isRetryable(
                URLError(.networkConnectionLost)
            )
        )
        XCTAssertTrue(
            LobbySyncRetryPolicy.isRetryable(
                Base44Error(message: "Unavailable", statusCode: 503)
            )
        )
        XCTAssertFalse(
            LobbySyncRetryPolicy.isRetryable(
                Base44Error(message: "Invalid", statusCode: 422)
            )
        )
        XCTAssertFalse(
            LobbySyncRetryPolicy.isRetryable(
                URLError(.cancelled)
            )
        )
    }
}

final class LobbyDraftPoolPolicyTests: XCTestCase {
    func testInvalidatedGeneratedDraftDoesNotReusePreviousAuthoritativePool() {
        XCTAssertEqual(
            LobbyDraftPoolPolicy.generatedPayloadWords(
                localWords: nil,
                priorAuthoritativeWords: ["Embassy", "Cipher"]
            ),
            []
        )
        XCTAssertEqual(
            LobbyDraftPoolPolicy.generatedPayloadWords(
                localWords: ["Orbit", "Comet"],
                priorAuthoritativeWords: ["Embassy", "Cipher"]
            ),
            ["Orbit", "Comet"]
        )
    }
}

final class GameRoomRealtimeSignalParserTests: XCTestCase {
    func testAcceptsOnlyExactUserRoomAndEntityEnvelope() throws {
        let entityRoom = "entities:app-1:GameRoomSignal"
        let event: [String: Any] = [
            "type": "update",
            "id": "signal-1",
            "data": [
                "user_id": "user-1",
                "room_id": "room-1",
                "lobby_revision": 8,
                "room_revision": 14,
                "room_updated_at": "2026-08-06T12:00:00.000Z",
                "state": "active"
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: event)
        let envelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: encoded, encoding: .utf8))
        ]

        XCTAssertEqual(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            ),
            GameRoomRealtimeSignal(
                roomID: "room-1",
                lobbyRevision: 8,
                roomRevision: 14,
                roomUpdatedAt: "2026-08-06T12:00:00.000Z",
                state: "active"
            )
        )
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-2",
                expectedRoomID: "room-1"
            )
        )
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-2"
            )
        )
    }

    func testAcceptsZeroAndRejectsMalformedOrNegativeRevision() throws {
        let entityRoom = "entities:app-1:GameRoomSignal"
        let event: [String: Any] = [
            "type": "update",
            "data": [
                "user_id": "user-1",
                "room_id": "room-1",
                "lobby_revision": 0,
                "state": "active"
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: event)
        let envelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: encoded, encoding: .utf8))
        ]

        XCTAssertEqual(
            GameRoomRealtimeSignalParser.parse(
                payload: [envelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            ),
            GameRoomRealtimeSignal(
                roomID: "room-1",
                lobbyRevision: 0,
                roomRevision: nil,
                roomUpdatedAt: nil,
                state: "active"
            )
        )
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [["room": entityRoom, "data": "not-json"]],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            )
        )

        var oversizedEvent = event
        var oversizedData = try XCTUnwrap(oversizedEvent["data"] as? [String: Any])
        oversizedData["lobby_revision"] = 1e20
        oversizedEvent["data"] = oversizedData
        let oversizedEncoded = try JSONSerialization.data(withJSONObject: oversizedEvent)
        let oversizedEnvelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: oversizedEncoded, encoding: .utf8))
        ]
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [oversizedEnvelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            )
        )

        var negativeEvent = event
        var negativeData = try XCTUnwrap(negativeEvent["data"] as? [String: Any])
        negativeData["lobby_revision"] = -1
        negativeEvent["data"] = negativeData
        let negativeEncoded = try JSONSerialization.data(withJSONObject: negativeEvent)
        let negativeEnvelope: [String: Any] = [
            "room": entityRoom,
            "data": try XCTUnwrap(String(data: negativeEncoded, encoding: .utf8))
        ]
        XCTAssertNil(
            GameRoomRealtimeSignalParser.parse(
                payload: [negativeEnvelope],
                expectedEntityRoom: entityRoom,
                expectedUserID: "user-1",
                expectedRoomID: "room-1"
            )
        )
    }
}

final class SpySliderInteractionStateTests: XCTestCase {
    func testOnlyOptedInNonTrackingRemoteTransactionAnimatesSlider() {
        XCTAssertTrue(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: true,
                transactionHasAnimation: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: true,
                allowsAnimation: true,
                transactionHasAnimation: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: false,
                transactionHasAnimation: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: true,
                transactionHasAnimation: false,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SpySliderProgrammaticUpdatePolicy.shouldAnimate(
                isTracking: false,
                allowsAnimation: true,
                transactionHasAnimation: true,
                reduceMotion: true
            )
        )
    }

    func testTouchCancelRestoresInitialValueWithoutCommit() throws {
        var interaction = SpySliderInteractionState()

        XCTAssertTrue(interaction.begin(at: 15))
        interaction.track(9)

        XCTAssertEqual(try XCTUnwrap(interaction.cancel()), 15)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.lastTrackedValue)
        XCTAssertNil(interaction.commit(9))
    }

    func testTouchUpCommitsExactFinalNativeValue() throws {
        var interaction = SpySliderInteractionState()

        XCTAssertTrue(interaction.begin(at: 15))
        interaction.track(9)

        XCTAssertEqual(try XCTUnwrap(interaction.commit(8)), 8)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.cancel())
    }

    func testAccessibilityValueChangeCommitsWithoutTouchLifecycle() {
        var interaction = SpySliderInteractionState()

        XCTAssertTrue(interaction.commitsValueChangeImmediately(isTracking: false))
        XCTAssertFalse(interaction.commitsValueChangeImmediately(isTracking: true))

        XCTAssertTrue(interaction.begin(at: 15))
        XCTAssertFalse(interaction.commitsValueChangeImmediately(isTracking: false))
    }
}

final class RadarCameraAssistanceGateTests: XCTestCase {
    func testCameraAssistanceRequiresExplicitAuthorizedRadarIntent() {
        XCTAssertTrue(
            RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: true,
                wantsScanning: true,
                authorizationStatus: .authorized,
                supportsCameraAssistance: true,
                supportsWorldTracking: true
            )
        )
        XCTAssertFalse(
            RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: false,
                wantsScanning: true,
                authorizationStatus: .authorized,
                supportsCameraAssistance: true,
                supportsWorldTracking: true
            )
        )
        XCTAssertFalse(
            RadarCameraAssistanceGate.canEnable(
                hasExplicitRadarIntent: true,
                wantsScanning: true,
                authorizationStatus: .notDetermined,
                supportsCameraAssistance: true,
                supportsWorldTracking: true
            )
        )
    }
}

final class RadarInvitationInteractionPolicyTests: XCTestCase {
    func testSecondTapCancelsOnlyPendingInvitation() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .available,
                invitationState: nil
            ),
            .send
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .available,
                invitationState: .waiting
            ),
            .cancel
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .available,
                invitationState: .accepted
            ),
            .none
        )
    }

    func testUnavailablePlayersCannotSendOrCancelInvitation() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .blocked,
                availability: .available,
                invitationState: nil
            ),
            .none
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .ask,
                availability: .inGame,
                invitationState: .waiting
            ),
            .none
        )
    }

    func testLiveAvailabilityReconcilesCardState() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.state(
                after: .inGame,
                currentState: .waiting
            ),
            .inGame
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                currentState: .inGame
            )
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                currentState: .declined
            ),
            .declined
        )
    }

    func testCancellationMustMatchInvitationAndSender() {
        let invitation = RadarIncomingInvitation(
            roomCode: "ABC123",
            hostCallSign: "Host",
            hostAvatar: "🕵️",
            wireInvitationID: "invite-1",
            sourcePeerID: "peer-1"
        )

        XCTAssertTrue(
            RadarInvitationCancellationPolicy.matches(
                invitation: invitation,
                invitationID: "invite-1",
                sourcePeerID: "peer-1"
            )
        )
        XCTAssertFalse(
            RadarInvitationCancellationPolicy.matches(
                invitation: invitation,
                invitationID: "invite-2",
                sourcePeerID: "peer-1"
            )
        )
        XCTAssertFalse(
            RadarInvitationCancellationPolicy.matches(
                invitation: invitation,
                invitationID: "invite-1",
                sourcePeerID: "peer-2"
            )
        )
    }
}

final class NavigationSwipeTests: XCTestCase {
    func testResolverMapsHorizontalSwipeDirection() {
        XCTAssertEqual(
            TabSwipeResolver.resolve(translation: CGSize(width: -80, height: 10)),
            .next
        )
        XCTAssertEqual(
            TabSwipeResolver.resolve(translation: CGSize(width: 80, height: -10)),
            .previous
        )
    }

    func testResolverRejectsShortVerticalAndDiagonalDrags() {
        XCTAssertNil(
            TabSwipeResolver.resolve(
                translation: CGSize(width: TabSwipeResolver.minimumTranslation - 1, height: 0)
            )
        )
        XCTAssertNil(TabSwipeResolver.resolve(translation: CGSize(width: 25, height: 90)))
        XCTAssertNil(TabSwipeResolver.resolve(translation: CGSize(width: 80, height: 70)))
    }

    func testResolverAcceptsHorizontalDominantDragAtThreshold() {
        XCTAssertEqual(
            TabSwipeResolver.resolve(
                translation: CGSize(width: TabSwipeResolver.minimumTranslation, height: 10)
            ),
            .previous
        )
    }

    func testResolverSuppressesTabSwipeWhileTextInputIsActive() {
        XCTAssertNil(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isTextInputActive: true
            )
        )
        XCTAssertEqual(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isTextInputActive: false
            ),
            .next
        )
    }

    func testResolverSuppressesTabSwipeFromInteractiveHorizontalControl() {
        XCTAssertNil(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isInteractiveHorizontalControlActive: true
            )
        )
        XCTAssertEqual(
            TabSwipeResolver.resolve(
                translation: CGSize(width: -120, height: 4),
                isInteractiveHorizontalControlActive: false
            ),
            .next
        )
    }

    func testPrimaryTabsAdvanceWithoutWrapping() {
        XCTAssertEqual(AppTab.home.primaryNeighbor(for: .next), .packs)
        XCTAssertEqual(AppTab.packs.primaryNeighbor(for: .next), .profile)
        XCTAssertNil(AppTab.profile.primaryNeighbor(for: .next))

        XCTAssertEqual(AppTab.profile.primaryNeighbor(for: .previous), .packs)
        XCTAssertEqual(AppTab.packs.primaryNeighbor(for: .previous), .home)
        XCTAssertNil(AppTab.home.primaryNeighbor(for: .previous))
    }

    func testNonPrimaryTabsDoNotParticipateInPrimarySwipes() {
        XCTAssertNil(AppTab.game.primaryNeighbor(for: .next))
        XCTAssertNil(AppTab.local.primaryNeighbor(for: .previous))
        XCTAssertNil(AppTab.history.primaryNeighbor(for: .previous))
    }

    func testCommunityTabsAdvanceWithoutExitOrWrapping() {
        XCTAssertEqual(CommunityTab.network.swipeNeighbor(for: .next), .me)
        XCTAssertEqual(CommunityTab.me.swipeNeighbor(for: .previous), .network)
        XCTAssertNil(CommunityTab.network.swipeNeighbor(for: .previous))
        XCTAssertNil(CommunityTab.me.swipeNeighbor(for: .next))
        XCTAssertNil(CommunityTab.exit.swipeNeighbor(for: .next))
    }

    func testCommunityMeTransitionWaitsForProfileAndIdleActions() {
        XCTAssertFalse(
            CommunityMeTransitionResolver.canCommit(
                selfUserID: nil,
                activeAction: nil
            )
        )
        XCTAssertFalse(
            CommunityMeTransitionResolver.canCommit(
                selfUserID: "user-a",
                activeAction: "friend-user-b"
            )
        )
        XCTAssertTrue(
            CommunityMeTransitionResolver.canCommit(
                selfUserID: "user-a",
                activeAction: nil
            )
        )
    }

    func testCommunityProfileResponseIsRejectedAfterNetworkInvalidatesRequest() {
        var state = CommunityProfileRequestState()
        let requestID = UUID()

        XCTAssertEqual(state.begin(requestID), requestID)
        XCTAssertTrue(state.accepts(requestID))

        state.invalidate()

        XCTAssertNil(state.activeRequestID)
        XCTAssertFalse(state.accepts(requestID))
    }

    func testActiveRoomPreviewWinsOverExplicitHomeRootPresentation() {
        XCTAssertFalse(
            HomeRootPresentationPolicy.showsLandingActions(
                hasActiveRoom: true,
                explicitlyRequested: true
            )
        )
        XCTAssertFalse(
            HomeRootPresentationPolicy.showsLandingActions(
                hasActiveRoom: true,
                explicitlyRequested: false
            )
        )
        XCTAssertTrue(
            HomeRootPresentationPolicy.showsLandingActions(
                hasActiveRoom: false,
                explicitlyRequested: true
            )
        )
        XCTAssertEqual(
            HomeRootPresentationPolicy.primaryAction(hasActiveRoom: true),
            .returnToActiveRoom
        )
        XCTAssertEqual(
            HomeRootPresentationPolicy.primaryAction(hasActiveRoom: false),
            .chooseMode
        )
    }
}
