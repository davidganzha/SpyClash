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
        case success
        case serverStatusVerified = "server_status_verified"
        case entitlement
    }
}

struct AppStoreEntitlement: Decodable {
    let provider: String
    let productID: String
    let status: String
    let expiresAt: Date
    let environment: String

    enum CodingKeys: String, CodingKey {
        case provider
        case productID = "product_id"
        case status
        case expiresAt = "expires_at"
        case environment
    }

    var grantsAccess: Bool {
        ["active", "trialing", "grace_period"].contains(status) && expiresAt > Date()
    }
}

enum StoreKitProductState: Equatable {
    case idle
    case loading
    case ready
    case unavailable(message: String)
}

enum StoreKitPurchaseState: Equatable {
    case idle
    case preparing
    case purchasing
    case pending
    case synchronizing
    case restoring
    case purchased
    case restored
    case cancelled
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .preparing, .purchasing, .synchronizing, .restoring:
            true
        default:
            false
        }
    }
}

enum StoreKitActionOutcome: Equatable {
    case purchased
    case pending
    case cancelled
    case restored(count: Int)
    case noPurchases
    case failed(message: String)
}

private enum StoreKitManagerError: LocalizedError {
    case authenticationRequired
    case productUnavailable
    case productMismatch
    case unverifiedTransaction
    case entitlementNotGranted
    case noWindowScene

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Sign in to your SpyClash account before purchasing."
        case .productUnavailable:
            "LIMITLESS is not available from the App Store right now."
        case .productMismatch:
            "The App Store returned an unexpected subscription product."
        case .unverifiedTransaction:
            "The App Store transaction could not be verified."
        case .entitlementNotGranted:
            "The purchase was verified, but LIMITLESS access is not active."
        case .noWindowScene:
            "The App Store subscription manager is unavailable right now."
        }
    }
}

@MainActor
@Observable
final class StoreKitManager {
    static let limitlessProductID = "com.spyclash.ios.limitless.weekly"

    private(set) var product: Product?
    private(set) var productState: StoreKitProductState = .idle
    private(set) var purchaseState: StoreKitPurchaseState = .idle
    private(set) var isSynchronizingEntitlements = false
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let client: Base44Client
    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored var onEntitlementChanged: (() async -> Void)?

    init(client: Base44Client) {
        self.client = client
        transactionUpdatesTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    var displayPrice: String? {
        product?.displayPrice
    }

    var canPurchase: Bool {
        product != nil && AppStore.canMakePayments && !purchaseState.isBusy
    }

    func accountDidChange() {
        purchaseState = .idle
        lastErrorMessage = nil
    }

    func loadProduct(force: Bool = false) async {
        if !force, product != nil { return }
        productState = .loading
        lastErrorMessage = nil

        do {
            let products = try await Product.products(for: [Self.limitlessProductID])
            guard let product = products.first(where: { $0.id == Self.limitlessProductID }),
                  product.type == .autoRenewable else {
                throw StoreKitManagerError.productUnavailable
            }
            self.product = product
            productState = .ready
        } catch is CancellationError {
            productState = product == nil ? .idle : .ready
        } catch {
            let message = error.localizedDescription
            productState = .unavailable(message: message)
            lastErrorMessage = message
        }
    }

    func purchaseLimitless() async -> StoreKitActionOutcome {
        guard client.hasSessionToken else {
            return fail(StoreKitManagerError.authenticationRequired)
        }
        purchaseState = .preparing
        lastErrorMessage = nil
        if product == nil {
            await loadProduct()
        }
        guard let product else {
            return fail(StoreKitManagerError.productUnavailable)
        }

        do {
            let context = try await client.prepareAppStorePurchase()
            guard context.productID == Self.limitlessProductID else {
                throw StoreKitManagerError.productMismatch
            }

            purchaseState = .purchasing
            let result = try await product.purchase(options: [
                .appAccountToken(context.appAccountToken)
            ])
            switch result {
            case .success(let verification):
                purchaseState = .synchronizing
                let response = try await persist(verification)
                guard response.entitlement.grantsAccess else {
                    throw StoreKitManagerError.entitlementNotGranted
                }
                purchaseState = .purchased
                await onEntitlementChanged?()
                return .purchased
            case .pending:
                purchaseState = .pending
                return .pending
            case .userCancelled:
                purchaseState = .cancelled
                return .cancelled
            @unknown default:
                throw StoreKitManagerError.unverifiedTransaction
            }
        } catch is CancellationError {
            purchaseState = .idle
            return .cancelled
        } catch {
            return fail(error)
        }
    }

    func restorePurchases() async -> StoreKitActionOutcome {
        guard client.hasSessionToken else {
            return fail(StoreKitManagerError.authenticationRequired)
        }

        purchaseState = .restoring
        lastErrorMessage = nil
        do {
            // Apple can present an App Store authentication prompt here, so
            // this method is called only from the explicit Restore button.
            try await AppStore.sync()
            let count = try await synchronizeStoreKitState()
            guard count > 0 else {
                purchaseState = .idle
                return .noPurchases
            }
            purchaseState = .restored
            await onEntitlementChanged?()
            return .restored(count: count)
        } catch is CancellationError {
            purchaseState = .idle
            return .cancelled
        } catch {
            return fail(error)
        }
    }

    @discardableResult
    func synchronizeStoreKitState() async throws -> Int {
        guard client.hasSessionToken else { return 0 }
        isSynchronizingEntitlements = true
        defer { isSynchronizingEntitlements = false }

        var synchronizedTransactionIDs = Set<UInt64>()
        // Transactions delivered while signed out remain unfinished. Bind and
        // acknowledge them only after a SpyClash account is authenticated.
        for await verification in Transaction.unfinished {
            try Task.checkCancellation()
            let transaction = verification.unsafePayloadValue
            guard transaction.productID == Self.limitlessProductID else {
                continue
            }
            try await persist(verification)
            synchronizedTransactionIDs.insert(transaction.id)
        }

        // Restore success is based only on Apple's current entitlements. An
        // expired, refunded, or revoked latest transaction must still be synced
        // below, but it must not be reported to the user as a restored purchase.
        var activeOriginalTransactionIDs = Set<UInt64>()
        for await verification in Transaction.currentEntitlements {
            try Task.checkCancellation()
            let transaction = verification.unsafePayloadValue
            guard transaction.productID == Self.limitlessProductID else {
                continue
            }
            let response = try await persist(verification)
            synchronizedTransactionIDs.insert(transaction.id)
            if response.entitlement.grantsAccess {
                activeOriginalTransactionIDs.insert(transaction.originalID)
            }
        }

        // currentEntitlements intentionally omits inactive/refunded access.
        // The latest signed transaction lets the backend persist that loss of
        // access after a missed foreground update, with Notifications V2 as the
        // independent server-to-server source of truth.
        if let latest = await Transaction.latest(for: Self.limitlessProductID) {
            try Task.checkCancellation()
            let transaction = latest.unsafePayloadValue
            if !synchronizedTransactionIDs.contains(transaction.id) {
                try await persist(latest)
            }
        }
        return activeOriginalTransactionIDs.count
    }

    func showManageSubscriptions() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw StoreKitManagerError.noWindowScene
        }
        try await AppStore.showManageSubscriptions(in: scene)
    }

    private func observeTransactionUpdates() async {
        for await verification in Transaction.updates {
            guard !Task.isCancelled else { return }
            guard verification.unsafePayloadValue.productID == Self.limitlessProductID,
                  client.hasSessionToken else {
                // Signed-out updates remain unfinished and are reconciled by
                // synchronizeStoreKitState() on the next authenticated session.
                continue
            }

            do {
                try await persist(verification)
                await onEntitlementChanged?()
            } catch is CancellationError {
                return
            } catch {
                // Do not finish on failure. StoreKit can redeliver this
                // transaction after Base44 or the network recovers.
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func persist(
        _ verification: VerificationResult<Transaction>
    ) async throws -> AppStoreEntitlementSyncResponse {
        guard case .verified(let transaction) = verification else {
            throw StoreKitManagerError.unverifiedTransaction
        }
        guard transaction.productID == Self.limitlessProductID else {
            throw StoreKitManagerError.productMismatch
        }

        let response = try await client.syncAppStoreTransaction(
            signedTransaction: verification.jwsRepresentation
        )
        guard response.success else {
            throw StoreKitManagerError.entitlementNotGranted
        }
        // A revoked or expired transaction still needs to be acknowledged once
        // the backend has persisted the loss of access. Purchase completion
        // separately requires a granting entitlement above.
        await transaction.finish()
        return response
    }

    private func fail(_ error: Error) -> StoreKitActionOutcome {
        let message = error.localizedDescription
        lastErrorMessage = message
        purchaseState = .failed(message: message)
        return .failed(message: message)
    }
}
