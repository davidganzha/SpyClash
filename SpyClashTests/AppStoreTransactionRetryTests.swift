import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class AppStoreTransactionRetryTests: XCTestCase {
    private let signedTransaction = "fixture.signed-transaction.unchanged"
    private static let busy = #"{"error":"Unable to verify App Store entitlement.","code":"apple_account_binding_busy","retryable":true}"#
    private static let success = #"{"success":true,"server_status_verified":true,"entitlement":{"product_id":"com.spyclash.ios.limitless.weekly","status":"active","expires_at":"2099-01-01T00:00:00Z"}}"#

    private func makeClient(
        server: AppStoreRetryServer,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in }
    ) -> Base44Client {
        AppStoreRetryURLProtocol.handler = { server.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppStoreRetryURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration), appStoreRetrySleep: sleep)
        client.setToken("original-token")
        return client
    }

    func testBusyThenSuccessReusesTheExactBodyAndOriginalAuthorization() async throws {
        let server = AppStoreRetryServer(responses: [(503, Self.busy), (200, Self.success)])
        var delays: [Duration] = []
        let client = makeClient(server: server, sleep: { delays.append($0) })
        defer { AppStoreRetryURLProtocol.handler = nil }

        let result = try await client.syncAppStoreTransaction(signedTransaction: signedTransaction)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.serverStatusVerified)
        XCTAssertEqual(delays, [.milliseconds(500)])
        let requests = server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer original-token" })
        XCTAssertTrue(requests.allSatisfy { $0.path.hasSuffix("/functions/app-store-entitlement") })
        let firstBody = try XCTUnwrap(requests.first?.body)
        XCTAssertTrue(requests.allSatisfy { $0.body == firstBody })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: String])
        XCTAssertEqual(body, ["action": "sync_transaction", "signed_transaction": signedTransaction, "access_token": "original-token"])
    }

    func testPersistentBusyStopsAfterFourAttemptsAndReturnsTheLastFailure() async {
        let server = AppStoreRetryServer(responses: [(503, Self.busy)])
        var delays: [Duration] = []
        let client = makeClient(server: server, sleep: { delays.append($0) })
        defer { AppStoreRetryURLProtocol.handler = nil }

        do {
            _ = try await client.syncAppStoreTransaction(signedTransaction: signedTransaction)
            XCTFail("An exhausted retry must remain a failure")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.code, "apple_account_binding_busy")
        } catch { XCTFail("Unexpected error: \(error)") }

        XCTAssertEqual(server.requests().count, 4)
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2)])
    }

    func testUnrelatedFailuresAndExplicitlyNonRetryableErrorsAreNeverRetried() async {
        let failures: [(Int, String)] = [
            (503, #"{"error":"Unable to verify App Store entitlement."}"#),
            (503, #"{"error":"Apple account binding is being updated. Retry shortly."}"#),
            (503, #"{"code":"other_unavailable","retryable":true}"#),
            (503, #"{"code":"apple_account_binding_busy","retryable":false}"#),
            (503, #"{"code":"apple_account_binding_busy"}"#),
            (409, Self.busy), (422, Self.busy), (500, Self.busy),
            (409, #"{"error":"This App Store subscription belongs to another SpyClash account."}"#),
        ]
        defer { AppStoreRetryURLProtocol.handler = nil }
        for response in failures {
            let server = AppStoreRetryServer(responses: [response])
            let client = makeClient(server: server, sleep: { _ in XCTFail("Unrelated errors must not wait for retry") })
            do {
                _ = try await client.syncAppStoreTransaction(signedTransaction: signedTransaction)
                XCTFail("Failure unexpectedly succeeded")
            } catch let error as Base44Error {
                XCTAssertEqual(error.statusCode, response.0)
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(server.requests().count, 1)
        }
    }

    func testCancellingDuringBackoffStopsWithoutSendingAnotherRequest() async {
        let server = AppStoreRetryServer(responses: [(503, Self.busy)])
        let sleeping = expectation(description: "Retry is waiting")
        let client = makeClient(server: server, sleep: { _ in
            sleeping.fulfill()
            try await Task.sleep(for: .seconds(30))
        })
        defer { AppStoreRetryURLProtocol.handler = nil }

        let delivery = Task { try await client.syncAppStoreTransaction(signedTransaction: signedTransaction) }
        await fulfillment(of: [sleeping], timeout: 2)
        delivery.cancel()
        do {
            _ = try await delivery.value
            XCTFail("Cancelled delivery unexpectedly succeeded")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(server.requests().count, 1)
    }

    func testAccountRotationDuringBackoffStopsIncludingLogoutAndSameTokenLogin() async {
        defer { AppStoreRetryURLProtocol.handler = nil }
        for restoreOriginalToken in [false, true] {
            let server = AppStoreRetryServer(responses: [(503, Self.busy)])
            let sleeping = expectation(description: "Retry is waiting before account rotation")
            var resume: CheckedContinuation<Void, any Error>?
            let client = makeClient(server: server, sleep: { _ in
                try await withCheckedThrowingContinuation {
                    resume = $0
                    sleeping.fulfill()
                }
            })
            let delivery = Task { try await client.syncAppStoreTransaction(signedTransaction: signedTransaction) }
            await fulfillment(of: [sleeping], timeout: 2)
            client.clearToken()
            client.setToken(restoreOriginalToken ? "original-token" : "replacement-token")
            resume?.resume()
            do {
                _ = try await delivery.value
                XCTFail("A new account scope must not resume old delivery")
            } catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(server.requests().count, 1)
        }
    }

    func testCancellationBeforeDeliveryPreventsTheFirstRequest() async {
        let server = AppStoreRetryServer(responses: [(200, Self.success)])
        let client = makeClient(server: server)
        defer { AppStoreRetryURLProtocol.handler = nil }
        let delivery = Task { try await client.syncAppStoreTransaction(signedTransaction: signedTransaction) }
        delivery.cancel()
        do {
            _ = try await delivery.value
            XCTFail("Cancelled delivery unexpectedly succeeded")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(server.requests().isEmpty)
    }

    func testPurchasePreparationDoesNotUseTheTransactionRetryPolicy() async {
        let server = AppStoreRetryServer(responses: [(503, Self.busy)])
        let client = makeClient(server: server, sleep: { _ in XCTFail("Prepare must not retry") })
        defer { AppStoreRetryURLProtocol.handler = nil }
        do {
            _ = try await client.prepareAppStorePurchase()
            XCTFail("Preparation unexpectedly succeeded")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 503)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(server.requests().count, 1)
    }
}

private final class AppStoreRetryServer: @unchecked Sendable {
    struct RecordedRequest {
        let path: String
        let authorization: String?
        let body: Data
    }
    private let lock = NSLock()
    private let responses: [(Int, String)]
    private var recorded: [RecordedRequest] = []

    init(responses: [(Int, String)]) { self.responses = responses }

    func requests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func handle(_ protocolRequest: AppStoreRetryURLProtocol) {
        do {
            let request = protocolRequest.request
            let body = try bodyData(from: request)
            lock.lock()
            let response = responses[min(recorded.count, responses.count - 1)]
            recorded.append(.init(path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
            lock.unlock()
            protocolRequest.respond(status: response.0, body: response.1)
        } catch {
            protocolRequest.client?.urlProtocol(protocolRequest, didFailWithError: error)
        }
    }

    private func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class AppStoreRetryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (AppStoreRetryURLProtocol) -> Void)?
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
