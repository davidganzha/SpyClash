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
    var canStartPurchase: Bool { !isBusy && self != .pending }

    func acceptsVerifiedBackgroundUpdate(operationMatches: Bool, grantsAccess: Bool) -> Bool {
        // An approval may arrive before purchase() returns .pending. Its verified
        // access can resolve pending, but never erase a newer failure or result.
        !isBusy && (operationMatches || (self == .pending && grantsAccess))
    }

    func afterVerifiedUpdate(grantsAccess: Bool, membershipRefreshed: Bool) -> Self {
        guard membershipRefreshed else { return self }
        if self == .pending && grantsAccess { return .purchased }
        if self == .failed { return grantsAccess ? .restored : .idle }
        return self
    }
}

@MainActor
protocol AppStoreTransactionClient: AnyObject {
    var currentAccessToken: String? { get }
    func syncAppStoreTransaction(signedTransaction: String) async throws -> AppStoreEntitlementSyncResponse
}

extension Base44Client: AppStoreTransactionClient {}

/// Acknowledges only canonically verified deliveries, scoped to the account that
/// submitted them. The native manager verifies StoreKit's signature first.
@MainActor
final class AppStoreTransactionDeliveryStore {
    private let client: any AppStoreTransactionClient
    private var scope = MembershipScope(userID: nil, accessToken: nil)
    private var generation = 0
    private var deliveries: [String: Task<AppStoreEntitlementSyncResponse, Error>] = [:]

    init(client: any AppStoreTransactionClient) { self.client = client }

    func bind(_ next: MembershipScope) {
        guard next != scope else { return }
        generation &+= 1
        deliveries.values.forEach { $0.cancel() }
        deliveries.removeAll()
        scope = next
    }

    func deliver(
        signedTransaction: String,
        productID: String,
        finish: @escaping @MainActor () async -> Void
    ) async throws -> AppStoreEntitlementSyncResponse {
        let expected = generation
        try requireScope(expected)
        guard productID == StoreKitManager.limitlessProductID else { throw MembershipError.verificationFailed }
        // A renewed/revoked representation of the same transaction ID must not
        // coalesce with an older signed payload.
        let key = "\(expected):\(signedTransaction)"
        if let existing = deliveries[key] {
            let response = try await existing.value
            try requireScope(expected)
            return response
        }
        let task = Task {
            let response = try await client.syncAppStoreTransaction(signedTransaction: signedTransaction)
            try requireScope(expected)
            guard response.acceptsDelivery(for: productID) else { throw MembershipError.verificationFailed }
            await finish()
            try requireScope(expected)
            return response
        }
        deliveries[key] = task
        defer { deliveries.removeValue(forKey: key) }
        let response = try await task.value
        try requireScope(expected)
        return response
    }

    private func requireScope(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation, scope.isAuthenticated,
              scope.accessToken == client.currentAccessToken else { throw CancellationError() }
    }
}

struct AppStoreTransactionReconciliation {
    private var deliveredPayloads = Set<String>()
    private var activeOriginalIDs = Set<UInt64>()
    var activeCount: Int { activeOriginalIDs.count }

    func contains(_ signedPayload: String) -> Bool { deliveredPayloads.contains(signedPayload) }

    mutating func record(signedPayload: String, originalID: UInt64, grantsAccess: Bool) {
        deliveredPayloads.insert(signedPayload)
        if grantsAccess { activeOriginalIDs.insert(originalID) }
        else { activeOriginalIDs.remove(originalID) }
    }
}

@MainActor
@Observable
final class StoreKitManager {
    static let limitlessProductID = "com.spyclash.ios.limitless.weekly"
    var product: Product? { productCatalog.product }
    var isLoadingProduct: Bool { productCatalog.isLoading }
    var productLoadIssue: StoreKitProductLoadIssue? { productCatalog.issue }
    @ObservationIgnored private let productCatalog: StoreKitProductCatalog<Product>
    private(set) var state: LimitlessPurchaseState = .idle
    private(set) var errorMessage: String?
    @ObservationIgnored private let client: Base44Client
    @ObservationIgnored private var scope = MembershipScope(userID: nil, accessToken: nil)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationRevision: UInt64 = 0
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var syncGeneration: Int?
    @ObservationIgnored private let deliveryStore: AppStoreTransactionDeliveryStore
    @ObservationIgnored private let syncAppStore: @MainActor () async throws -> Void
    @ObservationIgnored private let reconcileTransactions: (@MainActor () async throws -> Int)?
    @ObservationIgnored var onEntitlementChanged: (() async -> MembershipSnapshot?)?

    init(
        client: Base44Client,
        syncAppStore: @escaping @MainActor () async throws -> Void = { try await AppStore.sync() },
        reconcileTransactions: (@MainActor () async throws -> Int)? = nil
    ) {
        self.client = client
        self.deliveryStore = AppStoreTransactionDeliveryStore(client: client)
        self.syncAppStore = syncAppStore
        self.reconcileTransactions = reconcileTransactions
        self.productCatalog = StoreKitProductCatalog(productID: Self.limitlessProductID) {
            try await Product.products(for: [Self.limitlessProductID]).map {
                let period = $0.subscription?.subscriptionPeriod
                StoreKitCatalogDiagnostic.productMetadata(
                    idMatches: $0.id == Self.limitlessProductID,
                    autoRenewable: $0.type == .autoRenewable,
                    periodUnit: StoreKitCatalogPeriodUnit(period?.unit),
                    periodValue: period?.value
                ).log()
                return StoreKitCatalogItem(
                    id: $0.id,
                    isAutoRenewable: $0.type == .autoRenewable,
                    isWeekly: StoreKitWeeklyPeriod.matches(unit: period?.unit, value: period?.value),
                    value: $0
                )
            }
        }
        // Listen from application launch, including pending purchases completed later.
        updatesTask = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.scope.isAuthenticated,
                      verification.unsafePayloadValue.productID == Self.limitlessProductID else { continue }
                let expected = self.generation
                let operation = self.operationRevision
                do {
                    let response = try await self.persist(verification, generation: expected)
                    try self.requireScope(expected)
                    guard let refreshed = await self.onEntitlementChanged?() else { throw MembershipError.unavailable }
                    try self.requireScope(expected)
                    self.completeBackground(
                        grantsAccess: response.entitlement.grantsAccess && refreshed.grantsAccess(),
                        operation: operation
                    )
                } catch is CancellationError {
                    // Account rotation must not permanently stop the global listener.
                    continue
                } catch {
                    self.failBackground(error, generation: expected, operation: operation)
                }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func bind(_ scope: MembershipScope) {
        guard self.scope != scope else { return }
        generation &+= 1
        operationRevision &+= 1
        deliveryStore.bind(scope)
        self.scope = scope
        state = .idle
        errorMessage = nil
        syncGeneration = nil
    }

    var canPurchase: Bool {
        scope.isAuthenticated && product != nil && AppStore.canMakePayments && state.canStartPurchase
    }

    func loadProduct() async {
        await productCatalog.load()
    }

    func purchase(membership: MembershipStore) async {
        guard state.canStartPurchase else { return }
        let expected = generation
        let operation = beginOperation(.preparing)
        defer { endOperation(operation) }
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
                guard await membership.refresh(force: true), membership.hasAccess else { throw MembershipError.unavailable }
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
            fail(error, generation: expected, operation: operation)
        }
    }

    func restore() async {
        guard !state.isBusy, scope.isAuthenticated else { return }
        let expected = generation
        let operation = beginOperation(.restoring)
        defer { endOperation(operation) }
        do {
            // Only the user's Restore button may trigger Apple's authentication prompt.
            try await syncAppStore()
            try requireScope(expected)
            let count = try await synchronize(expected)
            try requireScope(expected)
            guard let refreshed = await onEntitlementChanged?(),
                  count == 0 || refreshed.grantsAccess() else { throw MembershipError.unavailable }
            try requireScope(expected)
            state = count > 0 ? .restored : .noPurchases
        } catch {
            fail(error, generation: expected, operation: operation)
        }
    }

    func synchronizeAfterActivation() async {
        guard scope.isAuthenticated, !state.isBusy, syncGeneration == nil else { return }
        let expected = generation
        let operation = operationRevision
        syncGeneration = expected
        defer { if syncGeneration == expected { syncGeneration = nil } }
        do {
            let count = try await synchronize(expected)
            try requireScope(expected)
            guard let refreshed = await onEntitlementChanged?() else { throw MembershipError.unavailable }
            try requireScope(expected)
            completeBackground(
                grantsAccess: count > 0 && refreshed.grantsAccess(),
                operation: operation
            )
        } catch {
            // Leave transactions unfinished on outages. Retried on activation/Restore.
            failBackground(error, generation: expected, operation: operation)
        }
    }

    private func synchronize(_ expected: Int) async throws -> Int {
        if let reconcileTransactions {
            try requireScope(expected)
            let count = try await reconcileTransactions()
            try requireScope(expected)
            return count
        }
        var reconciliation = AppStoreTransactionReconciliation()
        for await result in Transaction.unfinished {
            try requireScope(expected)
            guard result.unsafePayloadValue.productID == Self.limitlessProductID,
                  !reconciliation.contains(result.jwsRepresentation) else { continue }
            let response = try await persist(result, generation: expected)
            reconciliation.record(signedPayload: result.jwsRepresentation, originalID: result.unsafePayloadValue.originalID, grantsAccess: response.entitlement.grantsAccess)
        }
        for await result in Transaction.currentEntitlements {
            try requireScope(expected)
            guard result.unsafePayloadValue.productID == Self.limitlessProductID,
                  !reconciliation.contains(result.jwsRepresentation) else { continue }
            let response = try await persist(result, generation: expected)
            reconciliation.record(signedPayload: result.jwsRepresentation, originalID: result.unsafePayloadValue.originalID, grantsAccess: response.entitlement.grantsAccess)
        }
        // Refunded/expired purchases disappear from currentEntitlements but their
        // latest signed transaction must still reach the canonical server verifier.
        if let latest = await Transaction.latest(for: Self.limitlessProductID),
           !reconciliation.contains(latest.jwsRepresentation) {
            let response = try await persist(latest, generation: expected)
            reconciliation.record(signedPayload: latest.jwsRepresentation, originalID: latest.unsafePayloadValue.originalID, grantsAccess: response.entitlement.grantsAccess)
        }
        return reconciliation.activeCount
    }

    private func persist(_ result: VerificationResult<Transaction>, generation expected: Int) async throws -> AppStoreEntitlementSyncResponse {
        try requireScope(expected)
        guard case .verified(let transaction) = result,
              transaction.productID == Self.limitlessProductID else { throw MembershipError.verificationFailed }
        let response = try await deliveryStore.deliver(
            signedTransaction: result.jwsRepresentation,
            productID: transaction.productID,
            finish: { await transaction.finish() }
        )
        try requireScope(expected)
        return response
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

    private func beginOperation(_ next: LimitlessPurchaseState) -> UInt64 {
        operationRevision &+= 1
        state = next
        errorMessage = nil
        return operationRevision
    }

    private func endOperation(_ expected: UInt64) {
        // Also invalidate background work that began while the foreground
        // operation was running. Its entitlement delivery/refresh still completes.
        if operationRevision == expected { operationRevision &+= 1 }
    }

    private func ownsBackgroundResult(_ expected: UInt64) -> Bool {
        expected == operationRevision && !state.isBusy
    }

    private func completeBackground(grantsAccess: Bool, operation: UInt64) {
        guard state.acceptsVerifiedBackgroundUpdate(
            operationMatches: operation == operationRevision, grantsAccess: grantsAccess
        ) else { return }
        errorMessage = nil
        state = state.afterVerifiedUpdate(grantsAccess: grantsAccess, membershipRefreshed: true)
    }

    private func failBackground(_ error: Error, generation expected: Int, operation: UInt64) {
        guard expected == generation, ownsBackgroundResult(operation),
              !isCancellation(error) else { return }
        errorMessage = error.localizedDescription
        state = .failed
    }

    private func fail(_ error: Error, generation expected: Int, operation: UInt64) {
        guard expected == generation, operation == operationRevision else { return }
        if isCancellation(error) { state = .cancelled; return }
        errorMessage = error.localizedDescription
        state = .failed
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError { return true }
        return false
    }
}
