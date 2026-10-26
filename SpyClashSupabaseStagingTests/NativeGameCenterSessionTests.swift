import Foundation
import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class NativeGameCenterSessionTests: XCTestCase {
    private let actor = "11111111-1111-4111-8111-111111111111"
    private let otherActor = "22222222-2222-4222-8222-222222222222"

    private var configuration: SupabaseAppConfiguration {
        {
            var value = SupabaseAppConfiguration(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_test")
            value.gameCenterSignInEnabled = true
            return value
        }()
    }

    private var proof: GameCenterIdentityProof {
        .init(teamPlayerID: "G:fixture-player", bundleID: "com.spyclash.ios",
              publicKeyURL: "https://static.gc.apple.com/public-key/gc-prod-6.cer",
              signature: "dGVzdC1zaWduYXR1cmU=", salt: "dGVzdC1zYWx0",
              timestamp: 1_800_000_000_000, displayName: "Operative")
    }

    private func tokenResponse(access: String = "candidate", userID: String? = nil, provider: String = "game_center") -> Data {
        Data("""
        {"access_token":"\(access)","refresh_token":"refresh-\(access)","expires_in":3600,
         "user":{"id":"\(userID ?? actor)"},"provider":"\(provider)"}
        """.utf8)
    }

    private func profileResponse(userID: String? = nil, email: String? = nil) -> Data {
        let id = userID ?? actor
        return Data("""
        {"id":"\(id)","email":"\(email ?? id + "@example.test")","display_name":"Operative",
         "onboarding_completed":false,"onboarding_version":0,"is_verified":true}
        """.utf8)
    }

    private func makeSession(
        stored: SupabaseStoredSession? = nil,
        configuration suppliedConfiguration: SupabaseAppConfiguration? = nil,
        journal: SupabaseAppMutationJournal? = nil,
        save: @escaping (SupabaseStoredSession) throws -> Void = { _ in },
        saveLegacy: @escaping (SupabaseLegacyCredential) throws -> Void = { _ in },
        clearLegacy: @escaping () -> Void = {}
    ) -> SupabaseAppSession {
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [NativeSessionURLProtocol.self]
        return SupabaseAppSession(
            configuration: suppliedConfiguration ?? configuration, session: URLSession(configuration: network),
            storedSession: stored, saveSession: save, clearSession: {},
            mutationJournal: journal ?? SupabaseAppMutationJournal(),
            storedLegacy: nil, saveLegacy: saveLegacy, clearLegacy: clearLegacy
        )
    }

    private func configureSuccess(access: String = "candidate", profile: Data? = nil) {
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/game-center-session": [.init(body: tokenResponse(access: access))],
            "/functions/v1/app-services": [.init(body: profile ?? profileResponse())]
        ])
    }

    func testVerifiedGameCenterCandidateCommitsWithoutLegacyCredentialAndStartsOnboarding() async throws {
        configureSuccess()
        var saved: [SupabaseStoredSession] = []
        var legacyWrites = 0
        var legacyClears = 0
        let auth = makeSession(save: { saved.append($0) }, saveLegacy: { _ in legacyWrites += 1 }, clearLegacy: { legacyClears += 1 })

        XCTAssertThrowsError(try auth.commit(accessToken: "candidate"))
        let candidate = try await auth.exchangeGameCenter(proof: proof)
        XCTAssertNil(auth.accessToken, "An exchange is only a candidate until AppState accepts ownership")
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(candidate.user.id, actor)
        XCTAssertEqual(candidate.user.onboardingCompleted, false)
        XCTAssertEqual(candidate.user.onboardingVersion, 0)

        try auth.commit(accessToken: candidate.accessToken)
        XCTAssertEqual(auth.userID, actor)
        XCTAssertEqual(saved.map(\.nativeCredentialKind), [.gameCenter])
        XCTAssertEqual(legacyWrites, 0)
        XCTAssertEqual(legacyClears, 1)
        XCTAssertNil(auth.legacyCredential)
        XCTAssertThrowsError(try auth.legacyAccessToken())

        let records = NativeSessionURLProtocol.state.records
        XCTAssertEqual(records.map { $0.request.url!.path }, ["/functions/v1/game-center-session", "/functions/v1/app-services"])
        XCTAssertNil(records[0].request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(records[1].request.value(forHTTPHeaderField: "Authorization"), "Bearer candidate")
        let sentProof = try JSONDecoder().decode(GameCenterIdentityProof.self, from: records[0].body)
        XCTAssertEqual(sentProof, proof)
        let profileRequest = try JSONDecoder().decode(JSONValue.self, from: records[1].body)
        XCTAssertEqual(profileRequest["service"].string, "profile")
        XCTAssertEqual(profileRequest["action"].string, "current")
    }

    func testDisabledGameCenterDoesNotRequestOrReplaceSavedAccount() async throws {
        NativeSessionURLProtocol.state.reset([:])
        var disabled = configuration
        disabled.gameCenterSignInEnabled = false
        let stored = SupabaseStoredSession(accessToken: "existing", refreshToken: "refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600))
        let auth = makeSession(stored: stored, configuration: disabled)
        do {
            _ = try await auth.exchangeGameCenter(proof: proof)
            XCTFail("Disabled Game Center initiated an exchange")
        } catch let error as Base44Error {
            XCTAssertEqual(error.code, "game_center_disabled")
        }
        XCTAssertTrue(NativeSessionURLProtocol.state.records.isEmpty)
        XCTAssertEqual(auth.session, stored)
    }

    func testCommittedCandidateCannotRestoreAnAccountAfterLogout() async throws {
        configureSuccess()
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(save: { saved.append($0) })
        let candidate = try await auth.exchangeGameCenter(proof: proof)
        try auth.commit(accessToken: candidate.accessToken)
        auth.clear(revokeRemote: false)
        XCTAssertThrowsError(try auth.commit(accessToken: candidate.accessToken))
        XCTAssertNil(auth.accessToken)
        XCTAssertEqual(saved.count, 1)
    }

    func testRestoredNativeSessionRevalidatesWithoutALegacyAccount() async throws {
        NativeSessionURLProtocol.state.reset([
            "/auth/v1/token": [.init(body: tokenResponse(access: "restored"))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        let stored = SupabaseStoredSession(accessToken: "saved-access", refreshToken: "saved-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600), nativeCredentialKind: .gameCenter)
        let restored = makeSession(stored: stored)
        let token = try await restored.ensureAccessToken(forceLegacyValidation: true)
        let profile = try await restored.profile()
        XCTAssertEqual(token, "restored")
        XCTAssertEqual(profile.id, actor)
        XCTAssertTrue(restored.isNativeGameCenterSession)
        XCTAssertNil(restored.legacyCredential)
        XCTAssertEqual(NativeSessionURLProtocol.state.records.map { $0.request.url!.path }, ["/auth/v1/token", "/functions/v1/app-services"])
        XCTAssertEqual(NativeSessionURLProtocol.state.records.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer restored")
    }

    func testGameCenterCommitRejectsDifferentActorBeforePersistence() async throws {
        configureSuccess()
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(save: { saved.append($0) })
        let candidate = try await auth.exchangeGameCenter(proof: proof)
        XCTAssertThrowsError(try auth.commitGameCenter(accessToken: candidate.accessToken, userID: otherActor))
        XCTAssertNil(auth.accessToken)
        XCTAssertTrue(saved.isEmpty)
        try auth.commitGameCenter(accessToken: candidate.accessToken, userID: actor)
        XCTAssertEqual(auth.userID, actor)
        XCTAssertTrue(auth.isNativeGameCenterSession)
        XCTAssertEqual(saved.count, 1)
    }

    func testGameCenterCommitCannotAcceptClassicLoginCandidate() async throws {
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/legacy-session": [.init(body: Data("{\"access_token\":\"classic-candidate\",\"refresh_token\":\"classic-refresh\",\"expires_in\":3600,\"legacy_user_id\":\"legacy-person\",\"user\":{\"id\":\"\(actor)\"}}".utf8))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(save: { saved.append($0) })
        let candidate = try await auth.exchangeLegacySession("classic-login-bearer")
        XCTAssertThrowsError(try auth.commitGameCenter(accessToken: candidate.accessToken, userID: actor))
        XCTAssertNil(auth.accessToken)
        XCTAssertTrue(saved.isEmpty)
        try auth.commit(accessToken: candidate.accessToken)
        XCTAssertNil(auth.session?.nativeCredentialKind)
        XCTAssertEqual(try auth.legacyAccessToken(), "classic-login-bearer")
    }

    func testMismatchedProfileCannotBecomeAccount() async throws {
        for badProfile in [profileResponse(userID: otherActor), profileResponse(email: "untrusted@example.com")] {
            configureSuccess(profile: badProfile)
            var saved = false
            let auth = makeSession(save: { _ in saved = true })
            do {
                _ = try await auth.exchangeGameCenter(proof: proof)
                XCTFail("Mismatched authenticated profile was accepted")
            } catch let error as Base44Error {
                XCTAssertEqual(error.code, "invalid_account_profile")
            }
            XCTAssertThrowsError(try auth.commit(accessToken: "candidate"))
            XCTAssertNil(auth.accessToken)
            XCTAssertFalse(saved)
        }
    }

    func testIncorrectProviderResponseNeverFetchesProfileOrPersists() async throws {
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/game-center-session": [.init(body: tokenResponse(provider: "email"))]
        ])
        var saved = false
        let auth = makeSession(save: { _ in saved = true })
        do {
            _ = try await auth.exchangeGameCenter(proof: proof)
            XCTFail("Non-Game Center response was accepted by the Game Center route")
        } catch let error as Base44Error {
            XCTAssertEqual(error.code, "supabase_session_response_invalid")
        }
        XCTAssertEqual(NativeSessionURLProtocol.state.records.count, 1)
        XCTAssertFalse(saved)
        XCTAssertThrowsError(try auth.commit(accessToken: "candidate"))
    }

    func testExpiredNativeSessionUsesRefreshTokenAndPreservesProvider() async throws {
        NativeSessionURLProtocol.state.reset(["/auth/v1/token": [.init(body: tokenResponse(access: "renewed"))]])
        let stored = SupabaseStoredSession(accessToken: "expired", refreshToken: "stored-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(-10), nativeCredentialKind: .gameCenter)
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(stored: stored, save: { saved.append($0) })
        let access = try await auth.ensureAccessToken()
        XCTAssertEqual(access, "renewed")
        XCTAssertEqual(saved.map(\.nativeCredentialKind), [.gameCenter])
        XCTAssertNil(auth.legacyCredential)
        let records = NativeSessionURLProtocol.state.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].request.url!.path, "/auth/v1/token")
        XCTAssertEqual(records[0].request.url!.query, "grant_type=refresh_token")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: records[0].body)["refresh_token"].string, "stored-refresh")
        XCTAssertFalse(records.contains { $0.request.url!.path.contains("legacy-session") })
    }

    func testRefreshCannotSwitchActorOrOverwriteStoredAccount() async throws {
        NativeSessionURLProtocol.state.reset(["/auth/v1/token": [.init(body: tokenResponse(access: "foreign", userID: otherActor))]])
        let stored = SupabaseStoredSession(accessToken: "existing", refreshToken: "refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(-10), nativeCredentialKind: .gameCenter)
        var saved = false
        let auth = makeSession(stored: stored, save: { _ in saved = true })
        do {
            _ = try await auth.ensureAccessToken()
            XCTFail("Refresh changed the account")
        } catch let error as Base44Error {
            XCTAssertEqual(error.code, "supabase_session_missing")
        }
        XCTAssertEqual(auth.session, stored)
        XCTAssertFalse(saved)
    }

    func testDelayedGameCenterResponseCannotEvictClassicLoginCandidate() async throws {
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/game-center-session": [.init(body: tokenResponse(access: "old-game-center"), delay: 0.15)],
            "/functions/v1/legacy-session": [.init(body: Data("{\"access_token\":\"classic-candidate\",\"refresh_token\":\"classic-refresh\",\"expires_in\":3600,\"legacy_user_id\":\"legacy-person\",\"user\":{\"id\":\"\(actor)\"}}".utf8))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(save: { saved.append($0) })
        let older = Task { try await auth.exchangeGameCenter(proof: proof) }
        try await waitForRequestCount(1)
        let newer = try await auth.exchangeLegacySession("classic-login-bearer")
        do {
            _ = try await older.value
            XCTFail("Superseded Game Center attempt completed")
        } catch is CancellationError { }
        XCTAssertThrowsError(try auth.commit(accessToken: "old-game-center"))
        try auth.commit(accessToken: newer.accessToken)
        XCTAssertEqual(saved.map(\.accessToken), ["classic-candidate"])
        XCTAssertNil(auth.session?.nativeCredentialKind)
        XCTAssertEqual(try auth.legacyAccessToken(), "classic-login-bearer")
    }

    func testCancelledOwnershipAfterExchangeCannotPersistCandidate() async throws {
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/game-center-session": [.init(body: tokenResponse(), delay: 0.1)],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        var ownsAttempt = true
        var saved = false
        let auth = makeSession(save: { _ in saved = true })
        let pending = Task {
            try await auth.exchangeGameCenter(proof: proof) {
                guard ownsAttempt else { throw CancellationError() }
            }
        }
        try await waitForRequestCount(1)
        ownsAttempt = false
        do { _ = try await pending.value; XCTFail("Cancelled ownership was accepted") }
        catch is CancellationError { }
        XCTAssertEqual(NativeSessionURLProtocol.state.records.count, 1)
        XCTAssertThrowsError(try auth.commit(accessToken: "candidate"))
        XCTAssertNil(auth.accessToken)
        XCTAssertFalse(saved)
    }

    func testPersistenceFailureDoesNotExposeCandidateAsSignedIn() async throws {
        configureSuccess()
        enum StorageFailure: Error { case denied }
        var legacyClears = 0
        let auth = makeSession(save: { _ in throw StorageFailure.denied }, clearLegacy: { legacyClears += 1 })
        let candidate = try await auth.exchangeGameCenter(proof: proof)
        XCTAssertThrowsError(try auth.commit(accessToken: candidate.accessToken))
        XCTAssertNil(auth.accessToken)
        XCTAssertEqual(legacyClears, 0)
    }


    func testOldStoredSessionsDecodeWithoutNativeCredentialKind() throws {
        let original = SupabaseStoredSession(accessToken: "old", refreshToken: "old-refresh", userID: actor, expiresAt: Date())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "nativeCredentialKind")
        let decoded = try JSONDecoder().decode(SupabaseStoredSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.nativeCredentialKind, "Existing saved Base44 sessions must not become native accounts")
        XCTAssertEqual(decoded.accessToken, original.accessToken)
    }





    func testInvalidRefreshTokenIsReportedAsExpiredAuthentication() async throws {
        NativeSessionURLProtocol.state.reset([
            "/auth/v1/token": [.init(body: Data(#"{"code":"refresh_token_not_found","message":"Invalid Refresh Token: Refresh Token Not Found"}"#.utf8), status: 400)]
        ])
        let stored = SupabaseStoredSession(accessToken: "old", refreshToken: "invalid-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(-10), nativeCredentialKind: .gameCenter)
        let auth = makeSession(stored: stored)
        do {
            _ = try await auth.ensureAccessToken()
            XCTFail("Invalid refresh token was accepted")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 401, "AppState must be able to discard an expired account session and show sign-in")
        }
        XCTAssertEqual(auth.session, stored, "AppState owns clearing rejected session state")
    }

    func testNativeDeletionRequiresItsOwnConfirmationAndRetainsExactIntentAcrossRestart() async throws {
        let unresolved: [(Int, String)] = [
            (200, #"{"success":true}"#),
            (200, #"{"success":true,"original_account_deleted":true}"#),
            (200, #"{"success":false,"native_account_deleted":true}"#),
            (503, #"{"code":"account_deletion_pending","retryable":true}"#),
            (409, #"{"code":"account_deletion_request_conflict","retryable":false}"#)
        ]
        for (status, response) in unresolved {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            NativeSessionURLProtocol.state.reset([
                "/functions/v1/app-services": [
                    .init(body: Data(response.utf8), status: status),
                    .init(body: confirmedNativeDeletion)
                ]
            ])
            do {
                _ = try await deleteNativeAccount(using: nativeDeletionSession(directory: directory))
                XCTFail("Native deletion accepted an unresolved or legacy confirmation")
            } catch let error as Base44Error {
                if status == 200 { XCTAssertEqual(error.code, "account_deletion_response_invalid") }
            }
            let persisted = try String(contentsOf: directory.appendingPathComponent(actor + ".json"), encoding: .utf8)
            XCTAssertTrue(persisted.contains("request_id"))
            XCTAssertFalse(persisted.contains("native-private-access"))
            XCTAssertFalse(persisted.contains("base44_access_token"))

            let result = try await deleteNativeAccount(using: nativeDeletionSession(directory: directory))
            XCTAssertTrue(result.success)
            XCTAssertFalse(result.manualAppleRevocationRequired)
            let records = NativeSessionURLProtocol.state.records
            let bodies = try records.map { try JSONDecoder().decode(JSONValue.self, from: $0.body) }
            XCTAssertEqual(bodies.count, 2)
            XCTAssertEqual(bodies.first, bodies.last, "Retry after restart must reuse the original deletion intent")
            let first = try XCTUnwrap(bodies.first)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(first["request_id"].string)))
            XCTAssertEqual(first["deletion_scope"].string, "account")
            XCTAssertNil(first["base44_access_token"].string)
            XCTAssertTrue(records.allSatisfy { $0.request.timeoutInterval == 90 })
            XCTAssertTrue(records.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer native-private-access" })
            let remaining = try Data(contentsOf: directory.appendingPathComponent(actor + ".json"))
            XCTAssertTrue(try JSONDecoder().decode(JSONValue.self, from: remaining).array.isEmpty)
        }
    }

    func testNativeDeletionRefreshesExpiredJWTWithoutLegacyCredentialOrNewIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/app-services": [
                .init(body: Data(#"{"code":"jwt_expired"}"#.utf8), status: 401),
                .init(body: confirmedNativeDeletion)
            ],
            "/auth/v1/token": [.init(body: tokenResponse(access: "renewed-native"))]
        ])
        let result = try await deleteNativeAccount(using: nativeDeletionSession(directory: directory))
        XCTAssertTrue(result.success)
        let records = NativeSessionURLProtocol.state.records
        XCTAssertEqual(records.map { $0.request.url!.path }, ["/functions/v1/app-services", "/auth/v1/token", "/functions/v1/app-services"])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: records[0].body), try JSONDecoder().decode(JSONValue.self, from: records[2].body))
        XCTAssertEqual(records[2].request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-native")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: records[1].body)["refresh_token"].string, "native-private-refresh")
    }

    func testLateNativeDeletionSuccessAfterLogoutCannotAcknowledgeOldIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/app-services": [.init(body: confirmedNativeDeletion, delay: 0.15), .init(body: confirmedNativeDeletion)]
        ])
        let auth = nativeDeletionSession(directory: directory)
        let pending = Task { try await deleteNativeAccount(using: auth) }
        try await waitForRequestCount(1)
        auth.clear(revokeRemote: false)
        do { _ = try await pending.value; XCTFail("A departed account's success must not settle its saved intent") }
        catch { XCTAssertTrue(RequestCancellationPolicy.isCancellation(error)) }
        let persisted = try String(contentsOf: directory.appendingPathComponent(actor + ".json"), encoding: .utf8)
        XCTAssertTrue(persisted.contains("request_id"))
        _ = try await deleteNativeAccount(using: nativeDeletionSession(directory: directory))
        let bodies = try NativeSessionURLProtocol.state.records.map { try JSONDecoder().decode(JSONValue.self, from: $0.body) }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
    }

    private var confirmedNativeDeletion: Data {
        Data(#"{"success":true,"native_account_deleted":true,"auth_cleanup_pending":true}"#.utf8)
    }

    private func nativeDeletionSession(directory: URL) -> SupabaseAppSession {
        makeSession(
            stored: SupabaseStoredSession(accessToken: "native-private-access", refreshToken: "native-private-refresh", userID: actor,
                                          expiresAt: Date().addingTimeInterval(3600), nativeCredentialKind: .gameCenter),
            journal: SupabaseAppMutationJournal(directory: directory)
        )
    }

    private func deleteNativeAccount(using auth: SupabaseAppSession) async throws -> AccountDeletionResult {
        try await auth.service("profile", action: "delete", fields: ["deletion_scope": .string("account")], write: true)
    }

    private func waitForRequestCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if NativeSessionURLProtocol.state.records.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected intercepted request did not start")
        throw URLError(.timedOut)
    }


}

@MainActor
final class OnboardingSessionRecoveryTests: XCTestCase {
    func testRejectedSessionOpensSignInAndPreservesSelectedLanguageWithoutCompletingOnboarding() async throws {
        let profile = try makeUser()
        var cleared = 0
        let recovering = try makeState(clearToken: { cleared += 1 })
        recovering.user = profile
        recovering.setOnboardingLanguage(.ru)
        recovering.gameCenterOnboardingCompletionOverride = { _ in
            throw Base44Error(message: "Sign in to continue.", statusCode: 401, code: "unauthorized")
        }

        await recovering.finishOnboarding()

        XCTAssertNil(recovering.user)
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(recovering.authPhase, .email)
        XCTAssertEqual(recovering.authPresentationRequestID, 1)
        XCTAssertEqual(recovering.authError, "Сессия истекла. Войдите снова, чтобы завершить настройку.")
        XCTAssertEqual(recovering.language, .ru)
        XCTAssertEqual(AppLanguage.stored, .ru)
        XCTAssertFalse(recovering.isFinishingOnboarding)
        XCTAssertFalse(recovering.isGameCenterSigningIn)
        XCTAssertNil(OnboardingProgressStore.completedVersion(for: profile.id))
        XCTAssertNil(OnboardingProgressStore.pendingSubmission(for: profile.id))
        XCTAssertEqual(recovering.toastNotices.last?.title, recovering.authError)
    }

    func testTransientServiceFailureKeepsAccountAndOnboardingAvailableForRetry() async throws {
        var cleared = 0
        let state = try makeState(clearToken: { cleared += 1 })
        let profile = try makeUser()
        state.user = profile
        state.setOnboardingLanguage(.uk)
        var submissions = 0
        state.gameCenterOnboardingCompletionOverride = { _ in
            submissions += 1
            throw Base44Error(message: "Service temporarily unavailable.", statusCode: 503, code: "auth_unavailable", retryable: true)
        }

        await state.finishOnboarding()
        await state.finishOnboarding()

        XCTAssertEqual(submissions, 2)
        XCTAssertEqual(state.user?.id, profile.id)
        XCTAssertTrue(state.requiresOnboarding)
        XCTAssertEqual(state.language, .uk)
        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(state.authPresentationRequestID, 0)
        XCTAssertNil(state.authError)
        XCTAssertFalse(state.isFinishingOnboarding)
        XCTAssertNil(OnboardingProgressStore.completedVersion(for: profile.id))
    }

    func testLateUnauthorizedCannotSignOutReplacementAccount() async throws {
        var cleared = 0
        let state = try makeState(clearToken: { cleared += 1 })
        state.user = try makeUser()
        let pending = PendingOnboardingResponse()
        state.gameCenterOnboardingCompletionOverride = { _ in try await pending.wait() }
        let attempt = Task { await state.finishOnboarding() }
        try await waitUntil { pending.continuation != nil }
        let replacement = try makeUser()
        state.user = replacement
        pending.rejectUnauthorized()
        await attempt.value

        XCTAssertEqual(state.user?.id, replacement.id)
        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(state.authPresentationRequestID, 0)
        XCTAssertTrue(state.toastNotices.isEmpty)
        XCTAssertFalse(state.isFinishingOnboarding)
    }

    func testLateUnauthorizedCannotSignOutNewSessionForSameAccount() async throws {
        var cleared = 0
        let state = try makeState(clearToken: { cleared += 1 })
        let profile = try makeUser()
        state.user = profile
        let pending = PendingOnboardingResponse()
        state.gameCenterOnboardingCompletionOverride = { _ in try await pending.wait() }
        let attempt = Task { await state.finishOnboarding() }
        try await waitUntil { pending.continuation != nil }
        // No credentials exist in this clean test process; clearing rotates the
        // same generation used when an account receives a replacement session.
        SupabaseAppSession.shared.clear(revokeRemote: false)
        pending.rejectUnauthorized()
        await attempt.value

        XCTAssertEqual(state.user?.id, profile.id)
        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(state.authPresentationRequestID, 0)
        XCTAssertTrue(state.toastNotices.isEmpty)
        XCTAssertFalse(state.isFinishingOnboarding)
    }

    func testCancelledOnboardingDoesNotInterpretLateUnauthorizedAsLogout() async throws {
        var cleared = 0
        let state = try makeState(clearToken: { cleared += 1 })
        let profile = try makeUser()
        state.user = profile
        let pending = PendingOnboardingResponse()
        state.gameCenterOnboardingCompletionOverride = { _ in try await pending.wait() }
        let attempt = Task { await state.finishOnboarding() }
        try await waitUntil { pending.continuation != nil }
        attempt.cancel()
        pending.rejectUnauthorized()
        await attempt.value

        XCTAssertEqual(state.user?.id, profile.id)
        XCTAssertEqual(cleared, 0)
        XCTAssertEqual(state.authPresentationRequestID, 0)
        XCTAssertTrue(state.toastNotices.isEmpty)
        XCTAssertFalse(state.isFinishingOnboarding)
    }

    func testCompletedOnboardingCannotOverwriteReplacementRevealAfterLogout() async throws {
        let state = try makeState()
        let original = try makeUser()
        let completed = try makeUser(id: original.id, completed: true)
        state.user = original
        state.gameCenterOnboardingCompletionOverride = { _ in completed }
        let finishing = Task { await state.finishOnboarding() }
        try await waitUntil { state.onboardingLaunchMessage != nil }

        state.logout()
        let replacement = try makeUser()
        state.user = replacement
        state.onboardingLaunchMessage = "Replacement account setup"
        state.authHomeRevealPhase = .covered
        await finishing.value

        XCTAssertEqual(state.user?.id, replacement.id)
        XCTAssertEqual(state.onboardingLaunchMessage, "Replacement account setup")
        XCTAssertEqual(state.authHomeRevealPhase, .covered)
        XCTAssertTrue(state.requiresOnboarding)
    }

    func testPasswordRecoveryInvalidatesCompletedOnboardingReveal() async throws {
        let state = try makeState()
        let original = try makeUser()
        let completed = try makeUser(id: original.id, completed: true)
        state.user = original
        state.gameCenterOnboardingCompletionOverride = { _ in completed }
        let finishing = Task { await state.finishOnboarding() }
        try await waitUntil { state.onboardingLaunchMessage != nil }

        state.handleIncomingURL(try XCTUnwrap(URL(string: "spyclash-supabasetest://reset-password?token=recovery-fixture")))
        XCTAssertEqual(state.authPhase, .resetPassword(token: "recovery-fixture"))
        XCTAssertNil(state.onboardingLaunchMessage)
        XCTAssertEqual(state.authHomeRevealPhase, .idle)
        await finishing.value

        XCTAssertEqual(state.authPhase, .resetPassword(token: "recovery-fixture"))
        XCTAssertNil(state.onboardingLaunchMessage)
        XCTAssertEqual(state.authHomeRevealPhase, .idle)
        XCTAssertFalse(state.isFinishingOnboarding)
    }

    private func makeState(clearToken: @escaping @MainActor () -> Void = {}) throws -> AppState {
        // These tests exercise the real logout cleanup. Never revoke an account
        // left on a shared manual-QA device: run this suite on a clean simulator.
        try XCTSkipIf(SupabaseAppSession.shared.accessToken != nil, "Onboarding recovery tests require a clean QA Simulator with no saved account.")
        let language = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        let automaticEntry: Bool? = UserDefaults.standard.object(forKey: GameCenterAutomaticEntryPolicy.optOutKey) == nil
            ? nil : UserDefaults.standard.bool(forKey: GameCenterAutomaticEntryPolicy.optOutKey)
        addTeardownBlock {
            UserDefaults.standard.set(language, forKey: AppLanguage.storageKey)
            UserDefaults.standard.set(automaticEntry, forKey: GameCenterAutomaticEntryPolicy.optOutKey)
        }
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, saveStoredToken: { _ in }, clearStoredToken: clearToken)
        state.isRestoring = false
        return state
    }

    private func makeUser(id: String = UUID().uuidString.lowercased(), completed: Bool = false) throws -> SpyUser {
        addTeardownBlock { OnboardingProgressStore.clear(for: id) }
        return try JSONDecoder().decode(SpyUser.self, from: Data("""
        {"id":"\(id)","email":"\(id)@example.test","display_name":"Onboarding QA",
         "language":"en","onboarding_completed":\(completed),"onboarding_version":\(completed ? 2 : 0)}
        """.utf8))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Onboarding request did not suspend")
        throw URLError(.timedOut)
    }
}

@MainActor
private final class PendingOnboardingResponse {
    var continuation: CheckedContinuation<SpyUser, Error>?
    func wait() async throws -> SpyUser {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func rejectUnauthorized() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: Base44Error(message: "Sign in to continue.", statusCode: 401, code: "unauthorized"))
    }
}

private final class NativeSessionURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var body: Data
        var status = 200
        var delay: TimeInterval = 0
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
            self.queues = queues
            captured = []
        }
        func next(_ request: URLRequest, body: Data) -> Reply {
            lock.lock(); defer { lock.unlock() }
            captured.append(.init(request: request, body: body))
            let path = request.url?.path ?? ""
            guard var replies = queues[path], !replies.isEmpty else {
                return .init(body: Data(#"{"code":"unexpected_mock_request"}"#.utf8), status: 500)
            }
            let reply = replies.removeFirst()
            queues[path] = replies
            return reply
        }
        var records: [Record] {
            lock.lock(); defer { lock.unlock() }
            return captured
        }
    }

    static let state = State()
    private let loadingLock = NSRecursiveLock()
    private var stopped = false

    // Intercept every URL, including any accidental production request. No
    // request from these tests can fall through to a real network transport.
    override class func canInit(with request: URLRequest) -> Bool { true }
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
        let reply = Self.state.next(request, body: body)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            loadingLock.lock(); defer { loadingLock.unlock() }
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingLock.lock(); defer { loadingLock.unlock() }
        stopped = true
    }
}
