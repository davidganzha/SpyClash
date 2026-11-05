import XCTest
@testable import SpyClash

final class RewardedGenerationAdConfigurationTests: XCTestCase {
    private let liveApp = "ca-app-pub-1234567890123456~1234567890"
    private let liveUnit = "ca-app-pub-1234567890123456/0987654321"

    func testDebugAcceptsOnlyExplicitlyEnabledGoogleTestPair() {
        let config = make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID)
        XCTAssertTrue(config.isConfigured)
        XCTAssertTrue(config.isTestConfiguration)
        XCTAssertTrue(config.permits(adUnitID: RewardedGenerationAdConfiguration.testAdUnitID))
        XCTAssertFalse(config.permits(adUnitID: liveUnit))
        XCTAssertFalse(make(debug: true, app: liveApp, unit: liveUnit).isConfigured)
        XCTAssertFalse(make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, enabled: "NO").isConfigured)
    }

    func testReleaseRejectsTestAdsMissingConfigurationAndDefaultOff() {
        XCTAssertFalse(make(debug: false, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID).isConfigured)
        XCTAssertFalse(RewardedGenerationAdConfiguration(infoDictionary: [:], isDebugBuild: false).isConfigured)
        XCTAssertFalse(make(debug: false, app: liveApp, unit: liveUnit, enabled: "NO").isConfigured)
        XCTAssertFalse(make(debug: false, app: "$(SPYCLASH_ADMOB_APP_ID)", unit: "$(SPYCLASH_REWARDED_AD_UNIT_ID)").isConfigured)
    }

    func testReleaseRequiresMatchingPublisherAndRejectsServerUnitReplacement() {
        let config = make(debug: false, app: liveApp, unit: liveUnit)
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.isTestConfiguration)
        XCTAssertTrue(config.permits(adUnitID: liveUnit))
        XCTAssertFalse(config.permits(adUnitID: "ca-app-pub-1234567890123456/1111111111"))
        XCTAssertFalse(make(debug: false, app: liveApp, unit: "ca-app-pub-9999999999999999/0987654321").isConfigured)
        XCTAssertFalse(make(debug: false, app: liveApp, unit: liveUnit + "\nunknown").isConfigured)
    }

    private func make(debug: Bool, app: String, unit: String, enabled: String = "YES") -> RewardedGenerationAdConfiguration {
        RewardedGenerationAdConfiguration(infoDictionary: [
            "GADApplicationIdentifier": app,
            "SpyClashRewardedAdUnitID": unit,
            "SpyClashAdsEnabled": enabled,
        ], isDebugBuild: debug)
    }
}
