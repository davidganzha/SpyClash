import Foundation
import Observation
import OSLog
import StoreKit

enum StoreKitWeeklyPeriod {
    static func matches(unit: Product.SubscriptionPeriod.Unit?, value: Int?) -> Bool {
        (unit == .week && value == 1) || (unit == .day && value == 7)
    }
}

enum StoreKitCatalogPeriodUnit: String, Equatable, Sendable {
    case none, day, week, month, year, unknown

    init(_ unit: Product.SubscriptionPeriod.Unit?) {
        guard let unit else { self = .none; return }
        switch unit {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        case .year: self = .year
        @unknown default: self = .unknown
        }
    }
}

enum StoreKitProductLoadIssue: Equatable, Sendable {
    case notFound, unsupportedProduct, network, storeUnavailable, storefrontUnavailable
}

struct StoreKitCatalogItem<Value: Sendable>: Sendable {
    let id: String
    let isAutoRenewable: Bool
    let isWeekly: Bool
    let value: Value
}

enum StoreKitCatalogDiagnostic: Equatable, Sendable {
    case response(count: Int, contractMatched: Bool)
    case productMetadata(idMatches: Bool, autoRenewable: Bool, periodUnit: StoreKitCatalogPeriodUnit, periodValue: Int?)
    case failure(domain: String, code: Int)
    case cancelled

    private static let logger = Logger(subsystem: "com.spyclash.ios", category: "StoreKitCatalog")

    func log() {
#if DEBUG
        // The device console can capture these bounded fields without requiring
        // a system-wide log stream or exposing transaction/account details.
        print("[StoreKitCatalog] \(self)")
#endif
        switch self {
        case let .response(count, matched):
            Self.logger.info("Product lookup count=\(count, privacy: .public) contract_matched=\(matched, privacy: .public)")
        case let .productMetadata(idMatches, autoRenewable, unit, value):
            if let value {
                Self.logger.info("Product metadata id_matches=\(idMatches, privacy: .public) auto_renewable=\(autoRenewable, privacy: .public) period_unit=\(unit.rawValue, privacy: .public) period_value=\(value, privacy: .public)")
            } else {
                Self.logger.info("Product metadata id_matches=\(idMatches, privacy: .public) auto_renewable=\(autoRenewable, privacy: .public) period_unit=\(unit.rawValue, privacy: .public) period_value=none")
            }
        case let .failure(domain, code):
            Self.logger.error("Product lookup failed domain=\(domain, privacy: .public) code=\(code, privacy: .public)")
        case .cancelled:
            Self.logger.info("Product lookup cancelled")
        }
    }
}

struct StoreKitCatalogFailure: Equatable, Sendable {
    let issue: StoreKitProductLoadIssue?
    let diagnostic: StoreKitCatalogDiagnostic

    static func classify(_ error: any Error) -> Self {
        classify(error, depth: 0)
    }

    private static func classify(_ error: any Error, depth: Int) -> Self {
        if error is CancellationError { return .init(issue: nil, diagnostic: .cancelled) }
        if let storeError = error as? StoreKitError {
            switch storeError {
            case .networkError(let underlying): return classify(underlying, depth: depth + 1)
            case .systemError(let underlying) where depth < 2: return classify(underlying, depth: depth + 1)
            case .userCancelled: return .init(issue: nil, diagnostic: .cancelled)
            case .notAvailableInStorefront:
                return details(error, issue: .storefrontUnavailable)
            default: break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == URLError.cancelled.rawValue { return .init(issue: nil, diagnostic: .cancelled) }
            return details(error, issue: .network)
        }
        return details(error, issue: .storeUnavailable)
    }

    private static func details(_ error: any Error, issue: StoreKitProductLoadIssue) -> Self {
        let nsError = error as NSError
        // Never log messages, userInfo, underlying URLs or arbitrary domain text.
        let knownDomains: Set<String> = [
            NSURLErrorDomain, NSCocoaErrorDomain, "SKErrorDomain", "ASDErrorDomain",
            "AMSErrorDomain", "StoreKit.StoreKitError", "StoreKitError"
        ]
        return .init(
            issue: issue,
            diagnostic: .failure(domain: knownDomains.contains(nsError.domain) ? nsError.domain : "OtherErrorDomain", code: nsError.code)
        )
    }
}

/// A catalog request belongs to the app, so cancelling a sheet waiter must not
/// discard the shared result. Transaction/account state is kept elsewhere.
@MainActor
@Observable
final class StoreKitProductCatalog<Value: Sendable> {
    private(set) var product: Value?
    private(set) var isLoading = false
    private(set) var issue: StoreKitProductLoadIssue?
    @ObservationIgnored private let productID: String
    @ObservationIgnored private let fetch: @MainActor () async throws -> [StoreKitCatalogItem<Value>]
    @ObservationIgnored private let diagnostic: @MainActor (StoreKitCatalogDiagnostic) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(
        productID: String,
        fetch: @escaping @MainActor () async throws -> [StoreKitCatalogItem<Value>],
        diagnostic: @escaping @MainActor (StoreKitCatalogDiagnostic) -> Void = { $0.log() }
    ) {
        self.productID = productID
        self.fetch = fetch
        self.diagnostic = diagnostic
    }

    func load() async {
        guard product == nil else { return }
        if let loadTask { await loadTask.value; return }
        isLoading = true
        issue = nil
        let request = Task { [self] in
            defer { isLoading = false; loadTask = nil }
            do {
                let items = try await fetch()
                let match = items.first { $0.id == productID && $0.isAutoRenewable && $0.isWeekly }
                diagnostic(.response(count: items.count, contractMatched: match != nil))
                guard let match else {
                    issue = items.isEmpty ? .notFound : .unsupportedProduct
                    return
                }
                product = match.value
                issue = nil
            } catch {
                let failure = StoreKitCatalogFailure.classify(error)
                issue = failure.issue
                diagnostic(failure.diagnostic)
            }
        }
        loadTask = request
        await request.value
    }
}
