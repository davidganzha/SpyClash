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

    func testPendingBlocksDifferentActionAndRoomWithoutTransport() async throws {
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
        XCTAssertEqual(transport.requests.count, 1)
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

    private func makeStore(directory: URL? = nil) -> (FakeFullGameTransport, SupabaseFullGameStore) {
        let transport = FakeFullGameTransport(userID: viewer)
        let store = SupabaseFullGameStore(transport: transport, actorID: viewer, evidenceDirectory: directory ?? temporaryDirectory(), automaticallyWatches: false)
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
