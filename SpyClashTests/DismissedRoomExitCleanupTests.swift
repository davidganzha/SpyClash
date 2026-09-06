import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class DismissedRoomExitCleanupTests: XCTestCase {
    private func withStore(_ test: @MainActor (DismissedRoomExitIntentStore) async throws -> Void) async throws {
        let suite = "DismissedRoomExitCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await test(DismissedRoomExitIntentStore(defaults: defaults))
    }

    private func resolve(
        _ intent: DismissedRoomExitIntent,
        in store: DismissedRoomExitIntentStore,
        outcome: DismissedRoomExitOutcome = .completed
    ) -> Bool {
        store.resolve(
            intent, outcome: outcome, currentOwnerID: intent.ownerID,
            capturedAccessToken: "original-token", currentAccessToken: "original-token"
        )
    }

    func testCompletedCleanupDoesNotRestartOnForegroundOrRelaunchAndKeepsDismissalFence() async throws {
        try await withStore { store in
            store.defaults.set("room-1", forKey: "spyclash.dismissedRoomID")
            store.defaults.set("owner-1", forKey: "spyclash.dismissedRoomOwnerID")
            let intent = store.begin(ownerID: "owner-1", roomID: "room-1", membershipID: "member-1")
            var requests = 0
            let outcome = await DismissedRoomExitRetryPolicy.run(
                mode: .close, shouldContinue: { store.matches(intent) },
                operation: { requests += 1 }, sleep: { _ in XCTFail("No retry expected") }
            )
            XCTAssertEqual(outcome, .completed)
            XCTAssertTrue(resolve(intent, in: store, outcome: outcome))

            XCTAssertNil(store.pendingIntent(ownerID: "owner-1", roomID: "room-1", membershipID: "member-1"))
            let relaunched = DismissedRoomExitIntentStore(defaults: store.defaults)
            XCTAssertNil(relaunched.pendingIntent(ownerID: "owner-1", roomID: "room-1", membershipID: "member-1"))
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(store.defaults.string(forKey: "spyclash.dismissedRoomID"), "room-1")
            XCTAssertEqual(store.defaults.string(forKey: "spyclash.dismissedRoomOwnerID"), "owner-1")
        }
    }

    func testBothExitCASConflictsBecomeTerminalWithoutReplayOrFallback() async throws {
        for code in ["room_exit_membership_conflict", "room_exit_revision_conflict"] {
            try await withStore { store in
                let intent = store.begin(ownerID: "owner", roomID: "room", membershipID: "old-member")
                var attempts = 0
                let outcome = await DismissedRoomExitRetryPolicy.run(
                    mode: .close, shouldContinue: { true },
                    operation: {
                        attempts += 1
                        throw Base44Error(message: "Changed", statusCode: 409, code: code)
                    },
                    leaveFallback: { XCTFail("A newer membership must not be removed") },
                    sleep: { _ in XCTFail("A stale exit must not retry") }
                )
                XCTAssertEqual(outcome, .terminal)
                XCTAssertEqual(attempts, 1)
                XCTAssertTrue(resolve(intent, in: store, outcome: outcome))
                XCTAssertNil(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: "old-member"))
            }
        }
    }

    func testUnauthorizedExitRetainsExactIntentUntilRenewedSessionCompletesIt() async throws {
        for mode in [DismissedRoomExitMode.close, .leave] {
            try await withStore { store in
                let intent = store.begin(ownerID: "owner", roomID: "room", membershipID: "member")
                var tokens: [String] = []
                let firstOutcome = await DismissedRoomExitRetryPolicy.run(
                    mode: mode, shouldContinue: { store.matches(intent) },
                    operation: {
                        tokens.append("expired-token")
                        throw Base44Error(message: "Expired", statusCode: 401)
                    },
                    leaveFallback: { XCTFail("An expired session must not trigger another request") },
                    sleep: { _ in XCTFail("Authentication needs renewal, not a retry delay") }
                )
                XCTAssertEqual(firstOutcome, .deferred)
                XCTAssertFalse(store.resolve(
                    intent, outcome: firstOutcome, currentOwnerID: "owner",
                    capturedAccessToken: "expired-token", currentAccessToken: "expired-token"
                ))

                let relaunched = DismissedRoomExitIntentStore(defaults: store.defaults)
                let pending = try XCTUnwrap(relaunched.pendingIntent(
                    ownerID: "owner", roomID: "room", membershipID: "member"
                ))
                XCTAssertEqual(pending, intent)
                let renewedOutcome = await DismissedRoomExitRetryPolicy.run(
                    mode: mode, shouldContinue: { relaunched.matches(pending) },
                    operation: { tokens.append("renewed-token") },
                    sleep: { _ in XCTFail("No retry expected") }
                )
                XCTAssertEqual(renewedOutcome, .completed)
                XCTAssertTrue(relaunched.resolve(
                    pending, outcome: renewedOutcome, currentOwnerID: "owner",
                    capturedAccessToken: "renewed-token", currentAccessToken: "renewed-token"
                ))
                XCTAssertEqual(tokens, ["expired-token", "renewed-token"])
                XCTAssertNil(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: "member"))
            }
        }
    }

    func testUnauthorizedHostLeaveFallbackStaysPendingForRenewedSession() async throws {
        try await withStore { store in
            let intent = store.begin(ownerID: "owner", roomID: "room", membershipID: "member")
            var closeAttempts = 0
            var leaveAttempts = 0
            let firstOutcome = await DismissedRoomExitRetryPolicy.run(
                mode: .close, shouldContinue: { store.matches(intent) },
                operation: {
                    closeAttempts += 1
                    throw Base44Error(message: "Host changed", statusCode: 403)
                },
                leaveFallback: {
                    leaveAttempts += 1
                    throw Base44Error(message: "Expired", statusCode: 401)
                }, sleep: { _ in XCTFail("Do not repeat the expired session") }
            )
            XCTAssertEqual(firstOutcome, .deferred)
            XCTAssertFalse(resolve(intent, in: store, outcome: firstOutcome))
            XCTAssertEqual(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: "member"), intent)
            let renewedOutcome = await DismissedRoomExitRetryPolicy.run(
                mode: .close, shouldContinue: { store.matches(intent) },
                operation: {
                    closeAttempts += 1
                    throw Base44Error(message: "Host changed", statusCode: 403)
                },
                leaveFallback: { leaveAttempts += 1 }, sleep: { _ in XCTFail("No retry expected") }
            )
            XCTAssertEqual(renewedOutcome, .completed)
            XCTAssertTrue(store.resolve(
                intent, outcome: renewedOutcome, currentOwnerID: "owner",
                capturedAccessToken: "renewed-token", currentAccessToken: "renewed-token"
            ))
            XCTAssertEqual(closeAttempts, 2)
            XCTAssertEqual(leaveAttempts, 2)
            XCTAssertNil(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: "member"))
        }
    }

    func testLateOldCompletionCannotResolveNewIntentEvenForSameRoomAndMembership() async throws {
        try await withStore { store in
            let old = store.begin(ownerID: "owner", roomID: "room", membershipID: "member")
            let replacement = store.begin(ownerID: "owner", roomID: "room", membershipID: "member")
            XCTAssertNotEqual(old.id, replacement.id)
            XCTAssertFalse(resolve(old, in: store))
            XCTAssertEqual(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: "member"), replacement)
            XCTAssertTrue(resolve(replacement, in: store))
        }
    }

    func testAccountOrTokenChangesCannotResolveCapturedIntent() async throws {
        try await withStore { store in
            let intent = store.begin(ownerID: "owner-a", roomID: "room", membershipID: "member")
            XCTAssertFalse(store.resolve(
                intent, outcome: .completed, currentOwnerID: "owner-b",
                capturedAccessToken: "a", currentAccessToken: "a"
            ))
            XCTAssertFalse(store.resolve(
                intent, outcome: .terminal, currentOwnerID: "owner-a",
                capturedAccessToken: "a", currentAccessToken: "b"
            ))
            XCTAssertFalse(store.resolve(
                intent, outcome: .completed, currentOwnerID: "owner-a",
                capturedAccessToken: "a", currentAccessToken: nil
            ))
            XCTAssertEqual(store.pendingIntent(ownerID: "owner-a", roomID: "room", membershipID: "member"), intent)
        }
    }

    func testExplicitRejoinClearsReceiptAndRejectsLateCompletion() async throws {
        try await withStore { store in
            let old = store.begin(ownerID: "owner", roomID: "room", membershipID: "old-member")
            store.clear()
            XCTAssertFalse(resolve(old, in: store))
            let new = store.begin(ownerID: "owner", roomID: "room", membershipID: "new-member")
            XCTAssertFalse(resolve(old, in: store))
            XCTAssertTrue(store.matches(new))
        }
    }

    func testCancellationDuringBackoffRemainsPending() async throws {
        try await withStore { store in
            let intent = store.begin(ownerID: "owner", roomID: "room", membershipID: "member")
            let outcome = await DismissedRoomExitRetryPolicy.run(
                mode: .close, shouldContinue: { true },
                operation: { throw URLError(.timedOut) },
                sleep: { _ in throw CancellationError() }
            )
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertFalse(resolve(intent, in: store, outcome: outcome))
            XCTAssertTrue(store.matches(intent))
        }
    }

    func testScopeChangeWhileRequestIsInFlightCannotResolveSuccess() async throws {
        try await withStore { store in
            let intent = store.begin(ownerID: "owner", roomID: "room", membershipID: "member")
            var current = true
            let outcome = await DismissedRoomExitRetryPolicy.run(
                mode: .close, shouldContinue: { current },
                operation: { current = false }, sleep: { _ in XCTFail("No retry expected") }
            )
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertFalse(resolve(intent, in: store, outcome: outcome))
            XCTAssertTrue(store.matches(intent))
        }
    }

    func testExhaustedLeaveAndFailedHostFallbackRemainDeferred() async {
        var attempts = 0
        let leaveOutcome = await DismissedRoomExitRetryPolicy.run(
            mode: .leave, shouldContinue: { true },
            operation: { attempts += 1; throw URLError(.notConnectedToInternet) },
            sleep: { _ in }
        )
        XCTAssertEqual(leaveOutcome, .deferred)
        XCTAssertEqual(attempts, 3)
        let fallbackOutcome = await DismissedRoomExitRetryPolicy.run(
            mode: .close, shouldContinue: { true },
            operation: { throw Base44Error(message: "Host changed", statusCode: 403) },
            leaveFallback: { throw URLError(.timedOut) }, sleep: { _ in XCTFail("No retry expected") }
        )
        XCTAssertEqual(fallbackOutcome, .deferred)
    }

    func testLegacyDismissalGetsOneStableIntentWithItsOriginalMembership() async throws {
        try await withStore { store in
            let migrated = try XCTUnwrap(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: nil))
            let relaunched = DismissedRoomExitIntentStore(defaults: store.defaults)
            XCTAssertEqual(relaunched.pendingIntent(ownerID: "owner", roomID: "room", membershipID: nil), migrated)
            XCTAssertNil(migrated.membershipID)
            XCTAssertTrue(resolve(migrated, in: relaunched, outcome: .terminal))
            XCTAssertNil(store.pendingIntent(ownerID: "owner", roomID: "room", membershipID: nil))
        }
    }
}
