import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class GenerationRewardStoreTests: XCTestCase {
    private let owner = MembershipScope(userID: "owner", accessToken: "token")
    private var empty: GenerationRewardStatus { .init(enabled: true, unlimited: false, freeRemaining: 0, adAvailable: true) }

    private func storage() -> UserDefaults {
        UserDefaults(suiteName: "GenerationRewardStoreTests." + UUID().uuidString)!
    }

    func testClosingAdDoesNotGrantCreditOrBlockAnotherTry() async {
        let client = RewardClientMock(status: empty), ads = RewardAdMock()
        ads.earned = false
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        await store.watch()
        XCTAssertEqual(store.snapshot?.bonusCredits, 0)
        XCTAssertEqual(store.notice, .incomplete)
        XCTAssertNil(store.pendingAttemptID)
        XCTAssertTrue(store.canWatch)
        XCTAssertEqual(client.claimCount, 0)
    }

    func testEarnedClientCallbackCannotMintCreditWithoutServerConfirmation() async {
        let client = RewardClientMock(status: empty), ads = RewardAdMock(), saved = storage()
        let store = GenerationRewardStore(client: client, ads: ads, defaults: saved, sleep: { _ in throw CancellationError() })
        store.bind(owner)
        _ = await store.refresh()
        await store.watch()
        XCTAssertEqual(store.snapshot?.bonusCredits, 0)
        XCTAssertTrue(store.isAwaitingReward)
        XCTAssertFalse(store.canWatch)
        XCTAssertNotNil(store.pendingAttemptID)

        client.claimState = "earned"
        client.status = .init(enabled: true, unlimited: false, freeRemaining: 0, bonusCredits: 1, adAvailable: true)
        let restored = GenerationRewardStore(client: client, ads: ads, defaults: saved)
        restored.bind(owner)
        XCTAssertTrue(restored.isAwaitingReward)
        _ = await restored.refresh()
        XCTAssertEqual(restored.snapshot?.bonusCredits, 1)
        XCTAssertEqual(restored.notice, .earned)
        XCTAssertNil(restored.pendingAttemptID)
        XCTAssertEqual(ads.presentCount, 1, "Recovery must not replay an ad.")
    }

    func testUnavailableAdLeavesBalanceUnchangedAndAllowsRetry() async {
        let client = RewardClientMock(status: empty), ads = RewardAdMock()
        ads.failure = URLError(.notConnectedToInternet)
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        await store.watch()
        XCTAssertEqual(store.snapshot?.bonusCredits, 0)
        XCTAssertEqual(store.notice, .unavailable)
        XCTAssertFalse(store.isAwaitingReward)
        XCTAssertTrue(store.canWatch)
        XCTAssertNil(store.pendingAttemptID)
    }

    func testServerConfirmationBeforeAdDismissalDoesNotRecreatePendingReward() async throws {
        let client = RewardClientMock(status: empty), ads = RewardAdMock()
        var dismiss: CheckedContinuation<Bool, Error>?
        ads.earlyEarned = true
        ads.handler = { try await withCheckedThrowingContinuation { dismiss = $0 } }
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        let watch = Task { await store.watch() }
        for _ in 0..<100 where dismiss == nil { await Task.yield() }
        let continuation = try XCTUnwrap(dismiss)
        XCTAssertTrue(store.isAwaitingReward)
        client.claimState = "earned"
        client.status = .init(enabled: true, unlimited: false, freeRemaining: 0, bonusCredits: 1, adAvailable: true)
        await store.recoverPending()
        XCTAssertNil(store.pendingAttemptID)
        continuation.resume(returning: true)
        await watch.value
        XCTAssertFalse(store.isAwaitingReward)
        XCTAssertEqual(store.snapshot?.bonusCredits, 1)
    }

    func testAccountChangeDiscardsLateAdResponse() async throws {
        let client = RewardClientMock(status: empty), ads = RewardAdMock()
        var completion: CheckedContinuation<Bool, Error>?
        ads.handler = { try await withCheckedThrowingContinuation { completion = $0 } }
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        let watch = Task { await store.watch() }
        for _ in 0..<100 where completion == nil { await Task.yield() }
        let pending = try XCTUnwrap(completion)
        store.bind(.init(userID: "another", accessToken: "another-token"))
        pending.resume(returning: true)
        await watch.value
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.pendingAttemptID)
        XCTAssertFalse(store.isAwaitingReward)
        XCTAssertEqual(client.claimCount, 0)
    }

    func testUnlimitedAndAvailableFreeCreditNeverOfferAnAd() async {
        let client = RewardClientMock(status: .init(enabled: true, unlimited: true, freeRemaining: nil, adAvailable: true))
        let ads = RewardAdMock()
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        await store.watch()
        XCTAssertFalse(store.canWatch)
        XCTAssertEqual(ads.presentCount, 0)
        client.status = .init(enabled: true, unlimited: false, freeRemaining: 1, adAvailable: true)
        _ = await store.refresh()
        XCTAssertFalse(store.canWatch)
        XCTAssertTrue(store.snapshot?.canGenerate == true)
    }

    func testLateStatusFromPreviousAccountCannotOverwriteNewAccount() async throws {
        let client = RewardClientMock(status: empty), ads = RewardAdMock()
        var response: CheckedContinuation<GenerationRewardStatus, Error>?
        client.statusHandler = { try await withCheckedThrowingContinuation { response = $0 } }
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        let load = Task { await store.refresh() }
        for _ in 0..<100 where response == nil { await Task.yield() }
        let pending = try XCTUnwrap(response)
        store.bind(.init(userID: "new-owner", accessToken: "new-token"))
        pending.resume(returning: empty)
        _ = await load.value
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isLoading)
    }

    func testServerStatusDecodesUTCResetAndUnlimitedWithoutInventingCredits() throws {
        let status = try JSONDecoder().decode(GenerationRewardStatus.self, from: Data(#"{"enabled":true,"unlimited":false,"daily_limit":3,"free_remaining":0,"bonus_credits":1,"resets_at":"2026-11-06T00:00:00.000Z","ad_available":true}"#.utf8))
        XCTAssertNotNil(status.resetsAt)
        XCTAssertTrue(status.canGenerate)
        XCTAssertFalse(status.needsReward)
        let unknown = try JSONDecoder().decode(GenerationRewardStatus.self, from: Data(#"{"enabled":true,"unlimited":false}"#.utf8))
        XCTAssertFalse(unknown.canGenerate)
        XCTAssertFalse(unknown.adAvailable)
        XCTAssertFalse(unknown.testAdAvailable)
        let test = try JSONDecoder().decode(GenerationRewardStatus.self, from: Data(#"{"enabled":false,"unlimited":true,"bonus_credits":2,"test_ad_available":true}"#.utf8))
        XCTAssertTrue(test.testAdAvailable)
        XCTAssertTrue(test.canGenerate)
        XCTAssertFalse(test.needsReward)
        XCTAssertEqual(test.bonusCredits, 2)
    }

    func testOwnedAdRequiresServerEligibilityAndDoesNotChangeRegularAllowance() async {
        let client = RewardClientMock(status: .init(enabled: false, unlimited: true, freeRemaining: nil, adAvailable: false))
        let ads = RewardAdMock()
        ads.isOwnedSimulatorTestConfiguration = true
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        await store.watch(testAd: true)
        XCTAssertFalse(store.showsTestAdControls)
        XCTAssertFalse(store.canWatchTestAd)
        XCTAssertEqual(client.prepareCount, 0)
        XCTAssertEqual(ads.presentCount, 0)

        client.status = .init(enabled: false, unlimited: true, freeRemaining: nil, bonusCredits: 2, adAvailable: false, testAdAvailable: true)
        _ = await store.refresh()
        XCTAssertTrue(store.showsTestAdControls)
        XCTAssertTrue(store.canWatchTestAd)
        XCTAssertFalse(store.canWatch)
        XCTAssertTrue(store.snapshot?.canGenerate == true)
        await store.watch()
        XCTAssertEqual(client.prepareCount, 0, "Test capability must not authorize the ordinary ad action.")
        XCTAssertEqual(store.snapshot?.bonusCredits, 2)
    }

    func testSampleOrNonTestBuildAndPreviewCannotUseServerTestCapability() async {
        let status = GenerationRewardStatus(enabled: false, unlimited: false, freeRemaining: 3, adAvailable: false, testAdAvailable: true)
        let client = RewardClientMock(status: status), ads = RewardAdMock()
        let store = GenerationRewardStore(client: client, ads: ads, defaults: storage())
        store.bind(owner)
        _ = await store.refresh()
        await store.watch(testAd: true)
        XCTAssertFalse(store.canWatchTestAd)
        XCTAssertFalse(store.showsTestAdControls)
        XCTAssertEqual(client.prepareCount, 0)
        ads.isOwnedSimulatorTestConfiguration = true
        store.bind(owner, preview: status)
        await store.watch(testAd: true)
        XCTAssertFalse(store.canWatchTestAd)
        XCTAssertEqual(client.prepareCount, 0)
        XCTAssertEqual(ads.presentCount, 0)
    }

    func testOwnedAdUsesRealPrepareAndWaitsForServerBonusWithoutSpendingFreeCredits() async {
        let status = GenerationRewardStatus(enabled: false, unlimited: true, freeRemaining: 3, bonusCredits: 2, adAvailable: false, testAdAvailable: true)
        let client = RewardClientMock(status: status), ads = RewardAdMock(), saved = storage()
        ads.isOwnedSimulatorTestConfiguration = true
        let store = GenerationRewardStore(client: client, ads: ads, defaults: saved, sleep: { _ in throw CancellationError() })
        store.bind(owner)
        _ = await store.refresh()
        await store.watch(testAd: true)
        XCTAssertEqual(client.prepareCount, 1)
        XCTAssertEqual(ads.presentCount, 1)
        XCTAssertEqual(ads.presentedUserID, "server-reward-owner")
        XCTAssertEqual(ads.presentedCustomData, "opaque-server-issued-data")
        XCTAssertEqual(store.snapshot?.bonusCredits, 2, "An SDK reward callback cannot award a real test credit.")
        XCTAssertEqual(store.snapshot?.freeRemaining, 3)
        XCTAssertTrue(store.snapshot?.unlimited == true)
        XCTAssertTrue(store.isAwaitingReward)
        XCTAssertFalse(store.canWatchTestAd)

        client.claimState = "earned"
        client.status = .init(enabled: false, unlimited: true, freeRemaining: 3, bonusCredits: 3, adAvailable: false, testAdAvailable: true)
        await store.recoverPending()
        XCTAssertEqual(store.snapshot?.bonusCredits, 3)
        XCTAssertEqual(store.snapshot?.freeRemaining, 3)
        XCTAssertTrue(store.snapshot?.unlimited == true)
        XCTAssertEqual(store.notice, .earned)
        XCTAssertTrue(store.showsTestAdControls)
        XCTAssertNil(store.pendingAttemptID)
        XCTAssertEqual(ads.presentCount, 1)

        client.status = .init(enabled: false, unlimited: true, freeRemaining: nil, adAvailable: false)
        _ = await store.refresh()
        XCTAssertFalse(store.showsTestAdControls, "Revoking the server capability must remove all test controls.")
        XCTAssertFalse(store.canWatchTestAd)
        store.bind(.init(userID: "another", accessToken: "another-token"))
        XCTAssertFalse(store.showsTestAdControls)
        XCTAssertFalse(store.canWatchTestAd)
    }

    func testOwnedTestRewardRecoversAfterRelaunchWithoutReplayingAd() async {
        let status = GenerationRewardStatus(enabled: false, unlimited: true, freeRemaining: nil, adAvailable: false, testAdAvailable: true)
        let client = RewardClientMock(status: status), ads = RewardAdMock(), saved = storage()
        ads.isOwnedSimulatorTestConfiguration = true
        let store = GenerationRewardStore(client: client, ads: ads, defaults: saved, sleep: { _ in throw CancellationError() })
        store.bind(owner)
        _ = await store.refresh()
        await store.watch(testAd: true)
        client.claimState = "earned"
        client.status = .init(enabled: false, unlimited: true, freeRemaining: nil, bonusCredits: 1, adAvailable: false, testAdAvailable: true)
        let restored = GenerationRewardStore(client: client, ads: ads, defaults: saved)
        restored.bind(owner)
        XCTAssertTrue(restored.isAwaitingReward)
        _ = await restored.refresh()
        XCTAssertEqual(restored.snapshot?.bonusCredits, 1)
        XCTAssertEqual(restored.notice, .earned)
        XCTAssertTrue(restored.showsTestAdControls)
        XCTAssertNil(restored.pendingAttemptID)
        XCTAssertEqual(client.prepareCount, 1)
        XCTAssertEqual(ads.presentCount, 1)
    }
}

@MainActor private final class RewardClientMock: GenerationRewardsClientProtocol {
    var status: GenerationRewardStatus
    var claimState = "pending"
    var claimCount = 0
    var prepareCount = 0
    var statusHandler: (() async throws -> GenerationRewardStatus)?
    init(status: GenerationRewardStatus) { self.status = status }
    func generationRewardStatus() async throws -> GenerationRewardStatus {
        if let statusHandler { return try await statusHandler() }
        return status
    }
    func prepareGenerationReward(requestID: UUID) async throws -> GenerationRewardAttempt {
        prepareCount += 1
        return .init(attemptID: requestID, customData: "opaque-server-issued-data", adUnitID: "test", userID: "server-reward-owner")
    }
    func generationRewardClaim(attemptID: UUID) async throws -> GenerationRewardClaim {
        claimCount += 1
        return .init(state: claimState, status: status)
    }
}

@MainActor private final class RewardAdMock: GenerationRewardAdPresenting {
    var canOfferAds = true
    var isOwnedSimulatorTestConfiguration = false
    var earned = true
    var failure: Error?
    var presentCount = 0
    var earlyEarned = false
    var presentedUserID: String?
    var presentedCustomData: String?
    var handler: (() async throws -> Bool)?
    func present(adUnitID: String, userID: String, customData: String, onEarned: @escaping @MainActor () -> Void) async throws -> Bool {
        presentCount += 1
        presentedUserID = userID
        presentedCustomData = customData
        if earlyEarned { onEarned() }
        if let handler {
            let result = try await handler()
            if result && !earlyEarned { onEarned() }
            return result
        }
        if let failure { throw failure }
        if earned { onEarned() }
        return earned
    }
    func cancelPendingPresentation() {}
}
