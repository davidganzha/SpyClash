import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class AuthenticationFlowTests: XCTestCase {
    private func client() -> Base44Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationFlowURLProtocol.self]
        return Base44Client(session: URLSession(configuration: configuration))
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
        AuthenticationFlowURLProtocol.handler = { request in
            XCTAssertTrue(["reset-password-request", "reset-password", "resend-otp"].contains(request.request.url?.lastPathComponent ?? ""))
            request.respond(status: 200, body: "{}")
        }
        defer { AuthenticationFlowURLProtocol.handler = nil }
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
        AuthenticationFlowURLProtocol.handler = { request in held.receive(request) }
        defer { AuthenticationFlowURLProtocol.handler = nil }
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
            AuthenticationFlowURLProtocol.handler = { request in held.receive(request) }
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
            AuthenticationFlowURLProtocol.handler = nil
        }
    }

    func testProfileSyncFailurePreservesPreviousSession() async {
        for status in [409, 503] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            var sessionURLs: [URL] = []
            let state = state(client: client, store: store, onSessionURL: { sessionURLs.append($0) })
            AuthenticationFlowURLProtocol.handler = { request in
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
        AuthenticationFlowURLProtocol.handler = nil
    }

    func testErrorAndMalformedCallbacksNeverProvision() async {
        for callback in ["spyclash://auth?error=invalid_state", "spyclash://join?access_token=candidate", "spyclash://auth?access_token="] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            let state = state(client: client, store: store, callback: callback)
            AuthenticationFlowURLProtocol.handler = { request in
                XCTFail("Invalid callback must not call the backend")
                request.respond(status: 500, body: "{}")
            }
            await state.loginWithGoogle()
            XCTAssertEqual(client.currentAccessToken, "existing")
            XCTAssertEqual(store.token, "existing")
            XCTAssertFalse(state.isBusy)
            XCTAssertNotNil(state.authError)
        }
        AuthenticationFlowURLProtocol.handler = nil
    }

    func testLogoutDuringProviderSyncCannotRestoreAccount() async throws {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let held = AuthenticationHeldRequest()
        AuthenticationFlowURLProtocol.handler = { request in held.receive(request) }
        defer { AuthenticationFlowURLProtocol.handler = nil }
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
        AuthenticationFlowURLProtocol.handler = { request in held.receive(request) }
        defer { AuthenticationFlowURLProtocol.handler = nil }
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

    func testOldProviderFailureCannotClearReplacementCredentials() async {
        let client = client()
        client.setToken("existing")
        let store = AuthenticationMemoryStore(token: "existing")
        let state = state(client: client, store: store)
        let held = AuthenticationHeldRequest()
        AuthenticationFlowURLProtocol.handler = { request in held.receive(request) }
        defer { AuthenticationFlowURLProtocol.handler = nil }
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
        AuthenticationFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.request.url?.lastPathComponent, "verify-otp")
            request.respond(status: 200, body: "{}")
        }
        defer { AuthenticationFlowURLProtocol.handler = nil }
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
        AuthenticationFlowURLProtocol.handler = { request in
            if request.request.url?.lastPathComponent == "autoRegisterUser" {
                XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
                request.respond(status: 200, body: "{}")
            } else {
                XCTAssertEqual(request.request.url?.lastPathComponent, "me")
                XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer candidate")
                request.respond(status: 200, body: #"{"id":"candidate-user","email":"candidate@example.test"}"#)
            }
        }
        defer { AuthenticationFlowURLProtocol.handler = nil }
        let user = try await client.autoRegisterUser(accessToken: "candidate")
        XCTAssertEqual(user.id, "candidate-user")
        XCTAssertEqual(client.currentAccessToken, "existing")
    }

    func testAppleRegistrationUsesBindingAwareRouteWithoutReplacingSession() async throws {
        let client = client()
        client.setToken("existing")
        XCTAssertEqual(Base44Client.providerRegistrationFunction(appleBindingTicket: nil), "autoRegisterUser")
        XCTAssertEqual(Base44Client.providerRegistrationFunction(appleBindingTicket: ""), "autoRegisterUser")
        AuthenticationFlowURLProtocol.handler = { request in
            XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2")
            XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
            request.respond(status: 200, body: #"{"success":true,"user":{"id":"candidate-user","email":"candidate@example.test"}}"#)
        }
        defer { AuthenticationFlowURLProtocol.handler = nil }
        let user = try await client.autoRegisterUser(appleBindingTicket: "binding-fixture", accessToken: "candidate")
        XCTAssertEqual(user.id, "candidate-user")
        XCTAssertEqual(client.currentAccessToken, "existing")
    }

    func testAppleRegistrationCannotFallBackToUnboundProfile() async throws {
        let client = client()
        client.setToken("existing")
        defer { AuthenticationFlowURLProtocol.handler = nil }
        for body in [
            #"{"success":true}"#,
            #"{"success":false,"user":{"id":"candidate-user","email":"candidate@example.test"}}"#,
            #"{"user":{"id":"candidate-user","email":"candidate@example.test"}}"#,
            #"{"success":true,"user":{"id":"","email":"candidate@example.test"}}"#,
            #"{"success":true,"user":{"id":"candidate-user","email":""}}"#
        ] {
            AuthenticationFlowURLProtocol.handler = { request in
                XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUserV2", "No old handler or User/me fallback may bypass Apple binding")
                request.respond(status: 200, body: body)
            }
            do {
                _ = try await client.autoRegisterUser(appleBindingTicket: "binding-fixture", accessToken: "candidate")
                XCTFail("A response without explicit binding success and a verified user cannot complete Apple binding")
            } catch let error as Base44Error {
                XCTAssertEqual(error.code, "apple_binding_response_invalid")
            }
            XCTAssertEqual(client.currentAccessToken, "existing")
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

private final class AuthenticationFlowURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (AuthenticationFlowURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler(self)
    }
    override func stopLoading() {}
    func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
