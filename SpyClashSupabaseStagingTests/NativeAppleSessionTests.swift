import Foundation
import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class NativeAppleSessionTests: XCTestCase {
    private let actor = "11111111-1111-4111-8111-111111111111"
    private let otherActor = "22222222-2222-4222-8222-222222222222"
    private let authorizationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private var configuration: SupabaseAppConfiguration {
        var value = SupabaseAppConfiguration(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test")
        value.appleSignInEnabled = true
        value.gameCenterSignInEnabled = true
        return value
    }

    private var credential: AppleSignInCredential {
        .init(identityToken: "synthetic-apple-id-token", authorizationCode: "synthetic-single-use-code",
              rawNonce: "synthetic-nonce", state: "native-state-already-checked",
              appleUserID: "must-not-select-owner", email: "must-not-select-owner@example.test",
              givenName: "Existing", familyName: "Player")
    }

    private func tokenResponse(access: String = "apple-candidate", userID: String? = nil,
                               provider: String = "apple", migrationVersion: Int = 1) -> Data {
        Data("""
        {"access_token":"\(access)","refresh_token":"refresh-\(access)","expires_in":3600,
         "provider":"\(provider)","migration_version":\(migrationVersion),"user":{"id":"\(userID ?? actor)"}}
        """.utf8)
    }

    private func profileResponse(userID: String? = nil, email: String? = nil) -> Data {
        let id = userID ?? actor
        return Data("""
        {"id":"\(id)","email":"\(email ?? id + "@example.test")","display_name":"Existing Operative",
         "onboarding_completed":true,"onboarding_version":1,"is_verified":true,"language":"ru"}
        """.utf8)
    }

    private func makeSession(stored: SupabaseStoredSession? = nil,
                             legacy: SupabaseLegacyCredential? = nil,
                             configuration supplied: SupabaseAppConfiguration? = nil,
                             journal: SupabaseAppMutationJournal? = nil,
                             save: @escaping (SupabaseStoredSession) throws -> Void = { _ in },
                             clearLegacy: @escaping () -> Void = {}) -> SupabaseAppSession {
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [AppleSessionURLProtocol.self]
        return SupabaseAppSession(configuration: supplied ?? configuration, session: URLSession(configuration: network),
                                  storedSession: stored, saveSession: save, clearSession: {},
                                  mutationJournal: journal ?? SupabaseAppMutationJournal(), storedLegacy: legacy,
                                  saveLegacy: { _ in XCTFail("Apple authentication must not persist a Base44 bearer") },
                                  clearLegacy: clearLegacy)
    }

    private func successfulExchange(profile: Data? = nil) {
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/apple-session": [.init(body: tokenResponse())],
            "/functions/v1/app-services": [.init(body: profile ?? profileResponse())],
            "/auth/v1/logout": [.init(body: Data("{}".utf8))]
        ])
    }

    func testAppleUsesOnlyOwnedSupabaseEndpointAndPreservesExistingProfileUntilTypedCommit() async throws {
        successfulExchange()
        let previous = SupabaseStoredSession(accessToken: "prior-account", refreshToken: "prior-refresh", userID: actor,
                                            expiresAt: Date().addingTimeInterval(3600))
        let legacy = SupabaseLegacyCredential(actorID: actor, legacyUserID: "prior-legacy-id", accessToken: "prior-private-bearer")
        var persisted: [SupabaseStoredSession] = []
        var legacyClears = 0
        var profileSync = 0
        let auth = makeSession(stored: previous, legacy: legacy, save: { persisted.append($0) }, clearLegacy: { legacyClears += 1 })

        let candidate = try await auth.exchangeApple(credential: credential, requestID: authorizationID,
                                                     onProfileSync: { profileSync += 1 })
        XCTAssertEqual(auth.session, previous, "A candidate must not replace the saved account before UI ownership is checked")
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(candidate.user.id, actor)
        XCTAssertEqual(candidate.user.callSign, "Existing Operative")
        XCTAssertEqual(candidate.user.onboardingCompleted, true)
        XCTAssertEqual(profileSync, 1)
        XCTAssertThrowsError(try auth.commitApple(accessToken: candidate.accessToken, userID: otherActor))
        XCTAssertThrowsError(try auth.commitGameCenter(accessToken: candidate.accessToken, userID: actor))
        XCTAssertTrue(persisted.isEmpty)

        try auth.commitApple(accessToken: candidate.accessToken, userID: actor)
        XCTAssertEqual(auth.userID, actor)
        XCTAssertTrue(auth.isNativeAppleSession)
        XCTAssertTrue(auth.isNativeSession)
        XCTAssertFalse(auth.isNativeGameCenterSession)
        XCTAssertEqual(persisted.map(\.nativeCredentialKind), [.apple])
        XCTAssertEqual(legacyClears, 1)
        XCTAssertNil(auth.legacyCredential)
        XCTAssertThrowsError(try auth.legacyAccessToken())

        let records = AppleSessionURLProtocol.state.records
        XCTAssertEqual(records.map { $0.request.url!.path }, ["/functions/v1/apple-session", "/functions/v1/app-services"])
        XCTAssertTrue(records.allSatisfy { $0.request.url?.host == "bbkfsgnordtdiblgdzkg.supabase.co" })
        XCTAssertEqual(records[0].request.timeoutInterval, 60)
        XCTAssertNil(records[0].request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(records[1].request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-candidate")
        let body = try JSONDecoder().decode(JSONValue.self, from: records[0].body)
        XCTAssertEqual(Set(body.object!.keys), ["identity_token", "authorization_code", "raw_nonce", "request_id", "given_name", "family_name"])
        XCTAssertEqual(body["identity_token"].string, credential.identityToken)
        XCTAssertEqual(body["authorization_code"].string, credential.authorizationCode)
        XCTAssertEqual(body["raw_nonce"].string, credential.rawNonce)
        XCTAssertEqual(body["request_id"].string, authorizationID.uuidString.lowercased())
        XCTAssertEqual(body["given_name"].string, "Existing")
        XCTAssertNil(body["email"].string)
        XCTAssertNil(body["apple_user_id"].string)
        XCTAssertNil(body["user_id"].string)
        XCTAssertNil(body["base44_access_token"].string)
    }

    func testMissingProviderConfigurationMakesNoRequestAndKeepsSavedAccount() async throws {
        AppleSessionURLProtocol.state.reset([:])
        var disabled = configuration
        disabled.appleSignInEnabled = false
        let stored = SupabaseStoredSession(accessToken: "saved", refreshToken: "refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600))
        let auth = makeSession(stored: stored, configuration: disabled)
        do {
            _ = try await auth.exchangeApple(credential: credential, requestID: authorizationID)
            XCTFail("Disabled Apple login made an exchange")
        } catch let error as Base44Error { XCTAssertEqual(error.code, "apple_sign_in_disabled") }
        XCTAssertEqual(auth.session, stored)
        XCTAssertTrue(AppleSessionURLProtocol.state.records.isEmpty)
    }

    func testCancellationAtAppleCommitDoesNotPersistOrReplaceTheSavedAccount() async throws {
        successfulExchange()
        let stored = SupabaseStoredSession(accessToken: "existing", refreshToken: "existing-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600))
        var persisted = false
        let auth = makeSession(stored: stored, save: { _ in persisted = true })
        let candidate = try await auth.exchangeApple(credential: credential, requestID: authorizationID)
        let cancelledCommit = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try auth.commitApple(accessToken: candidate.accessToken, userID: actor)
        }
        do { try await cancelledCommit.value; XCTFail("Cancelled Apple acceptance persisted the candidate") }
        catch is CancellationError { }
        XCTAssertFalse(persisted)
        XCTAssertEqual(auth.session, stored)
    }

    func testAppleTransportTimeoutDoesNotRetryTheSingleUseCodeOrReplaceSavedAccount() async throws {
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/apple-session": [.init(body: Data(), transportError: .timedOut)]
        ])
        let stored = SupabaseStoredSession(accessToken: "existing", refreshToken: "existing-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600))
        var persisted = false
        let auth = makeSession(stored: stored, save: { _ in persisted = true })
        do { _ = try await auth.exchangeApple(credential: credential, requestID: authorizationID); XCTFail("Transport timeout was accepted") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "supabase_transport_interrupted") }
        XCTAssertFalse(persisted)
        XCTAssertEqual(auth.session, stored)
        XCTAssertEqual(AppleSessionURLProtocol.state.records.count, 1, "A consumed Apple authorization code must not be retried automatically")
        XCTAssertEqual(AppleSessionURLProtocol.state.records[0].request.timeoutInterval, 60)
    }

    func testWrongProviderOrMigrationProtocolCannotBecomeAnAppleSession() async throws {
        for response in [tokenResponse(provider: "game_center"), tokenResponse(migrationVersion: 0), tokenResponse(migrationVersion: 2)] {
            AppleSessionURLProtocol.state.reset(["/functions/v1/apple-session": [.init(body: response)]])
            var persisted = false
            let auth = makeSession(save: { _ in persisted = true })
            do {
                _ = try await auth.exchangeApple(credential: credential, requestID: authorizationID)
                XCTFail("An incompatible migration response was accepted")
            } catch let error as Base44Error { XCTAssertEqual(error.code, "supabase_session_response_invalid") }
            XCTAssertFalse(persisted)
            XCTAssertNil(auth.accessToken)
            XCTAssertThrowsError(try auth.commitApple(accessToken: "apple-candidate", userID: actor))
            XCTAssertEqual(AppleSessionURLProtocol.state.records.count, 1)
        }
    }

    func testProfileOwnerMismatchRevokesOnlyRejectedCandidateAndKeepsSavedAccount() async throws {
        successfulExchange(profile: profileResponse(userID: otherActor))
        let stored = SupabaseStoredSession(accessToken: "existing", refreshToken: "existing-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600))
        var persisted = false
        let auth = makeSession(stored: stored, save: { _ in persisted = true })
        do {
            _ = try await auth.exchangeApple(credential: credential, requestID: authorizationID)
            XCTFail("Apple candidate accepted another account's profile")
        } catch let error as Base44Error { XCTAssertEqual(error.code, "invalid_account_profile") }
        try await waitForRequests(3)
        XCTAssertEqual(auth.session, stored)
        XCTAssertFalse(persisted)
        XCTAssertThrowsError(try auth.commitApple(accessToken: "apple-candidate", userID: actor))
        let cleanup = try XCTUnwrap(AppleSessionURLProtocol.state.records.last)
        XCTAssertEqual(cleanup.request.url?.path, "/auth/v1/logout")
        XCTAssertEqual(cleanup.request.url?.query, "scope=local")
        XCTAssertEqual(cleanup.request.value(forHTTPHeaderField: "Authorization"), "Bearer apple-candidate")
    }

    func testDelayedAppleSuccessAfterLogoutCannotRestoreOrPersistTheAccount() async throws {
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/apple-session": [.init(body: tokenResponse(), delay: 0.1)],
            "/auth/v1/logout": [.init(body: Data("{}".utf8))]
        ])
        var persisted = false
        let auth = makeSession(save: { _ in persisted = true })
        let task = Task { try await auth.exchangeApple(credential: credential, requestID: authorizationID) }
        try await waitForRequests(1)
        auth.clear(revokeRemote: false)
        do { _ = try await task.value; XCTFail("Late Apple completion survived logout") }
        catch is CancellationError { }
        try await waitForRequests(2)
        XCTAssertFalse(persisted)
        XCTAssertNil(auth.session)
        XCTAssertThrowsError(try auth.commitApple(accessToken: "apple-candidate", userID: actor))
        XCTAssertFalse(AppleSessionURLProtocol.state.records.contains { $0.request.url?.path == "/functions/v1/app-services" })
    }

    func testLateAppleFailureAfterLogoutIsCancellationRatherThanAVisibleAuthError() async throws {
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/apple-session": [.init(body: Data(#"{"code":"apple_identity_invalid","message":"Invalid identity"}"#.utf8), status: 401, delay: 0.1)]
        ])
        let auth = makeSession()
        let task = Task { try await auth.exchangeApple(credential: credential, requestID: authorizationID) }
        try await waitForRequests(1)
        auth.clear(revokeRemote: false)
        do { _ = try await task.value; XCTFail("Late auth failure was returned after ownership changed") }
        catch is CancellationError { }
        XCTAssertNil(auth.session)
    }

    func testSupersededAppleCandidateCannotEvictTheNewerCandidate() async throws {
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/apple-session": [
                .init(body: tokenResponse(access: "old-apple"), delay: 0.1),
                .init(body: tokenResponse(access: "new-apple"))
            ],
            "/functions/v1/app-services": [.init(body: profileResponse())],
            "/auth/v1/logout": [.init(body: Data("{}".utf8))]
        ])
        var persisted: [SupabaseStoredSession] = []
        let auth = makeSession(save: { persisted.append($0) })
        let old = Task { try await auth.exchangeApple(credential: credential, requestID: authorizationID) }
        try await waitForRequests(1)
        let new = try await auth.exchangeApple(credential: credential, requestID: UUID())
        do { _ = try await old.value; XCTFail("Superseded Apple response remained current") }
        catch is CancellationError { }
        try await waitForRequests(4)
        XCTAssertThrowsError(try auth.commitApple(accessToken: "old-apple", userID: actor))
        try auth.commitApple(accessToken: new.accessToken, userID: actor)
        XCTAssertEqual(auth.accessToken, "new-apple")
        XCTAssertEqual(persisted.map(\.accessToken), ["new-apple"])
        XCTAssertEqual(AppleSessionURLProtocol.state.records.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer old-apple")
    }

    func testIncompleteMigrationFailsWithoutReplacingSavedIdentityOrFallingBackToBase44() async throws {
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/apple-session": [.init(body: Data(#"{"code":"apple_migration_pending","message":"Account migration is not complete.","retryable":true}"#.utf8), status: 503)]
        ])
        let stored = SupabaseStoredSession(accessToken: "existing", refreshToken: "refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600))
        let auth = makeSession(stored: stored)
        do { _ = try await auth.exchangeApple(credential: credential, requestID: authorizationID); XCTFail("Incomplete mapping was accepted") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "apple_migration_pending") }
        XCTAssertEqual(auth.session, stored)
        XCTAssertEqual(AppleSessionURLProtocol.state.records.count, 1)
    }

    func testSavedAppleSessionRestoresAndRefreshesWithSameUUIDWithoutBase44Credential() async throws {
        AppleSessionURLProtocol.state.reset([
            "/auth/v1/token": [.init(body: tokenResponse(access: "renewed"))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        let beforeRelaunch = SupabaseStoredSession(accessToken: "expired", refreshToken: "stored-private-refresh", userID: actor,
                                                  expiresAt: Date().addingTimeInterval(-10), nativeCredentialKind: .apple)
        let restored = try JSONDecoder().decode(SupabaseStoredSession.self, from: JSONEncoder().encode(beforeRelaunch))
        let obsoleteLegacy = SupabaseLegacyCredential(actorID: actor, legacyUserID: "old-id", accessToken: "must-not-use")
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(stored: restored, legacy: obsoleteLegacy, save: { saved.append($0) })
        let token = try await auth.ensureAccessToken()
        let user = try await auth.profile()
        XCTAssertEqual(token, "renewed")
        XCTAssertEqual(user.id, actor)
        XCTAssertTrue(auth.isNativeAppleSession)
        XCTAssertNil(auth.legacyCredential)
        XCTAssertEqual(saved.map(\.nativeCredentialKind), [.apple])
        let records = AppleSessionURLProtocol.state.records
        XCTAssertEqual(records.map { $0.request.url!.path }, ["/auth/v1/token", "/functions/v1/app-services"])
        XCTAssertEqual(records[0].request.url?.query, "grant_type=refresh_token")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: records[0].body)["refresh_token"].string, "stored-private-refresh")
        XCTAssertFalse(records.contains { $0.request.url?.path.contains("legacy-session") == true })
    }

    func testAppleRefreshRejectsAccountSwitchAndLeavesSavedSessionUnchanged() async throws {
        AppleSessionURLProtocol.state.reset(["/auth/v1/token": [.init(body: tokenResponse(userID: otherActor))]])
        let stored = SupabaseStoredSession(accessToken: "expired", refreshToken: "refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(-10), nativeCredentialKind: .apple)
        var saved = false
        let auth = makeSession(stored: stored, save: { _ in saved = true })
        do { _ = try await auth.ensureAccessToken(); XCTFail("Refresh replaced Apple account ownership") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "supabase_session_missing") }
        XCTAssertEqual(auth.session, stored)
        XCTAssertFalse(saved)
    }

    func testNativeAppleCommitCannotAcceptGameCenterCandidate() async throws {
        let proof = GameCenterIdentityProof(teamPlayerID: "G:fixture", bundleID: "com.spyclash.ios",
                                            publicKeyURL: "https://static.gc.apple.com/public-key/gc-prod-6.cer",
                                            signature: "dGVzdA==", salt: "dGVzdA==", timestamp: 1_800_000_000_000,
                                            displayName: "Operative")
        AppleSessionURLProtocol.state.reset([
            "/functions/v1/game-center-session": [.init(body: tokenResponse(access: "gc-candidate", provider: "game_center"))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        let auth = makeSession()
        let candidate = try await auth.exchangeGameCenter(proof: proof)
        XCTAssertThrowsError(try auth.commitApple(accessToken: candidate.accessToken, userID: actor))
        XCTAssertNil(auth.session)
        try auth.commitGameCenter(accessToken: candidate.accessToken, userID: actor)
        XCTAssertTrue(auth.isNativeGameCenterSession)
    }

    func testAppleDeletionRequiresItsOwnExactConfirmationAndPreservesFailedIntent() async throws {
        for marker in ["native_account_deleted", "original_account_deleted", "apple_account_deleted"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            AppleSessionURLProtocol.state.reset([
                "/functions/v1/app-services": [.init(body: Data("{\"success\":true,\"\(marker)\":true}".utf8))]
            ])
            let auth = makeSession(stored: .init(accessToken: "apple", refreshToken: "refresh", userID: actor,
                                                expiresAt: Date().addingTimeInterval(3600), nativeCredentialKind: .apple),
                                   journal: SupabaseAppMutationJournal(directory: directory))
            do {
                let result: AccountDeletionResult = try await auth.service("profile", action: "delete",
                    fields: ["deletion_scope": .string("account")], write: true)
                XCTAssertEqual(marker, "apple_account_deleted", "Another provider's deletion marker must not erase an Apple account locally")
                XCTAssertTrue(result.success)
            } catch let error as Base44Error {
                XCTAssertNotEqual(marker, "apple_account_deleted")
                XCTAssertEqual(error.code, "account_deletion_response_invalid")
            }
            let journal = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: directory.appendingPathComponent(actor + ".json")))
            XCTAssertEqual(journal.array.count, marker == "apple_account_deleted" ? 0 : 1)
            let body = try JSONDecoder().decode(JSONValue.self, from: AppleSessionURLProtocol.state.records[0].body)
            XCTAssertNil(body["base44_access_token"].string)
        }
    }

    private func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if AppleSessionURLProtocol.state.records.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected intercepted Apple request did not start")
        throw URLError(.timedOut)
    }
}

private final class AppleSessionURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var body: Data
        var status = 200
        var delay: TimeInterval = 0
        var transportError: URLError.Code? = nil
    }
    struct Record: Sendable {
        let request: URLRequest
        let body: Data
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [Reply]] = [:]
        private var captured: [Record] = []
        func reset(_ queues: [String: [Reply]]) {
            lock.lock(); defer { lock.unlock() }
            self.queues = queues; captured = []
        }
        func next(_ request: URLRequest, body: Data) -> Reply {
            lock.lock(); defer { lock.unlock() }
            captured.append(.init(request: request, body: body))
            let path = request.url?.path ?? ""
            guard var queue = queues[path], !queue.isEmpty else {
                return .init(body: Data(#"{"code":"unexpected_mock_request"}"#.utf8), status: 500)
            }
            let reply = queue.removeFirst(); queues[path] = queue; return reply
        }
        var records: [Record] { lock.lock(); defer { lock.unlock() }; return captured }
    }
    static let state = State()
    private let lock = NSRecursiveLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let reply = Self.state.next(request, body: body)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            if let error = reply.transportError {
                client?.urlProtocol(self, didFailWithError: URLError(error))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); defer { lock.unlock() }; stopped = true }
}
