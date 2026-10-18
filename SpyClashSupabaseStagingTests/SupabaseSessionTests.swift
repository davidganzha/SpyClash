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

    func testNearbyDiscoveryRequiresSameSupabaseProject() {
        XCTAssertEqual(SupabaseAppRuntime.radarServiceType, "spy-bbkfsg")
        XCTAssertTrue(SupabaseAppRuntime.acceptsRadarBackend("supabase:bbkfsgnordtdiblgdzkg"))
        for namespace in [nil, "base44", "supabase:otherproject", "supabase:bbkfsgnordtdiblgdzkg "] {
            XCTAssertFalse(SupabaseAppRuntime.acceptsRadarBackend(namespace))
        }
    }

    func testRecoveryLinksRemainInsideTestAppScheme() {
        XCTAssertEqual(ResetPasswordLinkParser.tokenIfPresent(from: "spyclash-supabasetest://reset-password?token=recovery"), "recovery")
        XCTAssertEqual(ResetPasswordLinkParser.tokenIfPresent(from: "spyclash-supabasetest://reset-password#reset_token=recovery"), "recovery")
        XCTAssertNil(ResetPasswordLinkParser.tokenIfPresent(from: "spyclash://reset-password?token=production"))
        XCTAssertNil(ResetPasswordLinkParser.tokenIfPresent(from: "https://spyclash.com/reset-password?token=production"))
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, saveStoredToken: { _ in }, clearStoredToken: {})
        state.handleIncomingURL(URL(string: "https://spyclash.com/reset-password?token=production")!)
        if case .resetPassword = state.authPhase { XCTFail("TEST claimed the original app's recovery link") }
        state.handleIncomingURL(URL(string: "spyclash-supabasetest://reset-password?token=recovery")!)
        if case .resetPassword(let token) = state.authPhase { XCTAssertEqual(token, "recovery") }
        else { XCTFail("TEST rejected its own recovery link") }
    }

    func testRecoveryParserRejectsForeignOriginsRoutesAndAmbiguousCredentials() {
        for link in [
            "https://example.test/reset-password?token=a", "https://spyclash.com.example.test/reset-password?token=a",
            "https://user@spyclash.com/reset-password?token=a", "https://spyclash.com:443/reset-password?token=a",
            "http://spyclash.com/reset-password?token=a", "https://spyclash.com/reset-password/extra?token=a",
            "https://spyclash.com/%72eset-password?token=a", "https://spyclash.com/reset-password#token=a",
            "spyclash://reset?token=a", "spyclash://join/reset-password?token=a",
            "spyclash://reset-password?token=a#token=b", "spyclash://reset-password?token=a&token=b",
            "spyclash://reset-password?token=a&reset_token=b", "spyclash://reset-password?token=a&access_token=b",
            "spyclash://reset-password?token=a&error=invalid", "spyclash://reset-password?token=",
            "spyclash://reset-password?token=%20a", "spyclash://reset-password?token=a%0Ab",
            "spyclash://reset-password?token=" + String(repeating: "a", count: 20_001)
        ] {
            XCTAssertNil(ResetPasswordLinkParser.tokenIfPresent(from: link, customScheme: "spyclash", allowsCanonicalWebLink: true), link)
        }
        XCTAssertEqual(ResetPasswordLinkParser.tokenIfPresent(from: "https://spyclash.com/reset-password?token=a%2Bb", customScheme: "spyclash", allowsCanonicalWebLink: true), "a+b")
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
        var sequences: [String: [(Int, Data)]] = [:]
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var statusCode = 200
        func reset(response: Data, statusCode: Int = 200) { lock.lock(); defer { lock.unlock() }; calls = 0; self.response = response; responses = [:]; sequences = [:]; requests = []; bodies = []; self.statusCode = statusCode }
        func reset(responses: [String: Data]) { lock.lock(); defer { lock.unlock() }; calls = 0; response = Data(); self.responses = responses; sequences = [:]; requests = []; bodies = []; statusCode = 200 }
        func reset(sequences: [String: [(Int, Data)]]) { lock.lock(); defer { lock.unlock() }; calls = 0; response = Data(); responses = [:]; self.sequences = sequences; requests = []; bodies = []; statusCode = 200 }
        func next(request: URLRequest, body: Data) -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            calls += 1; requests.append(request); bodies.append(body)
            let path = request.url?.path ?? ""
            if var queue = sequences[path], !queue.isEmpty {
                let response = queue.removeFirst(); sequences[path] = queue; return response
            }
            return (statusCode, responses[path] ?? response)
        }
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
        let (status, data) = Self.state.next(request: request, body: body)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            if status == -1 {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension SupabaseSessionTests {
    private func mockHTTP() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StagingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func storedAuth(directory: URL? = nil) -> SupabaseAppSession {
        SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: mockHTTP(), storedSession: .init(accessToken: "current-supabase", refreshToken: "refresh", userID: actor, expiresAt: Date().addingTimeInterval(3600)), saveSession: { _ in }, clearSession: {}, mutationJournal: .init(directory: directory), storedLegacy: .init(actorID: actor, legacyUserID: "legacy-person", accessToken: "private-legacy-credential"), saveLegacy: { _ in }, clearLegacy: {})
    }

    private var renewedSessionResponse: Data {
        Data("{\"access_token\":\"renewed-supabase\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"legacy_user_id\":\"legacy-person\",\"user\":{\"id\":\"\(actor)\"}}".utf8)
    }

    func testSessionExpiryRespectsServerAbsoluteDeadlineAndMaximumLifetime() throws {
        let deadline = Int(Date().timeIntervalSince1970) + 120
        var value: [String: JSONValue] = ["access_token": .string("access"), "refresh_token": .string("refresh"), "expires_in": .number(3600), "expires_at": .number(Double(deadline)), "user": .object(["id": .string(actor)])]
        XCTAssertEqual(try SupabaseAppSession.decodeSession(.object(value)).expiresAt.timeIntervalSince1970, Double(deadline))
        value["expires_at"] = .number(1)
        XCTAssertThrowsError(try SupabaseAppSession.decodeSession(.object(value)))
        value.removeValue(forKey: "expires_at")
        value["expires_in"] = .number(3601)
        XCTAssertThrowsError(try SupabaseAppSession.decodeSession(.object(value)))
    }

    func testExpiredAppCredentialRevalidatesSourceAndReplaysExactImmutableCommandOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        StagingURLProtocol.state.reset(sequences: [
            "/functions/v1/app-services": [(401, Data(#"{"code":"legacy_session_revalidation_required"}"#.utf8)), (200, Data(#"{"updated":true}"#.utf8))],
            "/functions/v1/legacy-session": [(200, renewedSessionResponse)]
        ])
        let auth = storedAuth(directory: directory)
        let result: JSONValue = try await auth.service("profile", action: "update", fields: ["display_name": .string("Operative")], write: true)
        XCTAssertTrue(result["updated"].bool)
        let requests = StagingURLProtocol.state.recordedRequests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/functions/v1/app-services", "/functions/v1/legacy-session", "/functions/v1/app-services"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer current-supabase", "Bearer private-legacy-credential", "Bearer renewed-supabase"])
        let bodies = StagingURLProtocol.state.recordedBodies
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: bodies[0]), try JSONDecoder().decode(JSONValue.self, from: bodies[2]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(actor + ".json"))), .array([]))
    }

    func testExplicitSessionRevocationDoesNotSilentlySignInOrDiscardPendingMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        StagingURLProtocol.state.reset(response: Data(#"{"code":"session_revoked"}"#.utf8), statusCode: 401)
        do {
            let _: JSONValue = try await storedAuth(directory: directory).service("profile", action: "update", fields: ["display_name": .string("Operative")], write: true)
            XCTFail("Revoked session was accepted")
        } catch let error as Base44Error { XCTAssertEqual(error.code, "session_revoked") }
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        let pending = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(actor + ".json")))
        XCTAssertEqual(pending.array.count, 1)
    }

    func testRevalidationIsBoundedToOneRetry() async throws {
        StagingURLProtocol.state.reset(sequences: [
            "/functions/v1/app-services": Array(repeating: (401, Data(#"{"code":"legacy_session_revalidation_required"}"#.utf8)), count: 2),
            "/functions/v1/legacy-session": [(200, renewedSessionResponse)]
        ])
        do { let _: JSONValue = try await storedAuth().service("profile", action: "current"); XCTFail("Repeated rejection was accepted") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "legacy_session_revalidation_required") }
        XCTAssertEqual(StagingURLProtocol.state.count, 3)
    }

    func testGameCredentialCannotRevalidateIntoAnotherAccount() async throws {
        StagingURLProtocol.state.reset(sequences: [
            "/functions/v1/full-game-core": [(401, Data(#"{"code":"jwt_expired"}"#.utf8))],
            "/functions/v1/legacy-session": [(200, Data(#"{"access_token":"wrong-account","refresh_token":"refresh","expires_in":3600,"legacy_user_id":"legacy-person","user":{"id":"22222222-2222-4222-8222-222222222222"}}"#.utf8))]
        ])
        let auth = storedAuth()
        do { _ = try await auth.fullGame(.object(["action": .string("get_active_room")])); XCTFail("Account changed during refresh") }
        catch { XCTAssertEqual(StagingURLProtocol.state.count, 2) }
        XCTAssertEqual(auth.userID, actor)
        XCTAssertEqual(auth.accessToken, "current-supabase")
    }

    func testLegacyRecoveryAndResendUseOwnerEmailWithoutSessionHeaders() async throws {
        StagingURLProtocol.state.reset(response: Data("{}".utf8))
        let auth = SupabaseLegacyAuth(session: mockHTTP())
        try await auth.resend(email: "  person@example.com\n")
        try await auth.requestRecovery(email: "person@example.com")
        try await auth.resetPassword(token: "base44-recovery-token", password: " exact password ")
        let requests = StagingURLProtocol.state.recordedRequests
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["resend-otp", "reset-password-request", "reset-password"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "spyclash.com" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        let bodies = try StagingURLProtocol.state.recordedBodies.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        XCTAssertEqual(bodies[0]["email"].string, "person@example.com")
        XCTAssertEqual(bodies[2]["new_password"].string, " exact password ")
        XCTAssertEqual(bodies[2]["reset_token"].string, "base44-recovery-token")
    }

    func testInvalidRecoveryTokensAndProviderKeysNeverReachBase44() async throws {
        StagingURLProtocol.state.reset(response: Data("{}".utf8))
        let auth = SupabaseLegacyAuth(session: mockHTTP())
        for token in ["", "line\nbreak", " leading", "sb_publishable_client", "sb_secret_server"] {
            do { try await auth.resetPassword(token: token, password: "new-password"); XCTFail("Invalid recovery token was sent") }
            catch let error as Base44Error { XCTAssertEqual(error.code, "invalid_recovery_token") }
            do { try await auth.registerProvider(legacyToken: token, appleBindingTicket: nil); XCTFail("Invalid provider token was sent") }
            catch let error as Base44Error { XCTAssertEqual(error.code, "wrong_credential_provider") }
        }
        XCTAssertEqual(StagingURLProtocol.state.count, 0)
    }

    func testAppleProviderRegistrationUsesV2AndPreservesBindingTicketInBody() async throws {
        StagingURLProtocol.state.reset(response: Data(#"{"success":true,"user":{"id":"synthetic-user","email":"person@example.test"}}"#.utf8))
        let auth = SupabaseLegacyAuth(session: mockHTTP())
        try await auth.registerProvider(legacyToken: "synthetic-provider-token", appleBindingTicket: "synthetic-binding-ticket")
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        let request = try XCTUnwrap(StagingURLProtocol.state.recordedRequests.first)
        XCTAssertEqual(request.url?.host, "spyclash.com")
        XCTAssertEqual(request.url?.path, "/api/apps/\(Base44Client.appID)/functions/autoRegisterUserV2")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
        XCTAssertEqual(body["access_token"].string, "synthetic-provider-token")
        XCTAssertEqual(body["apple_binding_ticket"].string, "synthetic-binding-ticket")
    }

    func testAppleProviderRegistrationRejectsUnverifiedSuccessWithoutFallback() async throws {
        let invalid = [
            #"{}"#,
            #"{"success":true}"#,
            #"{"success":false,"user":{"id":"synthetic-user","email":"person@example.test"}}"#,
            #"{"user":{"id":"synthetic-user","email":"person@example.test"}}"#,
            #"{"success":true,"user":{"id":"","email":"person@example.test"}}"#,
            #"{"success":true,"user":{"id":"synthetic-user","email":""}}"#,
        ]
        let auth = SupabaseLegacyAuth(session: mockHTTP())
        for response in invalid {
            StagingURLProtocol.state.reset(response: Data(response.utf8))
            do {
                try await auth.registerProvider(legacyToken: "synthetic-provider-token", appleBindingTicket: "synthetic-binding-ticket")
                XCTFail("Apple binding requires explicit success and a verified user")
            } catch let error as Base44Error {
                XCTAssertEqual(error.code, "apple_binding_response_invalid")
            }
            XCTAssertEqual(StagingURLProtocol.state.count, 1)
            XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.url?.lastPathComponent, "autoRegisterUserV2")
        }
    }

    func testGoogleProviderRegistrationKeepsLegacyRouteWithoutAppleBinding() async throws {
        let auth = SupabaseLegacyAuth(session: mockHTTP())
        for bindingTicket in [nil, ""] as [String?] {
            StagingURLProtocol.state.reset(response: Data("{}".utf8))
            try await auth.registerProvider(legacyToken: "synthetic-google-token", appleBindingTicket: bindingTicket)
            XCTAssertEqual(StagingURLProtocol.state.count, 1)
            XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.url?.lastPathComponent, "autoRegisterUser")
            XCTAssertNil(StagingURLProtocol.state.recordedRequests.first?.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
            XCTAssertEqual(body["access_token"].string, "synthetic-google-token")
            XCTAssertNil(body.object?["apple_binding_ticket"])
        }
    }

    func testLegacyErrorsPreserveProviderCodeAndRetryability() async throws {
        StagingURLProtocol.state.reset(response: Data(#"{"error":{"code":"rate_limited","error_description":"Wait before requesting another code."}}"#.utf8), statusCode: 429)
        do { try await SupabaseLegacyAuth(session: mockHTTP()).resend(email: "person@example.com"); XCTFail("Rate limit was accepted") }
        catch let error as Base44Error {
            XCTAssertEqual(error.code, "rate_limited")
            XCTAssertEqual(error.message, "Wait before requesting another code.")
            XCTAssertTrue(error.retryable)
        }
    }

    func testAccountDeletionUsesLongTimeoutAndKeepsProviderCredentialOutOfJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        StagingURLProtocol.state.reset(response: Data(#"{"code":"account_deletion_pending"}"#.utf8), statusCode: 503)
        do { let _: JSONValue = try await storedAuth(directory: directory).service("profile", action: "delete", fields: ["deletion_scope": .string("account")], write: true, includeLegacyCredential: true); XCTFail("Pending delete was accepted") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "account_deletion_pending") }
        XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.timeoutInterval, 90)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
        XCTAssertEqual(body["base44_access_token"].string, "private-legacy-credential")
        let saved = try String(contentsOf: directory.appendingPathComponent(actor + ".json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("private-legacy-credential"))
        XCTAssertFalse(saved.contains("base44_access_token"))
        XCTAssertTrue(saved.contains("request_id"))
    }

    func testMembershipCredentialOnlyReachesExplicitBridgeActions() async throws {
        StagingURLProtocol.state.reset(response: Data("{}".utf8))
        let auth = storedAuth()
        for action in ["check", "prepare", "sync_transaction"] {
            let _: JSONValue = try await auth.service("membership", action: action, includeLegacyCredential: true)
        }
        XCTAssertEqual(StagingURLProtocol.state.count, 3)
        for data in StagingURLProtocol.state.recordedBodies {
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data)["base44_access_token"].string, "private-legacy-credential")
        }
        do { let _: JSONValue = try await auth.service("membership", action: "arbitrary", includeLegacyCredential: true); XCTFail("Unapproved action received credential") }
        catch { XCTAssertEqual(StagingURLProtocol.state.count, 3) }
    }
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
        let loginGeneration = auth.generation
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
        XCTAssertEqual(auth.generation, loginGeneration, "Transport rotation must preserve the account's login scope")
    }
}

extension SupabaseSessionTests {
    func testLateExchangeCannotReplaceNewerCandidateBeforeItsProfileReturns() async throws {
        let fixture = SessionExchangeFixture()
        defer { fixture.close() }
        let auth = fixture.auth()
        let generation = auth.generation
        let firstStarted = expectation(description: "First exchange started")
        let nextProfileStarted = expectation(description: "New candidate awaiting profile")
        var firstRequest: SessionExchangeFixture.Request?
        var nextProfile: SessionExchangeFixture.Request?
        fixture.handle = { request in
            switch (request.path, request.authorization) {
            case ("/functions/v1/legacy-session", "Bearer first-legacy"):
                firstRequest = request
                firstStarted.fulfill()
            case ("/functions/v1/legacy-session", "Bearer next-legacy"):
                request.respond(200, fixture.exchange(token: "next-candidate"))
            case ("/functions/v1/app-services", "Bearer next-candidate"):
                nextProfile = request
                nextProfileStarted.fulfill()
            case ("/functions/v1/app-services", "Bearer first-candidate"):
                request.respond(200, fixture.profile)
            default:
                XCTFail("Unexpected synthetic authentication request")
                request.respond(500, "{}")
            }
        }
        let first = Task { try await auth.exchangeLegacySession("first-legacy") }
        await fulfillment(of: [firstStarted], timeout: 3)
        let next = Task { try await auth.exchangeLegacySession("next-legacy") }
        await fulfillment(of: [nextProfileStarted], timeout: 3)
        try XCTUnwrap(firstRequest).respond(200, fixture.exchange(token: "first-candidate"))
        do { _ = try await first.value; XCTFail("The superseded exchange returned a candidate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(auth.generation, generation, "Candidate isolation must not invalidate the saved session")
        try XCTUnwrap(nextProfile).respond(200, fixture.profile)
        do {
            let verified = try await next.value
            try auth.commit(accessToken: verified.accessToken)
        } catch { XCTFail("A late older response invalidated the current candidate: \(type(of: error))") }
        XCTAssertEqual(auth.accessToken, "next-candidate")
        XCTAssertEqual(try auth.legacyAccessToken(), "next-legacy")
        XCTAssertThrowsError(try auth.commit(accessToken: "first-candidate"))
    }

    func testSupersededProfileFailureCannotClearNewerReadyCandidate() async throws {
        let fixture = SessionExchangeFixture()
        defer { fixture.close() }
        let auth = fixture.auth(stored: true)
        let profileStarted = expectation(description: "Old candidate awaiting profile")
        var oldProfile: SessionExchangeFixture.Request?
        fixture.handle = { request in
            switch (request.path, request.authorization) {
            case ("/functions/v1/legacy-session", "Bearer first-legacy"):
                request.respond(200, fixture.exchange(token: "first-candidate"))
            case ("/functions/v1/app-services", "Bearer first-candidate"):
                oldProfile = request
                profileStarted.fulfill()
            case ("/functions/v1/legacy-session", "Bearer next-legacy"):
                request.respond(200, fixture.exchange(token: "next-candidate"))
            case ("/functions/v1/app-services", "Bearer next-candidate"):
                request.respond(200, fixture.profile)
            default:
                XCTFail("Unexpected synthetic authentication request")
                request.respond(500, "{}")
            }
        }
        let first = Task { try await auth.exchangeLegacySession("first-legacy") }
        await fulfillment(of: [profileStarted], timeout: 3)
        let next = try await auth.exchangeLegacySession("next-legacy")
        try XCTUnwrap(oldProfile).respond(503, #"{"code":"temporary_profile_failure"}"#)
        do { _ = try await first.value; XCTFail("A superseded profile failure escaped ownership checking") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(auth.accessToken, "saved-candidate")
        try auth.commit(accessToken: next.accessToken)
        XCTAssertEqual(auth.accessToken, "next-candidate")
        XCTAssertEqual(try auth.legacyAccessToken(), "next-legacy")
    }

    func testInvalidAttemptCannotStartExchangeOrEvictReadyCandidate() async throws {
        let fixture = SessionExchangeFixture()
        defer { fixture.close() }
        let auth = fixture.auth(stored: true)
        var requests = 0
        fixture.handle = { request in
            requests += 1
            request.respond(200, request.path == "/functions/v1/legacy-session"
                            ? fixture.exchange(token: "next-candidate") : fixture.profile)
        }
        let next = try await auth.exchangeLegacySession("next-legacy")
        do {
            _ = try await auth.exchangeLegacySession("obsolete-google-candidate", requireCurrentAttempt: { throw CancellationError() })
            XCTFail("An obsolete provider attempt started exchange")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(auth.accessToken, "saved-candidate")
        try auth.commit(accessToken: next.accessToken)
        XCTAssertEqual(auth.accessToken, "next-candidate")
    }

    func testAttemptInvalidationDuringProfileDiscardsCandidateAndPreservesSavedSession() async throws {
        let fixture = SessionExchangeFixture()
        defer { fixture.close() }
        let auth = fixture.auth(stored: true)
        let generation = auth.generation
        let profileStarted = expectation(description: "Candidate profile started")
        var heldProfile: SessionExchangeFixture.Request?
        var ownsAttempt = true
        fixture.handle = { request in
            if request.path == "/functions/v1/legacy-session" {
                request.respond(200, fixture.exchange(token: "discarded-candidate"))
            } else {
                heldProfile = request
                profileStarted.fulfill()
            }
        }
        let exchange = Task {
            try await auth.exchangeLegacySession("uncommitted-legacy") {
                guard ownsAttempt else { throw CancellationError() }
            }
        }
        await fulfillment(of: [profileStarted], timeout: 3)
        ownsAttempt = false
        try XCTUnwrap(heldProfile).respond(200, fixture.profile)
        do { _ = try await exchange.value; XCTFail("An invalidated attempt returned a candidate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try auth.commit(accessToken: "discarded-candidate"))
        XCTAssertEqual(auth.generation, generation)
        XCTAssertEqual(auth.accessToken, "saved-candidate")
        XCTAssertEqual(try auth.legacyAccessToken(), "saved-legacy")
        XCTAssertEqual(fixture.sessionWrites.count, 0)
        XCTAssertEqual(fixture.legacyWrites.count, 0)
        XCTAssertEqual(fixture.clearCount, 0)
    }

    func testMalformedSuccessfulRenewalPreservesSavedCredentialsAndCanRecover() async throws {
        let fixture = SessionExchangeFixture()
        defer { fixture.close() }
        let auth = fixture.auth(stored: true)
        let generation = auth.generation
        let missingLegacyID = fixture.exchange(token: "renewed-candidate")
            .replacingOccurrences(of: #","legacy_user_id":"synthetic-person""#, with: "")
        var replies = ["{}", missingLegacyID, fixture.exchange(token: "renewed-candidate")]
        fixture.handle = { request in
            XCTAssertEqual(request.path, "/functions/v1/legacy-session")
            XCTAssertEqual(request.authorization, "Bearer saved-legacy")
            guard !replies.isEmpty else { XCTFail("Unexpected automatic retry"); request.respond(500, "{}"); return }
            request.respond(200, replies.removeFirst())
        }
        for _ in 0..<2 {
            do { _ = try await auth.ensureAccessToken(forceLegacyValidation: true); XCTFail("Malformed response accepted") }
            catch let error as Base44Error {
                XCTAssertEqual(error.statusCode, 502, "A malformed response must not trigger restore's 401 credential deletion")
                XCTAssertEqual(error.code, "supabase_session_response_invalid")
                XCTAssertTrue(error.retryable)
            }
            XCTAssertEqual(auth.generation, generation)
            XCTAssertEqual(auth.accessToken, "saved-candidate")
            XCTAssertEqual(try auth.legacyAccessToken(), "saved-legacy")
            XCTAssertTrue(fixture.sessionWrites.isEmpty)
            XCTAssertEqual(fixture.clearCount, 0)
        }
        let renewed = try await auth.ensureAccessToken(forceLegacyValidation: true)
        XCTAssertEqual(renewed, "renewed-candidate")
        XCTAssertEqual(fixture.sessionWrites.count, 1)
        XCTAssertEqual(try auth.legacyAccessToken(), "saved-legacy")
        XCTAssertEqual(fixture.clearCount, 0)
    }

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

/// A separate registration per test prevents late URLProtocol callbacks from
/// reaching the next test. All values and responses are synthetic and held
/// explicitly, so ordering never depends on arbitrary network delays.
@MainActor
private final class SessionExchangeFixture {
    struct Request: Sendable {
        let path: String
        let authorization: String
        let respond: @Sendable (Int, String) -> Void
    }
    let id = UUID().uuidString
    let actor = "22222222-2222-4222-8222-222222222222"
    var handle: ((Request) -> Void)?
    var sessionWrites: [SupabaseStoredSession] = []
    var legacyWrites: [SupabaseLegacyCredential] = []
    var clearCount = 0
    private var http: URLSession?
    init() {
        SessionExchangeURLProtocol.handlers[id] = { [weak self] request in
            guard let self, let handle = self.handle else { request.respond(500, "{}"); return }
            handle(request)
        }
    }
    func close() {
        SessionExchangeURLProtocol.handlers.removeValue(forKey: id)
        handle = nil
        http?.invalidateAndCancel()
        http = nil
    }
    var profile: String { "{\"id\":\"\(actor)\",\"email\":\"\(actor)@example.test\"}" }
    func exchange(token: String) -> String {
        "{\"access_token\":\"\(token)\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"legacy_user_id\":\"synthetic-person\",\"user\":{\"id\":\"\(actor)\"}}"
    }
    func auth(stored: Bool = false) -> SupabaseAppSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionExchangeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Session-Exchange-Fixture": id]
        let http = URLSession(configuration: configuration)
        self.http = http
        return SupabaseAppSession(
            configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"),
            session: http,
            storedSession: stored ? .init(accessToken: "saved-candidate", refreshToken: "synthetic-saved-refresh", userID: actor, expiresAt: .distantFuture) : nil,
            saveSession: { [weak self] in self?.sessionWrites.append($0) }, clearSession: { [weak self] in self?.clearCount += 1 },
            storedLegacy: stored ? .init(actorID: actor, legacyUserID: "synthetic-person", accessToken: "saved-legacy") : nil,
            saveLegacy: { [weak self] in self?.legacyWrites.append($0) }, clearLegacy: { [weak self] in self?.clearCount += 1 }
        )
    }
}

private final class SessionExchangeURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handlers: [String: (SessionExchangeFixture.Request) -> Void] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let registration = request.value(forHTTPHeaderField: "X-Session-Exchange-Fixture") ?? ""
        let snapshot = SessionExchangeFixture.Request(
            path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization") ?? ""
        ) { [self] status, body in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        Task { @MainActor in
            guard let handler = Self.handlers[registration] else { snapshot.respond(500, "{}"); return }
            handler(snapshot)
        }
    }
    override func stopLoading() {}
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


@MainActor
private final class SessionAppStoreDeliveryClient: AppStoreTransactionClient {
    let auth: SupabaseAppSession
    init(_ auth: SupabaseAppSession) { self.auth = auth }
    var currentAccessToken: String? { auth.accessToken }
    var membershipSessionGeneration: UUID? { auth.generation }
    func syncAppStoreTransaction(signedTransaction: String) async throws -> AppStoreEntitlementSyncResponse {
        try await auth.service("membership", action: "sync_transaction", fields: ["signed_transaction": .string(signedTransaction)], write: true, includeLegacyCredential: true)
    }
}

extension SupabaseSessionTests {
    private var deliveryProduct: String { "com.spyclash.ios.limitless.weekly" }
    private func deliveryReceipt(status: String) -> Data {
        Data("{\"success\":true,\"server_status_verified\":true,\"entitlement\":{\"product_id\":\"\(deliveryProduct)\",\"status\":\"\(status)\",\"expires_at\":\"2099-01-01T00:00:00Z\"}}".utf8)
    }
    private func deliveryStore(_ auth: SupabaseAppSession) -> AppStoreTransactionDeliveryStore {
        let store = AppStoreTransactionDeliveryStore(client: SessionAppStoreDeliveryClient(auth))
        store.bind(.init(userID: auth.userID, accessToken: auth.accessToken, sessionGeneration: auth.generation))
        return store
    }
    private func seedLostAppStoreACK(_ directory: URL) async throws -> JSONValue {
        StagingURLProtocol.state.reset(response: Data(), statusCode: -1)
        let auth = storedAuth(directory: directory)
        var finished = false
        do {
            _ = try await deliveryStore(auth).deliver(signedTransaction: "synthetic-JWS-A", productID: deliveryProduct) { finished = true }
            XCTFail("Lost ACK was accepted")
        } catch { XCTAssertFalse(finished) }
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
        let persisted = try String(contentsOf: directory.appendingPathComponent(actor + ".json"), encoding: .utf8)
        XCTAssertTrue(persisted.contains("synthetic-JWS-A"))
        XCTAssertFalse(persisted.contains("private-legacy-credential"))
        XCTAssertFalse(persisted.contains("current-supabase"))
        XCTAssertFalse(persisted.contains("base44_access_token"))
        return body
    }

    func testAppStoreLostACKReopenDrainsExactAThenVerifiesChangedBWithoutFinishingFromA() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await seedLostAppStoreACK(directory)
        StagingURLProtocol.state.reset(sequences: ["/functions/v1/app-services": [(200, deliveryReceipt(status: "active")), (200, deliveryReceipt(status: "revoked"))]])
        let reopened = storedAuth(directory: directory)
        var finishedB = 0
        let result = try await deliveryStore(reopened).deliver(signedTransaction: "synthetic-JWS-B", productID: deliveryProduct) { finishedB += 1 }
        XCTAssertEqual(finishedB, 1)
        XCTAssertEqual(result.entitlement.status, "revoked", "Caller B must receive B's canonical state, never old active A")
        let bodies = try StagingURLProtocol.state.recordedBodies.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], first)
        XCTAssertEqual(bodies[1]["signed_transaction"].string, "synthetic-JWS-B")
        XCTAssertNotEqual(bodies[0]["request_id"], bodies[1]["request_id"])
        XCTAssertTrue(StagingURLProtocol.state.recordedRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer current-supabase" })
        XCTAssertTrue(bodies.allSatisfy { $0["base44_access_token"].string == "private-legacy-credential" })
        XCTAssertNil(try SupabaseAppMutationJournal(directory: directory).pendingAppStoreTransaction(actorID: actor))
    }

    func testAppStoreRecoveryReceiptACannotFinishBWhoseOwnACKIsLost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await seedLostAppStoreACK(directory)
        StagingURLProtocol.state.reset(sequences: ["/functions/v1/app-services": [(200, deliveryReceipt(status: "active")), (-1, Data())]])
        let auth = storedAuth(directory: directory)
        let store = deliveryStore(auth)
        var finishedB = 0
        do {
            _ = try await store.deliver(signedTransaction: "synthetic-JWS-B", productID: deliveryProduct) { finishedB += 1 }
            XCTFail("A receipt finished unacknowledged B")
        } catch { XCTAssertEqual(finishedB, 0) }
        let pending = try XCTUnwrap(SupabaseAppMutationJournal(directory: directory).pendingAppStoreTransaction(actorID: actor))
        XCTAssertEqual(pending["signed_transaction"]?.string, "synthetic-JWS-B")
        StagingURLProtocol.state.reset(response: deliveryReceipt(status: "active"))
        _ = try await store.deliver(signedTransaction: "synthetic-JWS-B", productID: deliveryProduct) { finishedB += 1 }
        XCTAssertEqual(finishedB, 1)
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        let retry = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
        XCTAssertEqual(retry["request_id"], pending["request_id"])
    }

    func testAppStoreExactPayloadRetryRetainsOriginalIDWithoutExtraRecoveryDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await seedLostAppStoreACK(directory)
        StagingURLProtocol.state.reset(response: deliveryReceipt(status: "active"))
        _ = try await deliveryStore(storedAuth(directory: directory)).deliver(signedTransaction: "synthetic-JWS-A", productID: deliveryProduct) { }
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first)), first)
    }

    func testAppStoreRecoveryNeverReplaysSavedJWSForAnotherAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await seedLostAppStoreACK(directory)
        let other = "22222222-2222-4222-8222-222222222222"
        StagingURLProtocol.state.reset(response: deliveryReceipt(status: "active"))
        let auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test"), session: mockHTTP(), storedSession: .init(accessToken: "other-supabase", refreshToken: "other-refresh", userID: other, expiresAt: Date().addingTimeInterval(3600)), saveSession: { _ in }, clearSession: {}, mutationJournal: .init(directory: directory), storedLegacy: .init(actorID: other, legacyUserID: "other-legacy", accessToken: "other-private-legacy"), saveLegacy: { _ in }, clearLegacy: {})
        _ = try await deliveryStore(auth).deliver(signedTransaction: "synthetic-JWS-B", productID: deliveryProduct) { }
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        let sent = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(StagingURLProtocol.state.recordedBodies.first))
        XCTAssertEqual(sent["signed_transaction"].string, "synthetic-JWS-B")
        XCTAssertEqual(sent["base44_access_token"].string, "other-private-legacy")
        XCTAssertEqual(StagingURLProtocol.state.recordedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer other-supabase")
        let old = try XCTUnwrap(SupabaseAppMutationJournal(directory: directory).pendingAppStoreTransaction(actorID: actor))
        XCTAssertEqual(old["request_id"], first["request_id"])
    }

    func testAppStoreLogoutDuringRecoveryRetainsAAndNeverSendsOrFinishesB() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await seedLostAppStoreACK(directory)
        StagingURLProtocol.state.reset(response: deliveryReceipt(status: "active"))
        let auth = storedAuth(directory: directory)
        let store = deliveryStore(auth)
        var finished = false
        let task = Task { try await store.deliver(signedTransaction: "synthetic-JWS-B", productID: deliveryProduct) { finished = true } }
        for _ in 0..<100 where StagingURLProtocol.state.count == 0 { await Task.yield() }
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        auth.clear(revokeRemote: false)
        do { _ = try await task.value; XCTFail("A departed account's delivery completed") }
        catch { XCTAssertTrue(RequestCancellationPolicy.isCancellation(error)) }
        XCTAssertFalse(finished)
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
        XCTAssertEqual(try SupabaseAppMutationJournal(directory: directory).pendingAppStoreTransaction(actorID: actor)?["signed_transaction"]?.string, "synthetic-JWS-A")
    }

    func testAppStoreRecoveryKeepsRetryableFailureAndCanAdvanceAfterDefinitiveRejection() async throws {
        for (status, retryable) in [(401, false), (408, false), (425, false), (429, false), (409, true), (503, true), (400, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = SupabaseAppMutationJournal(directory: directory)
            let saved = try journal.prepare(actorID: actor, body: ["service": .string("membership"), "action": .string("sync_transaction"), "signed_transaction": .string("synthetic-JWS-A")])
            let error = Data("{\"code\":\"source_rejected\",\"retryable\":\(retryable)}".utf8)
            StagingURLProtocol.state.reset(sequences: ["/functions/v1/app-services": [(status, error), (200, deliveryReceipt(status: "active"))]])
            do {
                _ = try await deliveryStore(storedAuth(directory: directory)).deliver(signedTransaction: "synthetic-JWS-B", productID: deliveryProduct) { }
                XCTAssertEqual(status, 400)
                XCTAssertEqual(StagingURLProtocol.state.count, 2)
                XCTAssertNil(try journal.pendingAppStoreTransaction(actorID: actor))
            } catch {
                XCTAssertNotEqual(status, 400)
                XCTAssertEqual(StagingURLProtocol.state.count, 1)
                XCTAssertEqual(try journal.pendingAppStoreTransaction(actorID: actor)?["request_id"], saved["request_id"])
            }
        }
    }

    func testAppStoreCancelledQueuedDeliveryDoesNotCancelCurrentVerification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        StagingURLProtocol.state.reset(response: deliveryReceipt(status: "active"))
        let auth = storedAuth(directory: directory)
        let store = deliveryStore(auth)
        var finishedA = false
        let first = Task { try await store.deliver(signedTransaction: "synthetic-JWS-A", productID: deliveryProduct) { finishedA = true } }
        for _ in 0..<100 where StagingURLProtocol.state.count == 0 { await Task.yield() }
        let queued = Task { () -> AppStoreEntitlementSyncResponse in
            try await auth.service("membership", action: "sync_transaction", fields: ["signed_transaction": .string("synthetic-JWS-B")], write: true, includeLegacyCredential: true)
        }
        await Task.yield()
        queued.cancel()
        _ = try await first.value
        do { _ = try await queued.value; XCTFail("Cancelled waiter completed") }
        catch { XCTAssertTrue(RequestCancellationPolicy.isCancellation(error)) }
        XCTAssertTrue(finishedA)
        XCTAssertEqual(StagingURLProtocol.state.count, 1)
    }
}
