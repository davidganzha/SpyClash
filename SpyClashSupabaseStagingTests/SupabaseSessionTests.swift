import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class SupabaseSessionTests: XCTestCase {
    private let actor = "11111111-1111-4111-8111-111111111111"

    func testStagingConfigurationRejectsProductionAndSecretKeys() throws {
        XCTAssertThrowsError(try SupabaseAppConfiguration(backendURL: "https://spyclash.com", publishableKey: "sb_publishable_test").validated())
        XCTAssertThrowsError(try SupabaseAppConfiguration(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_secret_test").validated())
        XCTAssertNoThrow(try SupabaseAppConfiguration(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test").validated())
    }

    func testSessionRequiresRefreshTokenAndValidActor() throws {
        let value: JSONValue = .object(["access_token": .string("access"), "refresh_token": .string("refresh"), "expires_in": .number(3600), "user": .object(["id": .string(actor)])])
        let session = try SupabaseAppSession.decodeSession(value)
        XCTAssertEqual(session.userID, actor)
        XCTAssertGreaterThan(session.expiresAt.timeIntervalSinceNow, 3500)
        var bad = value.object!; bad["refresh_token"] = .string("")
        XCTAssertThrowsError(try SupabaseAppSession.decodeSession(.object(bad)))
        bad = value.object!; bad["user"] = .object(["id": .string("someone-else")])
        XCTAssertThrowsError(try SupabaseAppSession.decodeSession(.object(bad)))
    }

    func testPrivateContactEmailDoesNotReplaceGameIdentity() throws {
        let data = Data("{\"id\":\"\(actor)\",\"email\":\"\(actor)@example.test\",\"contact_email\":\"person@example.com\",\"display_name\":\"Operative\"}".utf8)
        let user = try JSONDecoder().decode(SpyUser.self, from: data)
        XCTAssertEqual(user.email, actor + "@example.test")
        XCTAssertEqual(user.accountEmail, "person@example.com")
        XCTAssertEqual(user.callSign, "Operative")
    }

    func testFreshSessionNeedsNoRefreshAndCannotCommitUnknownToken() async throws {
        let stored = SupabaseStoredSession(accessToken: "known", refreshToken: "refresh", userID: actor, expiresAt: Date().addingTimeInterval(3600))
        let session = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), storedSession: stored, saveSession: { _ in }, clearSession: {})
        let token = try await session.ensureAccessToken()
        XCTAssertEqual(token, "known")
        XCTAssertThrowsError(try session.commit(accessToken: "unowned-candidate"))
        XCTAssertEqual(session.userID, actor)
    }

    func testOAuthDisabledWithoutProviderConfiguration() throws {
        let session = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), storedSession: nil, saveSession: { _ in }, clearSession: {})
        XCTAssertFalse(try session.configuration().googleSignInEnabled)
        XCTAssertFalse(try session.configuration().appleSignInEnabled)
        XCTAssertNil(session.accessToken)
    }

    func testEmailOTPConfigurationAndValidationUseSixBase44Digits() throws {
        let data = Data("{\"backendURL\":\"https://bbkfsgnordtdiblgdzkg.supabase.co\",\"publishableKey\":\"sb_publishable_test\",\"appleSignInEnabled\":false,\"googleSignInEnabled\":false,\"emailOTPLength\":6}".utf8)
        var configuration = try JSONDecoder().decode(SupabaseAppConfiguration.self, from: data).validated()
        XCTAssertEqual(configuration.resolvedEmailOTPLength, 6)
        XCTAssertTrue(SupabaseAppRuntime.acceptsEmailOTP("123456", length: configuration.resolvedEmailOTPLength))
        for invalid in ["12345", "1234567", "12345678", "12345x", "１２３４５６"] {
            XCTAssertFalse(SupabaseAppRuntime.acceptsEmailOTP(invalid, length: configuration.resolvedEmailOTPLength))
        }
        configuration.emailOTPLength = nil
        XCTAssertEqual(configuration.resolvedEmailOTPLength, 6)
        configuration.emailOTPLength = 3
        XCTAssertThrowsError(try configuration.validated())
    }

    func testEmailOTPRejectsEightDigitsBeforeBase44Networking() async throws {
        StagingURLProtocol.state.reset(response: Data())
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [StagingURLProtocol.self]
        let auth = SupabaseLegacyAuth(session: URLSession(configuration: network))
        do { _ = try await auth.verify(email: "person@example.com", code: "12345678"); XCTFail("An eight-digit Supabase code must not be sent to Base44") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "invalid_email_otp") }
        XCTAssertEqual(StagingURLProtocol.state.count, 0)
    }
}

private final class StagingURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var response = Data()
        var responses: [String: Data] = [:]
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var statusCode = 200
        func reset(response: Data, statusCode: Int = 200) { lock.lock(); defer { lock.unlock() }; calls = 0; self.response = response; responses = [:]; requests = []; bodies = []; self.statusCode = statusCode }
        func reset(responses: [String: Data]) { lock.lock(); defer { lock.unlock() }; calls = 0; response = Data(); self.responses = responses; requests = []; bodies = []; statusCode = 200 }
        func next(request: URLRequest, body: Data) -> Data { lock.lock(); defer { lock.unlock() }; calls += 1; requests.append(request); bodies.append(body); return responses[request.url?.path ?? ""] ?? response }
        var recordedRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        var recordedBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { ["bbkfsgnordtdiblgdzkg.supabase.co", "spyclash.com"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let data = Self.state.next(request: request, body: body)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.state.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension SupabaseSessionTests {
    func testConcurrentRefreshRevalidatesLegacyWithOneExchange() async throws {
        let userID = "11111111-1111-4111-8111-111111111111"
        StagingURLProtocol.state.reset(response: Data("{\"access_token\":\"new-access\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600,\"legacy_user_id\":\"legacy-person\",\"user\":{\"id\":\"\(userID)\"}}".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        let http = URLSession(configuration: configuration)
        let expired = SupabaseStoredSession(accessToken: "expired", refreshToken: "one-use-refresh", userID: userID, expiresAt: .distantPast)
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: http, storedSession: expired, saveSession: { _ in }, clearSession: {}, storedLegacy: .init(actorID: userID, legacyUserID: "legacy-person", accessToken: "legacy-bearer"), saveLegacy: { _ in }, clearLegacy: {})
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await auth.ensureAccessToken() } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(tokens, Array(repeating: "new-access", count: 8))
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.url?.path, "/functions/v1/legacy-session")
        XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer legacy-bearer")
        XCTAssertEqual(auth.session?.refreshToken, "rotated-refresh")
    }
}

extension SupabaseSessionTests {
    func testLegacyExchangeRemainsUncommittedUntilAuthOwnerAccepts() async throws {
        let userID = "22222222-2222-4222-8222-222222222222"
        StagingURLProtocol.state.reset(responses: [
            "/functions/v1/legacy-session": Data("{\"access_token\":\"candidate\",\"refresh_token\":\"candidate-refresh\",\"expires_in\":3600,\"legacy_user_id\":\"legacy-person\",\"user\":{\"id\":\"\(userID)\"}}".utf8),
            "/functions/v1/app-services": Data("{\"id\":\"\(userID)\",\"email\":\"\(userID)@example.test\",\"contact_email\":\"person@example.com\"}".utf8)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        var saved: [SupabaseStoredSession] = []
        var legacySaved: [SupabaseLegacyCredential] = []
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: URLSession(configuration: configuration), storedSession: nil, saveSession: { saved.append($0) }, clearSession: {}, storedLegacy: nil, saveLegacy: { legacySaved.append($0) }, clearLegacy: {})
        let response = try await auth.exchangeLegacySession("legacy-bearer")
        XCTAssertEqual(response.user.id, userID)
        XCTAssertNil(auth.accessToken)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(legacySaved.isEmpty)
        try auth.commit(accessToken: response.accessToken)
        XCTAssertEqual(auth.userID, userID)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(legacySaved.first?.accessToken, "legacy-bearer")
        XCTAssertEqual(try auth.legacyAccessToken(), "legacy-bearer")
        let requests = StagingURLProtocol.state.recordedRequests
        XCTAssertEqual(requests.first(where: { $0.url?.path == "/functions/v1/legacy-session" })?.timeoutInterval, 90)
        XCTAssertEqual(requests.first(where: { $0.url?.path == "/functions/v1/app-services" })?.timeoutInterval, 20)
        XCTAssertGreaterThanOrEqual(SupabaseAppSession.transportConfiguration().timeoutIntervalForResource, 90)
    }

    func testBase44SignupUsesExistingEndpointWithoutSupabaseAuthorization() async throws {
        StagingURLProtocol.state.reset(response: Data("{}".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        let auth = SupabaseLegacyAuth(session: URLSession(configuration: configuration))
        try await auth.register(email: "person@example.com", password: "test-only-password")
        let request = try XCTUnwrap(StagingURLProtocol.state.recordedRequests.first)
        XCTAssertEqual(request.url?.host, "spyclash.com")
        XCTAssertEqual(request.url?.path, "/api/apps/69a0e57fa939f578082f8091/auth/register")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testStaleLegacyExchangeCannotCommitAfterLogout() async throws {
        StagingURLProtocol.state.reset(response: Data("{\"access_token\":\"stale\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"legacy_user_id\":\"legacy-person\",\"user\":{\"id\":\"11111111-1111-4111-8111-111111111111\"}}".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: URLSession(configuration: configuration), storedSession: nil, saveSession: { _ in XCTFail("Stale candidate persisted") }, clearSession: {}, storedLegacy: nil, saveLegacy: { _ in XCTFail("Stale legacy persisted") }, clearLegacy: {})
        let exchange = Task { try await auth.exchangeLegacySession("legacy-bearer") }
        for _ in 0..<100 where StagingURLProtocol.state.count == 0 { await Task.yield() }
        auth.clear(revokeRemote: false)
        do { _ = try await exchange.value; XCTFail("Stale exchange accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(auth.accessToken)
        XCTAssertNil(auth.legacyCredential)
        XCTAssertThrowsError(try auth.commit(accessToken: "stale"))
    }

    func testLegacyCredentialSwapsWithItsSupabaseAccountAndLogoutClearsBoth() async throws {
        let oldID = "11111111-1111-4111-8111-111111111111"
        let nextID = "22222222-2222-4222-8222-222222222222"
        StagingURLProtocol.state.reset(responses: [
            "/functions/v1/legacy-session": Data("{\"access_token\":\"next-supabase\",\"refresh_token\":\"next-refresh\",\"expires_in\":3600,\"legacy_user_id\":\"next-legacy-user\",\"user\":{\"id\":\"\(nextID)\"}}".utf8),
            "/functions/v1/app-services": Data("{\"id\":\"\(nextID)\",\"email\":\"\(nextID)@example.test\"}".utf8)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        var writes: [String] = []
        var cleared: [String] = []
        let old = SupabaseStoredSession(accessToken: "old-supabase", refreshToken: "old-refresh", userID: oldID, expiresAt: .distantFuture)
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: URLSession(configuration: configuration), storedSession: old, saveSession: { writes.append($0.accessToken) }, clearSession: { cleared.append("supabase") }, storedLegacy: .init(actorID: oldID, legacyUserID: "old-legacy-user", accessToken: "old-legacy"), saveLegacy: { writes.append($0.accessToken) }, clearLegacy: { cleared.append("legacy") })
        let candidate = try await auth.exchangeLegacySession("next-legacy")
        XCTAssertEqual(try auth.legacyAccessToken(), "old-legacy")
        XCTAssertEqual(auth.userID, oldID)
        XCTAssertTrue(writes.isEmpty)
        try auth.commit(accessToken: candidate.accessToken)
        XCTAssertEqual(writes, ["next-legacy", "next-supabase"])
        XCTAssertEqual(auth.userID, nextID)
        XCTAssertEqual(try auth.legacyAccessToken(), "next-legacy")
        auth.clear(revokeRemote: false)
        XCTAssertEqual(cleared, ["supabase", "legacy"])
        XCTAssertNil(auth.session)
        XCTAssertNil(auth.legacyCredential)
    }

    func testMismatchedStoredLegacyCredentialCannotBeUsedOrRefreshed() async throws {
        let stored = SupabaseStoredSession(accessToken: "supabase", refreshToken: "refresh", userID: actor, expiresAt: .distantPast)
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), storedSession: stored, saveSession: { _ in XCTFail("Mismatched credential refreshed") }, clearSession: {}, storedLegacy: .init(actorID: "22222222-2222-4222-8222-222222222222", legacyUserID: "someone-else", accessToken: "wrong-legacy"), saveLegacy: { _ in }, clearLegacy: {})
        XCTAssertThrowsError(try auth.legacyAccessToken())
        do { _ = try await auth.ensureAccessToken(); XCTFail("Mismatched credential must not refresh") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "legacy_session_missing") }
    }

    func testSupabaseJWTNeverReachesBase44ProviderRegistration() async throws {
        StagingURLProtocol.state.reset(response: Data("{}".utf8))
        let payload = Data("{\"iss\":\"https://bbkfsgnordtdiblgdzkg.supabase.co/auth/v1\"}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        let auth = SupabaseLegacyAuth(session: URLSession(configuration: configuration))
        do { try await auth.registerProvider(legacyToken: token, appleBindingTicket: nil); XCTFail("Supabase token was sent to Base44") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "wrong_credential_provider") }
        XCTAssertEqual(StagingURLProtocol.state.count, 0)
    }

    func testGeneratorRetryJournalNeverContainsLegacyBearer() async throws {
        StagingURLProtocol.state.reset(response: Data("{\"error\":\"temporarily_unavailable\"}".utf8), statusCode: 503)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = SupabaseStoredSession(accessToken: "supabase-game-bearer", refreshToken: "refresh", userID: actor, expiresAt: .distantFuture)
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: URLSession(configuration: configuration), storedSession: stored, saveSession: { _ in }, clearSession: {}, mutationJournal: SupabaseAppMutationJournal(directory: directory), storedLegacy: .init(actorID: actor, legacyUserID: "legacy-person", accessToken: "private-legacy-credential"), saveLegacy: { _ in }, clearLegacy: {})
        let requestID = UUID()
        let fields = SupabaseGameAdapter.generationFields(theme: "Animals", count: 5, requestID: requestID, excluding: ["cat", "dog"], preferFresh: true)
        do { let _: JSONValue = try await auth.service("legacy", action: "generate", fields: fields, write: true, includeLegacyCredential: true); XCTFail("Expected retryable failure") }
        catch let error as Base44Error { XCTAssertEqual(error.statusCode, 503) }
        let saved = try String(contentsOf: directory.appendingPathComponent(actor + ".json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("request_id"))
        XCTAssertFalse(saved.contains("private-legacy-credential"))
        XCTAssertFalse(saved.contains("base44_access_token"))
        XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-game-bearer")
        XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.timeoutInterval, 75)
        let wireBody = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
        XCTAssertEqual(wireBody["exclude_words"], .array([.string("cat"), .string("dog")]))
        XCTAssertNil(wireBody.object?["excluding"])
        XCTAssertEqual(wireBody["request_id"].string, requestID.uuidString.lowercased())
        XCTAssertEqual(wireBody["base44_access_token"].string, "private-legacy-credential")
    }

}

extension SupabaseSessionTests {
    func testServerInboxLinksStayInsideStagingApp() throws {
        let serverLink = URL(string: "spyclash://community/invites")!
        let local = SupabaseAppRuntime.localURL(forServerLink: serverLink)
        XCTAssertEqual(local.absoluteString, "spyclash-supabasetest://community/invites")
        XCTAssertEqual(serverLink.scheme, "spyclash")
        let web = URL(string: "https://example.com")!
        XCTAssertEqual(SupabaseAppRuntime.localURL(forServerLink: web), web)
    }
}

@MainActor
private final class StagingGameTransport: SupabaseFullGameTransport {
    let userID: String
    var onRealtime: ((String, JSONValue?) -> Void)?
    var handler: ((JSONValue) async throws -> JSONValue)?
    var watchHandler: ((String) async throws -> Void)?
    init(userID: String) { self.userID = userID }
    func fullGame(_ body: JSONValue) async throws -> JSONValue { try await handler?(body) ?? .object(["room": .null]) }
    func watch(roomID: String, table: String) async throws { try await watchHandler?(roomID) }
    func disconnectRealtime() {}
}

extension SupabaseSessionTests {
    func testGameSessionConnectsWithoutRoomAndCreatesFirstRoom() async throws {
        let actorID = "66666666-6666-4666-8666-666666666666"
        let roomID = "77777777-7777-4777-8777-777777777777"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StagingGameTransport(userID: actorID)
        transport.handler = { body in
            if body["action"].string == "get_active_room" { return .object(["room": .null]) }
            return .object(["room": .object(["id": .string(roomID), "code": .string("ABC123"), "host_email": .string(actorID + "@example.test"), "status": .string("waiting"), "room_revision": .number(1), "players": .array([])]), "receipt": .object(["request_id": body["request_id"], "room_id": .string(roomID), "revision": .number(1)])])
        }
        let store = SupabaseFullGameStore(evidenceDirectory: directory, automaticallyWatches: false)
        defer { store.disconnect() }
        try await store.connect(transport: transport, name: "Operative")
        XCTAssertEqual(store.userID, actorID)
        XCTAssertNil(store.room)
        _ = try await store.command(["action": .string("create_room")])
        XCTAssertEqual(store.room?.id, roomID)
        XCTAssertNil(store.pending)
        XCTAssertFalse(store.commandInFlight)
    }

    func testOldAccountReplyCannotAdoptRoomAfterReconnect() async throws {
        let firstID = "88888888-8888-4888-8888-888888888888"
        let nextID = "99999999-9999-4999-8999-999999999999"
        let roomID = "77777777-7777-4777-8777-777777777777"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var suspended: CheckedContinuation<JSONValue, Error>?
        var command: JSONValue = .null
        let first = StagingGameTransport(userID: firstID)
        first.handler = { body in
            if body["action"].string == "get_active_room" { return .object(["room": .null]) }
            command = body
            return try await withCheckedThrowingContinuation { suspended = $0 }
        }
        let store = SupabaseFullGameStore(evidenceDirectory: directory, automaticallyWatches: false)
        defer { store.disconnect() }
        try await store.connect(transport: first, name: "First")
        let old = Task { try await store.command(["action": .string("create_room")]) }
        for _ in 0..<100 where suspended == nil { await Task.yield() }
        let continuation = try XCTUnwrap(suspended)
        try await store.connect(transport: StagingGameTransport(userID: nextID), name: "Next")
        continuation.resume(returning: .object(["room": .object(["id": .string(roomID), "code": .string("ABC123"), "status": .string("waiting"), "room_revision": .number(1)]), "receipt": .object(["request_id": command["request_id"], "room_id": .string(roomID), "revision": .number(1)])]))
        do { _ = try await old.value; XCTFail("An old account must not adopt a room") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.userID, nextID)
        XCTAssertNil(store.room)
        XCTAssertNil(store.pending)
        XCTAssertFalse(store.commandInFlight)
    }

    func testOldAccountRestoreFailureAndSignalCannotChangeNewAccount() async throws {
        let firstID = "88888888-8888-4888-8888-888888888888"
        let nextID = "99999999-9999-4999-8999-999999999999"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var suspended: CheckedContinuation<JSONValue, Error>?
        let first = StagingGameTransport(userID: firstID)
        first.handler = { _ in try await withCheckedThrowingContinuation { suspended = $0 } }
        let store = SupabaseFullGameStore(evidenceDirectory: directory, automaticallyWatches: false)
        defer { store.disconnect() }
        let old = Task { try await store.connect(transport: first, name: "First") }
        for _ in 0..<100 where suspended == nil { await Task.yield() }
        let continuation = try XCTUnwrap(suspended)
        try await store.connect(transport: StagingGameTransport(userID: nextID), name: "Next")
        first.onRealtime?("subscribed", nil)
        continuation.resume(throwing: Base44Error(message: "Old restore failed", statusCode: 503, code: "old_restore_failure"))
        do { try await old.value; XCTFail("The obsolete connect must be canceled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.userID, nextID)
        XCTAssertEqual(store.lastError, "")
        XCTAssertEqual(store.realtime, "disconnected")
    }

    func testCanceledWatchCleanupCannotClearNextRoomWatch() async throws {
        let actorID = "66666666-6666-4666-8666-666666666666"
        let firstRoom = "77777777-7777-4777-8777-777777777777"
        let nextRoom = "88888888-8888-4888-8888-888888888888"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var watches: [String] = []
        var suspended: [String: CheckedContinuation<Void, Error>] = [:]
        let transport = StagingGameTransport(userID: actorID)
        transport.watchHandler = { roomID in
            watches.append(roomID)
            try await withCheckedThrowingContinuation { suspended[roomID] = $0 }
        }
        let store = SupabaseFullGameStore(evidenceDirectory: directory)
        defer {
            store.disconnect()
            for continuation in suspended.values { continuation.resume(throwing: CancellationError()) }
        }
        func room(_ id: String) -> JSONValue {
            .object(["id": .string(id), "code": .string("ABC123"), "host_email": .string(actorID + "@example.test"), "status": .string("waiting"), "room_revision": .number(1), "players": .array([])])
        }
        try await store.connect(transport: transport, name: "Operative")
        try store.adopt(room(firstRoom), activates: true)
        for _ in 0..<100 where suspended[firstRoom] == nil { await Task.yield() }
        let firstWatch = try XCTUnwrap(suspended.removeValue(forKey: firstRoom))
        try store.adopt(room(nextRoom), activates: true)
        for _ in 0..<100 where suspended[nextRoom] == nil { await Task.yield() }
        XCTAssertNotNil(suspended[nextRoom])
        firstWatch.resume()
        for _ in 0..<20 { await Task.yield() }
        try store.adopt(room(nextRoom))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(watches, [firstRoom, nextRoom])
        XCTAssertEqual(store.roomID, nextRoom)
    }
}
