import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class SessionRestoreTests: XCTestCase {
    private func makeState(
        store: RestoreTokenStore,
        server: RestoreHTTPServer
    ) -> AppState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestoreURLProtocol.self]
        RestoreURLProtocol.handler = { server.handle($0) }
        return AppState(
            client: Base44Client(session: URLSession(configuration: configuration)),
            readStoredToken: { store.read() },
            saveStoredToken: { store.value = $0 },
            clearStoredToken: { store.clear() }
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Session state did not converge")
    }

    func testForegroundRecoversUserAfterTransientColdStartFailureWithoutNewLogin() async throws {
        let store = RestoreTokenStore("saved-token")
        let server = RestoreHTTPServer(plans: [.http(503, "{}"), .success])
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }

        await state.restoreSession()
        XCTAssertNil(state.user)
        XCTAssertFalse(state.isRestoring)
        XCTAssertEqual(state.client.currentAccessToken, "saved-token")
        XCTAssertEqual(store.clearCount, 0)

        state.resumeAfterActivation()
        try await waitUntil { state.user?.id == "restored-user" && !state.isRestoring }
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(server.authorizations, ["Bearer saved-token", "Bearer saved-token"])
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(store.clearCount, 0)
    }

    func testRestoreIsSingleFlightAndForegroundDoesNotOverlapIt() async throws {
        let store = RestoreTokenStore("saved-token")
        let started = expectation(description: "User lookup started")
        let server = RestoreHTTPServer(plans: [.held], observed: { _ in started.fulfill() })
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }
        let first = Task { await state.restoreSession() }
        await fulfillment(of: [started], timeout: 1)

        await state.restoreSession()
        state.resumeAfterActivation()
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(store.readCount, 1)
        server.respondToRequest(at: 0, status: 200, body: RestoreHTTPServer.userJSON)
        await first.value
        XCTAssertEqual(state.user?.id, "restored-user")
        XCTAssertFalse(state.isRestoring)
    }

    func testDelayedUnauthorizedResponseCannotClearNewerOrSwitchBackCredentials() async throws {
        for replacement in ["replacement-token", "saved-token"] {
            let store = RestoreTokenStore("saved-token")
            let started = expectation(description: "Old lookup started")
            let server = RestoreHTTPServer(plans: [.held], observed: { _ in started.fulfill() })
            let state = makeState(store: store, server: server)
            let oldRestore = Task { await state.restoreSession() }
            await fulfillment(of: [started], timeout: 1)

            state.client.setToken("replacement-token")
            state.client.setToken(replacement)
            store.value = replacement
            server.respondToRequest(at: 0, status: 401, body: "{}")
            await oldRestore.value
            XCTAssertEqual(state.client.currentAccessToken, replacement)
            XCTAssertEqual(store.value, replacement)
            XCTAssertEqual(store.clearCount, 0)
            XCTAssertNil(state.user)
            XCTAssertFalse(state.isRestoring)
            state.logout()
        }
        RestoreURLProtocol.handler = nil
    }

    func testDelayedSuccessfulRestoreCannotUndoLogout() async {
        let store = RestoreTokenStore("saved-token")
        let started = expectation(description: "Lookup started")
        let server = RestoreHTTPServer(plans: [.held], observed: { _ in started.fulfill() })
        let state = makeState(store: store, server: server)
        defer { RestoreURLProtocol.handler = nil }
        let restore = Task { await state.restoreSession() }
        await fulfillment(of: [started], timeout: 1)

        state.logout()
        server.respondToRequest(at: 0, status: 200, body: RestoreHTTPServer.userJSON)
        await restore.value
        XCTAssertNil(state.user)
        XCTAssertNil(state.client.currentAccessToken)
        XCTAssertNil(store.value)
        XCTAssertFalse(state.isRestoring)
    }

    func testLogoutDisablesKeychainBootstrapEvenIfDeletingStoredTokenFails() async throws {
        let store = RestoreTokenStore("saved-token")
        store.retainsValueOnClear = true
        let server = RestoreHTTPServer(plans: [.http(503, "{}")])
        let state = makeState(store: store, server: server)
        defer { RestoreURLProtocol.handler = nil }
        await state.restoreSession()
        state.logout()
        XCTAssertEqual(store.value, "saved-token")

        state.resumeAfterActivation()
        await state.restoreSession()
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertNil(state.client.currentAccessToken)
        XCTAssertNil(state.user)
    }

    func testManualAuthenticationPreventsRestoreAndForegroundRequests() async throws {
        let store = RestoreTokenStore("saved-token")
        let server = RestoreHTTPServer(plans: [.success])
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }
        state.isRestoring = false
        state.isBusy = true
        await state.restoreSession()
        state.resumeAfterActivation()
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(store.readCount, 0)

        state.isBusy = false
        await state.restoreSession()
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(state.user?.id, "restored-user")
    }

    func testExplicitAuthIntentInvalidatesInFlightRestoreWithoutDeletingStoredToken() async {
        let store = RestoreTokenStore("saved-token")
        let started = expectation(description: "Lookup started")
        let server = RestoreHTTPServer(plans: [.held], observed: { _ in started.fulfill() })
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }
        let restore = Task { await state.restoreSession() }
        await fulfillment(of: [started], timeout: 1)

        state.invalidateSessionRestore()
        state.isBusy = true
        server.respondToRequest(at: 0, status: 401, body: "{}")
        await restore.value
        XCTAssertEqual(state.client.currentAccessToken, "saved-token")
        XCTAssertEqual(store.value, "saved-token")
        XCTAssertEqual(store.clearCount, 0)
        XCTAssertFalse(state.isRestoring)
        state.isBusy = false
    }

    func testCancelledRestorePreservesCredentialAndAllowsLaterForegroundRecovery() async throws {
        let store = RestoreTokenStore("saved-token")
        let started = expectation(description: "Lookup started")
        let server = RestoreHTTPServer(plans: [.held, .success], observed: { count in
            if count == 1 { started.fulfill() }
        })
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }
        let restore = Task { await state.restoreSession() }
        await fulfillment(of: [started], timeout: 1)
        restore.cancel()
        await restore.value
        XCTAssertEqual(store.clearCount, 0)
        XCTAssertEqual(state.client.currentAccessToken, "saved-token")
        XCTAssertFalse(state.isRestoring)

        state.resumeAfterActivation()
        try await waitUntil { state.user?.id == "restored-user" && !state.isRestoring }
        XCTAssertEqual(server.requestCount, 2)
    }

    func testTemporarilyUnavailableStoredTokenCanBeLoadedOnLaterForeground() async throws {
        let store = RestoreTokenStore(nil)
        let server = RestoreHTTPServer(plans: [.success])
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }
        await state.restoreSession()
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertFalse(state.isRestoring)

        store.value = "unlocked-token"
        state.resumeAfterActivation()
        try await waitUntil { state.user?.id == "restored-user" && !state.isRestoring }
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(store.readCount, 2)
        XCTAssertEqual(state.client.currentAccessToken, "unlocked-token")
    }

    func testCurrentUnauthorizedCredentialIsClearedAndNotRetriedOnForeground() async {
        let store = RestoreTokenStore("expired-token")
        let server = RestoreHTTPServer(plans: [.http(401, "{}")])
        let state = makeState(store: store, server: server)
        defer { state.logout(); RestoreURLProtocol.handler = nil }
        await state.restoreSession()
        XCTAssertNil(state.client.currentAccessToken)
        XCTAssertNil(store.value)
        XCTAssertEqual(store.clearCount, 1)
        XCTAssertFalse(state.isRestoring)
        state.resumeAfterActivation()
        await state.restoreSession()
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(store.readCount, 1)
    }

    func testClearingAnAlreadyEmptyTokenStillInvalidatesPendingAuthenticationGeneration() {
        let client = Base44Client()
        let beforeLogout = client.sessionGeneration
        client.clearToken()
        XCTAssertNotEqual(client.sessionGeneration, beforeLogout)
    }
}

@MainActor
private final class RestoreTokenStore {
    var value: String?
    var readCount = 0
    var clearCount = 0
    var retainsValueOnClear = false
    init(_ value: String?) { self.value = value }
    func read() -> String? { readCount += 1; return value }
    func clear() {
        clearCount += 1
        if !retainsValueOnClear { value = nil }
    }
}

private final class RestoreHTTPServer: @unchecked Sendable {
    enum Plan {
        case held
        case http(Int, String)
        static var success: Self { .http(200, RestoreHTTPServer.userJSON) }
    }
    static let userJSON = #"{"id":"restored-user","email":"restore@example.test","language":"en","onboarding_completed":true,"onboarding_version":99}"#
    private let lock = NSLock()
    private let plans: [Plan]
    private let observed: (@Sendable (Int) -> Void)?
    private var userRequests: [RestoreURLProtocol] = []

    init(plans: [Plan], observed: (@Sendable (Int) -> Void)? = nil) {
        self.plans = plans
        self.observed = observed
    }
    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return userRequests.count
    }
    var authorizations: [String?] {
        lock.lock(); defer { lock.unlock() }
        return userRequests.map { $0.request.value(forHTTPHeaderField: "Authorization") }
    }
    func handle(_ request: RestoreURLProtocol) {
        guard request.request.url?.path.hasSuffix("/entities/User/me") == true else {
            request.respond(status: 200, body: "null")
            return
        }
        lock.lock()
        let index = userRequests.count
        userRequests.append(request)
        let plan = plans.indices.contains(index) ? plans[index] : .http(500, "{}")
        lock.unlock()
        observed?(index + 1)
        if case let .http(status, body) = plan { request.respond(status: status, body: body) }
    }
    func respondToRequest(at index: Int, status: Int, body: String) {
        lock.lock()
        let request = userRequests.indices.contains(index) ? userRequests[index] : nil
        lock.unlock()
        request?.respond(status: status, body: body)
    }
}

private final class RestoreURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (RestoreURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(status: Int, body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
