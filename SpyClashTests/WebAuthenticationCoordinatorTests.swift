import AuthenticationServices
import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class WebAuthenticationCoordinatorTests: XCTestCase {
    private let loginURL = URL(string: "https://spyclash.com/login")!
    private let callback = URL(string: "spyclash://auth?access_token=first")!

    private func assertFailure(
        _ task: Task<URL, any Error>,
        _ expected: WebAuthenticationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected authentication failure", file: file, line: line)
        } catch let error as WebAuthenticationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected failure: \(error)", file: file, line: line)
        }
    }

    func testSuccessCompletesOnceAndIgnoresDuplicateCallback() async throws {
        let started = expectation(description: "Browser started")
        let harness = SessionHarness { started.fulfill() }
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let task = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [started], timeout: 1)
        let session = try XCTUnwrap(harness.sessions.first)
        session.complete(callback, nil)
        session.complete(nil, NSError(domain: "old", code: 1))
        let result = try await task.value
        XCTAssertEqual(result, callback)
        XCTAssertEqual(session.cancelCount, 0)
        coordinator.cancel()
        XCTAssertEqual(session.cancelCount, 0)
    }

    func testExplicitCancelResumesEvenWhenSessionNeverCallsItsCompletion() async throws {
        let started = expectation(description: "Browser started")
        let harness = SessionHarness { started.fulfill() }
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let task = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [started], timeout: 1)
        let session = try XCTUnwrap(harness.sessions.first)
        coordinator.cancel()
        coordinator.cancel()
        await assertFailure(task, .cancelled)
        XCTAssertEqual(session.cancelCount, 1)
        session.complete(callback, nil)
    }

    func testTaskCancellationCancelsBrowserAndResumesContinuation() async throws {
        let started = expectation(description: "Browser started")
        let harness = SessionHarness { started.fulfill() }
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let task = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(harness.sessions.first?.cancelCount, 1)
    }

    func testAlreadyCancelledTaskDoesNotStartOrReplaceBrowser() async throws {
        let started = expectation(description: "First browser started")
        let harness = SessionHarness { started.fulfill() }
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let first = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [started], timeout: 1)
        let cancelled = Task { try await coordinator.authenticate(url: loginURL) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation before starting a browser")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(harness.sessions.count, 1)
        XCTAssertEqual(harness.sessions[0].cancelCount, 0)
        harness.sessions[0].complete(callback, nil)
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, callback)
    }

    func testTaskCancellationWinsEvenIfCallbackRunsBeforeCancellationHandler() async throws {
        let started = expectation(description: "Browser started")
        let harness = SessionHarness { started.fulfill() }
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let task = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        // Still on this MainActor turn: the cancellation handler's queued
        // cleanup has not run, but the framework can already deliver a URL.
        harness.sessions[0].complete(callback, nil)
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not return an authentication token")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    func testStartFailureAndLateCallbackResumeOnlyOnce() async throws {
        let harness = SessionHarness(startResult: false)
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let task = Task { try await coordinator.authenticate(url: loginURL) }
        await assertFailure(task, .couldNotStart)
        let session = try XCTUnwrap(harness.sessions.first)
        XCTAssertEqual(session.cancelCount, 1)
        session.complete(callback, nil)
        session.complete(nil, NSError(domain: "late", code: 2))
    }

    func testTimeoutCancelsBrowserWithoutWaitingForFrameworkCallback() async throws {
        let sleeping = expectation(description: "Deadline scheduled")
        let sleeper = ManualAuthenticationSleeper { _ in sleeping.fulfill() }
        let harness = SessionHarness()
        let coordinator = WebAuthenticationCoordinator(
            makeSession: harness.makeSession,
            sleep: { await sleeper.sleep($0) }
        )
        let task = Task { try await coordinator.authenticate(url: loginURL, timeout: 7) }
        await fulfillment(of: [sleeping], timeout: 1)
        sleeper.wakeAll()
        await assertFailure(task, .expired)
        XCTAssertEqual(harness.sessions.first?.cancelCount, 1)
    }

    func testCompletionAfterSuspendedDeadlineIsRejectedBeforeWatchdogRuns() async throws {
        let sleeping = expectation(description: "Deadline scheduled")
        let sleeper = ManualAuthenticationSleeper { _ in sleeping.fulfill() }
        let harness = SessionHarness()
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = WebAuthenticationCoordinator(
            makeSession: harness.makeSession,
            now: { now },
            sleep: { await sleeper.sleep($0) }
        )
        let task = Task { try await coordinator.authenticate(url: loginURL, timeout: 5) }
        await fulfillment(of: [sleeping], timeout: 1)
        now.addTimeInterval(5)
        harness.sessions[0].complete(callback, nil)
        await assertFailure(task, .expired)
        XCTAssertEqual(harness.sessions[0].cancelCount, 1)
        sleeper.wakeAll()
    }

    func testSupersededSessionAndOldTimerCannotCompleteReplacement() async throws {
        let sleeping = expectation(description: "Both deadlines scheduled")
        sleeping.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "First browser started")
        let sleeper = ManualAuthenticationSleeper { _ in sleeping.fulfill() }
        let harness = SessionHarness()
        harness.onStart = { if harness.sessions.count == 1 { firstStarted.fulfill() } }
        let coordinator = WebAuthenticationCoordinator(
            makeSession: harness.makeSession,
            sleep: { await sleeper.sleep($0) }
        )
        let first = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [sleeping], timeout: 1)
        await assertFailure(first, .cancelled)
        XCTAssertEqual(harness.sessions[0].cancelCount, 1)
        harness.sessions[0].complete(callback, nil)
        sleeper.wakeFirst()
        let replacement = URL(string: "spyclash://auth?access_token=replacement")!
        harness.sessions[1].complete(replacement, nil)
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, replacement)
        XCTAssertEqual(harness.sessions[1].cancelCount, 0)
        sleeper.wakeAll()
    }

    func testSynchronousCallbackDuringCancelCannotWinOverCancellation() async throws {
        let started = expectation(description: "Browser started")
        let harness = SessionHarness { started.fulfill() }
        let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
        let task = Task { try await coordinator.authenticate(url: loginURL) }
        await fulfillment(of: [started], timeout: 1)
        let session = try XCTUnwrap(harness.sessions.first)
        session.onCancel = { session.complete(self.callback, nil) }
        coordinator.cancel()
        await assertFailure(task, .cancelled)
    }

    func testOnlyFrameworkCancellationDomainIsTreatedAsUserCancellation() async throws {
        for (domain, expected) in [
            (ASWebAuthenticationSessionError.errorDomain, WebAuthenticationError.cancelled),
            ("unrelated.domain", WebAuthenticationError.failed)
        ] {
            let started = expectation(description: "Browser started \(domain)")
            let harness = SessionHarness { started.fulfill() }
            let coordinator = WebAuthenticationCoordinator(makeSession: harness.makeSession)
            let task = Task { try await coordinator.authenticate(url: loginURL) }
            await fulfillment(of: [started], timeout: 1)
            harness.sessions[0].complete(nil, NSError(
                domain: domain, code: ASWebAuthenticationSessionError.canceledLogin.rawValue
            ))
            await assertFailure(task, expected)
        }
    }

    func testCallbackTokenParserAcceptsCanonicalRouteAndPreservesToken() throws {
        for route in ["spyclash://auth", "spyclash://auth/"] {
            let url = try XCTUnwrap(URL(string: "\(route)?auth_provider=google&access_token=a%2Bb.c_d-1"))
            XCTAssertEqual(try WebAuthenticationCallback.accessToken(from: url), "a+b.c_d-1")
        }
        let maximum = String(repeating: "a", count: 20_000)
        XCTAssertEqual(try WebAuthenticationCallback.accessToken(from: XCTUnwrap(
            URL(string: "spyclash://auth?access_token=\(maximum)")
        )), maximum)
    }

    func testCallbackTokenParserRejectsWrongRoutesAmbiguityAndInvalidTokens() throws {
        let rejected = [
            "https://auth?access_token=a", "spyclash://join?access_token=a",
            "spyclash://auth/extra?access_token=a", "spyclash://auth:443?access_token=a",
            "spyclash://user@auth?access_token=a", "spyclash://user:password@auth?access_token=a",
            "spyclash://auth?access_token=a#fragment", "spyclash://auth#access_token=a",
            "spyclash://auth?access_token=", "spyclash://auth?access_token",
            "spyclash://auth?access_token=%20", "spyclash://auth?access_token=%20a",
            "spyclash://auth?access_token=a%0Ab", "spyclash://auth?access_token=a&access_token=b",
            "spyclash://auth?access_token=a&error=access_denied",
            "spyclash://auth?access_token=a&error_description=untrusted",
            "spyclash://auth?access_token=a&auth_provider=google&auth_provider=apple",
            "spyclash://auth?error=access_denied&error=server_error",
            "spyclash://auth?access_token=\(String(repeating: "a", count: 20_001))"
        ]
        for raw in rejected {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try WebAuthenticationCallback.accessToken(from: url)) { error in
                XCTAssertEqual(error as? WebAuthenticationError, .invalidCallback)
            }
        }
    }

    func testProviderErrorsBecomeTypedFailuresWithoutReflectingDescription() throws {
        for (code, expected) in [
            ("access_denied", WebAuthenticationError.cancelled),
            ("invalid_state", WebAuthenticationError.invalidCallback),
            ("session_expired", WebAuthenticationError.expired),
            ("temporarily_unavailable", WebAuthenticationError.temporarilyUnavailable),
            ("server_error", WebAuthenticationError.temporarilyUnavailable),
            ("unrecognized_server_detail", WebAuthenticationError.failed)
        ] {
            let url = try XCTUnwrap(URL(string: "spyclash://auth?error=\(code)&error_description=untrusted-secret"))
            XCTAssertThrowsError(try WebAuthenticationCallback.accessToken(from: url)) { error in
                XCTAssertEqual(error as? WebAuthenticationError, expected)
                XCTAssertFalse(String(describing: error).contains("untrusted-secret"))
            }
        }
    }
}

@MainActor
private final class SessionHarness {
    var sessions: [FakeWebAuthenticationSession] = []
    var onStart: () -> Void
    let startResult: Bool

    init(startResult: Bool = true, onStart: @escaping () -> Void = {}) {
        self.startResult = startResult
        self.onStart = onStart
    }

    func makeSession(_ url: URL, completion: @escaping WebAuthenticationCoordinator.Completion) -> any WebAuthenticationSession {
        let session = FakeWebAuthenticationSession(startResult: startResult, completion: completion, onStart: onStart)
        sessions.append(session)
        return session
    }
}

@MainActor
private final class FakeWebAuthenticationSession: WebAuthenticationSession {
    let startResult: Bool
    let complete: WebAuthenticationCoordinator.Completion
    let onStart: () -> Void
    var onCancel: (() -> Void)?
    private(set) var cancelCount = 0

    init(startResult: Bool, completion: @escaping WebAuthenticationCoordinator.Completion, onStart: @escaping () -> Void) {
        self.startResult = startResult
        self.complete = completion
        self.onStart = onStart
    }

    func start() -> Bool { onStart(); return startResult }
    func cancel() { cancelCount += 1; onCancel?() }
}

/// Deliberately permits old cancelled timers to resume, so tests exercise the
/// coordinator's ownership fence. Each test drains every stored continuation.
@MainActor
private final class ManualAuthenticationSleeper {
    let onSleep: (Duration) -> Void
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(onSleep: @escaping (Duration) -> Void) { self.onSleep = onSleep }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            onSleep(duration)
        }
    }

    func wakeFirst() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func wakeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
