import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class AuthenticationFlowTests: XCTestCase {
    private var clientRegistration: String?
    private var requestHandler: (@Sendable (AuthenticationFlowURLProtocol) -> Void)? {
        get { clientRegistration.flatMap { AuthenticationFlowURLProtocol.handlers[$0] } }
        set {
            guard let clientRegistration else {
                if newValue != nil { XCTFail("Create an owned HTTP client before installing its handler") }
                return
            }
            AuthenticationFlowURLProtocol.handlers[clientRegistration] = newValue
        }
    }

    private func client() -> Base44Client {
        // Logout cleanup may outlive the test or a loop iteration. Retire its
        // exact registration before creating another client; no later request
        // can acquire the next client's authentication handler. The session
        // stays valid so background cleanup can receive a normal cancellation.
        if let clientRegistration { AuthenticationFlowURLProtocol.handlers.removeValue(forKey: clientRegistration) }
        let registration = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationFlowURLProtocol.self]
        configuration.httpAdditionalHeaders = [AuthenticationFlowURLProtocol.registrationHeader: registration]
        let session = URLSession(configuration: configuration)
        clientRegistration = registration
        addTeardownBlock {
            AuthenticationFlowURLProtocol.handlers.removeValue(forKey: registration)
        }
        return Base44Client(session: session)
    }

    func testRetiredClientCannotReachReplacementHandler() async throws {
        let retired = client()
        requestHandler = { request in
            XCTFail("A retired client's handler must not execute")
            request.respond(status: 500, body: "{}")
        }
        let replacement = client()
        let registration = expectation(description: "Only replacement V2 registration reaches its handler")
        registration.assertForOverFulfill = true
        requestHandler = { request in
            XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2")
            XCTAssertEqual(try? request.jsonBody(), ["access_token": "replacement-candidate", "apple_binding_ticket": "replacement-binding"])
            registration.fulfill()
            request.respond(status: 200, body: #"{"success":true,"user":{"id":"replacement-user","email":"replacement@example.test"}}"#)
        }
        defer { requestHandler = nil }
        do {
            try await retired.resendOTP(email: "retired@example.test")
            XCTFail("A retired client's request must be cancelled by its transport")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let user = try await replacement.autoRegisterUser(appleBindingTicket: "replacement-binding", accessToken: "replacement-candidate")
        XCTAssertEqual(user.id, "replacement-user")
        await fulfillment(of: [registration], timeout: 1)
    }

    private func state(
        client: Base44Client,
        store: AuthenticationMemoryStore,
        callback: String = "spyclash://auth?access_token=candidate",
        onSessionURL: @escaping (URL) -> Void = { _ in }
    ) -> AppState {
        let coordinator = WebAuthenticationCoordinator(makeSession: { url, completion in
            onSessionURL(url)
            return AuthenticationImmediateSession {
                completion(URL(string: callback), nil)
            }
        })
        return AppState(client: client, readStoredToken: { store.token },
                        saveStoredToken: { store.token = $0; store.saves += 1 },
                        clearStoredToken: { store.token = nil; store.clears += 1 },
                        webAuthentication: coordinator)
    }

    func testGoogleLoginURLUsesFixedPublicCallbackPage() throws {
        let client = client()
        for requestedCallback in [
            "spyclash://auth",
            "https://spyclash.com/api/apps/\(Base44Client.appID)/functions/mobileAuthCallback",
            "https://example.test/redirect?access_token=unexpected"
        ] {
            let url = client.googleLoginURL(callbackURL: try XCTUnwrap(URL(string: requestedCallback)))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "spyclash.com")
            XCTAssertEqual(components.path, "/api/apps/\(Base44Client.appID)/auth/sso/login")
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.queryItems, [
                URLQueryItem(name: "app_id", value: Base44Client.appID),
                URLQueryItem(name: "from_url", value: "https://spyclash.com/MobileAuthCallback.html?auth_provider=google")
            ])
        }
    }

    func testCanonicalRecoveryLinkOpensNativePasswordFormWithoutReplacingCredentials() {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        for link in ["https://spyclash.com/reset-password?token=recovery", "spyclash://reset-password#?token=recovery"] {
            state.handleIncomingURL(URL(string: link)!)
            if case .resetPassword(let token) = state.authPhase { XCTAssertEqual(token, "recovery") }
            else { XCTFail("Canonical recovery did not open the password form") }
        }
        XCTAssertEqual(client.currentAccessToken, "existing")
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.clears, 0)
    }

    func testUntrustedRecoveryLinksCannotReplaceNativeAuthPhase() {
        let state = state(client: client(), store: AuthenticationMemoryStore(token: nil))
        state.authPhase = .password(email: "owner@example.test")
        for link in ["https://foreign.test/reset-password?token=a", "spyclash-supabasetest://reset-password?token=a", "spyclash://reset-password?token=a&token=b"] {
            state.handleIncomingURL(URL(string: link)!)
            if case .password(let email) = state.authPhase { XCTAssertEqual(email, "owner@example.test") }
            else { XCTFail("Untrusted recovery link changed authentication") }
        }
    }

    func testRecoveryAndResendCompleteWithoutCreatingSession() async {
        let client = client()
        let store = AuthenticationMemoryStore(token: nil)
        let state = state(client: client, store: store)
        requestHandler = { request in
            XCTAssertTrue(["reset-password-request", "reset-password", "resend-otp"].contains(request.request.url?.lastPathComponent ?? ""))
            request.respond(status: 200, body: "{}")
        }
        defer { requestHandler = nil }
        await state.requestPasswordReset(email: "owner@example.test")
        if case .resetEmailSent(let email) = state.authPhase { XCTAssertEqual(email, "owner@example.test") }
        else { XCTFail("Recovery request did not reach its confirmation") }
        state.authPhase = .resetPassword(token: "recovery")
        await state.resetPassword(token: "recovery", newPassword: "new-password")
        if case .email = state.authPhase {} else { XCTFail("Password change did not return to login") }
        state.authPhase = .otp(email: "owner@example.test")
        await state.resendVerificationCode(email: "owner@example.test")
        if case .otp(let email) = state.authPhase { XCTAssertEqual(email, "owner@example.test") }
        else { XCTFail("Resending OTP changed the verification phase") }
        XCTAssertNotNil(state.authNotice)
        XCTAssertNil(state.authError)
        XCTAssertNil(state.user)
        XCTAssertNil(client.currentAccessToken)
        XCTAssertEqual(store.saves, 0)
    }

    func testCancelledRecoveryCannotOverwriteNextAuthenticationPhase() async {
        let state = state(client: client(), store: AuthenticationMemoryStore(token: nil))
        let held = AuthenticationHeldRequest()
        requestHandler = { request in held.receive(request) }
        defer { requestHandler = nil }
        let recovery = Task { await state.requestPasswordReset(email: "old@example.test") }
        let request = await held.next()
        state.logout()
        state.authPhase = .password(email: "next@example.test")
        request.respond(status: 200, body: "{}")
        await recovery.value
        if case .password(let email) = state.authPhase { XCTAssertEqual(email, "next@example.test") }
        else { XCTFail("Late recovery replaced the next sign-in") }
        XCTAssertNil(state.authNotice)
    }

    func testRecoveryLinkSupersedesPendingEmailAndProviderLoginWithoutErasingSession() async {
        for provider in [false, true] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            let state = state(client: client, store: store)
            let held = AuthenticationHeldRequest()
            requestHandler = { request in held.receive(request) }
            let login = Task {
                if provider { await state.loginWithGoogle() }
                else { await state.login(email: "candidate@example.test", password: "password") }
            }
            let request = await held.next()
            state.handleIncomingURL(URL(string: "https://spyclash.com/reset-password?token=recovery")!)
            XCTAssertFalse(state.isBusy)
            let response = provider
                ? #"{"user":{"id":"candidate-user","email":"candidate@example.test"}}"#
                : #"{"access_token":"candidate","user":{"id":"candidate-user","email":"candidate@example.test"}}"#
            request.respond(status: 200, body: response)
            await login.value
            XCTAssertEqual(state.authPhase, .resetPassword(token: "recovery"))
            XCTAssertEqual(client.currentAccessToken, "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertEqual(store.saves, 0)
            XCTAssertEqual(store.clears, 0)
            XCTAssertNil(state.user)
            XCTAssertNil(state.authError)
            requestHandler = nil
        }
    }

    func testProfileSyncFailurePreservesPreviousSession() async {
        for status in [409, 503] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            var sessionURLs: [URL] = []
            let state = state(client: client, store: store, onSessionURL: { sessionURLs.append($0) })
            requestHandler = { request in
                XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUser")
                XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
                request.respond(status: status, body: #"{"error":"Temporary failure"}"#)
            }
            await state.loginWithGoogle()
            XCTAssertEqual(sessionURLs.count, 1)
            let components = sessionURLs.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            XCTAssertEqual(
                components?.queryItems?.first(where: { $0.name == "from_url" })?.value,
                "https://spyclash.com/MobileAuthCallback.html?auth_provider=google"
            )
            XCTAssertEqual(client.currentAccessToken, "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertEqual(store.saves, 0)
            XCTAssertEqual(store.clears, 0)
            XCTAssertNil(state.user)
            XCTAssertFalse(state.isBusy)
            XCTAssertNotNil(state.authError)
        }
        requestHandler = nil
    }

    func testErrorAndMalformedCallbacksNeverProvision() async {
        for callback in ["spyclash://auth?error=invalid_state", "spyclash://join?access_token=candidate", "spyclash://auth?access_token="] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            let state = state(client: client, store: store, callback: callback)
            requestHandler = { request in
                XCTFail("Invalid callback must not call the backend")
                request.respond(status: 500, body: "{}")
            }
            await state.loginWithGoogle()
            XCTAssertEqual(client.currentAccessToken, "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertFalse(state.isBusy)
            XCTAssertNotNil(state.authError)
        }
        requestHandler = nil
    }

    func testLogoutDuringProviderSyncCannotRestoreAccount() async throws {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let held = AuthenticationHeldRequest()
        requestHandler = { request in held.receive(request) }
        defer { requestHandler = nil }
        let login = Task { await state.loginWithGoogle() }
        let request = await held.next()
        state.logout()
        request.respond(status: 200, body: #"{"user":{"id":"candidate-user","email":"candidate@example.test"}}"#)
        await login.value
        XCTAssertNil(client.currentAccessToken)
        XCTAssertNil(store.token)
        XCTAssertNil(state.user)
        XCTAssertEqual(store.saves, 0)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.authError)
    }

    func testLogoutDuringEmailLoginCannotInstallLateCredentials() async {
        let client = client()
        let store = AuthenticationMemoryStore(token: nil)
        let state = state(client: client, store: store)
        let held = AuthenticationHeldRequest()
        requestHandler = { request in held.receive(request) }
        defer { requestHandler = nil }
        let login = Task { await state.login(email: "candidate@example.test", password: "test-only") }
        let request = await held.next()
        state.logout()
        request.respond(status: 200, body: #"{"access_token":"late","user":{"id":"candidate-user","email":"candidate@example.test"}}"#)
        await login.value
        XCTAssertNil(client.currentAccessToken)
        XCTAssertNil(store.token)
        XCTAssertNil(state.user)
        XCTAssertEqual(store.saves, 0)
        XCTAssertFalse(state.isBusy)
    }

    func testEmailAndOTPRejectObsoleteAttemptBeforeStartingNetwork() async {
        let client = client()
        client.setToken("existing")
        requestHandler = { request in
            XCTFail("An obsolete attempt must not contact the identity service")
            request.respond(status: 500, body: "{}")
        }
        defer { requestHandler = nil }
        for otp in [false, true] {
            do {
                if otp {
                    _ = try await client.verify(email: "candidate@example.test", code: "123456", requireCurrentAttempt: { throw CancellationError() })
                } else {
                    _ = try await client.login(email: "candidate@example.test", password: "test-only", requireCurrentAttempt: { throw CancellationError() })
                }
                XCTFail("An obsolete attempt returned credentials")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(client.currentAccessToken, "existing")
        }
    }

    func testEmailAndOTPRejectLateCredentialBeforeItCanStartSessionExchange() async throws {
        for otp in [false, true] {
            let client = client()
            client.setToken("existing")
            let generation = client.sessionGeneration
            let held = AuthenticationHeldRequest()
            requestHandler = { request in held.receive(request) }
            defer { requestHandler = nil }
            var ownsAttempt = true
            let authentication = Task {
                let requireCurrentAttempt: @MainActor @Sendable () throws -> Void = {
                    guard ownsAttempt else { throw CancellationError() }
                }
                if otp {
                    _ = try await client.verify(email: "candidate@example.test", code: "123456", requireCurrentAttempt: requireCurrentAttempt)
                } else {
                    _ = try await client.login(email: "candidate@example.test", password: "test-only", requireCurrentAttempt: requireCurrentAttempt)
                }
            }
            let request = await held.next()
            XCTAssertEqual(request.request.url?.lastPathComponent, otp ? "verify-otp" : "login")
            ownsAttempt = false
            request.respond(status: 200, body: #"{"access_token":"late","user":{"id":"candidate-user","email":"candidate@example.test"}}"#)
            do { try await authentication.value; XCTFail("A superseded source credential escaped to the next auth stage") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(client.sessionGeneration, generation)
            XCTAssertEqual(client.currentAccessToken, "existing")
        }
    }

    func testOldProviderFailureCannotClearReplacementCredentials() async {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let held = AuthenticationHeldRequest()
        requestHandler = { request in held.receive(request) }
        defer { requestHandler = nil }
        let login = Task { await state.loginWithGoogle() }
        let request = await held.next()
        client.setToken("replacement")
        store.token = "replacement"
        request.respond(status: 503, body: #"{"error":"Temporary failure"}"#)
        await login.value
        XCTAssertEqual(client.currentAccessToken, "replacement")
        XCTAssertEqual(store.token, "replacement")
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.authError)
    }

    func testOTPDoesNotMakeUnauthorizedLegacyProfileRequest() async {
        let client = client()
        let store = AuthenticationMemoryStore(token: nil)
        let state = state(client: client, store: store)
        requestHandler = { request in
            XCTAssertEqual(request.request.url?.lastPathComponent, "verify-otp")
            request.respond(status: 200, body: "{}")
        }
        defer { requestHandler = nil }
        await state.verify(email: "candidate@example.test", code: "123456")
        if case .password(let email) = state.authPhase {
            XCTAssertEqual(email, "candidate@example.test")
        } else { XCTFail("OTP should advance to password") }
        XCTAssertNil(state.authError)
        XCTAssertFalse(state.isBusy)
    }

    func testOldAppleRevealCannotChangeReplacementAuthentication() async throws {
        let client = client()
        let store = AuthenticationMemoryStore(token: nil)
        let state = state(client: client, store: store)
        let oldID = try XCTUnwrap(state.beginAuthenticationAttempt())
        let reveal = Task { try await state.revealHomeAfterAppleAuth(attemptID: oldID) }
        for _ in 0..<100 where state.authHomeRevealPhase != .covered { await Task.yield() }
        XCTAssertEqual(state.authHomeRevealPhase, .covered)
        state.logout()
        _ = try XCTUnwrap(state.beginAuthenticationAttempt())
        state.appleAuthStage = .verifyingIdentity
        do { try await reveal.value; XCTFail("Old reveal must stop") }
        catch is CancellationError { }
        XCTAssertEqual(state.appleAuthStage, .verifyingIdentity)
        XCTAssertEqual(state.authHomeRevealPhase, .idle)
        XCTAssertTrue(state.isBusy)
        state.logout()
    }

    func testProfileFallbackUsesCandidateBearerWithoutReplacingSession() async throws {
        let client = client()
        client.setToken("existing")
        requestHandler = { request in
            if request.request.url?.lastPathComponent == "autoRegisterUser" {
                XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
                request.respond(status: 200, body: "{}")
            } else {
                XCTAssertEqual(request.request.url?.lastPathComponent, "me")
                XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer candidate")
                request.respond(status: 200, body: #"{"id":"candidate-user","email":"candidate@example.test"}"#)
            }
        }
        defer { requestHandler = nil }
        let user = try await client.autoRegisterUser(accessToken: "candidate")
        XCTAssertEqual(user.id, "candidate-user")
        XCTAssertEqual(client.currentAccessToken, "existing")
    }

    func testAppleRegistrationUsesBindingAwareRouteWithoutReplacingSession() async throws {
        let client = client()
        client.setToken("existing")
        XCTAssertEqual(Base44Client.providerRegistrationFunction(appleBindingTicket: nil), "autoRegisterUser")
        XCTAssertEqual(Base44Client.providerRegistrationFunction(appleBindingTicket: ""), "autoRegisterUser")
        let registration = expectation(description: "One binding verification")
        registration.assertForOverFulfill = true
        requestHandler = { request in
            XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2")
            XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(try? request.jsonBody(), [
                "access_token": "candidate",
                "apple_binding_ticket": "original-native-binding-fixture"
            ])
            registration.fulfill()
            request.respond(status: 200, body: #"{"success":true,"user":{"id":"candidate-user","email":"candidate@example.test"}}"#)
        }
        defer { requestHandler = nil }
        let session = try await client.appleNativeProviderSession(AppleNativeSession(
            accessToken: "candidate", bindingTicket: "original-native-binding-fixture"
        ), requireCurrentAttempt: {})
        await fulfillment(of: [registration], timeout: 1)
        XCTAssertEqual(session.user.id, "candidate-user")
        XCTAssertEqual(session.accessToken, "candidate")
        XCTAssertEqual(client.currentAccessToken, "existing")
    }

    func testAppleRegistrationCannotFallBackToUnboundProfile() async throws {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        defer { requestHandler = nil }
        for body in [
            #"{}"#,
            #"{"success":true}"#,
            #"{"success":false,"user":{"id":"candidate-user","email":"candidate@example.test"}}"#,
            #"{"user":{"id":"candidate-user","email":"candidate@example.test"}}"#,
            #"{"success":true,"user":{"id":"","email":"candidate@example.test"}}"#,
            #"{"success":true,"user":{"id":"candidate-user","email":""}}"#
        ] {
            let registration = expectation(description: "Malformed binding response is terminal")
            registration.assertForOverFulfill = true
            requestHandler = { request in
                XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2", "No old handler or User/me fallback may bypass Apple binding")
                registration.fulfill()
                request.respond(status: 200, body: body)
            }
            do {
                try await state.acceptAppleNativeSession(
                    AppleNativeSession(accessToken: "candidate", bindingTicket: "binding-fixture"),
                    attemptID: attempt
                )
                XCTFail("A response without explicit binding success and a verified user cannot complete Apple binding")
            } catch let error as Base44Error {
                XCTAssertEqual(error.code, "apple_binding_response_invalid")
            }
            await fulfillment(of: [registration], timeout: 1)
            XCTAssertEqual(client.currentAccessToken, "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertEqual(store.saves, 0)
            XCTAssertEqual(store.clears, 0)
            XCTAssertNil(state.user)
        }
    }

    func testNativeAppleRequiresValidBindingBeforeAnyRegistrationOrCommit() async throws {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        requestHandler = { request in
            XCTFail("A missing or malformed native binding must never reach any provider endpoint")
            request.respond(status: 500, body: "{}")
        }
        defer { requestHandler = nil }
        for binding in ["", " ", "binding fixture", "binding\nfixture", String(repeating: "b", count: 513)] {
            do {
                try await state.acceptAppleNativeSession(
                    AppleNativeSession(accessToken: "candidate", bindingTicket: binding), attemptID: attempt
                )
                XCTFail("Invalid binding must fail before registration")
            } catch let error as Base44Error {
                XCTAssertEqual(error.code, "apple_binding_ticket_invalid")
            }
        }
        XCTAssertEqual(client.currentAccessToken, "existing")
        XCTAssertEqual(store.token, "existing")
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.clears, 0)
        XCTAssertNil(state.user)
    }

    func testNativeAppleCannotSubstituteSavedTokenForInvalidCandidate() async throws {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        requestHandler = { request in
            XCTFail("Invalid native candidate must not fall back to the existing token")
            request.respond(status: 500, body: "{}")
        }
        defer { requestHandler = nil }
        for token in ["", " ", "candidate injected", "candidate\n", String(repeating: "t", count: 20_001)] {
            do {
                try await state.acceptAppleNativeSession(
                    AppleNativeSession(accessToken: token, bindingTicket: "original-binding"), attemptID: attempt
                )
                XCTFail("Invalid candidate was accepted")
            } catch let error as Base44Error {
                XCTAssertEqual(error.code, "apple_session_candidate_invalid")
            }
        }
        XCTAssertEqual(client.currentAccessToken, "existing")
        XCTAssertEqual(store.token, "existing")
        XCTAssertEqual(store.saves, 0)
        XCTAssertEqual(store.clears, 0)
        XCTAssertNil(state.user)
    }

    func testNativeAppleBindingRejectionPreservesSessionWithoutFallback() async throws {
        defer { requestHandler = nil }
        for status in [401, 409] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            let state = state(client: client, store: store)
            let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
            let registration = expectation(description: "Binding rejection is terminal")
            registration.assertForOverFulfill = true
            requestHandler = { request in
                XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2")
                XCTAssertEqual(try? request.jsonBody(), [
                    "access_token": "untrusted-candidate",
                    "apple_binding_ticket": "original-binding"
                ])
                registration.fulfill()
                request.respond(status: status, body: #"{"error":"Apple account binding rejected"}"#)
            }
            do {
                try await state.acceptAppleNativeSession(
                    AppleNativeSession(accessToken: "untrusted-candidate", bindingTicket: "original-binding"),
                    attemptID: attempt
                )
                XCTFail("An unauthorized or mismatched binding must not commit")
            } catch let error as Base44Error {
                XCTAssertEqual(error.statusCode, status)
            }
            await fulfillment(of: [registration], timeout: 1)
            XCTAssertEqual(client.currentAccessToken, "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertEqual(store.saves, 0)
            XCTAssertEqual(store.clears, 0)
            XCTAssertNil(state.user)
        }
    }

    func testNativeAppleBindingSuccessCannotCommitAfterAttemptOrSessionChanges() async throws {
        defer { requestHandler = nil }
        for replaceSession in [false, true] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            let state = state(client: client, store: store)
            let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
            let held = AuthenticationHeldRequest()
            requestHandler = { request in held.receive(request) }
            let acceptance = Task {
                try await state.acceptAppleNativeSession(
                    AppleNativeSession(accessToken: "late-candidate", bindingTicket: "original-binding"),
                    attemptID: attempt
                )
            }
            let request = await held.next()
            XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2")
            if replaceSession {
                client.setToken("replacement")
            } else {
                state.handleIncomingURL(URL(string: "https://spyclash.com/reset-password?token=recovery")!)
                _ = try XCTUnwrap(state.beginAuthenticationAttempt())
            }
            request.respond(status: 200, body: #"{"success":true,"user":{"id":"candidate-user","email":"candidate@example.test"}}"#)
            do { try await acceptance.value; XCTFail("Late binding verification must not commit") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(client.currentAccessToken, replaceSession ? "replacement" : "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertEqual(store.saves, 0)
            XCTAssertEqual(store.clears, 0)
            XCTAssertNil(state.user)
            XCTAssertTrue(state.isBusy)
        }
    }
}

@MainActor
private final class AuthenticationMemoryStore {
    var token: String?
    var saves = 0
    var clears = 0
    init(token: String?) { self.token = token }
}

@MainActor
private final class AuthenticationImmediateSession: WebAuthenticationSession {
    let completion: () -> Void
    init(completion: @escaping () -> Void) { self.completion = completion }
    func start() -> Bool { completion(); return true }
    func cancel() {}
}

private final class AuthenticationHeldRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthenticationFlowURLProtocol?
    private var waiter: CheckedContinuation<Void, Never>?
    func receive(_ request: AuthenticationFlowURLProtocol) {
        lock.lock()
        value = request
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }
    private func receivedRequest() -> AuthenticationFlowURLProtocol {
        lock.lock(); defer { lock.unlock() }
        return value!
    }
    @MainActor func next() async -> AuthenticationFlowURLProtocol {
        await withCheckedContinuation { continuation in
            lock.lock()
            if value != nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
        return receivedRequest()
    }
}

private final class AuthenticationRequestHandlers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: @Sendable (AuthenticationFlowURLProtocol) -> Void] = [:]

    subscript(registration: String) -> (@Sendable (AuthenticationFlowURLProtocol) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return values[registration]
        }
        set {
            lock.lock(); defer { lock.unlock() }
            values[registration] = newValue
        }
    }

    func removeValue(forKey registration: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: registration)
    }
}

private final class AuthenticationFlowURLProtocol: URLProtocol, @unchecked Sendable {
    static let registrationHeader = "X-Authentication-Test-Client"
    static let handlers = AuthenticationRequestHandlers()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let registration = request.value(forHTTPHeaderField: Self.registrationHeader) ?? ""
        guard let handler = Self.handlers[registration] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        handler(self)
    }
    override func stopLoading() {}
    func jsonBody() throws -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
