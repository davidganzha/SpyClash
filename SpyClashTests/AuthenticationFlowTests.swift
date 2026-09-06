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

    private func state(client: Base44Client, store: AuthenticationMemoryStore, callback: String = "spyclash://auth?access_token=candidate") -> AppState {
        let coordinator = WebAuthenticationCoordinator(makeSession: { _, completion in
            AuthenticationImmediateSession {
                completion(URL(string: callback), nil)
            }
        })
        return AppState(client: client, readStoredToken: { store.token },
                        saveStoredToken: { store.token = $0; store.saves += 1 },
                        clearStoredToken: { store.token = nil; store.clears += 1 },
                        webAuthentication: coordinator)
    }

    func testProfileSyncFailurePreservesPreviousSession() async {
        for status in [409, 503] {
            let client = client()
            client.setToken("existing")
            let store = AuthenticationMemoryStore(token: "existing")
            let state = state(client: client, store: store)
            AuthenticationFlowURLProtocol.handler = { request in
                XCTAssertEqual(request.request.url?.lastPathComponent, "autoRegisterUser")
                XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
                request.respond(status: status, body: #"{"error":"Temporary failure"}"#)
            }
            await state.loginWithGoogle()
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
