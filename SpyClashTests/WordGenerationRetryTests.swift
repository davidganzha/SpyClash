import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class WordGenerationRetryTests: XCTestCase {
    private func makeClient() -> Base44Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("generation-original-token")
        return client
    }

    private static let safeConflict = #"{"error":"Busy","code":"active_lease","retryable":true,"retry_phase":"before_effects","effects_started":false}"#

    func testOnlyCompletePreEffectContractCanRetryWithinBoundedBudget() {
        let safe = Base44Error(
            message: "Busy", statusCode: 409, code: "active_lease", retryable: true,
            retryPhase: "before_effects", effectsStarted: false
        )
        XCTAssertEqual(WordGenerationRetryPolicy.delayMilliseconds(for: safe, completedRetries: 0), 250)
        XCTAssertEqual(WordGenerationRetryPolicy.delayMilliseconds(for: safe, completedRetries: 1), 650)
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: safe, completedRetries: 2))
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: safe, completedRetries: -1))
        var changed = safe
        changed.retryAfterSeconds = 120
        XCTAssertEqual(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0), 3_000)
        changed.retryAfterSeconds = 1
        XCTAssertEqual(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0), 1_000)
        changed = safe; changed.effectsStarted = nil
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.effectsStarted = true
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.retryPhase = nil
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.retryPhase = "effects_may_have_started"
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.retryPhase = "BEFORE_EFFECTS"
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.retryable = false
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.statusCode = 503
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
        changed = safe; changed.code = "lobby_revision_conflict"
        XCTAssertNil(WordGenerationRetryPolicy.delayMilliseconds(for: changed, completedRetries: 0))
    }

    func testTwoPreEffectConflictsRetrySameGenerationPayloadAndThenSucceed() async throws {
        let recorder = GenerationRequestRecorder()
        let safeConflict = Self.safeConflict
        GenerationURLProtocol.handler = { request in
            let count = try recorder.append(request)
            if count == 1 { return GenerationURLProtocol.response(request, status: 409, body: safeConflict) }
            if count == 2 {
                return GenerationURLProtocol.response(request, status: 409, body: safeConflict.replacingOccurrences(of: "active_lease", with: "cas_contention"))
            }
            return GenerationURLProtocol.success(request)
        }
        defer { GenerationURLProtocol.handler = nil }
        let requestID = UUID()
        let result = try await makeClient().generateWordPack(
            theme: "  Countries  ", count: 12, requestID: requestID,
            excluding: ["France"], preferFresh: true
        )
        XCTAssertEqual(result.words, ["Canada", "Spain"])
        let requests = recorder.requests
        XCTAssertEqual(requests.count, 3)
        let first = try XCTUnwrap(requests.first)
        for request in requests {
            XCTAssertEqual(request.body, first.body)
            XCTAssertEqual(request.authorization, "Bearer generation-original-token")
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: first.body) as? [String: Any])
        XCTAssertEqual(body["request_id"] as? String, requestID.uuidString)
        XCTAssertEqual(body["theme"] as? String, "Countries")
        XCTAssertEqual(body["count"] as? Int, 12)
        XCTAssertEqual(body["exclude_words"] as? [String], ["France"])
        XCTAssertEqual(body["prefer_fresh"] as? Bool, true)
    }

    func testPersistentExplicitPreEffectConflictStopsAtThreeRequests() async {
        let recorder = GenerationRequestRecorder()
        let safeConflict = Self.safeConflict
        GenerationURLProtocol.handler = { request in
            _ = try recorder.append(request)
            return GenerationURLProtocol.response(request, status: 409, body: safeConflict)
        }
        defer { GenerationURLProtocol.handler = nil }
        do {
            _ = try await makeClient().generateWordPack(theme: "Countries", count: 12, requestID: UUID())
            XCTFail("Expected bounded conflict")
        } catch let error as Base44Error {
            XCTAssertEqual(error.retryPhase, "before_effects")
            XCTAssertEqual(error.effectsStarted, false)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(recorder.requests.count, 3)
    }

    func testLegacyPostEffectServerAndMalformedSafetyResponsesNeverReplay() async {
        let cases: [(Int, String)] = [
            (409, #"{"code":"active_lease","retryable":true}"#),
            (409, #"{"code":"active_lease","retryable":true,"retry_phase":"before_effects"}"#),
            (409, #"{"code":"active_lease","retryable":true,"effects_started":false}"#),
            (409, #"{"code":"active_lease","retryable":true,"retry_phase":"effects_may_have_started","effects_started":true}"#),
            (409, #"{"code":"active_lease","retryable":true,"retry_phase":"before_effects","effects_started":"false"}"#),
            (503, Self.safeConflict)
        ]
        for (status, body) in cases {
            let recorder = GenerationRequestRecorder()
            GenerationURLProtocol.handler = { request in
                _ = try recorder.append(request)
                return GenerationURLProtocol.response(request, status: status, body: body)
            }
            do {
                _ = try await makeClient().generateWordPack(theme: "Countries", count: 12, requestID: UUID())
                XCTFail("Expected non-replayed failure")
            } catch { }
            XCTAssertEqual(recorder.requests.count, 1, "status=\(status), body=\(body)")
        }
        GenerationURLProtocol.handler = nil
    }

    func testNetworkFailureAfterSafeConflictStopsImmediately() async {
        let recorder = GenerationRequestRecorder()
        let safeConflict = Self.safeConflict
        GenerationURLProtocol.handler = { request in
            if try recorder.append(request) == 1 {
                return GenerationURLProtocol.response(request, status: 409, body: safeConflict)
            }
            throw URLError(.networkConnectionLost)
        }
        defer { GenerationURLProtocol.handler = nil }
        do {
            _ = try await makeClient().generateWordPack(theme: "Countries", count: 12, requestID: UUID())
            XCTFail("Unknown provider outcome must stop")
        } catch { }
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testAccountSwitchAndSwitchBackStopOldGenerationRetry() async {
        let recorder = GenerationRequestRecorder()
        let first = expectation(description: "Initial generation request")
        let safeConflict = Self.safeConflict
        GenerationURLProtocol.handler = { request in
            _ = try recorder.append(request)
            first.fulfill()
            return GenerationURLProtocol.response(request, status: 409, body: safeConflict)
        }
        defer { GenerationURLProtocol.handler = nil }
        let client = makeClient()
        let task = Task { try await client.generateWordPack(theme: "Countries", count: 12, requestID: UUID()) }
        await fulfillment(of: [first], timeout: 1)
        client.setToken("replacement-token")
        client.setToken("generation-original-token")
        do {
            _ = try await task.value
            XCTFail("A changed authentication generation must cancel the request")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testCancellationStopsGenerationRetry() async {
        let recorder = GenerationRequestRecorder()
        let first = expectation(description: "Initial generation request")
        let safeConflict = Self.safeConflict
        GenerationURLProtocol.handler = { request in
            _ = try recorder.append(request)
            first.fulfill()
            return GenerationURLProtocol.response(request, status: 409, body: safeConflict)
        }
        defer { GenerationURLProtocol.handler = nil }
        let client = makeClient()
        let task = Task { try await client.generateWordPack(theme: "Countries", count: 12, requestID: UUID()) }
        await fulfillment(of: [first], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(recorder.requests.count, 1)
    }
}

private final class GenerationRequestRecorder: @unchecked Sendable {
    struct Entry { let body: Data; let authorization: String? }
    private let lock = NSLock()
    private var entries: [Entry] = []

    var requests: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func append(_ request: URLRequest) throws -> Int {
        let body: Data
        if let direct = request.httpBody { body = direct }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let length = stream.read(buffer, maxLength: 4096)
                if length < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if length == 0 { break }
                result.append(buffer, count: length)
            }
            body = result
        } else { throw URLError(.cannotDecodeContentData) }
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(body: body, authorization: request.value(forHTTPHeaderField: "Authorization")))
        return entries.count
    }
}

private final class GenerationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func response(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }
    static func success(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        response(request, status: 200, body: #"{"category":"Countries","words":["Canada","Spain"]}"#)
    }
}
