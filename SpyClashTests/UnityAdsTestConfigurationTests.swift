import XCTest
@testable import SpyClash

final class UnityAdsTestConfigurationTests: XCTestCase {
    private let info: [String: Any] = [
        "SpyClashUnityTestGameID": UnityAdsTestConfiguration.sampleGameID,
        "SpyClashUnityTestAdUnitID": UnityAdsTestConfiguration.sampleAdUnitID
    ]

    func testReleaseCannotEnableUnityEvenWithEveryTestFlag() {
        var configured = info
        configured["SpyClashUnityTestAdsEnabled"] = "YES"
        let config = UnityAdsTestConfiguration(infoDictionary: configured,
            arguments: ["--spyclash-test-unity-ads", "--spyclash-unity-ad-preview"], isDebugBuild: false)
        XCTAssertFalse(config.isEnabled)
        XCTAssertFalse(config.opensPreview)
    }

    func testNormalDebugLaunchDoesNotEnableSDK() {
        XCTAssertFalse(make().isEnabled)
        XCTAssertFalse(make(arguments: ["--spyclash-test-unity-ads=true"]).isEnabled)
    }

    func testExplicitPreviewUsesSampleWithoutMockingAccount() {
        let config = make(arguments: ["--spyclash-unity-ad-preview"])
        XCTAssertTrue(config.isEnabled)
        XCTAssertTrue(config.opensPreview)
        XCTAssertEqual(config.gameID, "14850")
        XCTAssertEqual(config.adUnitID, "rewardedVideo")
    }

    func testIntegratedFlagDoesNotReplaceNormalAppRoot() {
        let config = make(arguments: ["--spyclash-test-unity-ads"])
        XCTAssertTrue(config.isEnabled)
        XCTAssertFalse(config.opensPreview)
    }

    func testFixturePreviewCannotLoadRealSDK() {
        XCTAssertFalse(make(arguments: ["--spyclash-test-unity-ads", "--spyclash-ui-preview"]).isEnabled)
    }

    func testInvalidIDsCannotStartSDK() {
        for gameID in ["", "0", "$(MISSING)", "abc", "12 34"] {
            var invalid = info
            invalid["SpyClashUnityTestGameID"] = gameID
            XCTAssertFalse(make(info: invalid, arguments: ["--spyclash-unity-ad-preview"]).isEnabled)
        }
        for unitID in ["", "$(MISSING)", "rewarded video"] {
            var invalid = info
            invalid["SpyClashUnityTestAdUnitID"] = unitID
            XCTAssertFalse(make(info: invalid, arguments: ["--spyclash-unity-ad-preview"]).isEnabled)
        }
    }

    private func make(info: [String: Any]? = nil, arguments: [String] = []) -> UnityAdsTestConfiguration {
        UnityAdsTestConfiguration(infoDictionary: info ?? self.info, arguments: arguments, isDebugBuild: true)
    }
}
