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
