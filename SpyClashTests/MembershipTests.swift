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
        XCTAssertTrue(MembershipSnapshot.freePreview.isResolved)
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
        XCTAssertEqual(LimitlessPurchaseState.pending.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .purchased)
        XCTAssertEqual(LimitlessPurchaseState.pending.afterVerifiedUpdate(grantsAccess: false, membershipRefreshed: true), .pending)
        XCTAssertEqual(LimitlessPurchaseState.pending.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: false), .pending)
        XCTAssertEqual(LimitlessPurchaseState.restoring.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .restoring)
        XCTAssertEqual(LimitlessPurchaseState.idle.afterVerifiedUpdate(grantsAccess: true, membershipRefreshed: true), .idle)
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
    func checkSubscription() async throws -> MembershipSnapshot {
        if suspend {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return try result.get()
    }
}
