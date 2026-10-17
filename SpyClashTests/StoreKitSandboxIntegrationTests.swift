import Foundation
import Security
import StoreKit
import StoreKitTest
import XCTest
@testable import SpyClash

/// Real StoreKit 2 products, purchases and transaction sequences in Xcode's
/// local StoreKit environment. Only the backend acknowledgement is a fixture.
/// This does not establish Apple-server verification or TestFlight acceptance.
@MainActor
final class StoreKitSandboxIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SPYCLASH_RUN_LOCAL_STOREKIT_TESTS"] == "1" else {
            throw XCTSkip("Requires an isolated Simulator with working local StoreKitTest; opt in with SPYCLASH_RUN_LOCAL_STOREKIT_TESTS=1. Skipped tests are not purchase/Restore verification.")
        }
    }

    func testRealPurchaseDeliversFinishesAndRestoresOnFreshMembershipStore() async throws {
        let harness = try await StoreKitIntegrationHarness()
        defer { harness.close() }

        await harness.manager.purchase(membership: harness.membership)

        XCTAssertEqual(harness.manager.state, .purchased, harness.manager.errorMessage ?? "")
        XCTAssertTrue(harness.membership.hasAccess)
        XCTAssertEqual(harness.backend.prepareCount, 1)
        XCTAssertGreaterThanOrEqual(harness.backend.deliveryCount, 1)
        XCTAssertEqual(harness.backend.deliveredAccountTokens, [harness.backend.accountToken.uuidString.lowercased()])
        XCTAssertEqual(harness.backend.deliveredProductIDs, [StoreKitManager.limitlessProductID])
        try await assertNoUnfinishedTransactions()

        harness.manager.bind(MembershipScope(userID: nil, accessToken: nil))
        let restoredMembership = MembershipStore(client: harness.client)
        restoredMembership.bind(harness.scope)
        let restoredManager = StoreKitManager(client: harness.client)
        restoredManager.bind(harness.scope)
        restoredManager.onEntitlementChanged = {
            guard await restoredMembership.refresh(force: true) else { return nil }
            return restoredMembership.snapshot
        }
        defer { restoredManager.bind(MembershipScope(userID: nil, accessToken: nil)) }
        let deliveriesBeforeRestore = harness.backend.deliveryCount

        await restoredManager.restore()

        XCTAssertEqual(restoredManager.state, .restored, restoredManager.errorMessage ?? "")
        XCTAssertTrue(restoredMembership.hasAccess)
        XCTAssertGreaterThan(harness.backend.deliveryCount, deliveriesBeforeRestore)
        XCTAssertEqual(harness.backend.prepareCount, 1, "Restore must not prepare a new purchase")
        XCTAssertEqual(harness.store.allTransactions().count, 1)
    }

    func testRejectedDeliveryStaysUnfinishedAndExplicitRestoreRetriesIt() async throws {
        let harness = try await StoreKitIntegrationHarness()
        defer { harness.close() }
        harness.backend.rejectDelivery = true

        await harness.manager.purchase(membership: harness.membership)

        XCTAssertEqual(harness.manager.state, .failed)
        XCTAssertEqual(harness.manager.operationFailure?.stage, .serverDelivery)
        XCTAssertFalse(harness.membership.hasAccess)
        let unfinished = await unfinishedProductIDs()
        XCTAssertTrue(unfinished.contains(StoreKitManager.limitlessProductID), "Unacknowledged StoreKit deliveries must remain retryable")

        harness.backend.rejectDelivery = false
        await harness.manager.restore()

        XCTAssertEqual(harness.manager.state, .restored, harness.manager.errorMessage ?? "")
        XCTAssertTrue(harness.membership.hasAccess)
        XCTAssertEqual(harness.store.allTransactions().count, 1, "Retry must restore the original purchase")
        try await assertNoUnfinishedTransactions()
    }

    func testAccessUnverifiedStartsNoPaymentAndRetryCanCompleteRealPurchase() async throws {
        let harness = try await StoreKitIntegrationHarness()
        defer { harness.close() }
        harness.backend.rejectMembership = true

        await harness.manager.purchase(membership: harness.membership)

        XCTAssertEqual(harness.manager.state, .failed)
        XCTAssertEqual(harness.manager.operationFailure?.stage, .purchaseEligibility)
        XCTAssertTrue(harness.manager.operationFailure?.reason.contains("ACCESS_UNVERIFIED") == true)
        XCTAssertNil(harness.manager.product)
        XCTAssertEqual(harness.backend.prepareCount, 0)
        XCTAssertEqual(harness.backend.deliveryCount, 0)
        XCTAssertTrue(harness.store.allTransactions().isEmpty)

        harness.backend.rejectMembership = false
        await harness.manager.purchase(membership: harness.membership)

        XCTAssertEqual(harness.manager.state, .purchased, harness.manager.errorMessage ?? "")
        XCTAssertTrue(harness.membership.hasAccess)
        XCTAssertEqual(harness.store.allTransactions().count, 1)
        try await assertNoUnfinishedTransactions()
    }

    func testEmptyRestoreUsesRealAppStoreSyncAndDoesNotInventAccess() async throws {
        let harness = try await StoreKitIntegrationHarness()
        defer { harness.close() }
        harness.manager.bind(MembershipScope(userID: nil, accessToken: nil))
        var appleSyncCount = 0
        let manager = StoreKitManager(client: harness.client, syncAppStore: {
            appleSyncCount += 1
            try await AppStore.sync()
        })
        manager.bind(harness.scope)
        manager.onEntitlementChanged = {
            guard await harness.membership.refresh(force: true) else { return nil }
            return harness.membership.snapshot
        }
        defer { manager.bind(MembershipScope(userID: nil, accessToken: nil)) }

        await manager.restore()

        XCTAssertEqual(manager.state, .noPurchases, manager.errorMessage ?? "")
        XCTAssertEqual(appleSyncCount, 1)
        XCTAssertFalse(harness.membership.hasAccess)
        XCTAssertEqual(harness.backend.deliveryCount, 0)
        XCTAssertTrue(harness.store.allTransactions().isEmpty)
    }

    func testRealAskToBuyApprovalCompletesThroughTransactionUpdates() async throws {
        let harness = try await StoreKitIntegrationHarness()
        defer { harness.close() }
        harness.store.askToBuyEnabled = true

        await harness.manager.purchase(membership: harness.membership)

        XCTAssertEqual(harness.manager.state, .pending)
        XCTAssertFalse(harness.membership.hasAccess)
        XCTAssertEqual(harness.backend.deliveryCount, 0)
        let pending = try XCTUnwrap(harness.store.allTransactions().first(where: \.pendingAskToBuyConfirmation))
        try harness.store.approveAskToBuyTransaction(identifier: pending.identifier)
        let deadline = Date().addingTimeInterval(10)
        while harness.manager.state == .pending && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(harness.manager.state, .purchased, harness.manager.errorMessage ?? "")
        XCTAssertTrue(harness.membership.hasAccess)
        try await assertNoUnfinishedTransactions()
    }

    private func unfinishedProductIDs() async -> [String] {
        var products: [String] = []
        for await result in Transaction.unfinished { products.append(result.unsafePayloadValue.productID) }
        return products
    }

    private func assertNoUnfinishedTransactions(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        var unfinished = await unfinishedProductIDs()
        while !unfinished.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            unfinished = await unfinishedProductIDs()
        }
        XCTAssertTrue(unfinished.isEmpty, "Acknowledged transactions should finish", file: file, line: line)
    }
}

/// Exercises the fixture transport even when StoreKit integration is opted out.
/// Only this URLSession uses the protocol; no real StoreKit or backend is used.
@MainActor
final class StoreKitFixtureTransportTests: XCTestCase {
    func testFixtureCallbackAndBackendStateStayOnMainActor() async throws {
        let backend = StoreKitFixtureBackend()
        let registrationID = UUID().uuidString
        StoreKitFixtureURLProtocol.handlers[registrationID] = { request in
            MainActor.preconditionIsolated()
            return backend.respond(to: request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreKitFixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-StoreKit-Fixture": registrationID]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            StoreKitFixtureURLProtocol.handlers.removeValue(forKey: registrationID)
        }
        var request = URLRequest(url: URL(string: "https://storekit-fixture.invalid/checkSubscription")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"access_token":"storekit-fixture-session"}"#.utf8)

        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["tier"] as? String, "free")
        XCTAssertEqual(body["apple_purchase_enabled"] as? Bool, true)

        backend.rejectMembership = true
        let (_, rejected) = try await session.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertEqual(backend.prepareCount, 0)
        XCTAssertEqual(backend.deliveryCount, 0)

        StoreKitFixtureURLProtocol.handlers.removeValue(forKey: registrationID)
        let replacementID = UUID().uuidString
        StoreKitFixtureURLProtocol.handlers[replacementID] = { _ in
            XCTFail("An old session reached the replacement fixture")
            return .json(status: 200, body: [:])
        }
        defer { StoreKitFixtureURLProtocol.handlers.removeValue(forKey: replacementID) }
        let (_, closed) = try await session.data(for: request)
        XCTAssertEqual((closed as? HTTPURLResponse)?.statusCode, 503,
                       "A closed fixture registration must not reach another backend")
    }
}

@MainActor
private final class StoreKitIntegrationHarness {
    let store: SKTestSession
    let backend = StoreKitFixtureBackend()
    let client: Base44Client
    let membership: MembershipStore
    let manager: StoreKitManager
    let scope = MembershipScope(userID: "storekit-fixture-user", accessToken: "storekit-fixture-session")
    private let network: URLSession
    private let fixtureURL: URL
    private let registrationID = UUID().uuidString

    init() async throws {
        // This test target deliberately uses the shared manager's original
        // transport. The hosted Supabase bridge has its own contract tests.
        guard !SupabaseAppRuntime.isEnabled else {
            throw NSError(domain: "StoreKitFixture", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "StoreKit fixture requires SpyClash / Debug; hybrid transport is blocked"
            ])
        }
        // The host also owns a StoreKit listener. Never create local purchases
        // in a host that could deliver them using a real saved account.
        // Query existence only: do not read, migrate, print or clear tokens.
        for service in ["com.spyclash.ios", "com.spyclash.app"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "base44_access_token",
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else {
                throw NSError(domain: "StoreKitFixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "StoreKit fixture requires a simulator host with no saved account"
                ])
            }
        }
        fixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent("StoreKitFixture-\(UUID().uuidString).storekit")
        try Data(Self.configuration.utf8).write(to: fixtureURL)
        store = try SKTestSession(contentsOf: fixtureURL)
        store.resetToDefaultState()
        store.clearTransactions()
        store.disableDialogs = true
        store.timeRate = .realTime
        // SKTestSession initialization can silently fail on some Simulator
        // runtimes. Prove the local test service is active using only its
        // test-only API before allowing any Product.purchase/AppStore.sync.
        // The canary ID is not a real App Store product. No purchase fallback.
        let canary = try await store.buyProduct(identifier: "com.spyclash.fixture.local-canary", options: [])
        guard canary.productID == "com.spyclash.fixture.local-canary",
              canary.environment == .xcode else {
            throw NSError(domain: "StoreKitFixture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Local StoreKit environment was not confirmed; purchase blocked"
            ])
        }
        await canary.finish()
        store.clearTransactions()
        guard store.allTransactions().isEmpty else {
            throw NSError(domain: "StoreKitFixture", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Local StoreKit reset was not confirmed; purchase blocked"
            ])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StoreKitFixtureURLProtocol.self]
        config.httpAdditionalHeaders = ["X-StoreKit-Fixture": registrationID]
        network = URLSession(configuration: config)
        client = Base44Client(session: network, appStoreRetrySleep: { _ in })
        client.setToken(scope.accessToken!)
        membership = MembershipStore(client: client)
        membership.bind(scope)
        manager = StoreKitManager(client: client)
        manager.bind(scope)
        let backend = self.backend
        StoreKitFixtureURLProtocol.handlers[registrationID] = { request in
            return backend.respond(to: request)
        }
        let membership = self.membership
        manager.onEntitlementChanged = {
            guard await membership.refresh(force: true) else { return nil }
            return membership.snapshot
        }
    }

    func close() {
        manager.bind(MembershipScope(userID: nil, accessToken: nil))
        network.invalidateAndCancel()
        StoreKitFixtureURLProtocol.handlers.removeValue(forKey: registrationID)
        store.clearTransactions()
        store.resetToDefaultState()
        try? FileManager.default.removeItem(at: fixtureURL)
    }

    // Test fixture values, not App Store Connect prices or configuration. This
    // string is in the XCTest bundle only, never the application target.
    private static let configuration = #"""
    {
      "identifier":"53505943", "nonRenewingSubscriptions":[],
      "products":[{"displayPrice":"0.01","familyShareable":false,"internalID":"5350594301",
        "localizations":[{"description":"Local environment proof only","displayName":"Local Canary","locale":"en_US"}],
        "productID":"com.spyclash.fixture.local-canary","referenceName":"Local Canary","type":"NonConsumable"}],
      "settings":{"_locale":"en_US","_storefront":"USA","_failTransactionsEnabled":false},
      "subscriptionGroups":[{"id":"22234605","name":"Local LIMITLESS Fixture","localizations":[],
        "subscriptions":[{"adHocOffers":[],"codeOffers":[],"displayPrice":"2.99","familyShareable":false,
          "groupNumber":1,"internalID":"6790603600","introductoryOffer":null,
          "localizations":[{"description":"Local test only","displayName":"LIMITLESS Fixture","locale":"en_US"}],
          "productID":"com.spyclash.ios.limitless.weekly","recurringSubscriptionPeriod":"P1W",
          "referenceName":"Local Weekly","subscriptionGroupID":"22234605","type":"RecurringSubscription","winbackOffers":[]}]}],
      "version":{"major":4,"minor":0}
    }
    """#
}

@MainActor
private final class StoreKitFixtureBackend {
    let accountToken = UUID()
    var rejectMembership = false
    var rejectDelivery = false
    private(set) var prepareCount = 0
    private(set) var deliveryCount = 0
    private(set) var deliveredAccountTokens = Set<String>()
    private(set) var deliveredProductIDs = Set<String>()
    private var active = false
    private var expiry: Date?

    func respond(to request: StoreKitFixtureRequest) -> StoreKitFixtureResponse {
        do {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            guard request.method == "POST", body["access_token"] as? String == "storekit-fixture-session" else {
                XCTFail("Fixture received an unexpected request or credential")
                return .json(status: 401, body: ["error":"fixture_session_invalid"])
            }
            switch request.pathComponent {
            case "checkSubscription":
                if rejectMembership { return .json(status: 502, body: ["error":"fixture_unavailable","code":"legacy_billing_response_invalid"]) }
                return .json(status: 200, body: membershipBody())
            case "app-store-entitlement":
                if body["action"] as? String == "prepare" {
                    prepareCount += 1
                    XCTAssertEqual(body["requested_product_id"] as? String, StoreKitManager.limitlessProductID)
                    return .json(status: 200, body: ["product_id":StoreKitManager.limitlessProductID,"app_account_token":accountToken.uuidString])
                } else if body["action"] as? String == "sync_transaction" {
                    deliveryCount += 1
                    if rejectDelivery { return .json(status: 503, body: ["error":"fixture_verification_unavailable","retryable":true]) }
                    let signed = try XCTUnwrap(body["signed_transaction"] as? String)
                    let fields = signed.split(separator: ".")
                    XCTAssertEqual(fields.count, 3, "Actual StoreKit JWS is delivered intact")
                    guard fields.count == 3 else { throw URLError(.cannotDecodeContentData) }
                    var encoded = String(fields[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as? [String: Any])
                    let productID = try XCTUnwrap(payload["productId"] as? String)
                    let token = try XCTUnwrap(payload["appAccountToken"] as? String)
                    XCTAssertEqual(token.lowercased(), accountToken.uuidString.lowercased())
                    deliveredProductIDs.insert(productID)
                    deliveredAccountTokens.insert(token.lowercased())
                    expiry = Date(timeIntervalSince1970: try XCTUnwrap(payload["expiresDate"] as? Double) / 1000)
                    active = payload["revocationDate"] == nil && expiry! > Date()
                    return .json(status: 200, body: ["success":true,"server_status_verified":true,
                        "entitlement":["product_id":productID,"status":active ? "active" : "expired","expires_at":ISO8601DateFormatter().string(from: expiry!)]])
                } else { throw URLError(.unsupportedURL) }
            default: throw URLError(.unsupportedURL)
            }
        } catch {
            XCTFail("Local StoreKit fixture rejected request: \(type(of: error))")
            return .json(status: 500, body: ["error":"fixture_contract_mismatch"])
        }
    }

    private func membershipBody() -> [String: Any] {
        ["active":active,"tier":active ? "limitless" : "free","status":active ? "active" : "inactive",
         "protocol":"limitless","providers":active ? ["apple"] : [],
         "benefits":["ai_generations_daily_limit":active ? NSNull() as Any : 10,"premium_avatars":active,
                     "full_history":active,"advanced_statistics":active,"history_limit":active ? NSNull() as Any : 5],
         "expires_at":expiry.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
         "apple_purchase_enabled":!active]
    }
}

private struct StoreKitFixtureRequest: Sendable {
    let registrationID: String
    let method: String?
    let pathComponent: String
    let body: Data
}

private struct StoreKitFixtureResponse: Sendable {
    let status: Int
    let body: Data

    static func json(status: Int, body: [String: Any]) -> Self {
        Self(status: status, body: try! JSONSerialization.data(withJSONObject: body))
    }
}

private final class StoreKitFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handlers: [String: @MainActor @Sendable (StoreKitFixtureRequest) -> StoreKitFixtureResponse] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let snapshot = StoreKitFixtureRequest(registrationID: request.value(forHTTPHeaderField: "X-StoreKit-Fixture") ?? "",
                method: request.httpMethod,
                pathComponent: request.url?.lastPathComponent ?? "", body: try bodyData())
            // Only immutable values cross the actor boundary. Foundation's
            // URLProtocol and client callbacks remain on the transport side.
            Task { @Sendable [self] in
                let response = await Self.response(to: snapshot)
                respond(response)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

    @MainActor
    private static func response(to request: StoreKitFixtureRequest) -> StoreKitFixtureResponse {
        guard let handler = handlers[request.registrationID] else {
            return .json(status: 503, body: ["error": "fixture_unavailable"])
        }
        return handler(request)
    }

    private func bodyData() throws -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return data
    }

    private func respond(_ reply: StoreKitFixtureResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
