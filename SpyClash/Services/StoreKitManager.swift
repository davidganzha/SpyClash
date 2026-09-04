import Foundation
import Observation
import StoreKit
import UIKit

struct AppStorePurchaseContext: Decodable {
    let productID: String
    let appAccountToken: UUID
    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case appAccountToken = "app_account_token"
    }
}

struct AppStoreEntitlementSyncResponse: Decodable {
    let success: Bool
    let serverStatusVerified: Bool
    let entitlement: AppStoreEntitlement
    enum CodingKeys: String, CodingKey {
        case success, entitlement
        case serverStatusVerified = "server_status_verified"
    }
    func acceptsDelivery(for productID: String) -> Bool {
        success && serverStatusVerified && entitlement.productID == productID
    }
}

struct AppStoreEntitlement: Decodable {
    let productID: String
    let status: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case status
        case productID = "product_id"
        case expiresAt = "expires_at"
    }
    var grantsAccess: Bool {
        ["active", "trialing", "grace_period"].contains(status) && expiresAt > Date()
    }
}

enum LimitlessPurchaseState: Equatable {
    case idle, preparing, purchasing, synchronizing, restoring, pending, purchased, restored, noPurchases, cancelled
    case failed
    var isBusy: Bool { [.preparing, .purchasing, .synchronizing, .restoring].contains(self) }

    func afterVerifiedUpdate(grantsAccess: Bool, membershipRefreshed: Bool) -> Self {
        self == .pending && grantsAccess && membershipRefreshed ? .purchased : self
    }
}

@MainActor
@Observable
final class StoreKitManager {
    static let limitlessProductID = "com.spyclash.ios.limitless.weekly"
    private(set) var product: Product?
    private(set) var isLoadingProduct = false
    private(set) var state: LimitlessPurchaseState = .idle
    private(set) var errorMessage: String?
    @ObservationIgnored private let client: Base44Client
    @ObservationIgnored private var scope = MembershipScope(userID: nil, accessToken: nil)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var syncGeneration: Int?
    @ObservationIgnored private var deliveries: [String: Task<AppStoreEntitlementSyncResponse, Error>] = [:]
    @ObservationIgnored var onEntitlementChanged: (() async -> Bool)?

    init(client: Base44Client) {
        self.client = client
        // Listen from application launch, including pending purchases completed later.
        updatesTask = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.scope.isAuthenticated,
                      verification.unsafePayloadValue.productID == Self.limitlessProductID else { continue }
                let expected = self.generation
                do {
                    let response = try await self.persist(verification, generation: expected)
                    try self.requireScope(expected)
                    let refreshed = await self.onEntitlementChanged?() == true
                    try self.requireScope(expected)
                    self.state = self.state.afterVerifiedUpdate(
                        grantsAccess: response.entitlement.grantsAccess,
                        membershipRefreshed: refreshed
                    )
                } catch is CancellationError {
                    // Account rotation must not permanently stop the global listener.
                    continue
                } catch {
                    guard expected == self.generation else { continue }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func bind(_ scope: MembershipScope) {
        guard self.scope != scope else { return }
        generation &+= 1
        deliveries.values.forEach { $0.cancel() }
        deliveries.removeAll()
        self.scope = scope
        state = .idle
        errorMessage = nil
        syncGeneration = nil
    }

    var canPurchase: Bool {
        scope.isAuthenticated && product != nil && AppStore.canMakePayments && !state.isBusy
    }

    func loadProduct() async {
        guard product == nil, !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            product = try await Product.products(for: [Self.limitlessProductID])
                .first {
                    $0.id == Self.limitlessProductID && $0.type == .autoRenewable &&
                    $0.subscription?.subscriptionPeriod.unit == .week &&
                    $0.subscription?.subscriptionPeriod.value == 1
                }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func purchase(membership: MembershipStore) async {
        guard !state.isBusy else { return }
        let expected = generation
        state = .preparing
        errorMessage = nil
        do {
            guard await membership.refresh(), membership.canPurchase else {
                throw MembershipError.unavailable
            }
            try requireScope(expected)
            await loadProduct()
            try requireScope(expected)
            guard let product, AppStore.canMakePayments else { throw MembershipError.unavailable }
            let context = try await client.prepareAppStorePurchase()
            try requireScope(expected)
            guard context.productID == Self.limitlessProductID else { throw MembershipError.verificationFailed }
            state = .purchasing
            let result = try await product.purchase(options: [.appAccountToken(context.appAccountToken)])
            try requireScope(expected)
            switch result {
            case .success(let verification):
                state = .synchronizing
                let response = try await persist(verification, generation: expected)
                try requireScope(expected)
                guard response.entitlement.grantsAccess else { throw MembershipError.verificationFailed }
                guard await membership.refresh(), membership.hasAccess else { throw MembershipError.unavailable }
                try requireScope(expected)
                state = .purchased
            case .pending:
                state = .pending
            case .userCancelled:
                state = .cancelled
            @unknown default:
                throw MembershipError.verificationFailed
            }
        } catch {
            fail(error, generation: expected)
        }
    }

    func restore() async {
        guard !state.isBusy, scope.isAuthenticated else { return }
        let expected = generation
        state = .restoring
        errorMessage = nil
        do {
            // Only the user's Restore button may trigger Apple's authentication prompt.
            try await AppStore.sync()
            try requireScope(expected)
            let count = try await synchronize(expected)
            try requireScope(expected)
            if await onEntitlementChanged?() == false { throw MembershipError.unavailable }
            try requireScope(expected)
            state = count > 0 ? .restored : .noPurchases
        } catch {
            fail(error, generation: expected)
        }
    }

    func synchronizeAfterActivation() async {
        guard scope.isAuthenticated, !state.isBusy, syncGeneration == nil else { return }
        let expected = generation
        syncGeneration = expected
        defer { if syncGeneration == expected { syncGeneration = nil } }
        do {
            _ = try await synchronize(expected)
            try requireScope(expected)
            _ = await onEntitlementChanged?()
        } catch {
            // Leave transactions unfinished on outages. Retried on activation/Restore.
            if expected == generation, !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func synchronize(_ expected: Int) async throws -> Int {
        var seen = Set<UInt64>()
        var active = Set<UInt64>()
        for await result in Transaction.unfinished {
            try requireScope(expected)
            guard result.unsafePayloadValue.productID == Self.limitlessProductID else { continue }
            let response = try await persist(result, generation: expected)
            if response.entitlement.grantsAccess { active.insert(result.unsafePayloadValue.originalID) }
            seen.insert(result.unsafePayloadValue.id)
        }
        for await result in Transaction.currentEntitlements {
            try requireScope(expected)
            guard result.unsafePayloadValue.productID == Self.limitlessProductID else { continue }
            let response = try await persist(result, generation: expected)
            seen.insert(result.unsafePayloadValue.id)
            if response.entitlement.grantsAccess { active.insert(result.unsafePayloadValue.originalID) }
            else { active.remove(result.unsafePayloadValue.originalID) }
        }
        // Refunded/expired purchases disappear from currentEntitlements but their
        // latest signed transaction must still reach the canonical server verifier.
        if let latest = await Transaction.latest(for: Self.limitlessProductID),
           !seen.contains(latest.unsafePayloadValue.id) {
            let response = try await persist(latest, generation: expected)
            if response.entitlement.grantsAccess { active.insert(latest.unsafePayloadValue.originalID) }
            else { active.remove(latest.unsafePayloadValue.originalID) }
        }
        return active.count
    }

    private func persist(_ result: VerificationResult<Transaction>, generation expected: Int) async throws -> AppStoreEntitlementSyncResponse {
        try requireScope(expected)
        guard case .verified(let transaction) = result,
              transaction.productID == Self.limitlessProductID else { throw MembershipError.verificationFailed }
        // The same transaction may arrive through purchase() and updates together.
        // Coalesce only identical signed deliveries within the same account scope.
        let deliveryKey = "\(expected):\(result.jwsRepresentation)"
        if let existing = deliveries[deliveryKey] { return try await existing.value }
        let task = Task {
            let response = try await client.syncAppStoreTransaction(signedTransaction: result.jwsRepresentation)
            try requireScope(expected)
            guard response.acceptsDelivery(for: transaction.productID) else { throw MembershipError.verificationFailed }
            // Also finish revoked transactions after persisted revocation.
            // Never acknowledge unverified or failed deliveries.
            await transaction.finish()
            try requireScope(expected)
            return response
        }
        deliveries[deliveryKey] = task
        defer { deliveries.removeValue(forKey: deliveryKey) }
        return try await task.value
    }

    func manageSubscriptions() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { throw MembershipError.unavailable }
        try await AppStore.showManageSubscriptions(in: scene)
    }

    private func requireScope(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation, scope.isAuthenticated,
              scope.accessToken == client.currentAccessToken else { throw CancellationError() }
    }

    private func fail(_ error: Error, generation expected: Int) {
        guard expected == generation else { return }
        if error is CancellationError { state = .cancelled; return }
        errorMessage = error.localizedDescription
        state = .failed
    }
}
