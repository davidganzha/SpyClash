import Foundation
import XCTest
@testable import SpyClash

final class OnboardingTests: XCTestCase {
    func testRoutingUsesExplicitRemoteFalseBeforeLocalCompletion() {
        XCTAssertTrue(
            OnboardingRoutingPolicy.shouldPresentOnboarding(
                remoteCompleted: false,
                remoteVersion: 1,
                localCompletedVersion: 1
            )
        )
        XCTAssertTrue(
            OnboardingRoutingPolicy.shouldPresentOnboarding(
                remoteCompleted: false,
                remoteVersion: 1,
                localCompletedVersion: nil,
                localPendingVersion: 1
            )
        )
        XCTAssertFalse(
            OnboardingRoutingPolicy.shouldPresentOnboarding(
                remoteCompleted: nil,
                remoteVersion: nil,
                localCompletedVersion: 1
            )
        )
        XCTAssertFalse(
            OnboardingRoutingPolicy.shouldPresentOnboarding(
                remoteCompleted: true,
                remoteVersion: nil,
                localCompletedVersion: nil
            )
        )
        XCTAssertTrue(
            OnboardingRoutingPolicy.shouldPresentOnboarding(
                remoteCompleted: true,
                remoteVersion: 1,
                localCompletedVersion: 2,
                requiredVersion: 2
            )
        )
    }

    func testProgressIsAccountScopedAndRemoteStateIsVersionAware() throws {
        let suiteName = "OnboardingTests.Progress.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = OnboardingProgressStore(defaults: defaults)
        let submission = OnboardingSubmission(
            language: .uk,
            acquisitionSource: .chatGPT,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.savePending(submission, for: "user-a")
        XCTAssertEqual(store.pendingSubmission(for: "user-a"), submission)
        XCTAssertNil(store.pendingSubmission(for: "user-b"))
        XCTAssertEqual(store.completedVersion(for: "user-a"), 1)

        store.markSynced(submission, for: "user-a")
        XCTAssertEqual(store.completedVersion(for: "user-a"), 1)
        XCTAssertNil(store.pendingSubmission(for: "user-a"))

        try store.savePending(submission, for: "user-a")
        store.reconcileRemoteState(completed: false, version: 1, for: "user-a")
        XCTAssertNil(store.completedVersion(for: "user-a"))
        XCTAssertNil(store.pendingSubmission(for: "user-a"))

        store.reconcileRemoteState(completed: true, version: 1, for: "user-a")
        XCTAssertEqual(store.completedVersion(for: "user-a"), 1)
        XCTAssertNil(store.pendingSubmission(for: "user-a"))

        let versionTwoSubmission = OnboardingSubmission(
            language: .en,
            acquisitionSource: .webSearch,
            version: 2,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.savePending(versionTwoSubmission, for: "user-a")
        store.markSynced(submission, for: "user-a")
        XCTAssertEqual(
            store.pendingSubmission(for: "user-a"),
            versionTwoSubmission
        )
        store.reconcileRemoteState(completed: true, version: 1, for: "user-a")
        XCTAssertEqual(
            store.pendingSubmission(for: "user-a"),
            versionTwoSubmission
        )
        XCTAssertFalse(
            OnboardingRoutingPolicy.shouldPresentOnboarding(
                remoteCompleted: true,
                remoteVersion: 1,
                localCompletedVersion: store.completedVersion(for: "user-a"),
                localPendingVersion: versionTwoSubmission.version,
                requiredVersion: 2
            )
        )

        try store.savePending(submission, for: "user-b")
        XCTAssertFalse(store.isNearbyTransportEnabled(for: "user-a"))
        store.setNearbyTransportEnabled(true, for: "user-a")
        XCTAssertTrue(store.isNearbyTransportEnabled(for: "user-a"))
        XCTAssertFalse(store.isNearbyTransportEnabled(for: "user-b"))

        OnboardingProgressStore.clear(for: "user-a", defaults: defaults)
        XCTAssertNil(store.completedVersion(for: "user-a"))
        XCTAssertNil(store.pendingSubmission(for: "user-a"))
        XCTAssertFalse(store.isNearbyTransportEnabled(for: "user-a"))
        XCTAssertEqual(store.completedVersion(for: "user-b"), 1)
        XCTAssertEqual(store.pendingSubmission(for: "user-b"), submission)
    }

    @MainActor
    func testLateDeferredRouteReCoversRevealAndMountsLatestDestination() async throws {
        let appState = AppState()
        defer { appState.logout() }
        appState.isRestoring = false
        appState.user = SpyUser(
            id: "route-user",
            email: "route-user@example.com",
            fullName: nil,
            displayName: nil,
            avatar: nil,
            language: "ru",
            onboardingCompleted: true,
            onboardingVersion: OnboardingSubmission.currentVersion,
            role: nil,
            isVerified: true,
            rating: nil,
            gamesPlayed: nil,
            gamesWon: nil,
            remoteSpyID: nil,
            spyCardTheme: nil,
            spyCardAccent: nil,
            spyCardBadge: nil,
            radarInvitePolicy: nil
        )
        appState.authHomeRevealPhase = .revealing

        PushNotificationCoordinator.shared.route(userInfo: [
            "event_type": "friend_request"
        ])
        XCTAssertEqual(appState.authHomeRevealPhase, .covered)

        appState.handleIncomingURL(
            try XCTUnwrap(
                URL(string: "spyclash://notifications?scope=global&id=announcement-1")
            )
        )
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(appState.shellRoute, .notifications)
        XCTAssertEqual(appState.authHomeRevealPhase, .covered)
        XCTAssertEqual(appState.notificationFocusItemID, "global:announcement-1")
    }

    func testSpyUserDecodesLegacyAndVersionedOnboardingPayloads() throws {
        let legacy = try JSONDecoder().decode(
            SpyUser.self,
            from: Data(#"{"id":"legacy","email":"legacy@example.com"}"#.utf8)
        )
        XCTAssertNil(legacy.onboardingCompleted)
        XCTAssertNil(legacy.onboardingVersion)
        XCTAssertNil(legacy.onboardingCompletedAt)
        XCTAssertNil(legacy.acquisitionSource)

        let versioned = try JSONDecoder().decode(
            SpyUser.self,
            from: Data(
                #"{"id":"versioned","email":"versioned@example.com","onboarding_completed":true,"onboarding_version":1,"onboarding_completed_at":"2026-08-29T10:00:00Z","acquisition_source":"chatgpt"}"#.utf8
            )
        )
        XCTAssertEqual(versioned.onboardingCompleted, true)
        XCTAssertEqual(versioned.onboardingVersion, 1)
        XCTAssertEqual(versioned.onboardingCompletedAt, "2026-08-29T10:00:00Z")
        XCTAssertEqual(versioned.acquisitionSource, "chatgpt")
    }

    @MainActor
    func testCompleteOnboardingUsesOneAuthenticatedPartialUserUpdate() async throws {
        let recorder = OnboardingRequestRecorder()
        OnboardingURLProtocol.requestHandler = { request in
            try recorder.record(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"id":"user-1","email":"operative@example.com","language":"es","onboarding_completed":true,"onboarding_version":1,"onboarding_completed_at":"2023-11-14T22:13:20Z","acquisition_source":"friends_or_family"}"#
            return (response, Data(payload.utf8))
        }
        defer { OnboardingURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("onboarding-token")
        let submission = OnboardingSubmission(
            language: .es,
            acquisitionSource: .friendsOrFamily,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let user = try await client.completeOnboarding(submission)

        XCTAssertEqual(user.onboardingCompleted, true)
        XCTAssertEqual(user.onboardingVersion, 1)
        let request = try XCTUnwrap(recorder.lastRequest())
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.path,
            "/api/apps/\(Base44Client.appID)/entities/User/me"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer onboarding-token"
        )

        let body = try XCTUnwrap(recorder.lastBody())
        XCTAssertEqual(body["language"] as? String, "es")
        XCTAssertEqual(body["acquisition_source"] as? String, "friends_or_family")
        XCTAssertEqual(body["onboarding_completed"] as? Bool, true)
        XCTAssertEqual(body["onboarding_version"] as? Int, 1)
        XCTAssertEqual(body["onboarding_completed_at"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(body.count, 5)
        XCTAssertEqual(recorder.requestCount(), 1)
    }

    @MainActor
    func testCompleteOnboardingRejectsAnUnconfirmedUserResponse() async throws {
        OnboardingURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"id":"user-1","email":"operative@example.com"}"#.utf8)
            )
        }
        defer { OnboardingURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("onboarding-token")

        do {
            _ = try await client.completeOnboarding(
                OnboardingSubmission(
                    language: .en,
                    acquisitionSource: .other
                )
            )
            XCTFail("An incomplete User response must not confirm onboarding.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 502)
            XCTAssertTrue(error.retryable)
        }
    }
}

private final class OnboardingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: [String: Any]?
    private var count = 0

    func record(_ request: URLRequest) throws {
        let bodyData: Data
        if let requestBody = request.httpBody {
            bodyData = requestBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count < 0 {
                    throw stream.streamError ?? URLError(.cannotDecodeContentData)
                }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            bodyData = data
        } else {
            throw URLError(.cannotDecodeContentData)
        }

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        lock.lock()
        self.request = request
        body = object
        count += 1
        lock.unlock()
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        let snapshot = request
        lock.unlock()
        return snapshot
    }

    func lastBody() -> [String: Any]? {
        lock.lock()
        let snapshot = body
        lock.unlock()
        return snapshot
    }

    func requestCount() -> Int {
        lock.lock()
        let snapshot = count
        lock.unlock()
        return snapshot
    }
}

private final class OnboardingURLProtocol: URLProtocol, @unchecked Sendable {
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
}
