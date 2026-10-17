import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class SupabaseSocialRealtimeTests: XCTestCase {
    private let actor = "11111111-1111-4111-8111-111111111111"
    private let profile = "22222222-2222-4222-8222-222222222222"

    func testSignalParserRejectsForeignRecipientsMalformedRevisionsAndDeletes() {
        let valid = signalPayload(recipient: actor, revision: 3)
        XCTAssertEqual(SupabaseSocialSignal.decode(valid, recipientUserID: actor)?.revision, 3)
        XCTAssertNil(SupabaseSocialSignal.decode(valid, recipientUserID: profile))
        for revision: Double in [-1, 0, 1.5, .infinity, Double(Int.max)] {
            XCTAssertNil(SupabaseSocialSignal.decode(signalPayload(recipient: actor, revision: revision), recipientUserID: actor))
        }
        XCTAssertNil(SupabaseSocialSignal.decode(signalPayload(recipient: actor, revision: 1, type: "DELETE"), recipientUserID: actor))
        XCTAssertNil(SupabaseSocialSignal.decode(signalPayload(recipient: actor, revision: 1, table: "app_profile_signals"), recipientUserID: actor))
        XCTAssertNil(SupabaseSocialSignal.decode(signalPayload(recipient: actor, revision: 1, table: "private_profiles"), recipientUserID: actor))
    }

    func testCatchUpRequiresLivePostgresSubscriptionAndSignalsAreOrderedPerProfile() async throws {
        let harness = Harness(userID: actor), service = harness.makeService()
        defer { service.stop() }
        var catchUps = 0, signals: [SupabaseSocialSignal] = []
        service.onCatchUp = { catchUps += 1 }; service.onChange = { signals.append($0) }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        XCTAssertEqual(socket.sent[0]["payload"]["config"]["postgres_changes"].array.count, 2)
        XCTAssertEqual(socket.sent[0]["payload"]["access_token"].string, "token-1")
        socket.push(joinReply(userID: actor))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(catchUps, 0, "A channel join is not proof that Postgres streaming is live")
        socket.push(system(userID: actor)); socket.push(system(userID: actor))
        try await eventually { catchUps == 1 }
        for revision: Double in [5, 5, 4, 6] {
            socket.push(event(userID: actor, payload: signalPayload(recipient: actor, revision: revision)))
        }
        socket.push(event(userID: actor, payload: signalPayload(recipient: actor, revision: 2, table: "app_profile_signals", profile: profile)))
        socket.push(event(userID: actor, payload: signalPayload(recipient: actor, revision: 1, table: "app_profile_signals", profile: actor)))
        try await eventually { signals.count == 4 }
        XCTAssertEqual(signals.map(\.revision), [5, 6, 2, 1])
        XCTAssertEqual(signals.suffix(2).map(\.profileUserID), [profile, actor])
        service.start(userID: actor)
        XCTAssertEqual(harness.sockets.count, 1, "Repeated starts must preserve the existing stream")
    }

    func testPostgresFailureClosesSocketAndReconnectCatchesUpOnlyWhenReady() async throws {
        let harness = Harness(userID: actor), service = harness.makeService()
        defer { service.stop() }
        var catchUps = 0; service.onCatchUp = { catchUps += 1 }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        harness.sockets[0].push(joinReply(userID: actor)); harness.sockets[0].push(system(userID: actor))
        try await eventually { catchUps == 1 }
        harness.sockets[0].push(system(userID: actor, status: "error"))
        try await eventually { harness.sockets.count == 2 && harness.sockets[1].sent.count == 1 }
        XCTAssertTrue(harness.sockets[0].cancelled)
        XCTAssertEqual(catchUps, 1)
        // The server can confirm the CDC system before it delivers the join reply.
        harness.sockets[1].push(system(userID: actor)); harness.sockets[1].push(joinReply(userID: actor))
        try await eventually { catchUps == 2 }
    }

    func testJoinTimeoutRetriesAndStopCancelsPendingReconnect() async throws {
        let harness = Harness(userID: actor)
        let service = harness.makeService(timeout: .milliseconds(25))
        service.start(userID: actor)
        try await eventually { harness.sockets.count >= 2 }
        XCTAssertTrue(harness.sockets[0].cancelled)
        service.stop()
        let count = harness.sockets.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(harness.sockets.count, count)
        XCTAssertTrue(harness.sockets.allSatisfy(\.cancelled))
    }

    func testAccountGenerationChangeDuringTokenRequestCannotOpenSocket() async throws {
        let harness = Harness(userID: actor)
        var tokenContinuation: CheckedContinuation<String, Error>?
        harness.tokenProvider = { try await withCheckedThrowingContinuation { tokenContinuation = $0 } }
        let service = harness.makeService()
        service.start(userID: actor)
        try await eventually { tokenContinuation != nil }
        harness.account = .init(userID: actor, generation: UUID())
        tokenContinuation?.resume(returning: "stale-token")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(harness.sockets.isEmpty)
        service.stop()
    }

    func testAccountGenerationChangeAfterReceiveDiscardsOldSignalAndClosesSocket() async throws {
        let harness = Harness(userID: actor), service = harness.makeService()
        defer { service.stop() }
        var signals: [SupabaseSocialSignal] = []; service.onChange = { signals.append($0) }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        socket.push(joinReply(userID: actor)); socket.push(system(userID: actor))
        try await Task.sleep(for: .milliseconds(10))
        harness.account = .init(userID: profile, generation: UUID())
        socket.push(event(userID: actor, payload: signalPayload(recipient: actor, revision: 10)))
        try await eventually { socket.cancelled }
        XCTAssertTrue(signals.isEmpty)
        XCTAssertEqual(harness.sockets.count, 1)
    }

    func testMissingHeartbeatAcknowledgementReconnects() async throws {
        let harness = Harness(userID: actor)
        let service = harness.makeService(heartbeat: .milliseconds(25), timeout: .milliseconds(15))
        defer { service.stop() }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        socket.push(joinReply(userID: actor)); socket.push(system(userID: actor))
        try await eventually { socket.sent.contains { $0["event"].string == "heartbeat" } }
        try await eventually { harness.sockets.count >= 2 }
        XCTAssertTrue(socket.cancelled)
        XCTAssertTrue(socket.sent.contains { $0["event"].string == "access_token" })
    }

    func testTokenRenewalDoesNotDelayHeartbeatsAndCannotSendAfterAccountChanges() async throws {
        let harness = Harness(userID: actor)
        var renewToken: CheckedContinuation<String, Error>?
        var requests = 0
        harness.tokenProvider = {
            requests += 1
            if requests == 1 { return "initial-token" }
            return try await withCheckedThrowingContinuation { renewToken = $0 }
        }
        let service = harness.makeService(heartbeat: .milliseconds(20), timeout: .milliseconds(100))
        defer { service.stop() }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        socket.push(joinReply(userID: actor)); socket.push(system(userID: actor))
        try await eventually { renewToken != nil && socket.sent.contains { $0["event"].string == "heartbeat" } }
        let firstBeat = socket.sent.first { $0["event"].string == "heartbeat" }!
        socket.push(.object(["topic": .string("phoenix"), "event": .string("phx_reply"), "ref": firstBeat["ref"], "payload": .object(["status": .string("ok")])]))
        try await eventually { socket.sent.filter { $0["event"].string == "heartbeat" }.count == 2 }
        harness.account = .init(userID: profile, generation: UUID())
        renewToken?.resume(returning: "other-account-token")
        try await eventually { socket.cancelled }
        XCTAssertFalse(socket.sent.contains { $0["event"].string == "access_token" })
    }

    func testDocumentedJoinReplyWithoutEchoedFilterStillRequiresRecipientScopedRecords() async throws {
        let harness = Harness(userID: actor), service = harness.makeService()
        defer { service.stop() }
        var catchUps = 0, signals: [SupabaseSocialSignal] = []
        service.onCatchUp = { catchUps += 1 }; service.onChange = { signals.append($0) }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        var reply = joinReply(userID: actor).object!
        var payload = reply["payload"]!.object!, response = payload["response"]!.object!
        response["postgres_changes"] = .array(response["postgres_changes"]!.array.map { binding in
            var fields = binding.object!; fields.removeValue(forKey: "filter"); return .object(fields)
        })
        payload["response"] = .object(response); reply["payload"] = .object(payload)
        socket.push(.object(reply)); socket.push(system(userID: actor))
        try await eventually { catchUps == 1 }
        socket.push(event(userID: actor, payload: signalPayload(recipient: profile, revision: 1)))
        socket.push(event(userID: actor, payload: signalPayload(recipient: actor, revision: 2)))
        try await eventually { signals.count == 1 }
        XCTAssertEqual(signals.first?.revision, 2)
    }

    func testInvalidSubscriptionIDsForceRejoin() async throws {
        let harness = Harness(userID: actor), service = harness.makeService()
        defer { service.stop() }
        service.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        socket.push(joinReply(userID: actor)); socket.push(system(userID: actor))
        let payload = signalPayload(recipient: actor, revision: 1)
        var fields = payload.object!; fields["ids"] = .array([.number(99)])
        socket.push(event(userID: actor, payload: .object(fields)))
        try await eventually { socket.cancelled }
    }

    func testDeallocationCancelsActiveSocketWithoutRetainCycle() async throws {
        let harness = Harness(userID: actor)
        var service: SupabaseSocialRealtimeService? = harness.makeService()
        weak var weakService = service
        service?.start(userID: actor)
        try await eventually { harness.sockets.first?.sent.count == 1 }
        let socket = harness.sockets[0]
        socket.push(joinReply(userID: actor)); socket.push(system(userID: actor))
        try await Task.sleep(for: .milliseconds(10))
        service = nil
        XCTAssertNil(weakService)
        XCTAssertTrue(socket.cancelled)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for realtime state", file: file, line: line)
        throw URLError(.timedOut)
    }
    private func joinReply(userID: String) -> JSONValue {
        let subscriptions = ["app_user_signals", "app_profile_signals"].enumerated().map { index, table in JSONValue.object([
            "id": .number(Double(index + 1)), "table": .string(table), "event": .string("*"), "schema": .string("public"),
            "filter": .string("recipient_user_id=eq.\(userID)")
        ]) }
        return .object(["topic": .string("realtime:app-social-\(userID)"), "event": .string("phx_reply"), "ref": .string("1"),
                        "payload": .object(["status": .string("ok"), "response": .object(["postgres_changes": .array(subscriptions)])])])
    }
    private func system(userID: String, status: String = "ok") -> JSONValue {
        .object(["topic": .string("realtime:app-social-\(userID)"), "event": .string("system"),
                 "payload": .object(["status": .string(status), "extension": .string("postgres_changes")])])
    }
    private func event(userID: String, payload: JSONValue) -> JSONValue {
        .object(["topic": .string("realtime:app-social-\(userID)"), "event": .string("postgres_changes"), "payload": payload])
    }
    private func signalPayload(recipient: String, revision: Double, table: String = "app_user_signals", type: String = "UPDATE", profile: String? = nil) -> JSONValue {
        var record: [String: JSONValue] = ["recipient_user_id": .string(recipient), "revision": .number(revision)]
        if let profile { record["profile_user_id"] = .string(profile) }
        return .object(["ids": .array([.number(table == "app_profile_signals" ? 2 : 1)]),
                        "data": .object(["schema": .string("public"), "table": .string(table), "type": .string(type), "record": .object(record)])])
    }
}

@MainActor
private final class Harness {
    var account: SupabaseSocialRealtimeService.Account
    var sockets: [SocialFakeSocket] = []
    var tokenProvider: (() async throws -> String)?
    init(userID: String) { account = .init(userID: userID, generation: UUID()) }
    func makeService(heartbeat: Duration = .seconds(20), timeout: Duration = .seconds(1)) -> SupabaseSocialRealtimeService {
        SupabaseSocialRealtimeService(dependencies: .init(
            account: { self.account }, endpoint: { URL(string: "wss://example.test/realtime/v1/websocket")! },
            accessToken: { try await self.tokenProvider?() ?? "token-1" },
            makeSocket: { _ in let socket = SocialFakeSocket(); self.sockets.append(socket); return socket },
            heartbeatInterval: heartbeat, timeout: timeout, retryDelay: { _ in .milliseconds(5) }
        ))
    }
}

private final class SocialFakeSocket: SupabaseSocialRealtimeSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var outbound: [JSONValue] = []
    private var inbound: [JSONValue] = []
    private var waiter: CheckedContinuation<JSONValue, Error>?
    private var isCancelled = false
    var sent: [JSONValue] { lock.withLock { outbound } }
    var cancelled: Bool { lock.withLock { isCancelled } }
    func resume() {}
    func cancel() {
        let pending = lock.withLock { () -> CheckedContinuation<JSONValue, Error>? in
            isCancelled = true; let result = waiter; waiter = nil; return result
        }
        pending?.resume(throwing: CancellationError())
    }
    func send(_ frame: JSONValue) async throws {
        try lock.withLock {
            guard !isCancelled else { throw CancellationError() }
            outbound.append(frame)
        }
    }
    func receive() async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !inbound.isEmpty { continuation.resume(returning: inbound.removeFirst()) }
                else { waiter = continuation }
            }
        }
    }
    func push(_ frame: JSONValue) {
        let pending = lock.withLock { () -> CheckedContinuation<JSONValue, Error>? in
            guard !isCancelled else { return nil }
            if let result = waiter { waiter = nil; return result }
            inbound.append(frame); return nil
        }
        pending?.resume(returning: frame)
    }
}
