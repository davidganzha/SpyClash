import XCTest
@testable import SpyClash

final class UnityAdsTestConfigurationTests: XCTestCase {
    private let info: [String: Any] = [
        "SpyClashUnityTestGameID": UnityAdsTestConfiguration.sampleGameID,
        "SpyClashUnityTestAdUnitID": UnityAdsTestConfiguration.sampleAdUnitID
    ]
    private let projectInfo: [String: Any] = [
        "SpyClashUnityTestGameID": "800429660",
        "SpyClashUnityTestAdUnitID": "BP_Rewarded_iOS"
    ]

    func testReleaseCannotEnableUnityEvenWithEveryTestFlag() {
        var configured = projectInfo
        configured["SpyClashUnityTestAdsEnabled"] = "YES"
        let config = UnityAdsTestConfiguration(infoDictionary: configured,
            arguments: ["--spyclash-test-unity-ads", "--spyclash-unity-ad-preview", "--spyclash-unity-live-ad-preview"], isDebugBuild: false)
        XCTAssertFalse(config.isEnabled)
        XCTAssertFalse(config.opensPreview)
        XCTAssertTrue(config.isTestMode)
    }

    func testNormalDebugLaunchDoesNotEnableSDK() {
        XCTAssertFalse(make().isEnabled)
        XCTAssertFalse(make(arguments: ["--spyclash-test-unity-ads=true"]).isEnabled)
        XCTAssertFalse(make(info: projectInfo).isEnabled)
        XCTAssertTrue(make(info: projectInfo).isTestMode)
    }

    func testExplicitPreviewUsesSampleWithoutMockingAccount() {
        let config = make(arguments: ["--spyclash-unity-ad-preview"])
        XCTAssertTrue(config.isEnabled)
        XCTAssertTrue(config.opensPreview)
        XCTAssertEqual(config.gameID, "14850")
        XCTAssertEqual(config.adUnitID, "rewardedVideo")
        XCTAssertTrue(config.isTestMode)
    }

    func testIntegratedFlagDoesNotReplaceNormalAppRoot() {
        let config = make(arguments: ["--spyclash-test-unity-ads"])
        XCTAssertTrue(config.isEnabled)
        XCTAssertFalse(config.opensPreview)
        XCTAssertTrue(config.isTestMode)
    }

    func testFixturePreviewCannotLoadRealSDK() {
        XCTAssertFalse(make(arguments: ["--spyclash-test-unity-ads", "--spyclash-ui-preview"]).isEnabled)
        let liveFixture = make(info: projectInfo, arguments: ["--spyclash-unity-live-ad-preview", "--spyclash-ui-preview"])
        XCTAssertFalse(liveFixture.isEnabled)
        XCTAssertFalse(liveFixture.opensPreview)
        XCTAssertTrue(liveFixture.isTestMode)
    }

    func testExplicitLivePreviewUsesOwnProject() {
        let config = make(info: projectInfo, arguments: ["--spyclash-unity-live-ad-preview"])
        XCTAssertTrue(config.isEnabled)
        XCTAssertTrue(config.opensPreview)
        XCTAssertFalse(config.isTestMode)
        XCTAssertEqual(config.gameID, "800429660")
        XCTAssertEqual(config.adUnitID, "BP_Rewarded_iOS")
    }

    func testPublicSampleCannotRequestLiveAds() {
        for sampleID in ["14850", "014850"] {
            var sample = info
            sample["SpyClashUnityTestGameID"] = sampleID
            sample["SpyClashUnityTestAdsEnabled"] = "YES"
            let config = make(info: sample, arguments: ["--spyclash-unity-live-ad-preview"])
            XCTAssertFalse(config.isEnabled)
            XCTAssertFalse(config.opensPreview)
            XCTAssertTrue(config.isTestMode)
        }
    }

    func testOwnProjectUsesTestAdsUnlessLiveFlagIsExact() {
        for arguments in [["--spyclash-test-unity-ads"], ["--spyclash-unity-ad-preview"]] {
            let config = make(info: projectInfo, arguments: arguments)
            XCTAssertTrue(config.isEnabled)
            XCTAssertTrue(config.isTestMode)
        }
        let misspelled = make(info: projectInfo, arguments: ["--spyclash-unity-live-ad-preview=true"])
        XCTAssertFalse(misspelled.isEnabled)
        XCTAssertTrue(misspelled.isTestMode)
    }

    func testEmbeddedEnablingCannotRequestLiveAds() {
        var configured = projectInfo
        configured["SpyClashUnityTestAdsEnabled"] = "YES"
        let config = make(info: configured)
        XCTAssertTrue(config.isEnabled)
        XCTAssertFalse(config.opensPreview)
        XCTAssertTrue(config.isTestMode)
    }

    func testInvalidIDsCannotStartSDK() {
        for gameID in ["", "0", "$(MISSING)", "abc", "12 34"] {
            var invalid = projectInfo
            invalid["SpyClashUnityTestGameID"] = gameID
            for argument in ["--spyclash-unity-ad-preview", "--spyclash-unity-live-ad-preview"] {
                let config = make(info: invalid, arguments: [argument])
                XCTAssertFalse(config.isEnabled)
                XCTAssertTrue(config.isTestMode)
            }
        }
        for unitID in ["", "$(MISSING)", "rewarded video"] {
            var invalid = projectInfo
            invalid["SpyClashUnityTestAdUnitID"] = unitID
            for argument in ["--spyclash-unity-ad-preview", "--spyclash-unity-live-ad-preview"] {
                let config = make(info: invalid, arguments: [argument])
                XCTAssertFalse(config.isEnabled)
                XCTAssertTrue(config.isTestMode)
            }
        }
    }

    private func make(info: [String: Any]? = nil, arguments: [String] = []) -> UnityAdsTestConfiguration {
        UnityAdsTestConfiguration(infoDictionary: info ?? self.info, arguments: arguments, isDebugBuild: true)
    }
}
