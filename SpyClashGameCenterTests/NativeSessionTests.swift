import Foundation
import XCTest
@testable import SpyClashGameCenter

@MainActor
final class NativeSessionTests: XCTestCase {
    private let actor = "11111111-1111-4111-8111-111111111111"
    private let otherActor = "22222222-2222-4222-8222-222222222222"

    private var configuration: SupabaseAppConfiguration {
        .init(backendURL: "http://127.0.0.1:56330", publishableKey: "sb_publishable_test")
    }

    private var proof: GameCenterIdentityProof {
        .init(teamPlayerID: "G:fixture-player", bundleID: "com.spyclash.ios.gamecenter000",
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
        save: @escaping (SupabaseStoredSession) throws -> Void = { _ in },
        saveLegacy: @escaping (SupabaseLegacyCredential) throws -> Void = { _ in },
        clearLegacy: @escaping () -> Void = {}
    ) -> SupabaseAppSession {
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [NativeSessionURLProtocol.self]
        return SupabaseAppSession(
            configuration: configuration, session: URLSession(configuration: network),
            storedSession: stored, saveSession: save, clearSession: {},
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
                                          expiresAt: Date().addingTimeInterval(-10), nativeCredentialKind: .email)
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

    func testDelayedGameCenterResponseCannotEvictNewerEmailCandidate() async throws {
        NativeSessionURLProtocol.state.reset([
            "/functions/v1/game-center-session": [.init(body: tokenResponse(access: "old-game-center"), delay: 0.15)],
            "/auth/v1/token": [.init(body: tokenResponse(access: "new-email"))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        var saved: [SupabaseStoredSession] = []
        let auth = makeSession(save: { saved.append($0) })
        let older = Task { try await auth.exchangeGameCenter(proof: proof) }
        try await waitForRequestCount(1)
        let newer = try await auth.nativeEmailLogin(email: "fixture@example.test", password: "unused-test-password")
        do {
            _ = try await older.value
            XCTFail("Superseded Game Center attempt completed")
        } catch is CancellationError { }
        XCTAssertThrowsError(try auth.commit(accessToken: "old-game-center"))
        try auth.commit(accessToken: newer.accessToken)
        XCTAssertEqual(saved.map(\.accessToken), ["new-email"])
        XCTAssertEqual(auth.session?.nativeCredentialKind, .email)
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

    func testExperimentRejectsProductionEndpointsAndPrivilegedKeys() throws {
        XCTAssertNoThrow(try configuration.validated())
        for endpoint in ["https://bbkfsgnordtdiblgdzkg.supabase.co", "https://spyclash.com", "http://127.0.0.1:56330.evil.test", "http://127.0.0.1:56330/", "http://localhost:56330"] {
            XCTAssertThrowsError(try SupabaseAppConfiguration(backendURL: endpoint, publishableKey: "sb_publishable_test").validated(), endpoint)
        }
        for key in ["sb_secret_never_bundle", "", "sb_publishable_bad key", makeJWT(role: "service_role")] {
            XCTAssertThrowsError(try SupabaseAppConfiguration(backendURL: "http://127.0.0.1:56330", publishableKey: key).validated())
        }
        XCTAssertNoThrow(try SupabaseAppConfiguration(backendURL: "http://127.0.0.1:56330", publishableKey: makeJWT(role: "anon")).validated())
        var configuration = configuration
        configuration.permitsLegacyBilling = true
        XCTAssertThrowsError(try configuration.validated())
        XCTAssertFalse(SupabaseAppRuntime.acceptsRadarBackend("supabase:bbkfsgnordtdiblgdzkg"))
        XCTAssertEqual(SupabaseAppRuntime.callbackScheme, "spyclash-gamecenter000")
    }

    func testOldStoredSessionsDecodeWithoutNativeCredentialKind() throws {
        let original = SupabaseStoredSession(accessToken: "old", refreshToken: "old-refresh", userID: actor, expiresAt: Date())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "nativeCredentialKind")
        let decoded = try JSONDecoder().decode(SupabaseStoredSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.nativeCredentialKind, "Existing saved Base44 sessions must not become native accounts")
        XCTAssertEqual(decoded.accessToken, original.accessToken)
    }

    func testSelectedCloudExperimentAllowsOnlyItsExactOrigin() throws {
        let allowed = SupabaseAppConfiguration(backendURL: "https://ovowoixuyabccgkxcexp.supabase.co", publishableKey: "sb_publishable_test")
        XCTAssertNoThrow(try allowed.validated())
        XCTAssertEqual(allowed.projectReference, "ovowoixuyabccgkxcexp")
        XCTAssertEqual(configuration.projectReference, "gamecenter000-local")
        for origin in [
            "https://ovowoixuyabccgkxcexp.supabase.co.evil.test",
            "https://evil-ovowoixuyabccgkxcexp.supabase.co",
            "https://ovowoixuyabccgkxcexp.supabase.co:443",
            "https://ovowoixuyabccgkxcexp.supabase.co:8443",
            "https://ovowoixuyabccgkxcexp.supabase.co/",
            "http://ovowoixuyabccgkxcexp.supabase.co",
            "https://aaaaaaaaaaaaaaaaaaaa.supabase.co",
            "https://bbkfsgnordtdiblgdzkg.supabase.co",
            "https://user@ovowoixuyabccgkxcexp.supabase.co"
        ] {
            XCTAssertThrowsError(try SupabaseAppConfiguration(backendURL: origin, publishableKey: "sb_publishable_test").validated(), origin)
        }
        let selected = try SupabaseAppConfiguration.bundled()
        XCTAssertEqual(SupabaseAppRuntime.radarBackendNamespace, "supabase:" + selected.projectReference)
        XCTAssertTrue(SupabaseAppRuntime.acceptsRadarBackend("supabase:" + selected.projectReference))
        XCTAssertFalse(SupabaseAppRuntime.acceptsRadarBackend("supabase:bbkfsgnordtdiblgdzkg"))
        let other = selected.projectReference == "gamecenter000-local" ? "ovowoixuyabccgkxcexp" : "gamecenter000-local"
        XCTAssertFalse(SupabaseAppRuntime.acceptsRadarBackend("supabase:" + other))
    }

    func testNativeRecoveryRequiresOwnRouteAndUnambiguousRecoveryFragment() {
        XCTAssertEqual(ResetPasswordLinkParser.tokenIfPresent(from: "spyclash-gamecenter000://reset-password#type=recovery&access_token=fixture-token&refresh_token=fixture-refresh&expires_in=3600&token_type=bearer"), "fixture-token")
        for link in [
            "spyclash://reset-password#type=recovery&access_token=fixture-token",
            "spyclash-supabasetest://reset-password#type=recovery&access_token=fixture-token",
            "https://spyclash.com/reset-password#type=recovery&access_token=fixture-token",
            "spyclash-gamecenter000://auth-callback#type=recovery&access_token=fixture-token",
            "spyclash-gamecenter000://arbitrary#type=recovery&access_token=fixture-token",
            "spyclash-gamecenter000://reset-password/extra#type=recovery&access_token=fixture-token",
            "spyclash-gamecenter000://reset-password?type=recovery&access_token=fixture-token",
            "spyclash-gamecenter000://reset-password?unrelated=1#type=recovery&access_token=fixture-token",
            "spyclash-gamecenter000://reset-password#access_token=fixture-token",
            "spyclash-gamecenter000://reset-password#type=signup&access_token=fixture-token",
            "spyclash-gamecenter000://reset-password#type=recovery&type=signup&access_token=fixture-token",
            "spyclash-gamecenter000://reset-password#type=recovery&access_token=one&access_token=two",
            "spyclash-gamecenter000://reset-password#type=recovery&access_token=fixture-token&token=other",
            "spyclash-gamecenter000://reset-password#type=recovery&access_token=fixture-token&error=denied",
            "spyclash-gamecenter000://reset-password#type=recovery&access_token=",
            "spyclash-gamecenter000://reset-password#type=recovery&access_token=%20fixture-token",
            "spyclash-gamecenter000://reset-password#type=recovery&access_token=fixture%0Atoken",
            "spyclash-gamecenter000://reset-password?token=legacy-token",
            "spyclash-gamecenter000://reset-password#reset_token=legacy-token"
        ] {
            XCTAssertNil(ResetPasswordLinkParser.tokenIfPresent(from: link), link)
        }
    }

    func testEmailSignupConfirmationAndVerificationRemainIsolated() async throws {
        NativeSessionURLProtocol.state.reset([
            "/auth/v1/signup": [.init(body: Data("{\"user\":{\"id\":\"\(actor)\"}}".utf8))],
            "/auth/v1/verify": [.init(body: tokenResponse(access: "verified-email"))],
            "/functions/v1/app-services": [.init(body: profileResponse())]
        ])
        let auth = makeSession()
        let initial = try await auth.nativeEmailRegister(email: "fixture@example.test", password: "test-long-password")
        XCTAssertNil(initial)
        XCTAssertNil(auth.accessToken)
        let verified = try await auth.nativeEmailVerify(email: "fixture@example.test", code: "123456")
        try auth.commit(accessToken: verified.accessToken)
        XCTAssertEqual(auth.session?.nativeCredentialKind, .email)
        XCTAssertEqual(NativeSessionURLProtocol.state.records.map { $0.request.url!.host }, ["127.0.0.1", "127.0.0.1", "127.0.0.1"])
    }

    func testMalformedSignupResponseDoesNotPretendConfirmationWasSent() async throws {
        NativeSessionURLProtocol.state.reset(["/auth/v1/signup": [.init(body: Data("{}".utf8))]])
        let auth = makeSession()
        do {
            _ = try await auth.nativeEmailRegister(email: "fixture@example.test", password: "test-long-password")
            XCTFail("Malformed signup response pretended to be a pending email confirmation")
        } catch let error as Base44Error {
            XCTAssertEqual(error.code, "supabase_session_response_invalid")
        }
        XCTAssertNil(auth.accessToken)
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

    private func waitForRequestCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if NativeSessionURLProtocol.state.records.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected intercepted request did not start")
        throw URLError(.timedOut)
    }

    private func makeJWT(role: String) -> String {
        let payload = Data("{\"role\":\"\(role)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "e30.\(payload).fixture"
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

    private func makeUser() throws -> SpyUser {
        let id = UUID().uuidString.lowercased()
        addTeardownBlock { OnboardingProgressStore.clear(for: id) }
        return try JSONDecoder().decode(SpyUser.self, from: Data("""
        {"id":"\(id)","email":"\(id)@example.test","display_name":"Onboarding QA",
         "language":"en","onboarding_completed":false,"onboarding_version":0}
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
