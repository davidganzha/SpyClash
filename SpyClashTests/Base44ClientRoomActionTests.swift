import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class Base44ClientRoomActionTests: XCTestCase {
    func testRoundWrappersSendServerActionNames() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "playing")

        _ = try await client.startAssociation(room: room)
        _ = try await client.stopAssociationSpin(room: room)
        _ = try await client.markAnswerHeard(room: room)
        _ = try await client.continueRound(room: room)

        XCTAssertEqual(
            try recorder.requestBodies().map { try XCTUnwrap($0["action"] as? String) },
            ["start_association", "stop_association_spin", "mark_answer_heard", "continue_round"]
        )
        XCTAssertTrue(
            try recorder.requestBodies().allSatisfy {
                ($0["room_id"] as? String) == room.id &&
                    ($0["access_token"] as? String) == "test-token"
            }
        )
    }

    func testActiveRoomSendsPreferredIDAndDecodesNull() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("null".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = try await client.activeRoom(preferredRoomID: "room-from-web")

        XCTAssertNil(room)
        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "get_active_room")
        XCTAssertEqual(body["room_id"] as? String, "room-from-web")
        XCTAssertEqual(body["access_token"] as? String, "test-token")
    }

    func testSavedPackExclusionsAreFrozenIntoStartPlanAndTransport() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let disabledKeys = Set([RoomWordPoolFilter.key("removed")])
        let activeWords = RoomWordPoolFilter.activeWords(
            [" keep-a ", "removed", "KEEP-A", "keep-b"],
            excluding: disabledKeys
        )
        XCTAssertEqual(activeWords, ["keep-a", "keep-b"])

        let pack = WordPack(
            id: "pack-1",
            name: "Fresh pack",
            category: "TEST",
            words: activeWords,
            ownerEmail: "operative@example.com",
            isPublic: false
        )
        let client = makeClient()
        let room = GameRoom.previewRoom(status: "waiting")
        let plan = try client.makeGameStartPlan(
            room: room,
            wordPacks: [pack],
            selectedPackID: pack.id,
            gameMode: .questions,
            durationSeconds: 600
        )

        _ = try await client.armRoulette(room: room, plan: plan)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        let planBody = try XCTUnwrap(body["plan"] as? [String: Any])
        let secretWord = try XCTUnwrap(planBody["secret_word"] as? String)
        let pool = try XCTUnwrap(planBody["word_pool"] as? [[String: Any]])
        let transportedWords = try pool.map { try XCTUnwrap($0["word"] as? String) }

        XCTAssertEqual(Set(transportedWords), Set(activeWords))
        XCTAssertTrue(pool.allSatisfy { ($0["enabled"] as? Bool) == true })
        XCTAssertTrue(activeWords.contains(secretWord))
        XCTAssertFalse(transportedWords.contains("removed"))
    }

    func testGameRoomDecodesAuthoritativeLobbyProjection() throws {
        let room = try JSONDecoder().decode(
            GameRoom.self,
            from: Data(
                #"{"id":"room-1","code":"ABC123","lobby_schema_version":1,"lobby_revision":7,"lobby_word_source":"ai","lobby_source_pack_id":"pack-1","lobby_source_name":"Night Ops","lobby_theme":"espionage","lobby_category":"COVERT","lobby_word_count":42,"lobby_word_count_mode":"custom","lobby_word_pool":[{"id":"word-1","word":"Embassy","enabled":false},{"id":"word-2","word":"Cipher"}]}"#.utf8
            )
        )

        XCTAssertEqual(room.lobbySchemaVersion, 1)
        XCTAssertEqual(room.lobbyRevision, 7)
        XCTAssertEqual(room.lobbyWordSource, "ai")
        XCTAssertEqual(room.lobbySourcePackID, "pack-1")
        XCTAssertEqual(room.lobbySourceName, "Night Ops")
        XCTAssertEqual(room.lobbyTheme, "espionage")
        XCTAssertEqual(room.lobbyCategory, "COVERT")
        XCTAssertEqual(room.lobbyWordCount, 42)
        XCTAssertEqual(room.lobbyWordCountMode, "custom")
        XCTAssertEqual(room.lobbyWordPool?.map(\.id), ["word-1", "word-2"])
        XCTAssertEqual(room.lobbyWordPool?.map(\.enabled), [false, true])
    }

    func testLobbyStatePayloadEncodesExactBackendKeys() throws {
        let payload = LobbyStatePayload(
            gameMode: .associations,
            gameDurationSeconds: 300,
            lobbyWordSource: .manual,
            lobbySourcePackID: nil,
            lobbySourceName: "Hand-picked",
            lobbyTheme: nil,
            lobbyCategory: "CUSTOM",
            lobbyWordCount: 2,
            lobbyWordCountMode: .custom,
            lobbyWordPool: [
                LobbyWordPoolEntry(id: "word-1", word: "Embassy"),
                LobbyWordPoolEntry(word: "Cipher", enabled: false)
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )

        XCTAssertEqual(object["game_mode"] as? String, "associations")
        XCTAssertEqual(object["game_duration_seconds"] as? Int, 300)
        XCTAssertEqual(object["lobby_word_source"] as? String, "manual")
        XCTAssertNil(object["lobby_source_pack_id"])
        XCTAssertEqual(object["lobby_source_name"] as? String, "Hand-picked")
        XCTAssertNil(object["lobby_theme"])
        XCTAssertEqual(object["lobby_category"] as? String, "CUSTOM")
        XCTAssertEqual(object["lobby_word_count"] as? Int, 2)
        XCTAssertEqual(object["lobby_word_count_mode"] as? String, "custom")

        let words = try XCTUnwrap(object["lobby_word_pool"] as? [[String: Any]])
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0]["id"] as? String, "word-1")
        XCTAssertEqual(words[0]["word"] as? String, "Embassy")
        XCTAssertEqual(words[0]["enabled"] as? Bool, true)
        XCTAssertNil(words[1]["id"])
        XCTAssertEqual(words[1]["enabled"] as? Bool, false)
    }

    func testUpdateLobbyStateSendsRevisionedMutationEnvelope() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "waiting")
        let state = LobbyStatePayload(
            gameMode: .questions,
            gameDurationSeconds: 900,
            lobbyWordSource: .saved,
            lobbySourcePackID: "pack-1",
            lobbySourceName: "Classic",
            lobbyTheme: nil,
            lobbyCategory: "CLASSIC",
            lobbyWordCount: 25,
            lobbyWordCountMode: .recommended,
            lobbyWordPool: [LobbyWordPoolEntry(id: "word-1", word: "Embassy")]
        )

        _ = try await client.updateLobbyState(
            room: room,
            mutationID: "mutation-7",
            expectedRevision: 6,
            state: state
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "update_lobby_state")
        XCTAssertEqual(body["room_id"] as? String, room.id)
        XCTAssertEqual(body["access_token"] as? String, "test-token")
        XCTAssertEqual(body["mutation_id"] as? String, "mutation-7")
        XCTAssertEqual(body["expected_revision"] as? Int, 6)
        let encodedState = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(encodedState["game_mode"] as? String, "questions")
        XCTAssertEqual(encodedState["lobby_source_pack_id"] as? String, "pack-1")
    }

    func testArmRouletteSendsExpectedLobbyRevision() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        var room = GameRoom.previewRoom(status: "waiting")
        room.lobbyRevision = 12
        let plan = try client.makeGameStartPlan(
            room: room,
            wordPacks: [],
            selectedPackID: nil,
            gameMode: .questions,
            durationSeconds: 900
        )

        _ = try await client.armRoulette(room: room, plan: plan)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "arm_roulette")
        XCTAssertEqual(body["expected_lobby_revision"] as? Int, 12)
    }

    func testRadarInvitePolicyUsesAuthenticatedCommunityActionContract() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"radar_invite_policy":"automatic"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let confirmed = try await makeClient().updateRadarInvitePolicy(.automatic)

        XCTAssertEqual(confirmed, .automatic)
        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "set_radar_invite_policy")
        XCTAssertEqual(body["radar_invite_policy"] as? String, "automatic")
        XCTAssertEqual(body["access_token"] as? String, "test-token")
        XCTAssertTrue(try XCTUnwrap(recorder.requestURLs().first).absoluteString.contains("communityAction"))
    }

    func testRadarInvitePolicyFallbackMigratesLegacyValueOnlyOnceAndScopesAccounts() throws {
        let suiteName = "Base44ClientRoomActionTests.RadarInvitePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("automatic", forKey: RadarInvitePolicy.legacyStorageKey)

        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-a", defaults: defaults), .automatic)
        XCTAssertNil(defaults.string(forKey: RadarInvitePolicy.legacyStorageKey))
        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-b", defaults: defaults), .ask)

        RadarInvitePolicy.blocked.persist(for: "account-b", defaults: defaults)
        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-a", defaults: defaults), .automatic)
        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-b", defaults: defaults), .blocked)
    }

    func testSpyUserDecodesSharedRadarInvitePolicyField() throws {
        let user = try JSONDecoder().decode(
            SpyUser.self,
            from: Data(#"{"id":"user-1","email":"operative@example.com","radar_invite_policy":"blocked"}"#.utf8)
        )

        XCTAssertEqual(user.radarInvitePolicy, "blocked")
    }

    func testPendingRadarRetryProtectsLocalPolicyFromStaleSameAccountRefresh() {
        XCTAssertTrue(
            AppState.hasUncommittedRadarInvitePolicy(
                userID: "user-1",
                syncOwnerUserID: "user-1",
                syncState: .pendingRetry,
                hasQueuedWrite: false
            )
        )
        XCTAssertFalse(
            AppState.hasUncommittedRadarInvitePolicy(
                userID: "user-2",
                syncOwnerUserID: "user-1",
                syncState: .pendingRetry,
                hasQueuedWrite: false
            )
        )
        XCTAssertFalse(
            AppState.hasUncommittedRadarInvitePolicy(
                userID: "user-1",
                syncOwnerUserID: "user-1",
                syncState: .synced,
                hasQueuedWrite: false
            )
        )
    }

    func testRadarPresenceSnapshotRoundTripsAvailabilityPolicyAndRevision() throws {
        let snapshot = RadarPresenceSnapshot(
            availability: .inGame,
            invitePolicy: .blocked,
            revision: 42
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RadarPresenceSnapshot.self, from: encoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(object["availability"] as? String, "in_game")
        XCTAssertEqual(object["invitePolicy"] as? String, "blocked")
        XCTAssertEqual(object["revision"] as? Int, 42)
    }

    func testRadarPresenceVersionRejectsStaleDiscoveryAfterLiveUpdate() {
        XCTAssertTrue(
            RadarPresenceVersionPolicy.shouldApply(incoming: 12, current: 11)
        )
        XCTAssertTrue(
            RadarPresenceVersionPolicy.shouldApply(incoming: 12, current: 12)
        )
        XCTAssertFalse(
            RadarPresenceVersionPolicy.shouldApply(incoming: 11, current: 12)
        )
        XCTAssertFalse(
            RadarPresenceVersionPolicy.shouldApply(incoming: nil, current: 12)
        )
        XCTAssertTrue(
            RadarPresenceVersionPolicy.shouldApply(incoming: nil, current: 0)
        )
    }

    func testRadarPresenceTransitionsBlockAndUnblockExistingCard() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .blocked,
                currentState: .waiting
            ),
            .blocked
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .ask,
                currentState: .blocked
            )
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .automatic,
                currentState: .accepted
            )
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .automatic,
                currentState: .inGame
            )
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .automatic,
                availability: .available,
                invitationState: nil
            ),
            .send
        )
    }

    func testRadarRoomInviteQueuesBehindPresenceConnectionAttempt() {
        XCTAssertTrue(
            RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: false,
                hasPresenceAttempt: true,
                isConnecting: false
            )
        )
        XCTAssertTrue(
            RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: false,
                hasPresenceAttempt: false,
                isConnecting: true
            )
        )
        XCTAssertFalse(
            RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: false,
                hasPresenceAttempt: false,
                isConnecting: false
            )
        )
    }

    func testBlockingRadarInvitesDismissesExistingIncomingCard() {
        let radar = RadarNearbyService()
        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "ABC123",
                hostCallSign: "Host",
                hostAvatar: "🕵️"
            )
        )

        radar.setInvitePolicy(.blocked)
        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "XYZ789",
                hostCallSign: "Second Host",
                hostAvatar: "🥷"
            )
        )

        XCTAssertNil(radar.incomingInvitation)
    }

    func testRadarDoesNotResurrectUntrackedWireInvitation() {
        let radar = RadarNearbyService()

        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "ABC123",
                hostCallSign: "Host",
                hostAvatar: "🕵️",
                wireInvitationID: "cancelled-invite",
                sourcePeerID: "lost-peer"
            )
        )

        XCTAssertNil(radar.incomingInvitation)
    }

    func testRadarProfileRefreshPreservesInviteButAccountChangeClearsIt() {
        let radar = RadarNearbyService()
        let originalUser = makeRadarUser(
            id: "account-a",
            avatar: "🕵️",
            rating: 10,
            policy: .ask
        )
        let refreshedUser = makeRadarUser(
            id: "account-a",
            avatar: "🥷",
            rating: 25,
            policy: .ask
        )
        let nextAccount = makeRadarUser(
            id: "account-b",
            avatar: "🕶️",
            rating: 0,
            policy: .ask
        )
        let invitation = RadarIncomingInvitation(
            roomCode: "ABC123",
            hostCallSign: "Host",
            hostAvatar: "🕵️"
        )

        radar.configure(user: originalUser)
        radar.presentForConfirmation(invitation)
        radar.configure(user: refreshedUser)

        XCTAssertEqual(radar.incomingInvitation, invitation)

        radar.configure(user: nextAccount)

        XCTAssertNil(radar.incomingInvitation)
    }

    func testRadarCombinedProfileAndBlockedPolicyRefreshDismissesInvite() {
        let radar = RadarNearbyService()
        radar.configure(
            user: makeRadarUser(
                id: "account-a",
                avatar: "🕵️",
                rating: 10,
                policy: .ask
            )
        )
        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "ABC123",
                hostCallSign: "Host",
                hostAvatar: "🕵️"
            )
        )

        radar.configure(
            user: makeRadarUser(
                id: "account-a",
                avatar: "🥷",
                rating: 25,
                policy: .blocked
            )
        )

        XCTAssertNil(radar.incomingInvitation)
        XCTAssertEqual(radar.invitePolicy, .blocked)
    }

    private func makeRadarUser(
        id: String,
        avatar: String,
        rating: Int,
        policy: RadarInvitePolicy
    ) -> SpyUser {
        SpyUser(
            id: id,
            email: "\(id)@example.com",
            fullName: nil,
            displayName: id,
            avatar: avatar,
            language: nil,
            role: nil,
            isVerified: nil,
            rating: rating,
            gamesPlayed: 3,
            gamesWon: 2,
            remoteSpyID: id == "account-a" ? "123456" : "654321",
            spyCardTheme: nil,
            spyCardAccent: nil,
            spyCardBadge: nil,
            radarInvitePolicy: policy.rawValue
        )
    }

    private func makeClient() -> Base44Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("test-token")
        return client
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private var urls: [URL] = []

    func append(_ request: URLRequest) throws {
        let data = try Self.bodyData(from: request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        lock.lock()
        bodies.append(body)
        if let url = request.url {
            urls.append(url)
        }
        lock.unlock()
    }

    func requestBodies() throws -> [[String: Any]] {
        lock.lock()
        let snapshot = bodies
        lock.unlock()
        return snapshot
    }

    func requestURLs() -> [URL] {
        lock.lock()
        let snapshot = urls
        lock.unlock()
        return snapshot
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotDecodeContentData)
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func roomResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let payload = #"{"id":"room-1","code":"ABC123","status":"playing","players":[]}"#
        return (response, Data(payload.utf8))
    }
}
