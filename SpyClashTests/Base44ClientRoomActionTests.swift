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
