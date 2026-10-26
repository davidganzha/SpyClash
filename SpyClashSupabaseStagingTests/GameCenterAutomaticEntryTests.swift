import XCTest
@testable import SpyClashSupabaseStaging

@MainActor
final class GameCenterAutomaticEntryTests: XCTestCase {
    func testAutomaticEntryRunsOncePerLaunch() {
        let policy = GameCenterAutomaticEntryPolicy(defaults: isolatedDefaults())
        XCTAssertTrue(begin(policy))
        XCTAssertFalse(begin(policy))
    }

    func testRestoredAccountAndUnresolvedSavedSessionPreventNewAccount() {
        let policy = GameCenterAutomaticEntryPolicy(defaults: isolatedDefaults())
        XCTAssertFalse(begin(policy, hasUser: true))
        XCTAssertFalse(begin(policy, hasSavedSession: true))
        XCTAssertFalse(policy.hasAttempted)
    }

    func testExplicitAuthAndPasswordRecoveryTakePrecedence() {
        let policy = GameCenterAutomaticEntryPolicy(defaults: isolatedDefaults())
        XCTAssertFalse(begin(policy, isBusy: true))
        XCTAssertFalse(begin(policy, recoveryPresented: true))
        XCTAssertFalse(policy.hasAttempted)
    }

    func testExplicitLogoutOrClassicChoiceSurvivesRelaunch() {
        let defaults = isolatedDefaults()
        let first = GameCenterAutomaticEntryPolicy(defaults: defaults)
        XCTAssertTrue(begin(first))
        first.disableAutomaticEntry()
        XCTAssertFalse(begin(first))
        let relaunched = GameCenterAutomaticEntryPolicy(defaults: defaults)
        XCTAssertFalse(begin(relaunched))
    }

    func testNewPlayerOpensExistingFullOnboardingAndReturningPlayerKeepsProgress() {
        XCTAssertTrue(OnboardingRoutingPolicy.shouldPresentOnboarding(remoteCompleted: false, remoteVersion: 0, localCompletedVersion: 2))
        XCTAssertFalse(OnboardingRoutingPolicy.requiresLocalNetworkUpgrade(remoteCompleted: false, remoteVersion: 0))
        for version in [nil, 1, 2] as [Int?] {
            XCTAssertFalse(OnboardingRoutingPolicy.shouldPresentOnboarding(remoteCompleted: true, remoteVersion: version, localCompletedVersion: nil))
            XCTAssertFalse(OnboardingRoutingPolicy.requiresLocalNetworkUpgrade(remoteCompleted: true, remoteVersion: version))
        }
    }

    func testExplicitGameCenterButtonCanRetryAfterLogoutAndOnlyOnce() {
        let defaults = isolatedDefaults()
        let policy = GameCenterAutomaticEntryPolicy(defaults: defaults)
        policy.disableAutomaticEntry()
        XCTAssertFalse(begin(policy))
        policy.allowExplicitEntry()
        XCTAssertTrue(begin(policy))
        XCTAssertFalse(begin(policy))
        XCTAssertFalse(defaults.bool(forKey: GameCenterAutomaticEntryPolicy.optOutKey))
    }

    private func begin(_ policy: GameCenterAutomaticEntryPolicy, hasUser: Bool = false, hasSavedSession: Bool = false, isBusy: Bool = false, recoveryPresented: Bool = false) -> Bool {
        policy.begin(hasUser: hasUser, hasSavedSession: hasSavedSession, isBusy: isBusy, recoveryPresented: recoveryPresented)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "GameCenterAutomaticEntryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }
}
