import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class NotificationInboxModelTests: XCTestCase {
    func testItemAndUnreadContractDecodeSnakeCase() throws {
        let data = Data(
            #"""
            {
              "ok": true,
              "scope": "global",
              "items": [{
                "id": "notice-1",
                "scope": "global",
                "kind": "announcement",
                "importance": "urgent_from_future",
                "title": "Network update",
                "body": "Cross-platform sync is active.",
                "published_at": "2026-07-27T09:00:00Z",
                "read_at": null,
                "action_deep_link": "spyclash://rooms"
              }],
              "unread": {"global": 2, "personal": 1, "total": 3},
              "next_cursor": "cursor-2"
            }
            """#.utf8
        )

        let page = try JSONDecoder().decode(NotificationInboxPage.self, from: data)

        XCTAssertEqual(page.scope, .global)
        XCTAssertEqual(page.items.first?.importance, .quiet, "Unknown importance must fail soft.")
        XCTAssertEqual(page.items.first?.actionDeepLink, "spyclash://rooms")
        XCTAssertTrue(try XCTUnwrap(page.items.first).isUnread)
        XCTAssertEqual(page.unread.total, 3)
        XCTAssertEqual(page.nextCursor, "cursor-2")
    }

    func testUnreadCountsClampAndReplaceWithoutChangingOtherScope() {
        let counts = NotificationInboxUnreadCounts(global: -4, personal: 3)

        XCTAssertEqual(counts.global, 0)
        XCTAssertEqual(counts.replacing(.global, with: 7), .init(global: 7, personal: 3))
        XCTAssertEqual(counts.replacing(.personal, with: -1), .zero)
    }

    func testGlobalAnnouncementPushRoutesToFocusedInboxItem() throws {
        let route = PushNotificationCoordinator.notificationRoute(from: [
            "event_type": "global_announcement",
            "announcement_id": "announcement-29"
        ])

        guard case let .notifications(scope, itemID) = route else {
            return XCTFail("Global announcements must open the notification Inbox.")
        }
        XCTAssertEqual(scope, .global)
        XCTAssertEqual(itemID, "announcement-29")
    }

    func testAnnouncementDeepLinkTakesPrecedenceOverFallbackRoute() throws {
        let route = PushNotificationCoordinator.notificationRoute(from: [
            "event_type": "global_announcement",
            "announcement_id": "announcement-30",
            "deep_link": "spyclash://notifications?scope=global&id=global%3Aannouncement-30"
        ])

        guard case let .url(url) = route else {
            return XCTFail("A valid announcement deep link must be preserved.")
        }
        XCTAssertEqual(url.host, "notifications")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "id" })?
                .value,
            "global:announcement-30"
        )
    }

    func testSelfInboxDeepLinkIsNotRenderedAsRowAction() {
        let selfLink = NotificationInboxItem(
            id: "global:self-link",
            scope: .global,
            kind: "announcement",
            importance: .quiet,
            title: "Update",
            body: "Already visible here.",
            publishedAt: "2026-07-27T09:00:00.000Z",
            readAt: nil,
            actionDeepLink: "spyclash://notifications?id=global%3Aself-link"
        )
        let communityLink = NotificationInboxItem(
            id: "personal:community-link",
            scope: .personal,
            kind: "friend_request",
            importance: .important,
            title: "Friend request",
            body: "Open Community.",
            publishedAt: "2026-07-27T09:00:00Z",
            readAt: nil,
            actionDeepLink: "spyclash://community/requests"
        )

        XCTAssertNil(selfLink.actionableDeepLink)
        XCTAssertEqual(communityLink.actionableDeepLink, "spyclash://community/requests")
    }

    func testTimestampParserAcceptsFractionalAndWholeSecondISO8601() {
        XCTAssertNotNil(NotificationInboxTimestampParser.date(from: "2026-07-27T09:00:00.000Z"))
        XCTAssertNotNil(NotificationInboxTimestampParser.date(from: "2026-07-27T09:00:00Z"))
        XCTAssertNil(NotificationInboxTimestampParser.date(from: "not-a-date"))
    }

    func testOnlyImportantGlobalPublishRequiresConfirmation() {
        XCTAssertFalse(
            NotificationPublishConfirmationPolicy.requiresConfirmation(for: .quiet)
        )
        XCTAssertTrue(
            NotificationPublishConfirmationPolicy.requiresConfirmation(for: .important)
        )
    }

    func testCustomRouteParserPreservesTypedRoutesAndRejectsUnknownHosts() throws {
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://notifications?scope=personal&id=personal%3A1"))),
            .notifications(scope: .personal, itemID: "personal:1")
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://community/invites"))),
            .community
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://match/room-1"))),
            .match(roomID: "room-1")
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://game?room_id=room-2"))),
            .match(roomID: "room-2")
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://join?code=R4V3N"))),
            .join(code: "R4V3N")
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://reset-password?token=reset-token"))),
            .resetPassword(token: "reset-token")
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://auth"))),
            .authenticationCallback
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://rooms"))),
            .unsupported
        )
        XCTAssertEqual(
            SpyClashCustomRoute.parse(try XCTUnwrap(URL(string: "spyclash://ABCD"))),
            .unsupported,
            "Unknown custom hosts must never fall through as legacy room codes."
        )
    }
}

@MainActor
final class NotificationInboxStoreTests: XCTestCase {
    func testRefreshLoadsRequestedScopeAndUnreadCounts() async {
        let client = NotificationInboxClientStub()
        client.listHandler = { scope, cursor, limit in
            XCTAssertEqual(scope, .global)
            XCTAssertNil(cursor)
            XCTAssertEqual(limit, 12)
            return NotificationInboxPreview.page(for: .global)
        }
        let store = NotificationInboxStore(client: client, pageSize: 12)
        store.bindAccount("user-a")

        await store.refresh(scope: .global)

        XCTAssertEqual(store.feed(for: .global).items, NotificationInboxPreview.globalItems)
        XCTAssertEqual(store.feed(for: .global).loadState, .loaded)
        XCTAssertEqual(store.unread, NotificationInboxPreview.unread)
    }

    func testAccountGenerationDropsLateResponse() async {
        let client = NotificationInboxClientStub()
        client.listHandler = { _, _, _ in
            try await Task.sleep(for: .milliseconds(40))
            return NotificationInboxPreview.page(for: .global)
        }
        let store = NotificationInboxStore(client: client)
        store.bindAccount("user-a")

        let request = Task { await store.refresh(scope: .global) }
        await Task.yield()
        store.bindAccount("user-b")
        await request.value

        XCTAssertEqual(store.accountID, "user-b")
        XCTAssertTrue(store.feed(for: .global).items.isEmpty)
        XCTAssertEqual(store.feed(for: .global).loadState, .idle)
        XCTAssertEqual(store.unread, .zero)
    }

    func testMarkReadOptimisticallyUpdatesThenRollsBackOnFailure() async {
        let client = NotificationInboxClientStub()
        client.markReadHandler = { _ in
            try await Task.sleep(for: .milliseconds(35))
            throw NotificationInboxTestError.expectedFailure
        }
        let page = NotificationInboxPreview.page(for: .global)
        let store = NotificationInboxStore(
            client: client,
            initialPages: [.global: page],
            accountID: "user-a"
        )
        let item = try! XCTUnwrap(page.items.first)

        let mutation = Task { await store.markRead(item) }
        try? await Task.sleep(for: .milliseconds(5))

        XCTAssertFalse(try! XCTUnwrap(store.feed(for: .global).items.first).isUnread)
        XCTAssertEqual(store.unread.global, page.unread.global - 1)

        let mutationSucceeded = await mutation.value
        XCTAssertFalse(mutationSucceeded)
        XCTAssertTrue(try! XCTUnwrap(store.feed(for: .global).items.first).isUnread)
        XCTAssertEqual(store.unread, page.unread)
        XCTAssertNotNil(store.mutationError)
    }

    func testActionableRowOpensImmediatelyWhileReadReceiptContinues() async throws {
        let client = NotificationInboxClientStub()
        client.markReadHandler = { _ in
            try await Task.sleep(for: .milliseconds(80))
            return NotificationInboxMutationResponse(unread: .zero)
        }
        let page = NotificationInboxPreview.page(for: .personal)
        let store = NotificationInboxStore(
            client: client,
            initialPages: [.personal: page],
            accountID: "user-a"
        )
        let item = try XCTUnwrap(page.items.first)
        var openedItemID: String?

        let mutation = NotificationInboxRowInteraction.activate(
            item: item,
            store: store,
            onOpen: { openedItemID = $0.id }
        )

        XCTAssertEqual(openedItemID, item.id, "Navigation must happen synchronously.")
        XCTAssertNotNil(mutation)
        await mutation?.value
        XCTAssertFalse(try XCTUnwrap(store.feed(for: .personal).items.first).isUnread)
    }

    func testMarkReadCancellationRollsBackOptimisticStateForSameAccount() async throws {
        let client = NotificationInboxClientStub()
        client.markReadHandler = { _ in
            try await Task.sleep(for: .seconds(5))
            return NotificationInboxMutationResponse(unread: .zero)
        }
        let page = NotificationInboxPreview.page(for: .global)
        let store = NotificationInboxStore(
            client: client,
            initialPages: [.global: page],
            accountID: "user-a"
        )
        let item = try XCTUnwrap(page.items.first)

        let mutation = Task { await store.markRead(item) }
        await Task.yield()
        XCTAssertFalse(try XCTUnwrap(store.feed(for: .global).items.first).isUnread)

        mutation.cancel()
        let mutationSucceeded = await mutation.value
        XCTAssertFalse(mutationSucceeded)
        XCTAssertTrue(try XCTUnwrap(store.feed(for: .global).items.first).isUnread)
        XCTAssertEqual(store.unread, page.unread)
    }

    func testMarkAllCancellationRollsBackOptimisticStateForSameAccount() async throws {
        let client = NotificationInboxClientStub()
        client.markAllHandler = { _ in
            try await Task.sleep(for: .seconds(5))
            return NotificationInboxMutationResponse(unread: .zero)
        }
        let page = NotificationInboxPreview.page(for: .global)
        let store = NotificationInboxStore(
            client: client,
            initialPages: [.global: page],
            accountID: "user-a"
        )

        let mutation = Task { await store.markAllRead(scope: .global) }
        await Task.yield()
        XCTAssertEqual(store.unread.global, 0)
        XCTAssertTrue(store.feed(for: .global).items.allSatisfy { !$0.isUnread })

        mutation.cancel()
        let mutationSucceeded = await mutation.value
        XCTAssertFalse(mutationSucceeded)
        XCTAssertEqual(store.feed(for: .global).items, page.items)
        XCTAssertEqual(store.unread, page.unread)
    }

    func testPublishRetryReusesRequestIDUntilSuccess() async {
        let client = NotificationInboxClientStub()
        var attempts: [UUID] = []
        client.publishHandler = { draft in
            attempts.append(draft.requestID)
            if attempts.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            return NotificationGlobalPublishResponse(
                item: NotificationInboxItem(
                    id: "published-1",
                    scope: .global,
                    kind: "announcement",
                    importance: draft.importance,
                    title: draft.title,
                    body: draft.body,
                    publishedAt: "2026-07-27T10:00:00Z",
                    readAt: "2026-07-27T10:00:00Z",
                    actionDeepLink: draft.actionDeepLink
                ),
                unread: .zero
            )
        }
        let store = NotificationInboxStore(client: client, accountID: "admin-a")
        let requestID = UUID(uuidString: "B94C7D19-7C8E-4CF8-AE36-2F9B3D3A9D10")!
        let draft = NotificationGlobalDraft(
            requestID: requestID,
            title: "Sync restored",
            body: "Web and iOS are on the same channel.",
            importance: .important
        )

        let firstPublishSucceeded = await store.publishGlobal(draft)
        XCTAssertFalse(firstPublishSucceeded)
        XCTAssertEqual(store.pendingPublishRequestID, requestID)
        let secondPublishSucceeded = await store.publishGlobal(draft)
        XCTAssertTrue(secondPublishSucceeded)

        XCTAssertEqual(attempts, [requestID, requestID])
        XCTAssertNil(store.pendingPublishRequestID)
        XCTAssertEqual(store.feed(for: .global).items.first?.id, "published-1")
    }

#if DEBUG
    func testInstallPreviewNeverCallsClient() async {
        let client = NotificationInboxClientStub()
        let store = NotificationInboxStore(client: client)

        store.installPreview(accountID: "preview-user")
        await store.loadInitial()
        await store.refresh(scope: .personal)

        XCTAssertTrue(store.usesPreviewData)
        XCTAssertEqual(store.accountID, "preview-user")
        XCTAssertEqual(store.feed(for: .global).items, NotificationInboxPreview.globalItems)
        XCTAssertEqual(store.feed(for: .personal).items, NotificationInboxPreview.personalItems)
        XCTAssertEqual(client.callCount, 0)
    }
#endif
}

@MainActor
final class Base44ClientNotificationInboxTests: XCTestCase {
    func testTypedWrappersSendExactNotificationActionPayloads() async throws {
        let recorder = NotificationRequestRecorder()
        NotificationMockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return try NotificationMockURLProtocol.response(for: request)
        }
        defer { NotificationMockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let requestID = UUID(uuidString: "116D9FC5-A099-438E-B28E-4D108ADBC6A5")!

        _ = try await client.notificationInboxSummary()
        _ = try await client.notificationInboxList(scope: .personal, cursor: "cursor-a", limit: 200)
        _ = try await client.notificationInboxMarkRead(itemID: "notice-1")
        _ = try await client.notificationInboxMarkAllRead(scope: .global)
        _ = try await client.notificationInboxPublishGlobal(
            draft: NotificationGlobalDraft(
                requestID: requestID,
                title: "  Command update  ",
                body: "  Sync complete.  ",
                importance: .important,
                actionDeepLink: "spyclash://rooms"
            )
        )

        let requests = recorder.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasSuffix("/functions/notificationAction") == true })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies.map { $0["action"] as? String }, [
            "summary", "list", "mark_read", "mark_all_read", "publish_global"
        ])
        XCTAssertTrue(bodies.allSatisfy { ($0["access_token"] as? String) == "test-token" })

        XCTAssertEqual(bodies[1]["scope"] as? String, "personal")
        XCTAssertEqual(bodies[1]["cursor"] as? String, "cursor-a")
        XCTAssertEqual(bodies[1]["limit"] as? Int, 50)
        XCTAssertEqual(bodies[2]["item_id"] as? String, "notice-1")
        XCTAssertEqual(bodies[3]["scope"] as? String, "global")
        XCTAssertEqual(bodies[4]["request_id"] as? String, requestID.uuidString.lowercased())
        XCTAssertEqual(bodies[4]["title"] as? String, "Command update")
        XCTAssertEqual(bodies[4]["body"] as? String, "Sync complete.")
        XCTAssertEqual(bodies[4]["importance"] as? String, "important")
        XCTAssertEqual(bodies[4]["action_deep_link"] as? String, "spyclash://rooms")
    }

    func testPushRegistrationExplicitlyEnablesAnnouncements() async throws {
        let recorder = NotificationRequestRecorder()
        NotificationMockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return try NotificationMockURLProtocol.response(for: request)
        }
        defer { NotificationMockURLProtocol.requestHandler = nil }

        let client = makeClient()
        _ = try await client.registerPushDevice(
            installationID: "installation-a",
            apnsToken: "apns-token",
            environment: .sandbox,
            alertAuthorized: true,
            locale: "ru",
            appVersion: "1.0 (28)"
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        let preferences = try XCTUnwrap(body["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["announcements"] as? Bool, true)
    }

    private func makeClient() -> Base44Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationMockURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("test-token")
        return client
    }
}

@MainActor
private final class NotificationInboxClientStub: NotificationInboxClientProtocol {
    var callCount = 0
    var summaryHandler: () async throws -> NotificationInboxSummary = {
        throw NotificationInboxTestError.unimplemented
    }
    var listHandler: (
        NotificationInboxScope,
        String?,
        Int
    ) async throws -> NotificationInboxPage = { _, _, _ in
        throw NotificationInboxTestError.unimplemented
    }
    var markReadHandler: (String) async throws -> NotificationInboxMutationResponse = { _ in
        throw NotificationInboxTestError.unimplemented
    }
    var markAllHandler: (NotificationInboxScope) async throws -> NotificationInboxMutationResponse = { _ in
        throw NotificationInboxTestError.unimplemented
    }
    var publishHandler: (NotificationGlobalDraft) async throws -> NotificationGlobalPublishResponse = { _ in
        throw NotificationInboxTestError.unimplemented
    }

    func notificationInboxSummary() async throws -> NotificationInboxSummary {
        callCount += 1
        return try await summaryHandler()
    }

    func notificationInboxList(
        scope: NotificationInboxScope,
        cursor: String?,
        limit: Int
    ) async throws -> NotificationInboxPage {
        callCount += 1
        return try await listHandler(scope, cursor, limit)
    }

    func notificationInboxMarkRead(itemID: String) async throws -> NotificationInboxMutationResponse {
        callCount += 1
        return try await markReadHandler(itemID)
    }

    func notificationInboxMarkAllRead(
        scope: NotificationInboxScope
    ) async throws -> NotificationInboxMutationResponse {
        callCount += 1
        return try await markAllHandler(scope)
    }

    func notificationInboxPublishGlobal(
        draft: NotificationGlobalDraft
    ) async throws -> NotificationGlobalPublishResponse {
        callCount += 1
        return try await publishHandler(draft)
    }
}

private enum NotificationInboxTestError: LocalizedError {
    case unimplemented
    case expectedFailure

    var errorDescription: String? {
        switch self {
        case .unimplemented: "Test handler was not installed."
        case .expectedFailure: "Expected test failure."
        }
    }
}

private final class NotificationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func append(_ request: URLRequest) throws {
        _ = try Self.bodyData(from: request)
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        let snapshot = recordedRequests
        lock.unlock()
        return snapshot
    }

    func requestBodies() throws -> [[String: Any]] {
        try requests().map { request in
            let data = try Self.bodyData(from: request)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotDecodeContentData)
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class NotificationMockURLProtocol: URLProtocol, @unchecked Sendable {
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

    static func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let bodyData = try NotificationRequestRecorder.bodyDataForMock(from: request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? String)
        let payload: String

        switch action {
        case "summary":
            payload = #"{"ok":true,"unread":{"global":2,"personal":1,"total":3},"server_time":"2026-07-27T10:00:00Z"}"#
        case "list":
            payload = #"{"ok":true,"scope":"personal","items":[],"unread":{"global":2,"personal":1,"total":3},"next_cursor":null}"#
        case "mark_read", "mark_all_read":
            payload = #"{"ok":true,"unread":{"global":0,"personal":0,"total":0}}"#
        case "publish_global":
            payload = #"{"ok":true,"item":{"id":"published-1","scope":"global","kind":"announcement","importance":"important","title":"Command update","body":"Sync complete.","published_at":"2026-07-27T10:00:00Z","read_at":"2026-07-27T10:00:00Z","action_deep_link":"spyclash://rooms"},"unread":{"global":0,"personal":0,"total":0}}"#
        case "register_device":
            payload = #"{"ok":true,"registration_id":"registration-1","updated_at":"2026-07-27T10:00:00Z"}"#
        default:
            throw URLError(.unsupportedURL)
        }

        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(payload.utf8))
    }
}

private extension NotificationRequestRecorder {
    static func bodyDataForMock(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotDecodeContentData)
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
