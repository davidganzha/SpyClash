import Foundation
import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class SupabaseAppStoreRetryTests: XCTestCase {
    func testBusyThenSuccessRetainsJournalIDPayloadAndLinkedCredentials() async throws {
        var delays: [Duration] = []
        let fixture = HybridStoreKitRetryFixture(responses: [.busy, .success], sleep: { delays.append($0) })
        defer { fixture.close() }
        let receipt = try await fixture.deliver("fixture-JWS-A")
        XCTAssertTrue(receipt.serverStatusVerified)
        XCTAssertEqual(delays, [.milliseconds(500)])
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[0], fixture.requests[1])
        XCTAssertEqual(fixture.requests[0]["signed_transaction"].string, "fixture-JWS-A")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(fixture.requests[0]["request_id"].string)))
        XCTAssertEqual(fixture.requests[0]["base44_access_token"].string, "fixture-base44-credential")
        XCTAssertEqual(fixture.authorization, ["Bearer fixture-supabase", "Bearer fixture-supabase"])
        XCTAssertNil(try fixture.journal.pendingAppStoreTransaction(actorID: fixture.actor))
    }

    func testExhaustedBusyRetainsUnacknowledgedIntentAfterFourAttempts() async throws {
        var delays: [Duration] = []
        let fixture = HybridStoreKitRetryFixture(responses: [.busy], sleep: { delays.append($0) })
        defer { fixture.close() }
        do { _ = try await fixture.deliver("fixture-JWS-A"); XCTFail("Busy must remain a failure") }
        catch let error as Base44Error { XCTAssertEqual(error.code, "apple_account_binding_busy") }
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2)])
        XCTAssertEqual(fixture.requests.count, 4)
        XCTAssertTrue(fixture.requests.allSatisfy { $0 == fixture.requests.first })
        let saved = try XCTUnwrap(fixture.journal.pendingAppStoreTransaction(actorID: fixture.actor))
        XCTAssertEqual(saved["signed_transaction"]?.string, "fixture-JWS-A")
        XCTAssertEqual(saved["request_id"], fixture.requests[0]["request_id"])
        XCTAssertNil(saved["base44_access_token"], "Credentials must not enter the durable journal")
    }

    func testOnlyExplicitTyped503BindingBusyMayRetry() async throws {
        let failures: [HybridStoreKitRetryFixture.Reply] = [
            .init(status: 503, body: #"{"error":{"code":"apple_account_binding_busy","retryable":false}}"#),
            .init(status: 503, body: #"{"error":{"code":"apple_account_binding_busy"}}"#),
            .init(status: 503, body: #"{"error":{"code":"legacy_billing_rejected","retryable":true}}"#),
            .init(status: 409, body: #"{"error":{"code":"apple_account_binding_busy","retryable":true}}"#),
            .init(status: 401, body: #"{"error":{"code":"legacy_owner_mismatch","retryable":true}}"#)
        ]
        for reply in failures {
            let fixture = HybridStoreKitRetryFixture(responses: [reply], sleep: { _ in XCTFail("Unrelated failure retried") })
            defer { fixture.close() }
            do { _ = try await fixture.deliver("fixture-JWS-A"); XCTFail("Failure unexpectedly succeeded") }
            catch let error as Base44Error { XCTAssertEqual(error.statusCode, reply.status) }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testPurchasePreparationDoesNotRetryBindingBusy() async throws {
        let fixture = HybridStoreKitRetryFixture(responses: [.busy], sleep: { _ in XCTFail("Prepare must not retry") })
        defer { fixture.close() }
        do {
            let _: JSONValue = try await fixture.auth.service("membership", action: "prepare", fields: ["requested_product_id":.string("com.spyclash.ios.limitless.weekly")], write: true, includeLegacyCredential: true)
            XCTFail("Prepare unexpectedly succeeded")
        } catch let error as Base44Error { XCTAssertEqual(error.code, "apple_account_binding_busy") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testCancellationDuringBackoffStopsWithoutAcknowledgingTransaction() async throws {
        let sleeping = expectation(description: "Binding backoff started")
        let fixture = HybridStoreKitRetryFixture(responses: [.busy], sleep: { _ in
            sleeping.fulfill()
            try await Task.sleep(for: .seconds(30))
        })
        defer { fixture.close() }
        let task = Task { try await fixture.deliver("fixture-JWS-A") }
        await fulfillment(of: [sleeping], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled delivery succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertNotNil(try fixture.journal.pendingAppStoreTransaction(actorID: fixture.actor))
    }

    func testLogoutDuringBackoffCannotSendOldDeliveryWithNewScope() async throws {
        let sleeping = expectation(description: "Binding backoff started")
        var resume: CheckedContinuation<Void, Error>?
        let fixture = HybridStoreKitRetryFixture(responses: [.busy, .success], sleep: { _ in
            try await withCheckedThrowingContinuation { resume = $0; sleeping.fulfill() }
        })
        defer { fixture.close() }
        let task = Task { try await fixture.deliver("fixture-JWS-A") }
        await fulfillment(of: [sleeping], timeout: 3)
        fixture.auth.clear(revokeRemote: false)
        resume?.resume()
        do { _ = try await task.value; XCTFail("Old delivery survived logout") }
        catch is CancellationError {}
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertNotNil(try fixture.journal.pendingAppStoreTransaction(actorID: fixture.actor))
    }

    func testSavedDeliveryRecoveryRetriesExactAThenDeliversB() async throws {
        let fixture = HybridStoreKitRetryFixture(responses: [.busy, .success, .success])
        defer { fixture.close() }
        let saved = try fixture.journal.prepare(actorID: fixture.actor, body: ["service":.string("membership"),"action":.string("sync_transaction"),"signed_transaction":.string("fixture-JWS-A")])
        _ = try await fixture.deliver("fixture-JWS-B")
        XCTAssertEqual(fixture.requests.count, 3)
        XCTAssertEqual(fixture.requests.map { $0["signed_transaction"].string }, ["fixture-JWS-A", "fixture-JWS-A", "fixture-JWS-B"])
        XCTAssertEqual(fixture.requests[0], fixture.requests[1])
        XCTAssertEqual(fixture.requests[0]["request_id"], saved["request_id"])
        XCTAssertNotEqual(fixture.requests[2]["request_id"], saved["request_id"])
        XCTAssertNil(try fixture.journal.pendingAppStoreTransaction(actorID: fixture.actor))
    }

    func testQueuedTransactionCannotOvertakeBindingRetry() async throws {
        let sleeping = expectation(description: "A holds delivery lease during retry")
        var resume: CheckedContinuation<Void, Error>?
        let fixture = HybridStoreKitRetryFixture(responses: [.busy, .success, .success], sleep: { _ in
            try await withCheckedThrowingContinuation { resume = $0; sleeping.fulfill() }
        })
        defer { fixture.close() }
        let first = Task { try await fixture.deliver("fixture-JWS-A") }
        await fulfillment(of: [sleeping], timeout: 3)
        let second = Task { try await fixture.deliver("fixture-JWS-B") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.requests.count, 1)
        resume?.resume()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(fixture.requests.map { $0["signed_transaction"].string }, ["fixture-JWS-A", "fixture-JWS-A", "fixture-JWS-B"])
        XCTAssertNil(try fixture.journal.pendingAppStoreTransaction(actorID: fixture.actor))
    }
}

@MainActor
private final class HybridStoreKitRetryFixture {
    struct Reply: Sendable {
        let status: Int
        let body: String
        static let busy = Self(status: 503, body: #"{"error":{"code":"apple_account_binding_busy","message":"Retry shortly.","retryable":true}}"#)
        static let success = Self(status: 200, body: #"{"success":true,"server_status_verified":true,"entitlement":{"product_id":"com.spyclash.ios.limitless.weekly","status":"active","expires_at":"2099-01-01T00:00:00Z"}}"#)
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
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HybridStoreKitRetry-\(UUID())")
        journal = SupabaseAppMutationJournal(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HybridStoreKitURLProtocol.self]
        http = URLSession(configuration: configuration)
        auth = SupabaseAppSession(configuration: .init(backendURL: "https://bbkfsgnordtdiblgdzkg.supabase.co", publishableKey: "sb_publishable_fixture", permitsLegacyBilling: true), session: http,
            storedSession: .init(accessToken: "fixture-supabase", refreshToken: "fixture-refresh", userID: actor, expiresAt: Date().addingTimeInterval(3600)),
            saveSession: { _ in }, clearSession: {}, mutationJournal: journal,
            storedLegacy: .init(actorID: actor, legacyUserID: "fixture-legacy-user", accessToken: "fixture-base44-credential"), saveLegacy: { _ in }, clearLegacy: {}, appStoreRetrySleep: sleep)
        HybridStoreKitURLProtocol.handler = { [weak self] request in
            Task { @MainActor in self?.respond(to: request) }
        }
    }

    func deliver(_ jws: String) async throws -> AppStoreEntitlementSyncResponse {
        try await auth.service("membership", action: "sync_transaction", fields: ["signed_transaction":.string(jws)], write: true, includeLegacyCredential: true)
    }

    private func respond(to request: HybridStoreKitURLProtocol) {
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
        HybridStoreKitURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class HybridStoreKitURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (HybridStoreKitURLProtocol) -> Void)?
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
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
