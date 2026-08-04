import Foundation
import AVFoundation
import XCTest
@testable import SpyClash

final class OnlineRoundStateTests: XCTestCase {
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

    func testRoomPollPolicyUsesResponsiveCadenceAndBoundedFailureBackoff() {
        XCTAssertEqual(
            RoomPollPolicy.delaySeconds(
                roomStatus: "waiting",
                consecutiveFailures: 0,
                isApplicationActive: true
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RoomPollPolicy.delaySeconds(
                roomStatus: "playing",
                consecutiveFailures: 0,
                isApplicationActive: true
            ),
            1.2,
            accuracy: 0.001
        )
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 1, isApplicationActive: true), 2)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 2, isApplicationActive: true), 4)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 8, isApplicationActive: true), 8)
        XCTAssertEqual(RoomPollPolicy.delaySeconds(roomStatus: "waiting", consecutiveFailures: 0, isApplicationActive: false), 5)
    }
}

final class OnlineDurationSyncStateTests: XCTestCase {
    func testReleaseClaimsLockBeforeAsyncRequestCanStart() throws {
        var state = OnlineDurationSyncState()

        let request = try XCTUnwrap(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 8,
                confirmedDurationSeconds: 900
            )
        )

        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.isCurrent(request))
        XCTAssertFalse(state.acceptsRemoteUpdate(isDragging: false))
    }

    func testOnlyOneDurationMutationCanBePending() throws {
        var state = OnlineDurationSyncState()
        let first = try XCTUnwrap(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 8,
                confirmedDurationSeconds: 900
            )
        )

        XCTAssertNil(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 12,
                confirmedDurationSeconds: 900
            )
        )
        XCTAssertTrue(state.finish(first))
        XCTAssertFalse(state.isLocked)
        XCTAssertNotNil(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 12,
                confirmedDurationSeconds: 480
            )
        )
    }

    func testDraggingAndPendingDurationRejectRemoteSnapshots() throws {
        var state = OnlineDurationSyncState()
        XCTAssertFalse(state.acceptsRemoteUpdate(isDragging: true))
        XCTAssertTrue(state.acceptsRemoteUpdate(isDragging: false))

        _ = try XCTUnwrap(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 8,
                confirmedDurationSeconds: 900
            )
        )
        XCTAssertFalse(state.acceptsRemoteUpdate(isDragging: false))
    }

    func testStaleCompletionCannotUnlockNewDurationMutation() throws {
        var state = OnlineDurationSyncState()
        let first = try XCTUnwrap(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 8,
                confirmedDurationSeconds: 900
            )
        )
        XCTAssertTrue(state.finish(first))

        let second = try XCTUnwrap(
            state.begin(
                roomID: "room-1",
                requestedMinutes: 12,
                confirmedDurationSeconds: 480
            )
        )
        XCTAssertFalse(state.finish(first))
        XCTAssertTrue(state.isCurrent(second))
        XCTAssertTrue(state.isLocked)
    }
}

final class SpySliderInteractionStateTests: XCTestCase {
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

    func testExplicitHomeRootShowsLandingWithoutDiscardingActiveRoom() {
        XCTAssertTrue(
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
