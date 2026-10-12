import Foundation
import XCTest
@testable import SpyClashSupabaseTest

@MainActor
final class SupabaseGameAdapterTests: XCTestCase {
    private let viewer = "10000000-0000-0000-0000-000000000001"
    private let host = "10000000-0000-0000-0000-000000000002"
    private let roomID = "20000000-0000-0000-0000-000000000001"
    private let matchID = "30000000-0000-0000-0000-000000000001"
    private let membershipID = "40000000-0000-0000-0000-000000000001"

    func testSpyProjectionKeepsOnlyViewerRoleAndIgnoresUntrustedLegacySecrets() throws {
        let adapter = makeAdapter(role: "spy", word: .null)
        var value = try XCTUnwrap(adapter.store.snapshot.object)
        // Legacy fields must never widen what an authorized Supabase snapshot
        // projects into the existing GameRoom model, even after the round.
        value["phase"] = .string("finished")
        value["spy_emails"] = .array([.string(alias(host))])
        value["secret_word"] = .string("legacy secret must not project")
        value["cards_read"] = .array([.string(alias(host))])
        adapter.store.snapshot = .object(value)

        let room = try XCTUnwrap(adapter.currentRoom)
        XCTAssertEqual(room.spyEmailsList, [alias(viewer)])
        XCTAssertTrue(room.isSpy(email: alias(viewer)))
        XCTAssertFalse(room.isSpy(email: alias(host)))
        XCTAssertNil(room.secretWord)
        XCTAssertNil(room.word)
        XCTAssertTrue((room.revealedSpyEmails ?? []).isEmpty)
        XCTAssertTrue((room.cardsRead ?? []).isEmpty)
    }

    func testCivilianProjectionPreservesIdentityFencesVotesAndOwnWord() throws {
        let adapter = makeAdapter(role: "civilian", word: .string("Library"))
        let room = try XCTUnwrap(adapter.currentRoom)

        XCTAssertEqual(room.id, roomID)
        XCTAssertEqual(room.code, roomID)
        XCTAssertEqual(room.hostEmail, alias(host))
        XCTAssertEqual(room.viewerMembershipID, membershipID)
        XCTAssertEqual(room.matchID, matchID)
        XCTAssertEqual(room.roomRevision, 12)
        XCTAssertEqual(room.lobbyRevision, 3)
        XCTAssertEqual(room.normalizedStatus, "playing")
        XCTAssertEqual(room.secretWord, "Library")
        XCTAssertTrue(room.spyEmailsList.isEmpty)
        XCTAssertEqual(room.playersList.map(\.email), [alias(viewer), alias(host)])
        XCTAssertEqual(room.playersList.map(\.userID), [viewer, host])
        XCTAssertEqual(room.playersList.first?.membershipID, membershipID)
        XCTAssertEqual(room.readyPlayers, [alias(host)])
        XCTAssertEqual(room.detectiveVotes?.first?.voterEmail, alias(host))
        XCTAssertEqual(room.detectiveVotes?.first?.votedForEmail, alias(viewer))
        XCTAssertNil(room.gameStartedAt, "The bridge must not fabricate a production timer")
    }

    func testRoleReadConfirmationIsOwnOnlyAndExpiresOnNewMatch() throws {
        let adapter = makeAdapter(role: "civilian", word: .string("Library"))
        XCTAssertFalse(adapter.ownRoleConfirmed)
        let confirmed = try adapter.confirmOwnRole(roomID: roomID)
        XCTAssertEqual(confirmed.cardsRead, [alias(viewer)])
        XCTAssertTrue(adapter.ownRoleConfirmed)

        var next = try XCTUnwrap(adapter.store.snapshot.object)
        next["match_id"] = .string("30000000-0000-0000-0000-000000000002")
        adapter.store.snapshot = .object(next)
        XCTAssertFalse(adapter.ownRoleConfirmed)
        XCTAssertTrue((adapter.currentRoom?.cardsRead ?? []).isEmpty)
    }

    func testVotingPhaseIsVisibleBeforeFirstVoteWithoutFabricatedBallots() throws {
        let adapter = makeAdapter(role: "civilian", word: .string("Library"))
        var voting = try XCTUnwrap(adapter.store.snapshot.object)
        voting["votes"] = .array([])
        adapter.store.snapshot = .object(voting)
        let room = try XCTUnwrap(adapter.currentRoom)
        XCTAssertTrue(room.isVotingActive)
        XCTAssertEqual(room.detectiveVoteRoundID, matchID)
        XCTAssertTrue((room.detectiveVotes ?? []).isEmpty)

        voting["phase"] = .string("playing")
        adapter.store.snapshot = .object(voting)
        let playing = try XCTUnwrap(adapter.currentRoom)
        XCTAssertFalse(playing.isVotingActive)
        XCTAssertNil(playing.detectiveVoteRoundID)
    }

    func testRoleReadCannotConfirmAnotherRoom() throws {
        let adapter = makeAdapter(role: "spy", word: .null)
        XCTAssertThrowsError(try adapter.confirmOwnRole(roomID: UUID().uuidString)) { error in
            XCTAssertEqual((error as? LabFailure)?.code, "role_not_available")
        }
        XCTAssertFalse(adapter.ownRoleConfirmed)
        XCTAssertTrue((adapter.currentRoom?.cardsRead ?? []).isEmpty)
    }

    func testChangedReadyIntentCannotReplaceUnresolvedOriginal() async throws {
        let adapter = makeAdapter(role: "civilian", word: .string("Library"))
        let requestID = "50000000-0000-0000-0000-000000000001"
        let original = LabStore.Intent(
            requestID: requestID, actorID: viewer, roomID: roomID, action: "set_ready",
            source: .object(["room_id": .string(roomID), "action": .string("set_ready"),
                             "payload": .object(["ready": .bool(true)])]),
            body: .object(["p_request_id": .string(requestID), "p_room_id": .string(roomID),
                           "p_action": .string("set_ready"), "p_payload": .object([
                            "ready": .bool(true), "membership_id": .string(membershipID),
                            "settings_revision": .number(3)])])
        )
        adapter.store.pending[requestID] = original

        // New UI state must not rebind a command whose server outcome is unknown.
        var changed = try XCTUnwrap(adapter.store.snapshot.object)
        changed["settings_revision"] = .number(4)
        changed["own_membership_id"] = .string("40000000-0000-0000-0000-000000000002")
        adapter.store.snapshot = .object(changed)
        do {
            _ = try await adapter.setReady(false, roomID: roomID)
            XCTFail("An unresolved ready=true intent cannot become ready=false")
        } catch let error as LabFailure {
            XCTAssertEqual(error.code, "pending_command_requires_retry")
            XCTAssertTrue(error.ambiguous)
        }
        XCTAssertEqual(adapter.store.pending, [requestID: original])
    }

    func testPendingCommandBlocksFreshActionAndAnotherRoomBeforeNetwork() async throws {
        let adapter = makeAdapter(role: "civilian", word: .string("Library"))
        let original = pendingReadyIntent()
        adapter.store.pending[original.requestID] = original
        XCTAssertTrue(adapter.hasPendingRecovery)

        do {
            try await adapter.leaveRoom(roomID: roomID, membershipID: membershipID)
            XCTFail("Leave cannot overtake the unresolved ready action")
        } catch let error as LabFailure {
            XCTAssertEqual(error.code, "pending_command_requires_retry")
            XCTAssertTrue(error.ambiguous)
        }
        do {
            _ = try await adapter.joinRoom(code: "20000000-0000-0000-0000-000000000002")
            XCTFail("Joining another room cannot overtake an unresolved action")
        } catch let error as LabFailure {
            XCTAssertEqual(error.code, "pending_command_requires_retry")
            XCTAssertTrue(error.ambiguous)
        }
        // This adapter has no connected backend: a guard regression also fails
        // by producing not_signed_in instead of the recovery error above.
        XCTAssertEqual(adapter.store.pending, [original.requestID: original])
        XCTAssertEqual(adapter.currentRoom?.id, roomID)
    }

    func testMembershipLossClearsOnlyMatchingGenerationAndPreservesPending() throws {
        let adapter = makeAdapter(role: "civilian", word: .string("Library"))
        let store = adapter.store
        store.roomID = roomID
        let original = pendingReadyIntent()
        store.pending[original.requestID] = original
        let generation = store.roomContextGeneration
        let replacementMembership = "40000000-0000-0000-0000-000000000003"
        var replacement = try XCTUnwrap(store.snapshot.object)
        replacement["own_membership_id"] = .string(replacementMembership)
        store.snapshot = .object(replacement)

        store.clearCurrentRoomAfterMembershipLoss(roomID: roomID, expectedGeneration: generation, expectedMembershipID: membershipID)
        XCTAssertEqual(store.roomID, roomID, "An old membership's delayed failure must not evict a rejoin")
        XCTAssertEqual(store.snapshot["own_membership_id"].string, replacementMembership)
        XCTAssertEqual(store.roomContextGeneration, generation)

        store.clearCurrentRoomAfterMembershipLoss(roomID: roomID, expectedGeneration: generation, expectedMembershipID: replacementMembership)
        XCTAssertNil(store.roomID)
        XCTAssertEqual(store.snapshot, .null)
        XCTAssertNil(adapter.currentRoom)
        XCTAssertNil(store.watchedRoomID)
        XCTAssertGreaterThan(store.roomContextGeneration, generation)
        XCTAssertEqual(store.pending, [original.requestID: original])
        XCTAssertTrue(adapter.hasPendingRecovery, "Authorization loss must not discard an unknown command outcome")

        store.roomID = roomID
        store.snapshot = .object(replacement)
        store.clearCurrentRoomAfterMembershipLoss(roomID: roomID, expectedGeneration: generation, expectedMembershipID: replacementMembership)
        XCTAssertEqual(store.roomID, roomID, "An earlier room generation must not clear a later context")
        XCTAssertEqual(store.snapshot["own_membership_id"].string, replacementMembership)
    }

    private func pendingReadyIntent() -> LabStore.Intent {
        let requestID = "50000000-0000-0000-0000-000000000009"
        return LabStore.Intent(
            requestID: requestID, actorID: viewer, roomID: roomID, action: "set_ready",
            source: .object(["room_id": .string(roomID), "action": .string("set_ready"),
                             "payload": .object(["ready": .bool(true)])]),
            body: .object(["p_request_id": .string(requestID), "p_room_id": .string(roomID),
                           "p_action": .string("set_ready"), "p_payload": .object([
                            "ready": .bool(true), "membership_id": .string(membershipID),
                            "settings_revision": .number(3)])])
        )
    }

    private func alias(_ id: String) -> String { SupabaseGameAdapter.alias(for: id) }

    private func makeAdapter(role: String, word: JSONValue) -> SupabaseGameAdapter {
        let adapter = SupabaseGameAdapter()
        adapter.store.userID = viewer
        adapter.store.snapshot = .object([
            "room_id": .string(roomID), "host_id": .string(host), "phase": .string("voting"),
            "match_id": .string(matchID), "own_membership_id": .string(membershipID),
            "revision": .number(12), "settings_revision": .number(3),
            "own_role": .string(role), "own_word": word, "winner": .null,
            "players": .array([
                .object(["user_id": .string(viewer), "membership_id": .string(membershipID),
                         "name": .string("Viewer"), "ready": .bool(false)]),
                .object(["user_id": .string(host),
                         "membership_id": .string("40000000-0000-0000-0000-000000000002"),
                         "name": .string("Host"), "ready": .bool(true)])
            ]),
            "votes": .array([.object(["voter_id": .string(host), "target_id": .string(viewer)])])
        ])
        return adapter
    }
}
