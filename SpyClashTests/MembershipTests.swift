import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class MembershipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        active: Bool = true, tier: MembershipTier = .limitless,
        status: String = "active", providers: [String] = ["apple"],
        expiry: Date? = Date(timeIntervalSince1970: 1_900_000_000),
        purchase: Bool = false
    ) -> MembershipSnapshot {
        MembershipSnapshot(active: active, tier: tier, status: status, accessProtocol: "limitless", providers: providers, benefits: active ? .limitless : .free, expiresAt: expiry, aiGenerationsToday: nil, aiRemaining: nil, checkoutRequired: purchase)
    }

    func testVerifiedAppleAccessExpiresAndRevocationWins() {
        XCTAssertTrue(snapshot().grantsAccess(at: now))
        XCTAssertFalse(snapshot(expiry: now).grantsAccess(at: now))
        XCTAssertFalse(snapshot(status: "revoked").grantsAccess(at: now))
        XCTAssertFalse(snapshot(status: "refunded").grantsAccess(at: now))
        XCTAssertFalse(snapshot(status: "billing_retry").grantsAccess(at: now))
        XCTAssertTrue(snapshot(status: "grace_period").grantsAccess(at: now))
        XCTAssertFalse(snapshot(expiry: nil).grantsAccess(at: now))
    }

    func testPermanentAdminAndExplicitUniversalAccessRemainValid() {
        XCTAssertTrue(snapshot(providers: ["admin"], expiry: nil).grantsAccess(at: now))
        XCTAssertTrue(MembershipSnapshot.universalPreview.grantsAccess(at: now))
        XCTAssertFalse(snapshot(providers: ["unknown"], expiry: nil).grantsAccess(at: now))
        XCTAssertFalse(snapshot(providers: ["casada"], expiry: nil).grantsAccess(at: now))
    }

    func testContradictoryOrUnknownResponsesAreNotResolved() {
        XCTAssertFalse(snapshot(active: false).isResolved)
        XCTAssertFalse(snapshot(status: "unknown").isResolved)
        XCTAssertFalse(snapshot(providers: ["unknown"]).isResolved)
        XCTAssertFalse(snapshot(expiry: nil).isResolved)
        XCTAssertTrue(snapshot(providers: ["admin"], expiry: nil).isResolved)
        XCTAssertTrue(MembershipSnapshot.freePreview.isResolved)
    }

    func testExpiredActiveResponseCannotOfferAnotherPurchase() async {
        let client = MembershipTestClient()
        client.result = .success(snapshot(expiry: .distantPast, purchase: true))
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        _ = await store.refresh()
        XCTAssertFalse(store.hasAccess)
        XCTAssertFalse(store.canPurchase, "An active server response must be refreshed to verified FREE before checkout.")
    }

    func testAuthoritativeRefreshSupersedesOlderFreeReadAfterPurchase() async throws {
        let client = MembershipTestClient()
        var olderRead: CheckedContinuation<MembershipSnapshot, Error>?
        let paid = snapshot()
        client.handler = {
            if client.requestCount == 1 {
                return try await withCheckedThrowingContinuation { olderRead = $0 }
            }
            return paid
        }
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        let old = Task { await store.refresh() }
        for _ in 0..<100 where olderRead == nil { await Task.yield() }
        let continuation = try XCTUnwrap(olderRead)
        let fresh = await store.refresh(force: true)
        XCTAssertTrue(fresh)
        XCTAssertTrue(store.hasAccess)
        continuation.resume(returning: .freePreview)
        let refreshedOldCaller = await old.value
        XCTAssertTrue(refreshedOldCaller, "The caller observes the newer successful refresh, never its stale response.")
        XCTAssertTrue(store.hasAccess)
        XCTAssertEqual(client.requestCount, 2)
        XCTAssertFalse(store.isLoading)
    }

    func testRevocationSignalSupersedesOlderActiveRead() async throws {
        let client = MembershipTestClient()
        var olderRead: CheckedContinuation<MembershipSnapshot, Error>?
        client.handler = {
            if client.requestCount == 1 {
                return try await withCheckedThrowingContinuation { olderRead = $0 }
            }
            return .freePreview
        }
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        let old = Task { await store.refresh() }
        for _ in 0..<100 where olderRead == nil { await Task.yield() }
        let continuation = try XCTUnwrap(olderRead)
        _ = await store.refresh(force: true)
        continuation.resume(returning: snapshot())
        _ = await old.value
        XCTAssertFalse(store.hasAccess)
        XCTAssertEqual(store.snapshot, .freePreview)
        XCTAssertNil(store.unlockPresentationID)
    }

    func testOverlappingAuthoritativeRefreshesJoinNewestReadWithoutFalseFailure() async throws {
        let client = MembershipTestClient()
        var reads: [CheckedContinuation<MembershipSnapshot, Error>] = []
        client.handler = { try await withCheckedThrowingContinuation { reads.append($0) } }
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        let transactionRefresh = Task { await store.refresh(force: true) }
        for _ in 0..<100 where reads.count < 1 { await Task.yield() }
        XCTAssertEqual(reads.count, 1)
        let signalRefresh = Task { await store.refresh(force: true) }
        for _ in 0..<100 where reads.count < 2 { await Task.yield() }
        guard reads.count == 2 else { XCTFail("The signal must start a new read."); return }
        reads[0].resume(throwing: CancellationError())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(store.isLoading)
        reads[1].resume(returning: snapshot())
        let transactionResult = await transactionRefresh.value
        let signalResult = await signalRefresh.value
        XCTAssertTrue(transactionResult)
        XCTAssertTrue(signalResult)
        XCTAssertTrue(store.hasAccess)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(client.requestCount, 2)
    }

    func testExpiryInvalidatesObservedAccessWithoutWaitingForNetworkPoll() async throws {
        var clock = now
        let expires = now.addingTimeInterval(5)
        var expiryWait: CheckedContinuation<Void, Error>?
        let client = MembershipTestClient()
        client.result = .success(snapshot(expiry: expires))
        let store = MembershipStore(client: client, now: { clock }, sleep: { _ in
            try await withCheckedThrowingContinuation { expiryWait = $0 }
        })
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        _ = await store.refresh()
        for _ in 0..<100 where expiryWait == nil { await Task.yield() }
        let continuation = try XCTUnwrap(expiryWait)
        let previousRevision = store.revision
        XCTAssertTrue(store.hasAccess)
        clock = expires
        continuation.resume()
        for _ in 0..<100 where store.revision == previousRevision { await Task.yield() }
        XCTAssertGreaterThan(store.revision, previousRevision)
        XCTAssertGreaterThanOrEqual(store.evaluationDate, expires)
        XCTAssertFalse(store.hasAccess)
        XCTAssertEqual(store.benefits, .free)
        XCTAssertEqual(client.requestCount, 1)
    }

    func testOldAccountExpiryCannotInvalidateNewAccountState() async throws {
        var expiryWait: CheckedContinuation<Void, Error>?
        let clock = now
        let client = MembershipTestClient()
        client.result = .success(snapshot(expiry: now.addingTimeInterval(5)))
        let store = MembershipStore(client: client, now: { clock }, sleep: { _ in
            try await withCheckedThrowingContinuation { expiryWait = $0 }
        })
        store.bind(MembershipScope(userID: "first", accessToken: "one"))
        _ = await store.refresh()
        for _ in 0..<100 where expiryWait == nil { await Task.yield() }
        let continuation = try XCTUnwrap(expiryWait)
        store.bind(MembershipScope(userID: "second", accessToken: "two"), preview: .universalPreview)
        let revision = store.revision
        continuation.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(store.hasAccess)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.evaluationDate, clock)
    }

    func testDecodeCurrentContractIncludingExplicitApplePurchaseFlag() throws {
        let data = Data(#"""
        {"active":false,"tier":"free","protocol":"limitless","status":"inactive","providers":[],"expires_at":null,"benefits":{"ai_generations_daily_limit":10,"premium_avatars":false,"full_history":false,"advanced_statistics":false,"history_limit":5},"apple_purchase_enabled":true}
        """#.utf8)
        let membership = try JSONDecoder().decode(MembershipSnapshot.self, from: data)
        XCTAssertEqual(membership.checkoutRequired, true)
        XCTAssertEqual(membership.benefits.historyLimit, 5)
        XCTAssertFalse(membership.grantsAccess())
    }

    func testExistingPremiumStyleIsPreservedButNewStyleNeedsAccess() {
        XCTAssertTrue(LimitlessProfilePolicy.allows("dossier", current: "dossier", freeValues: ["field"], hasAccess: false))
        XCTAssertFalse(LimitlessProfilePolicy.allows("blacksite", current: "dossier", freeValues: ["field"], hasAccess: false))
        XCTAssertTrue(LimitlessProfilePolicy.allows("field", current: "dossier", freeValues: ["field"], hasAccess: false))
        XCTAssertTrue(LimitlessProfilePolicy.freeAvatars.contains("🦅"))
        XCTAssertFalse(LimitlessProfilePolicy.freeAvatars.contains("🃏"))
    }

    func testUnknownStateAndOutageNeverOfferPurchase() async {
        let client = MembershipTestClient()
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.canPurchase)
        client.result = .failure(MembershipError.unavailable)
        let refreshed = await store.refresh()
        XCTAssertFalse(refreshed)
        XCTAssertFalse(store.canPurchase)
        XCTAssertNil(store.snapshot)
    }

    func testApplePurchaseRequiresExplicitServerFlagAndVerifiedFreeState() async {
        let client = MembershipTestClient()
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        client.result = .success(snapshot(active: false, tier: .free, status: "inactive", providers: [], expiry: nil, purchase: true))
        _ = await store.refresh()
        XCTAssertTrue(store.canPurchase)
        client.result = .failure(MembershipError.unavailable)
        _ = await store.refresh()
        XCTAssertFalse(store.canPurchase)
        XCTAssertNotNil(store.snapshot)
    }

    func testAccountSwitchDiscardsLateResultAndClearsAccessImmediately() async {
        let client = MembershipTestClient()
        client.suspend = true
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "first", accessToken: "first-token"))
        let refresh = Task { await store.refresh() }
        for _ in 0..<100 where client.continuation == nil { await Task.yield() }
        XCTAssertNotNil(client.continuation)
        store.bind(MembershipScope(userID: "second", accessToken: "second-token"))
        client.continuation?.resume(returning: snapshot())
        _ = await refresh.value
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.hasAccess)
        XCTAssertFalse(store.canPurchase)
        XCTAssertFalse(store.isLoading)
    }

    func testSameAccountTokenRotationAlsoInvalidatesCachedAccess() async {
        let client = MembershipTestClient()
        client.result = .success(snapshot())
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "old-token"))
        _ = await store.refresh()
        XCTAssertTrue(store.hasAccess)
        store.bind(MembershipScope(userID: "user", accessToken: "new-token"))
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.canPurchase)
    }

    func testGenerationUsageUpdatesSnapshotWithoutOverlappingAccessOrChangingEntitlement() {
        let cases: [(MembershipSnapshot, Bool)] = [
            (.freePreview, false),
            (.universalPreview, true),
            (snapshot(expiry: .distantFuture), true),
            (snapshot(expiry: .distantPast), false)
        ]
        for (initial, hasAccess) in cases {
            let store = MembershipStore(client: MembershipTestClient())
            store.bind(MembershipScope(userID: "generation-user", accessToken: "fixture-token"), preview: initial)
            var expected = initial
            expected.aiGenerationsToday = 4
            expected.aiRemaining = hasAccess ? nil : 6

            // This exact call previously trapped in Swift's exclusivity check
            // after a generated draft arrived, including in preview mode.
            store.updateAIUsage(used: 4, remaining: 6)

            XCTAssertEqual(store.snapshot, expected)
            XCTAssertEqual(store.hasAccess, hasAccess)
        }
    }

    func testGenerationUsageClampsNegativeCountersAndAcceptsAbsentCounters() {
        let store = MembershipStore(client: MembershipTestClient())
        store.bind(MembershipScope(userID: "free-user", accessToken: "fixture-token"), preview: .freePreview)
        store.updateAIUsage(used: -2, remaining: -3)
        XCTAssertEqual(store.snapshot?.aiGenerationsToday, 0)
        XCTAssertEqual(store.snapshot?.aiRemaining, 0)
        store.updateAIUsage(used: nil, remaining: nil)
        XCTAssertNil(store.snapshot?.aiGenerationsToday)
        XCTAssertNil(store.snapshot?.aiRemaining)
        XCTAssertFalse(store.hasAccess)
    }

    func testGenerationUsageCannotCreateAnUnverifiedMembershipSnapshot() {
        let store = MembershipStore(client: MembershipTestClient())
        store.bind(MembershipScope(userID: "unresolved-user", accessToken: "fixture-token"))
        store.updateAIUsage(used: 1, remaining: 9)
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.hasAccess)
    }

    func testRealtimeMustMatchBothEntityRoomAndAccount() {
        let rooms = ["entities:app:MembershipSignal"]
        let valid: [Any] = [["room": rooms[0], "data": #"{"type":"update","data":{"user_id":"user"}}"#]]
        XCTAssertTrue(MembershipRealtimeService.accepts(valid, rooms: rooms, userID: "user"))
        XCTAssertFalse(MembershipRealtimeService.accepts(valid, rooms: rooms, userID: "another"))
        XCTAssertFalse(MembershipRealtimeService.accepts(valid, rooms: ["wrong"], userID: "user"))
        XCTAssertFalse(MembershipRealtimeService.accepts([["room":rooms[0],"data":"{}"]], rooms: rooms, userID: "user"))
    }

    func testTransactionIsFinishedOnlyAfterExplicitCanonicalVerification() {
        let product = StoreKitManager.limitlessProductID
        let entitlement = AppStoreEntitlement(productID: product, status: "active", expiresAt: Date.distantFuture)
        XCTAssertTrue(AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: true, entitlement: entitlement).acceptsDelivery(for: product))
        XCTAssertFalse(AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: false, entitlement: entitlement).acceptsDelivery(for: product))
        XCTAssertFalse(AppStoreEntitlementSyncResponse(success: false, serverStatusVerified: true, entitlement: entitlement).acceptsDelivery(for: product))
        XCTAssertFalse(AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: true, entitlement: entitlement).acceptsDelivery(for: "different-product"))
        let revoked = AppStoreEntitlement(productID: product, status: "revoked", expiresAt: .distantPast)
        XCTAssertTrue(AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: true, entitlement: revoked).acceptsDelivery(for: product))
        XCTAssertFalse(revoked.grantsAccess)
    }

    func testPendingApprovalClearsOnlyAfterVerifiedActiveUpdateAndRefresh() {
        XCTAssertFalse(LimitlessPurchaseState.pending.canStartPurchase)
        XCTAssertFalse(LimitlessPurchaseState.purchasing.canStartPurchase)
        XCTAssertTrue(LimitlessPurchaseState.cancelled.canStartPurchase)
        XCTAssertTrue(LimitlessPurchaseState.failed.canStartPurchase)
        XCTAssertEqual(LimitlessPurchaseState.pending.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .purchased)
        XCTAssertEqual(LimitlessPurchaseState.pending.afterVerifiedUpdate(grantsAccess: false, membershipRefreshed: true), .pending)
        XCTAssertEqual(LimitlessPurchaseState.pending.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: false), .pending)
        XCTAssertEqual(LimitlessPurchaseState.restoring.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .restoring)
        XCTAssertEqual(LimitlessPurchaseState.idle.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .idle)
        XCTAssertEqual(LimitlessPurchaseState.failed.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .restored)
        XCTAssertEqual(LimitlessPurchaseState.failed.afterVerifiedUpdate(grantsAccess: false, membershipRefreshed: true), .idle)
        XCTAssertEqual(LimitlessPurchaseState.failed.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: false), .failed)
    }

    func testRestoreReconcilesChangedSignedPayloadAndRemovesRevokedAccess() {
        var restore = AppStoreTransactionReconciliation()
        XCTAssertEqual(restore.activeCount, 0)
        restore.record(signedPayload: "transaction-42-active", originalID: 42, grantsAccess: true)
        XCTAssertTrue(restore.contains("transaction-42-active"))
        XCTAssertFalse(restore.contains("transaction-42-revoked"), "A newer signed representation of the same transaction must reach the verifier.")
        restore.record(signedPayload: "transaction-42-revoked", originalID: 42, grantsAccess: false)
        XCTAssertEqual(restore.activeCount, 0)
        restore.record(signedPayload: "transaction-43-active", originalID: 42, grantsAccess: true)
        restore.record(signedPayload: "transaction-44-active", originalID: 42, grantsAccess: true)
        XCTAssertEqual(restore.activeCount, 1, "Renewals belong to one original subscription.")
        restore.record(signedPayload: "transaction-44-expired", originalID: 42, grantsAccess: false)
        XCTAssertEqual(restore.activeCount, 0)
    }

    func testSimultaneousTransactionDeliveriesAreCoalescedAndFinishedOnce() async throws {
        let client = AppStoreDeliveryTestClient()
        var pending: CheckedContinuation<AppStoreEntitlementSyncResponse, Error>?
        client.handler = { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let delivery = AppStoreTransactionDeliveryStore(client: client)
        delivery.bind(MembershipScope(userID: "user", accessToken: "token"))
        var finishes = 0
        let first = Task { try await delivery.deliver(signedTransaction: "signed-fixture", productID: StoreKitManager.limitlessProductID, finish: { finishes += 1 }) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        let duplicate = Task { try await delivery.deliver(signedTransaction: "signed-fixture", productID: StoreKitManager.limitlessProductID, finish: { finishes += 1 }) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(finishes, 0)
        continuation.resume(returning: client.verifiedResponse)
        _ = try await first.value
        _ = try await duplicate.value
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(finishes, 1)
    }

    func testFailedCanonicalDeliveryRemainsUnfinishedAndCanRetry() async throws {
        let client = AppStoreDeliveryTestClient()
        client.handler = { _ in throw MembershipError.unavailable }
        let delivery = AppStoreTransactionDeliveryStore(client: client)
        delivery.bind(MembershipScope(userID: "user", accessToken: "token"))
        var finishes = 0
        do {
            _ = try await delivery.deliver(signedTransaction: "retry-fixture", productID: StoreKitManager.limitlessProductID, finish: { finishes += 1 })
            XCTFail("An unavailable verifier must not acknowledge the transaction.")
        } catch {}
        XCTAssertEqual(finishes, 0)
        client.handler = nil
        _ = try await delivery.deliver(signedTransaction: "retry-fixture", productID: StoreKitManager.limitlessProductID, finish: { finishes += 1 })
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testUnverifiedServerResponseNeverFinishesTransaction() async {
        let client = AppStoreDeliveryTestClient()
        client.handler = { _ in
            AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: false, entitlement: client.verifiedResponse.entitlement)
        }
        let delivery = AppStoreTransactionDeliveryStore(client: client)
        delivery.bind(MembershipScope(userID: "user", accessToken: "token"))
        var finished = false
        do {
            _ = try await delivery.deliver(signedTransaction: "unconfirmed-fixture", productID: StoreKitManager.limitlessProductID, finish: { finished = true })
            XCTFail("A success flag alone is insufficient.")
        } catch {}
        XCTAssertFalse(finished)
    }

    func testAccountRotationRejectsLateTransactionBeforeFinish() async throws {
        let client = AppStoreDeliveryTestClient()
        var pending: CheckedContinuation<AppStoreEntitlementSyncResponse, Error>?
        client.handler = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let delivery = AppStoreTransactionDeliveryStore(client: client)
        delivery.bind(MembershipScope(userID: "first", accessToken: "token"))
        var finished = false
        let old = Task { try await delivery.deliver(signedTransaction: "old-account-fixture", productID: StoreKitManager.limitlessProductID, finish: { finished = true }) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        client.currentAccessToken = "new-token"
        delivery.bind(MembershipScope(userID: "second", accessToken: "new-token"))
        continuation.resume(returning: client.verifiedResponse)
        do { _ = try await old.value; XCTFail("The old account must not receive a completed delivery.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(finished)
    }

    func testVerifiedRevocationIsFinishedWithoutGrantingAccess() async throws {
        let client = AppStoreDeliveryTestClient()
        client.handler = { _ in
            AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: true, entitlement: AppStoreEntitlement(productID: StoreKitManager.limitlessProductID, status: "revoked", expiresAt: .distantPast))
        }
        let delivery = AppStoreTransactionDeliveryStore(client: client)
        delivery.bind(MembershipScope(userID: "user", accessToken: "token"))
        var finished = false
        let response = try await delivery.deliver(signedTransaction: "revoked-fixture", productID: StoreKitManager.limitlessProductID, finish: { finished = true })
        XCTAssertTrue(finished)
        XCTAssertFalse(response.entitlement.grantsAccess)
    }

    func testRestoredBenefitsMatchHistoricalFreeAndLimitlessLimits() {
        XCTAssertEqual(MembershipBenefits.free.aiGenerationsDailyLimit, 10)
        XCTAssertEqual(MembershipBenefits.free.historyLimit, 5)
        XCTAssertFalse(MembershipBenefits.free.premiumAvatars)
        XCTAssertFalse(MembershipBenefits.free.fullHistory)
        XCTAssertFalse(MembershipBenefits.free.advancedStatistics)
        XCTAssertNil(MembershipBenefits.limitless.aiGenerationsDailyLimit)
        XCTAssertNil(MembershipBenefits.limitless.historyLimit)
        XCTAssertTrue(MembershipBenefits.limitless.premiumAvatars)
        XCTAssertTrue(MembershipBenefits.limitless.fullHistory)
        XCTAssertTrue(MembershipBenefits.limitless.advancedStatistics)
    }

    func testHistoricalPrimaryButtonNeverTreatsPreviewOrPendingAsPurchase() {
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: true, hasAccess: false, isBusy: false, isPending: false, accessIsUnknown: false, canPurchase: true, hasProduct: true, storeCanPurchase: true), .preview)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: false, isPending: true, accessIsUnknown: false, canPurchase: true, hasProduct: true, storeCanPurchase: true), .waiting)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: true, isPending: false, accessIsUnknown: false, canPurchase: true, hasProduct: true, storeCanPurchase: true), .waiting)
    }

    func testHistoricalPrimaryButtonPreservesCurrentVerificationGates() {
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: true, isBusy: false, isPending: false, accessIsUnknown: false, canPurchase: true, hasProduct: true, storeCanPurchase: true), .refresh)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: false, isPending: false, accessIsUnknown: true, canPurchase: true, hasProduct: true, storeCanPurchase: true), .refresh)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: false, isPending: false, accessIsUnknown: false, canPurchase: false, hasProduct: true, storeCanPurchase: true), .unavailable)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: false, isPending: false, accessIsUnknown: false, canPurchase: true, hasProduct: false, storeCanPurchase: false), .loadProduct)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: false, isPending: false, accessIsUnknown: false, canPurchase: true, hasProduct: true, storeCanPurchase: false), .unavailable)
        XCTAssertEqual(LimitlessPrimaryAction.resolve(isPreview: false, hasAccess: false, isBusy: false, isPending: false, accessIsUnknown: false, canPurchase: true, hasProduct: true, storeCanPurchase: true), .purchase)
    }

    func testHistoricalCapabilitiesKeepStableOrderAndOriginalRussianCopy() {
        let copy = LimitlessCopy(language: .ru)
        XCTAssertEqual(copy.features.map(\.id), ["unlimited", "profile_customization", "game_statistics"])
        XCTAssertEqual(copy.features.map(\.title), ["Безлимит", "Кастомизация профиля", "Статистика игр"])
        XCTAssertEqual(copy.historicalSubscribe, "ОФОРМИТЬ ПОДПИСКУ")
        XCTAssertEqual(copy.features[0].detail, "Неограниченная AI-генерация тем и слов для каждой новой миссии.")
    }

    func testUnlockPresentationRequiresVerifiedTransitionAndFeedbackIsOnce() async throws {
        let client = MembershipTestClient()
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        _ = await store.refresh()
        XCTAssertNil(store.unlockPresentationID)
        client.result = .failure(MembershipError.unavailable)
        _ = await store.refresh()
        XCTAssertNil(store.unlockPresentationID)
        client.result = .success(snapshot())
        _ = await store.refresh()
        let id = try XCTUnwrap(store.unlockPresentationID)
        XCTAssertTrue(store.claimUnlockFeedback(id))
        XCTAssertFalse(store.claimUnlockFeedback(id))
        _ = await store.refresh()
        XCTAssertEqual(store.unlockPresentationID, id)
        store.dismissUnlock(UUID())
        XCTAssertEqual(store.unlockPresentationID, id)
        store.dismissUnlock(id)
        _ = await store.refresh()
        XCTAssertNil(store.unlockPresentationID)
    }

    func testInitialPaidStateAndUniversalAccessDoNotCelebratePurchase() async {
        let client = MembershipTestClient()
        client.result = .success(snapshot())
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        _ = await store.refresh()
        XCTAssertNil(store.unlockPresentationID)
        client.result = .success(.freePreview)
        _ = await store.refresh()
        client.result = .success(.universalPreview)
        _ = await store.refresh()
        XCTAssertNil(store.unlockPresentationID)
    }

    func testAccountRotationAndRevocationClearUnlockPresentation() async {
        let client = MembershipTestClient()
        let store = MembershipStore(client: client)
        store.bind(MembershipScope(userID: "user", accessToken: "token"))
        _ = await store.refresh()
        client.result = .success(snapshot())
        _ = await store.refresh()
        XCTAssertNotNil(store.unlockPresentationID)
        client.result = .success(.freePreview)
        _ = await store.refresh()
        XCTAssertNil(store.unlockPresentationID)
        client.result = .success(snapshot())
        _ = await store.refresh()
        XCTAssertNotNil(store.unlockPresentationID)
        store.bind(MembershipScope(userID: "user", accessToken: "rotated"))
        XCTAssertNil(store.unlockPresentationID)
    }
}

@MainActor
private final class MembershipTestClient: MembershipClientProtocol {
    var result: Result<MembershipSnapshot, Error> = .success(.freePreview)
    var suspend = false
    var continuation: CheckedContinuation<MembershipSnapshot, Error>?
    var requestCount = 0
    var handler: (() async throws -> MembershipSnapshot)?
    func checkSubscription() async throws -> MembershipSnapshot {
        requestCount += 1
        if let handler { return try await handler() }
        if suspend {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return try result.get()
    }
}

@MainActor
private final class AppStoreDeliveryTestClient: AppStoreTransactionClient {
    var currentAccessToken: String? = "token"
    var requests: [String] = []
    var handler: ((String) async throws -> AppStoreEntitlementSyncResponse)?
    var verifiedResponse: AppStoreEntitlementSyncResponse {
        AppStoreEntitlementSyncResponse(success: true, serverStatusVerified: true, entitlement: AppStoreEntitlement(productID: StoreKitManager.limitlessProductID, status: "active", expiresAt: .distantFuture))
    }
    func syncAppStoreTransaction(signedTransaction: String) async throws -> AppStoreEntitlementSyncResponse {
        requests.append(signedTransaction)
        if let handler { return try await handler(signedTransaction) }
        return verifiedResponse
    }
}
