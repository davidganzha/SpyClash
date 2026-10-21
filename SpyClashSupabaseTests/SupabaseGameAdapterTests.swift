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

    func testProjectionUsesOriginalRoomIdentityRulesAndAuthorizedFields() throws {
        let (_, store) = makeStore()
        var value = fixture()
        value["spy_emails"] = .array([.string(alias(viewer)), .string(alias(host))])
        value["spies_know_each_other"] = .bool(true)
        value["secret_word"] = .null
        value["word"] = .null
        try store.adopt(.object(value))
        let adapter = SupabaseGameAdapter(store: store)
        let room = try XCTUnwrap(adapter.currentRoom)
        XCTAssertEqual(room.id, roomID)
        XCTAssertEqual(room.code, "ABC123")
        XCTAssertEqual(room.hostEmail, alias(host))
        XCTAssertEqual(room.viewerMembershipID, membershipID)
        XCTAssertEqual(room.matchID, matchID)
        XCTAssertEqual(room.roomRevision, 12)
        XCTAssertEqual(room.lobbyRevision, 3)
        XCTAssertEqual(room.playersList.map(\.userID), [viewer, host])
        XCTAssertEqual(room.spyEmailsList, [alias(viewer), alias(host)])
        XCTAssertNil(room.displayWord, "The client must not invent a word hidden by the authorized projection")
        XCTAssertNil(room.revealedSpyEmails)
        XCTAssertEqual(room.gameStartedAt, "2026-10-12T20:00:00Z")
        XCTAssertEqual(room.gamePausedTotalSeconds, 9)
        XCTAssertEqual(room.currentAnswer, #"{"kind":"question_turn_order_v1","order":["a","b"]}"#)
    }

    func testRoleConfirmationIsPersistedThroughOriginalCommand() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        let adapter = SupabaseGameAdapter(store: store)
        XCTAssertFalse(adapter.ownRoleConfirmed)
        transport.handler = { request in
            var updated = self.fixture(revision: 13)
            updated["cards_read"] = .array([.string(self.alias(self.viewer)), .string(self.alias(self.host))])
            return self.response(request: request, room: .object(updated), revision: 13)
        }
        let updated = try await adapter.roomAction(["action": .string("mark_role_card_read"), "room_id": .string(roomID)])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?["action"].string, "mark_role_card_read")
        XCTAssertEqual(updated.cardsReadList, [alias(viewer), alias(host)])
        XCTAssertTrue(adapter.ownRoleConfirmed)
        XCTAssertFalse(store.hasPendingRecovery)
    }

    func testAmbiguousIntentKeepsRequestAndFencesAcrossNewSnapshot() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw URLError(.networkConnectionLost) }
        let source: [String: JSONValue] = ["action": .string("advance_question"), "room_id": .string(roomID)]
        await expectCode("transport_-1005") { _ = try await store.command(source) }
        let original = try XCTUnwrap(store.pending)
        XCTAssertEqual(original.body["expected_revision"].integer, 12)
        XCTAssertEqual(original.body["expected_match_id"].string, matchID)
        XCTAssertEqual(original.body["expected_membership_id"].string, membershipID)
        var newer = fixture(revision: 14)
        newer["viewer_membership_id"] = .string("replacement-membership")
        try store.adopt(.object(newer))
        transport.handler = { request in self.response(request: request, room: .object(newer), revision: 14) }
        _ = try await store.retryPending()
        XCTAssertEqual(transport.requests[0], transport.requests[1], "Retry must preserve the original request ID, membership, match and turn revision")
        XCTAssertFalse(store.hasPendingRecovery)
    }

    func testPendingRecoversOriginalBeforeAllowingDifferentActionAndRoom() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw URLError(.networkConnectionLost) }
        _ = try? await store.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        let original = store.pending
        await expectCode("pending_command_requires_retry") {
            _ = try await store.command(["action": .string("leave_room"), "room_id": .string(self.roomID)])
        }
        await expectCode("pending_command_requires_retry") {
            _ = try await store.command(["action": .string("join_room"), "room_code": .string("XYZ789")])
        }
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests.allSatisfy { $0 == original?.body }, "Only the original saved action may be retried")
        XCTAssertEqual(store.pending, original)
    }

    func testKnownCommitRecoveryReadsWithoutResendingMutation() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        transport.handler = { request in
            if request["action"].string == "toggle_ready" { return self.response(request: request, room: .null, revision: 13) }
            throw URLError(.networkConnectionLost)
        }
        _ = try? await store.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        XCTAssertNotNil(store.pending?.acknowledgement)
        XCTAssertTrue(store.hasPendingRecovery)
        transport.handler = { _ in .object(["room": .object(self.fixture(revision: 13))]) }
        _ = try await store.retryPending()
        XCTAssertEqual(transport.requests.compactMap { $0["action"].string }, ["toggle_ready", "get_room", "get_room"])
        XCTAssertEqual(store.room?.roomRevision, 13)
        XCTAssertFalse(store.hasPendingRecovery)
    }

    func testKnownJoinReceiptRecoversItsTargetInsteadOfAnOlderSelectedRoom() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        let target = "20000000-0000-0000-0000-000000000002"
        transport.handler = { request in
            .object(["receipt": .object(["request_id": request["request_id"], "room_id": .string(target), "revision": .number(20)]),
                     "room": .object(["id": .string(target)])])
        }
        await expectCode("invalid_full_game_response") {
            _ = try await store.command(["action": .string("join_room"), "room_code": .string("XYZ789")])
        }
        var joined = fixture(revision: 20)
        joined["id"] = .string(target)
        joined["code"] = .string("XYZ789")
        transport.handler = { _ in .object(["room": .object(joined)]) }
        _ = try await store.retryPending()
        XCTAssertEqual(store.roomID, target)
        XCTAssertEqual(store.room?.code, "XYZ789")
        XCTAssertEqual(transport.requests.compactMap { $0["action"].string }, ["join_room", "get_room"])
        XCTAssertFalse(store.hasPendingRecovery)
    }

    func testExplicitTurnRevisionIsNeverReboundToNewerSnapshot() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture(revision: 15)))
        transport.handler = { _ in throw URLError(.networkConnectionLost) }
        _ = try? await store.command(["action": .string("advance_question"), "room_id": .string(roomID), "expected_revision": .number(12),
                                     "expected_match_id": .string("original-match"), "expected_membership_id": .string("original-membership")])
        XCTAssertEqual(transport.requests[0]["expected_revision"].integer, 12)
        XCTAssertEqual(transport.requests[0]["expected_match_id"].string, "original-match")
        XCTAssertEqual(transport.requests[0]["expected_membership_id"].string, "original-membership")
    }

    func testDefinitiveConflictPreservesTypedErrorAndAllowsNewIntent() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw FullGameTransportFailure(error: Base44Error(message: "Changed", statusCode: 409, code: "lobby_revision_conflict"), ambiguous: false) }
        let source: [String: JSONValue] = ["action": .string("update_lobby_state"), "room_id": .string(roomID), "expected_revision": .number(3)]
        await expectCode("lobby_revision_conflict") { _ = try await store.command(source) }
        XCTAssertFalse(store.hasPendingRecovery)
        let firstID = transport.requests[0]["request_id"].string
        transport.handler = { request in self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13) }
        _ = try await store.command(source)
        XCTAssertNotEqual(firstID, transport.requests[1]["request_id"].string)
    }

    func testMembershipLossCannotClearReplacementMembershipOrGeneration() throws {
        let (_, store) = makeStore()
        try store.adopt(.object(fixture()))
        let generation = store.roomContextGeneration
        var rejoined = fixture(revision: 13)
        rejoined["viewer_membership_id"] = .string("replacement")
        try store.adopt(.object(rejoined))
        store.clearRoom(expectedRoomID: roomID, generation: generation, membership: membershipID)
        XCTAssertEqual(store.room?.viewerMembershipID, "replacement")
        store.clearRoom(expectedRoomID: roomID, generation: generation, membership: "replacement")
        XCTAssertNil(store.room)
        try store.adopt(.object(rejoined))
        store.clearRoom(expectedRoomID: roomID, generation: generation, membership: "replacement")
        XCTAssertEqual(store.room?.viewerMembershipID, "replacement")
    }

    func testDurableIntentRestoresOnlyForSameActorWithoutDisplayingCachedRole() async throws {
        let directory = temporaryDirectory()
        let (transport, store) = makeStore(directory: directory)
        var secret = fixture()
        secret["secret_word"] = .string("Library")
        try store.adopt(.object(secret))
        transport.handler = { _ in throw URLError(.networkConnectionLost) }
        _ = try? await store.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        let restored = SupabaseFullGameStore(transport: transport, actorID: viewer, evidenceDirectory: directory, automaticallyWatches: false)
        XCTAssertEqual(restored.pending, store.pending)
        XCTAssertNil(restored.room)
        XCTAssertEqual(restored.snapshot, .null)
        let other = SupabaseFullGameStore(transport: transport, actorID: host, evidenceDirectory: directory, automaticallyWatches: false)
        XCTAssertNil(other.pending)
        XCTAssertNil(other.roomID)
    }

    func testMalformedReadDoesNotClearCurrentMembership() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        transport.handler = { _ in .object(["unexpected": .bool(true)]) }
        await expectCode("invalid_full_game_response") { _ = try await store.refreshRoom(id: self.roomID) }
        XCTAssertEqual(store.room?.viewerMembershipID, membershipID)
    }

    func testLostPackAcknowledgementRetriesOriginalCommandWithoutChangingActiveRoom() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        let adapter = SupabaseGameAdapter(store: store)
        transport.handler = { _ in throw URLError(.networkConnectionLost) }
        _ = try? await adapter.wordPackAction("create", packID: nil, name: "Test Pack", category: "Objects", words: ["Camera", "Phone"])
        let original = try XCTUnwrap(store.pending)
        transport.handler = { request in
            .object(["receipt": .object(["request_id": request["request_id"], "room_id": .null, "revision": .null]),
                     "pack": .object(["id": .string("60000000-0000-0000-0000-000000000001"), "name": .string("Test Pack"), "category": .string("Objects"), "words": .array([.string("Camera"), .string("Phone")])])])
        }
        let response = try await adapter.retrySavedCommand()
        let pack = try JSONDecoder().decode(WordPack.self, from: response["pack"].data())
        XCTAssertEqual(pack.words, ["Camera", "Phone"])
        XCTAssertEqual(transport.requests[1], original.body)
        XCTAssertEqual(store.room?.id, roomID)
        XCTAssertEqual(store.room?.roomRevision, 12)
        XCTAssertFalse(store.hasPendingRecovery)
    }

    func testTimeoutRecoversAutomaticallyWithOriginalRequestAndAuthoritativeRead() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        var writes = 0
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            writes += 1
            if writes == 1 { throw URLError(.timedOut) }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        _ = try? await store.command(["action": .string("advance_question"), "room_id": .string(roomID)])
        XCTAssertTrue(store.isRecoveringSavedCommand)
        await until { clock.delays.count == 1 }
        clock.advance()
        await until { !store.hasPendingRecovery }
        XCTAssertEqual(transport.requests[0], transport.requests[1])
        XCTAssertEqual(transport.requests[1]["expected_revision"].integer, 12)
        XCTAssertEqual(transport.requests[1]["expected_membership_id"].string, membershipID)
        XCTAssertEqual(transport.requests[1]["expected_match_id"].string, matchID)
        XCTAssertEqual(transport.requests.last?["action"].string, "get_room")
        XCTAssertEqual(store.room?.roomRevision, 13)
        XCTAssertEqual(store.recoveryGeneration, 1)
        XCTAssertEqual(store.recoveredAction, "advance_question")
        XCTAssertFalse(store.isRecoveringSavedCommand)
    }

    func testAcknowledgedMalformedProjectionRecoversAutomaticallyWithoutAnotherWrite() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            return self.response(request: request, room: .object(["id": .string(self.roomID)]), revision: 13)
        }
        await expectCode("invalid_full_game_response") {
            _ = try await store.command(["action": .string("mark_role_card_read"), "room_id": .string(self.roomID)])
        }
        XCTAssertNotNil(store.pending?.acknowledgement)
        await until { clock.delays.count == 1 }
        clock.advance()
        await until { !store.hasPendingRecovery }
        XCTAssertEqual(transport.requests.compactMap { $0["action"].string }, ["mark_role_card_read", "get_room"])
        XCTAssertEqual(store.room?.roomRevision, 13)
        XCTAssertEqual(store.recoveryGeneration, 1)
    }

    func testRecoveryBackoffIsBoundedAndForegroundWakeResumesSameIntent() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw URLError(.notConnectedToInternet) }
        _ = try? await store.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        for attempt in 1...4 {
            await until { clock.delays.count == attempt }
            clock.advance()
            await until { transport.requests.count == attempt + 1 && !store.commandInFlight }
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(clock.delays, [.milliseconds(400), .seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertTrue(store.hasPendingRecovery)
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        store.resumePendingRecovery()
        await until { !store.hasPendingRecovery }
        XCTAssertEqual(transport.requests[0], transport.requests[5])
        XCTAssertEqual(store.recoveryGeneration, 1)
    }

    func testConnectRestoresJournalAndRecoversWithoutUserRetry() async throws {
        let directory = temporaryDirectory()
        let (transport, original) = makeStore(directory: directory)
        try original.adopt(.object(fixture()))
        transport.handler = { _ in throw URLError(.networkConnectionLost) }
        _ = try? await original.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        let saved = try XCTUnwrap(original.pending)
        original.disconnect()
        let restored = SupabaseFullGameStore(evidenceDirectory: directory, automaticallyWatches: false)
        defer { restored.disconnect() }
        transport.handler = { request in
            if ["get_room", "get_active_room"].contains(request["action"].string ?? "") {
                return .object(["room": .object(self.fixture(revision: 13))])
            }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        try await restored.connect(transport: transport, name: "Viewer")
        await until { !restored.hasPendingRecovery }
        XCTAssertEqual(transport.requests.filter { $0["action"].string == "toggle_ready" }, [saved.body, saved.body])
        XCTAssertEqual(restored.room?.roomRevision, 13)
        XCTAssertEqual(restored.recoveryGeneration, 1)
    }

    func testConcurrentIdenticalTapsShareOneRequestAndNeverShowRecoveryForOrdinaryFlight() async throws {
        let (transport, store) = makeStore()
        let gate = RecoveryTestGate()
        try store.adopt(.object(fixture()))
        transport.handler = { request in
            await gate.wait()
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        let input: [String: JSONValue] = ["action": .string("toggle_ready"), "room_id": .string(roomID)]
        let first = Task { try await store.command(input) }
        await until { transport.requests.count == 1 }
        let second = Task { try await store.command(input) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(store.commandInFlight)
        XCTAssertFalse(store.isRecoveringSavedCommand)
        XCTAssertEqual(transport.requests.count, 1)
        gate.open()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a, b)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(store.recoveryGeneration, 0)
    }

    func testDuplicateDifferentTapsQueuedBehindAnotherCommandShareTheirRequest() async throws {
        let (transport, store) = makeStore()
        let firstGate = RecoveryTestGate()
        let secondGate = RecoveryTestGate()
        try store.adopt(.object(fixture()))
        transport.handler = { request in
            if request["action"].string == "toggle_ready" { await firstGate.wait() }
            else { await secondGate.wait() }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        let first = Task { try await store.command(["action": .string("toggle_ready"), "room_id": .string(self.roomID)]) }
        await until { transport.requests.count == 1 }
        let next: [String: JSONValue] = ["action": .string("mark_role_card_read"), "room_id": .string(roomID)]
        let second = Task { try await store.command(next) }
        let duplicate = Task { try await store.command(next) }
        for _ in 0..<10 { await Task.yield() }
        firstGate.open()
        _ = try await first.value
        await until { transport.requests.count == 2 }
        secondGate.open()
        let a = try await second.value
        let b = try await duplicate.value
        XCTAssertEqual(a, b)
        XCTAssertEqual(transport.requests.compactMap { $0["action"].string }, ["toggle_ready", "mark_role_card_read"])
    }

    func testDifferentActionAutomaticallyResolvesPreviousIntentBeforeSending() async throws {
        let (transport, store) = makeStore()
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw URLError(.timedOut) }
        _ = try? await store.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        let saved = try XCTUnwrap(store.pending)
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        _ = try await store.command(["action": .string("mark_role_card_read"), "room_id": .string(roomID)])
        XCTAssertEqual(transport.requests[1], saved.body)
        XCTAssertEqual(transport.requests.compactMap { $0["action"].string }, ["toggle_ready", "toggle_ready", "get_room", "mark_role_card_read"])
        XCTAssertFalse(store.hasPendingRecovery)
    }

    func testQueuedTurnNeverRebindsAfterPrecedingCommandChangesRevision() async throws {
        let (transport, store) = makeStore()
        let gate = RecoveryTestGate()
        try store.adopt(.object(fixture()))
        transport.handler = { request in
            await gate.wait()
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        let first = Task { try await store.command(["action": .string("toggle_ready"), "room_id": .string(self.roomID)]) }
        await until { transport.requests.count == 1 }
        let next = Task { try await store.command(["action": .string("advance_question"), "room_id": .string(self.roomID)]) }
        for _ in 0..<10 { await Task.yield() }
        gate.open()
        _ = try await first.value
        await expectCode("stale_room_context") { _ = try await next.value }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDelayedOldAccountCommandCannotMutateNewConnectionOrPublishRecovery() async throws {
        let (transport, store) = makeStore()
        let gate = RecoveryTestGate()
        try store.adopt(.object(fixture()))
        transport.handler = { request in
            await gate.wait()
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        let old = Task { try await store.command(["action": .string("toggle_ready"), "room_id": .string(self.roomID)]) }
        await until { transport.requests.count == 1 }
        let other = FakeFullGameTransport(userID: host)
        other.handler = { _ in .object(["room": .null]) }
        try await store.connect(transport: other, name: "Host")
        gate.open()
        do { _ = try await old.value; XCTFail("Old connection must be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.userID, host)
        XCTAssertNil(store.room)
        XCTAssertNil(store.pending)
        XCTAssertEqual(store.lastReceipt, .null)
        XCTAssertEqual(store.recoveryGeneration, 0)
        XCTAssertFalse(store.isRecoveringSavedCommand)
    }

    func testDelayedReadCannotChangeSameAccountAfterReconnect() async throws {
        let (transport, store) = makeStore()
        let gate = RecoveryTestGate()
        try store.adopt(.object(fixture()))
        transport.handler = { _ in
            await gate.wait()
            return .object(["room": .object(self.fixture(revision: 13))])
        }
        let old = Task { try await store.refreshRoom(id: self.roomID) }
        await until { transport.requests.count == 1 }
        let replacement = FakeFullGameTransport(userID: viewer)
        replacement.handler = { _ in .object(["room": .null]) }
        try await store.connect(transport: replacement, name: "Viewer")
        gate.open()
        await expectCode("stale_room_context") { _ = try await old.value }
        XCTAssertNil(store.room)
        XCTAssertNil(store.roomID)
    }

    func testReplayedReceiptCannotResurrectMembershipAfterAuthoritativeRemoval() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw URLError(.timedOut) }
        _ = try? await store.command(["action": .string("mark_role_card_read"), "room_id": .string(roomID)])
        transport.handler = { request in
            if request["action"].string == "get_room" { throw Base44Error(message: "Removed", statusCode: 403, code: "not_member") }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        _ = try await store.refreshRoom(id: roomID)
        XCTAssertNil(store.room)
        await until { clock.delays.count == 1 }
        clock.advance()
        await until { !store.hasPendingRecovery }
        XCTAssertNil(store.room)
        XCTAssertNil(store.roomID)
        XCTAssertEqual(store.recoveredResponse["room"], .null)
        XCTAssertEqual(transport.requests.filter { $0["action"].string == "mark_role_card_read" }.count, 2)
    }

    func testRetryableHTTPFailureKeepsOriginalIntentForAutomaticRecovery() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw FullGameTransportFailure(error: Base44Error(message: "Slow down", statusCode: 429, code: "rate_limited", retryable: true), ambiguous: false) }
        await expectCode("rate_limited") { _ = try await store.command(["action": .string("toggle_ready"), "room_id": .string(self.roomID)]) }
        XCTAssertNotNil(store.pending)
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        await until { clock.delays.count == 1 }
        clock.advance()
        await until { !store.hasPendingRecovery }
        XCTAssertEqual(transport.requests[0], transport.requests[1])
    }

    func testServerCooldownIsRespectedAcrossForegroundRecoveryWake() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep, recoveryNow: { clock.now })
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw FullGameTransportFailure(error: Base44Error(message: "Slow down", statusCode: 429, code: "rate_limited", retryable: true, retryAfterSeconds: 30), ambiguous: false) }
        _ = try? await store.command(["action": .string("toggle_ready"), "room_id": .string(roomID)])
        await until { clock.delays.count == 1 }
        XCTAssertEqual(clock.delays, [.seconds(30)])
        store.resumePendingRecovery()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(transport.requests.count, 1)
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        clock.advance()
        await until { !store.hasPendingRecovery }
        XCTAssertEqual(transport.requests[0], transport.requests[1])
    }

    func testForegroundConsumerOfBackgroundRetryDoesNotPublishDuplicateCompletion() async throws {
        let clock = RecoveryTestClock()
        let gate = RecoveryTestGate()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        let input: [String: JSONValue] = ["action": .string("toggle_ready"), "room_id": .string(roomID)]
        transport.handler = { _ in throw URLError(.timedOut) }
        _ = try? await store.command(input)
        transport.handler = { request in
            if request["action"].string == "get_room" { return .object(["room": .object(self.fixture(revision: 13))]) }
            await gate.wait()
            return self.response(request: request, room: .object(self.fixture(revision: 13)), revision: 13)
        }
        await until { clock.delays.count == 1 }
        clock.advance()
        await until { transport.requests.count == 2 }
        let foreground = Task { try await store.command(input) }
        for _ in 0..<10 { await Task.yield() }
        gate.open()
        _ = try await foreground.value
        XCTAssertFalse(store.hasPendingRecovery)
        XCTAssertEqual(store.recoveryGeneration, 0)
        XCTAssertEqual(transport.requests.filter { $0["action"].string == "toggle_ready" }.count, 2)
    }

    func testDefinitiveRejectionNeverEntersAutomaticRecovery() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        try store.adopt(.object(fixture()))
        transport.handler = { _ in throw FullGameTransportFailure(error: Base44Error(message: "Changed", statusCode: 409, code: "room_revision_conflict"), ambiguous: false) }
        await expectCode("room_revision_conflict") { _ = try await store.command(["action": .string("advance_question"), "room_id": .string(self.roomID)]) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(store.hasPendingRecovery)
        XCTAssertFalse(store.isRecoveringSavedCommand)
        XCTAssertTrue(clock.delays.isEmpty)
        XCTAssertEqual(store.recoveryGeneration, 0)
    }

    func testBackgroundPackRecoveryPublishesOriginalReceiptAndPackOnce() async throws {
        let clock = RecoveryTestClock()
        let (transport, store) = makeStore(automaticallyRecovers: true, recoverySleep: clock.sleep)
        let input: [String: JSONValue] = ["action": .string("create_word_pack"), "name": .string("Objects"), "words": .array([.string("Camera")])]
        transport.handler = { _ in throw URLError(.timedOut) }
        _ = try? await store.command(input)
        let saved = try XCTUnwrap(store.pending)
        transport.handler = { request in
            .object(["receipt": .object(["request_id": request["request_id"]]),
                     "pack": .object(["id": .string("60000000-0000-0000-0000-000000000001"), "name": .string("Objects"), "words": .array([.string("Camera")])])])
        }
        await until { clock.delays.count == 1 }
        clock.advance()
        await until { !store.hasPendingRecovery }
        XCTAssertEqual(store.recoveryGeneration, 1)
        XCTAssertEqual(store.recoveredAction, "create_word_pack")
        XCTAssertEqual(store.recoveredResponse["receipt"]["request_id"].string, saved.requestID)
        XCTAssertEqual(store.recoveredResponse["pack"]["name"].string, "Objects")
        store.resumePendingRecovery()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.recoveryGeneration, 1)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testGeneratorStaysOnBase44AndNeverCallsSupabase() async throws {
        let (transport, store) = makeStore()
        let adapter = SupabaseGameAdapter(store: store)
        await expectCode("base44_generation_requires_auth") {
            _ = try await adapter.generateWordPack(theme: "Places", count: 20, requestID: UUID(), excluding: [], preferFresh: false)
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(store.hasPendingRecovery)
    }

    private func expectCode(_ code: String, operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as Base44Error { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected \(type(of: error))", file: file, line: line) }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Expected controlled asynchronous operation to finish", file: file, line: line)
    }

    private func makeStore(directory: URL? = nil, automaticallyRecovers: Bool = false,
                           recoverySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           recoveryNow: @escaping () -> ContinuousClock.Instant = { .now }) -> (FakeFullGameTransport, SupabaseFullGameStore) {
        let transport = FakeFullGameTransport(userID: viewer)
        let store = SupabaseFullGameStore(transport: transport, actorID: viewer, evidenceDirectory: directory ?? temporaryDirectory(), automaticallyWatches: false,
                                          automaticallyRecovers: automaticallyRecovers, recoverySleep: recoverySleep, recoveryNow: recoveryNow)
        addTeardownBlock { @MainActor in store.disconnect() }
        return (transport, store)
    }
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("full-game-unit-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func alias(_ id: String) -> String { SupabaseGameAdapter.alias(for: id) }
    private func response(request: JSONValue, room: JSONValue, revision: Int) -> JSONValue {
        .object(["room": room, "revision": .number(Double(revision)), "receipt": .object([
            "request_id": request["request_id"], "room_id": .string(roomID), "revision": .number(Double(revision))
        ])])
    }
    private func fixture(revision: Int = 12) -> [String: JSONValue] {
        ["id": .string(roomID), "code": .string("ABC123"), "host_email": .string(alias(host)), "status": .string("playing"),
         "match_id": .string(matchID), "viewer_membership_id": .string(membershipID), "room_revision": .number(Double(revision)), "lobby_revision": .number(3),
         "game_started_at": .string("2026-10-12T20:00:00Z"), "game_duration_seconds": .number(600), "game_paused_total_seconds": .number(9),
         "game_mode": .string("questions"), "question_phase": .string("asking"), "current_answer": .string(#"{"kind":"question_turn_order_v1","order":["a","b"]}"#),
         "cards_read": .array([]), "players": .array([
            .object(["email": .string(alias(viewer)), "name": .string("Viewer"), "avatar": .string("🕵️"), "user_id": .string(viewer), "membership_id": .string(membershipID)]),
            .object(["email": .string(alias(host)), "name": .string("Host"), "avatar": .string("🎭"), "user_id": .string(host)])])]
    }
}

@MainActor
private final class FakeFullGameTransport: SupabaseFullGameTransport {
    let userID: String
    var onRealtime: ((String, JSONValue?) -> Void)?
    var requests: [JSONValue] = []
    var handler: ((JSONValue) async throws -> JSONValue)?
    init(userID: String) { self.userID = userID }
    func fullGame(_ body: JSONValue) async throws -> JSONValue {
        requests.append(body)
        guard let handler else { throw URLError(.notConnectedToInternet) }
        return try await handler(body)
    }
    func watch(roomID: String, table: String) async throws {}
    func disconnectRealtime() {}
}

/// Explicit continuations make network/retry ordering deterministic; no test
/// waits for the production backoff or depends on a live backend.
@MainActor
private final class RecoveryTestClock {
    private(set) var delays: [Duration] = []
    private(set) var now = ContinuousClock.now
    private var sleepers: [(Duration, CheckedContinuation<Void, Never>)] = []
    func sleep(_ duration: Duration) async throws {
        delays.append(duration)
        await withCheckedContinuation { sleepers.append((duration, $0)) }
        try Task.checkCancellation()
    }
    func advance() {
        guard !sleepers.isEmpty else { return }
        let (duration, sleeper) = sleepers.removeFirst()
        now = now.advanced(by: duration)
        sleeper.resume()
    }
}

@MainActor
private final class RecoveryTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
