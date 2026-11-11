import Foundation
import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class SupabaseSharedGenerationRetryTests: XCTestCase {
    func testSharedWaitAndLookupRecoveryKeepOneUUIDPayloadAndSuccessfulBalance() async throws {
        var delays: [Duration] = []
        let fixture = SharedGenerationRetryFixture(responses: [.busy, .unavailable, .success], sleep: { delays.append($0) })
        defer { fixture.close() }
        let requestID = UUID()
        let pack = try await fixture.generate(requestID: requestID)
        XCTAssertEqual(pack.words, ["Knight", "Archer"])
        XCTAssertEqual(pack.aiGenerationsToday, 1)
        XCTAssertEqual(pack.aiRemaining, 2)
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1)])
        XCTAssertEqual(fixture.requests.count, 3)
        XCTAssertTrue(fixture.requests.allSatisfy { $0 == fixture.requests[0] })
        XCTAssertEqual(fixture.requests[0]["request_id"].string, requestID.uuidString.lowercased())
        XCTAssertEqual(fixture.requests[0]["exclude_words"].array, [.string("Giant")])
        XCTAssertEqual(fixture.requests[0]["prefer_fresh"], .bool(true))
        XCTAssertEqual(fixture.authorization, Array(repeating: "Bearer fixture-native", count: 3))
        // Acknowledging the one successful response frees this journal slot.
        let nextID = UUID()
        let next = try fixture.journal.prepare(actorID: fixture.actor, body: fixture.body(requestID: nextID))
        XCTAssertEqual(next["request_id"]?.string, nextID.uuidString.lowercased())
    }

    func testOnlyKnown503WithExplicitRetryFlagMayRetry() async throws {
        let failures: [SharedGenerationRetryFixture.Reply] = [
            .init(status: 503, body: #"{"code":"shared_generation_in_progress","retryable":false}"#),
            .init(status: 503, body: #"{"code":"shared_library_unavailable"}"#),
            .init(status: 503, body: #"{"code":"shared_library_unavailable","retryable":"true"}"#),
            .init(status: 409, body: #"{"code":"shared_generation_in_progress","retryable":true}"#),
            .init(status: 429, body: #"{"code":"ai_limit_reached","retryable":true}"#),
            .init(status: 503, body: #"{"code":"generation_in_progress","retryable":true}"#),
            .init(status: 503, body: #"{"code":"generation_outcome_unknown","retryable":true}"#),
            .init(status: 503, body: #"{"code":"ai_provider_unavailable","retryable":true}"#),
        ]
        for reply in failures {
            let fixture = SharedGenerationRetryFixture(responses: [reply], sleep: { _ in XCTFail("Unrelated failure retried") })
            defer { fixture.close() }
            do { _ = try await fixture.generate(); XCTFail("Failure unexpectedly succeeded") }
            catch let error as Base44Error { XCTAssertEqual(error.statusCode, reply.status) }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testBridgedLibraryBusyAlsoRetriesTheSameJournaledRequest() async throws {
        let busy = SharedGenerationRetryFixture.Reply(status: 503, body: #"{"code":"shared_library_busy","retryable":true}"#)
        let fixture = SharedGenerationRetryFixture(responses: [busy, .success])
        defer { fixture.close() }
        let result = try await fixture.generate()
        XCTAssertEqual(result.aiRemaining, 2)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[0], fixture.requests[1])
    }

    func testRetryBudgetIsBoundedAndKeepsUnacknowledgedUUID() async throws {
        var delays: [Duration] = []
        let fixture = SharedGenerationRetryFixture(responses: [.busy], sleep: { delays.append($0) })
        defer { fixture.close() }
        let requestID = UUID()
        do { _ = try await fixture.generate(requestID: requestID); XCTFail("Busy must remain a failure") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "shared_generation_in_progress") }
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15), .seconds(15)])
        XCTAssertEqual(fixture.requests.count, 9)
        XCTAssertTrue(fixture.requests.allSatisfy { $0 == fixture.requests[0] })
        let saved = try fixture.journal.prepare(actorID: fixture.actor, body: fixture.body(requestID: UUID()))
        XCTAssertEqual(saved["request_id"]?.string, requestID.uuidString.lowercased())
    }

    func testOtherServiceActionsDoNotUseGenerationRetry() async throws {
        let fixture = SharedGenerationRetryFixture(responses: [.busy], sleep: { _ in XCTFail("Status must not retry") })
        defer { fixture.close() }
        do {
            let _: JSONValue = try await fixture.auth.service("legacy", action: "status")
            XCTFail("Status unexpectedly succeeded")
        } catch let error as Base44Error { XCTAssertEqual(error.code, "shared_generation_in_progress") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testCancellationDuringBackoffKeepsIntentAndStopsSending() async throws {
        let sleeping = expectation(description: "Shared-library backoff started")
        let fixture = SharedGenerationRetryFixture(responses: [.busy], sleep: { _ in
            sleeping.fulfill()
            try await Task.sleep(for: .seconds(30))
        })
        defer { fixture.close() }
        let requestID = UUID()
        let task = Task { try await fixture.generate(requestID: requestID) }
        await fulfillment(of: [sleeping], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled generation succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(fixture.requests.count, 1)
        let saved = try fixture.journal.prepare(actorID: fixture.actor, body: fixture.body(requestID: UUID()))
        XCTAssertEqual(saved["request_id"]?.string, requestID.uuidString.lowercased())
    }

    func testAccountScopeChangeDuringBackoffCannotSendAnotherAttempt() async throws {
        let sleeping = expectation(description: "Shared-library backoff started")
        var resume: CheckedContinuation<Void, Error>?
        let fixture = SharedGenerationRetryFixture(responses: [.busy, .success], sleep: { _ in
            try await withCheckedThrowingContinuation { resume = $0; sleeping.fulfill() }
        })
        defer { fixture.close() }
        let requestID = UUID()
        let task = Task { try await fixture.generate(requestID: requestID) }
        await fulfillment(of: [sleeping], timeout: 3)
        fixture.auth.clear(revokeRemote: false)
        resume?.resume()
        do { _ = try await task.value; XCTFail("Old generation survived logout") }
        catch is CancellationError {}
        XCTAssertEqual(fixture.requests.count, 1)
        let saved = try fixture.journal.prepare(actorID: fixture.actor, body: fixture.body(requestID: UUID()))
        XCTAssertEqual(saved["request_id"]?.string, requestID.uuidString.lowercased())
    }
}

@MainActor
private final class SharedGenerationRetryFixture {
    struct Reply: Sendable {
        let status: Int
        let body: String
        static let busy = Self(status: 503, body: #"{"error":{"code":"shared_generation_in_progress","message":"Preparing words.","retryable":true}}"#)
        static let unavailable = Self(status: 503, body: #"{"error":{"code":"shared_library_unavailable","message":"Retry shortly.","retryable":true}}"#)
        static let success = Self(status: 200, body: #"{"name":"Clash Royale","category":"Clash Royale","words":["Knight","Archer"],"exhausted":false,"cache_hit":true,"ai_generations_today":1,"ai_remaining":2,"ai_limit":3}"#)
    }
    let actor = "11111111-1111-4111-8111-111111111111"
    let directory: URL
    let journal: SupabaseAppMutationJournal
    let auth: SupabaseAppSession
    let http: URLSession
    var requests: [JSONValue] = []
    var authorization: [String?] = []
    private let replies: [Reply]

    init(responses: [Reply], sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in }) {
        replies = responses
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedGenerationRetry-\(UUID())")
        journal = SupabaseAppMutationJournal(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedGenerationURLProtocol.self]
        http = URLSession(configuration: configuration)
        auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_fixture"), session: http,
            storedSession: .init(accessToken: "fixture-native", refreshToken: "fixture-refresh", userID: actor, expiresAt: Date().addingTimeInterval(3600), nativeCredentialKind: .gameCenter),
            saveSession: { _ in }, clearSession: {}, mutationJournal: journal,
            storedLegacy: nil, saveLegacy: { _ in }, clearLegacy: {}, sharedGenerationRetrySleep: sleep)
        SharedGenerationURLProtocol.handler = { [weak self] request in
            Task { @MainActor in self?.respond(to: request) }
        }
    }

    func body(requestID: UUID) -> [String: JSONValue] {
        var fields = SupabaseGameAdapter.generationFields(theme: "Clash Royale", count: 2, requestID: requestID, excluding: ["Giant"], preferFresh: true)
        fields["service"] = .string("legacy"); fields["action"] = .string("generate")
        return fields
    }

    func generate(requestID: UUID = UUID()) async throws -> GeneratedWordPack {
        try await auth.service("legacy", action: "generate", fields: body(requestID: requestID), write: true)
    }

    private func respond(to request: SharedGenerationURLProtocol) {
        do {
            XCTAssertEqual(request.request.url?.path, "/functions/v1/app-services")
            let json = try JSONDecoder().decode(JSONValue.self, from: request.bodyData())
            let reply = replies[min(requests.count, replies.count - 1)]
            requests.append(json)
            authorization.append(request.request.value(forHTTPHeaderField: "Authorization"))
            request.respond(status: reply.status, body: reply.body)
        } catch { request.client?.urlProtocol(request, didFailWithError: error) }
    }

    func close() {
        http.invalidateAndCancel()
        SharedGenerationURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SharedGenerationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (SharedGenerationURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        handler(self)
    }
    override func stopLoading() {}
    func bodyData() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
