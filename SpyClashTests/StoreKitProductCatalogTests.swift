import Foundation
import StoreKit
import XCTest
@testable import SpyClash

@MainActor
final class StoreKitProductCatalogTests: XCTestCase {
    private let productID = "catalog.weekly"

    private func item(id: String = "catalog.weekly", autoRenewable: Bool = true, weekly: Bool = true) -> StoreKitCatalogItem<String> {
        .init(id: id, isAutoRenewable: autoRenewable, isWeekly: weekly, value: "verified-product")
    }


    func testWeeklyPeriodAcceptsOneWeekAndSevenDaysInTheCatalog() async {
        for (unit, value) in [(Product.SubscriptionPeriod.Unit.week, 1), (.day, 7)] {
            XCTAssertTrue(StoreKitWeeklyPeriod.matches(unit: unit, value: value))
            let candidate = item(weekly: StoreKitWeeklyPeriod.matches(unit: unit, value: value))
            let catalog = StoreKitProductCatalog(productID: productID, fetch: { [candidate] }, diagnostic: { _ in })
            await catalog.load()
            XCTAssertEqual(catalog.product, "verified-product")
            XCTAssertNil(catalog.issue)
        }
    }

    func testWeeklyPeriodRejectsMissingValuesAndAllOtherDurations() {
        let invalid: [(Product.SubscriptionPeriod.Unit?, Int?)] = [
            (nil, nil), (nil, 1), (nil, 7), (.week, nil), (.day, nil),
            (.day, -1), (.day, 0), (.day, 1), (.day, 6), (.day, 8), (.day, 14),
            (.week, 0), (.week, 2), (.week, 7), (.month, 1), (.month, 7), (.year, 1)
        ]
        for (unit, value) in invalid {
            XCTAssertFalse(StoreKitWeeklyPeriod.matches(unit: unit, value: value), "Accepted a non-weekly duration")
        }
    }

    func testPeriodDiagnosticsUseOnlyClosedMetadataFields() {
        XCTAssertEqual(StoreKitCatalogPeriodUnit(nil), .none)
        XCTAssertEqual(StoreKitCatalogPeriodUnit(.day), .day)
        XCTAssertEqual(StoreKitCatalogPeriodUnit(.week), .week)
        XCTAssertEqual(StoreKitCatalogPeriodUnit(.month), .month)
        XCTAssertEqual(StoreKitCatalogPeriodUnit(.year), .year)
        let metadata = StoreKitCatalogDiagnostic.productMetadata(idMatches: true, autoRenewable: true, periodUnit: .day, periodValue: 7)
        XCTAssertEqual(metadata, .productMetadata(idMatches: true, autoRenewable: true, periodUnit: .day, periodValue: 7))
        XCTAssertFalse(String(describing: metadata).contains(productID), "Diagnostics exposed an arbitrary product identifier")
    }

    func testEmptyCatalogIsVisibleAndDiffersFromStoreFailure() async {
        var diagnostics: [StoreKitCatalogDiagnostic] = []
        let catalog = StoreKitProductCatalog<String>(productID: productID, fetch: { [] }, diagnostic: { diagnostics.append($0) })
        await catalog.load()
        XCTAssertNil(catalog.product)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertEqual(catalog.issue, .notFound)
        XCTAssertEqual(diagnostics, [.response(count: 0, contractMatched: false)])
    }

    func testProductIDTypeAndWeeklyPeriodAllRemainRequired() async {
        for candidate in [item(id: "other-product"), item(autoRenewable: false), item(weekly: false)] {
            var diagnostics: [StoreKitCatalogDiagnostic] = []
            let catalog = StoreKitProductCatalog(productID: productID, fetch: { [candidate] }, diagnostic: { diagnostics.append($0) })
            await catalog.load()
            XCTAssertNil(catalog.product)
            XCTAssertEqual(catalog.issue, .unsupportedProduct)
            XCTAssertEqual(diagnostics, [.response(count: 1, contractMatched: false)])
        }
    }

    func testMatchingProductLoadsAndSuccessfulValueIsReused() async {
        var requests = 0
        let candidates = [item(id: "unrelated"), item()]
        let catalog = StoreKitProductCatalog(productID: productID, fetch: { requests += 1; return candidates }, diagnostic: { _ in })
        await catalog.load()
        await catalog.load()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(catalog.product, "verified-product")
        XCTAssertNil(catalog.issue)
        XCTAssertFalse(catalog.isLoading)
    }

    func testRetryReplacesCatalogFailureWithSuccessfulProduct() async {
        var requests = 0
        let candidate = item()
        let catalog = StoreKitProductCatalog(productID: productID, fetch: {
            requests += 1
            if requests == 1 { throw URLError(.notConnectedToInternet) }
            return [candidate]
        }, diagnostic: { _ in })
        await catalog.load()
        XCTAssertEqual(catalog.issue, .network)
        await catalog.load()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(catalog.product, "verified-product")
        XCTAssertNil(catalog.issue)
    }

    func testConcurrentWaitersJoinTheSameCatalogRequest() async throws {
        var requests = 0
        var continuation: CheckedContinuation<[StoreKitCatalogItem<String>], any Error>?
        let catalog = StoreKitProductCatalog<String>(productID: productID, fetch: {
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, diagnostic: { _ in })
        let first = Task { await catalog.load() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let completion = try XCTUnwrap(continuation)
        let second = Task { await catalog.load() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(catalog.isLoading)
        completion.resume(returning: [item()])
        await first.value
        await second.value
        XCTAssertEqual(catalog.product, "verified-product")
        XCTAssertFalse(catalog.isLoading)
    }

    func testClosingOneSheetDoesNotCancelTheSharedRequestForTheNextSheet() async throws {
        var requests = 0
        var continuation: CheckedContinuation<[StoreKitCatalogItem<String>], any Error>?
        let catalog = StoreKitProductCatalog<String>(productID: productID, fetch: {
            requests += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, diagnostic: { _ in })
        let dismissedSheet = Task { await catalog.load() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let completion = try XCTUnwrap(continuation)
        dismissedSheet.cancel()
        let reopenedSheet = Task { await catalog.load() }
        for _ in 0..<10 { await Task.yield() }
        completion.resume(returning: [item()])
        await dismissedSheet.value
        await reopenedSheet.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(catalog.product, "verified-product")
        XCTAssertNil(catalog.issue)
    }

    func testCancelledProviderRequestDoesNotBecomeAnErrorOrPreventRetry() async {
        var requests = 0
        let candidate = item()
        var diagnostics: [StoreKitCatalogDiagnostic] = []
        let catalog = StoreKitProductCatalog(productID: productID, fetch: {
            requests += 1
            if requests == 1 { throw CancellationError() }
            return [candidate]
        }, diagnostic: { diagnostics.append($0) })
        await catalog.load()
        XCTAssertNil(catalog.issue)
        XCTAssertFalse(catalog.isLoading)
        XCTAssertEqual(diagnostics, [.cancelled])
        await catalog.load()
        XCTAssertEqual(catalog.product, "verified-product")
        XCTAssertEqual(requests, 2)
    }

    func testStoreKitNetworkAndStorefrontErrorsHaveSpecificIssues() {
        let network = StoreKitCatalogFailure.classify(StoreKitError.networkError(URLError(.timedOut)))
        XCTAssertEqual(network.issue, .network)
        XCTAssertEqual(network.diagnostic, .failure(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue))
        XCTAssertEqual(StoreKitCatalogFailure.classify(StoreKitError.notAvailableInStorefront).issue, .storefrontUnavailable)
        XCTAssertNil(StoreKitCatalogFailure.classify(StoreKitError.networkError(URLError(.cancelled))).issue)
    }

    func testDiagnosticsExposeOnlyKnownDomainAndCodeNeverPrivateErrorDetails() async {
        var diagnostics: [StoreKitCatalogDiagnostic] = []
        let error = NSError(domain: "https://secret.example/?token=private", code: 42, userInfo: [NSLocalizedDescriptionKey: "private-token", NSURLErrorFailingURLStringErrorKey: "https://private.example"])
        let catalog = StoreKitProductCatalog<String>(productID: productID, fetch: { throw error }, diagnostic: { diagnostics.append($0) })
        await catalog.load()
        XCTAssertEqual(catalog.issue, .storeUnavailable)
        XCTAssertEqual(diagnostics, [.failure(domain: "OtherErrorDomain", code: 42)])
        XCTAssertFalse(String(describing: diagnostics).contains("private"))
        let apple = StoreKitCatalogFailure.classify(NSError(domain: "ASDErrorDomain", code: 500, userInfo: [NSLocalizedDescriptionKey: "private-apple-error"]))
        XCTAssertEqual(apple.diagnostic, .failure(domain: "ASDErrorDomain", code: 500))
    }
}
