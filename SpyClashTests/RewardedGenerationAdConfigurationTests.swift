import XCTest
import UIKit
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

    func testOwnedSimulatorRequiresExplicitGateAndKeepsSampleCreativeFlagFalse() {
        XCTAssertFalse(make(debug: true, app: liveApp, unit: liveUnit, simulator: true).isConfigured)
        XCTAssertFalse(make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: "NO").isConfigured)

        let config = make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: "YES")
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.isTestConfiguration, "Owned test units must not request a Google sample creative override.")
        XCTAssertTrue(config.permits(adUnitID: liveUnit))
        XCTAssertFalse(config.permits(adUnitID: RewardedGenerationAdConfiguration.testAdUnitID))
        XCTAssertFalse(config.permits(adUnitID: "ca-app-pub-1234567890123456/1111111111"))
    }

    func testOwnedSimulatorGateCannotEnablePhysicalDebug() {
        XCTAssertFalse(make(debug: true, app: liveApp, unit: liveUnit, simulator: false, ownedSimulatorTest: true).isConfigured)
        let sample = make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: false, ownedSimulatorTest: true)
        XCTAssertTrue(sample.isConfigured)
        XCTAssertTrue(sample.isTestConfiguration)
    }

    func testOwnedSimulatorGateStillRequiresAdsEnabled() {
        XCTAssertFalse(make(debug: true, app: liveApp, unit: liveUnit, enabled: "NO", simulator: true, ownedSimulatorTest: true).isConfigured)
        let config = make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: true)
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.isTestConfiguration)
    }

    func testOwnedSimulatorRejectsInvalidOrMismatchedIDs() {
        XCTAssertFalse(make(debug: true, app: "$(SPYCLASH_ADMOB_APP_ID)", unit: liveUnit, simulator: true, ownedSimulatorTest: true).isConfigured)
        XCTAssertFalse(make(debug: true, app: liveApp, unit: "", simulator: true, ownedSimulatorTest: true).isConfigured)
        XCTAssertFalse(make(debug: true, app: liveApp, unit: liveUnit + "\nunknown", simulator: true, ownedSimulatorTest: true).isConfigured)
        XCTAssertFalse(make(debug: true, app: liveApp, unit: "ca-app-pub-9999999999999999/0987654321", simulator: true, ownedSimulatorTest: true).isConfigured)
        XCTAssertFalse(make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: liveUnit, simulator: true, ownedSimulatorTest: true).isConfigured)
        XCTAssertFalse(make(debug: true, app: liveApp, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true, ownedSimulatorTest: true).isConfigured)
    }

    func testOwnedSimulatorGatePreservesOfficialSamplePair() {
        let config = make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true, ownedSimulatorTest: true)
        XCTAssertTrue(config.isConfigured)
        XCTAssertTrue(config.isTestConfiguration)
        XCTAssertTrue(config.permits(adUnitID: RewardedGenerationAdConfiguration.testAdUnitID))
    }

    func testReleaseRejectsOwnedSimulatorGateEvenWithOtherwiseValidConfiguration() {
        XCTAssertFalse(make(debug: false, app: liveApp, unit: liveUnit, enabled: "NO", simulator: true, ownedSimulatorTest: true).isConfigured)
        XCTAssertFalse(make(debug: false, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true, ownedSimulatorTest: true).isConfigured)
        let config = make(debug: false, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: true)
        XCTAssertFalse(config.isConfigured)
        XCTAssertFalse(config.isTestConfiguration)
        XCTAssertFalse(make(debug: false, app: liveApp, unit: liveUnit, simulator: false, ownedSimulatorTest: "YES").isConfigured)
        XCTAssertTrue(make(debug: false, app: liveApp, unit: liveUnit, ownedSimulatorTest: "NO").isConfigured)
    }

    func testOwnedTestingCapabilityRequiresEveryBuildAndConfigurationGate() {
        XCTAssertTrue(make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: true).isOwnedSimulatorTestConfiguration)
        for configuration in [
            make(debug: true, app: liveApp, unit: liveUnit, simulator: true),
            make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: false),
            make(debug: true, app: liveApp, unit: liveUnit, simulator: false, ownedSimulatorTest: true),
            make(debug: true, app: liveApp, unit: liveUnit, enabled: "NO", simulator: true, ownedSimulatorTest: true),
            make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true, ownedSimulatorTest: true),
            make(debug: false, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: true),
            make(debug: false, app: liveApp, unit: liveUnit, simulator: false, ownedSimulatorTest: "NO"),
            make(debug: true, app: liveApp, unit: "ca-app-pub-9999999999999999/0987654321", simulator: true, ownedSimulatorTest: true),
        ] {
            XCTAssertFalse(configuration.isOwnedSimulatorTestConfiguration)
        }
    }

    func testLocalSampleViewingRequiresExplicitFlagOutsideUIPreview() {
        let config = make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true)
        XCTAssertTrue(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads"], isPreview: false))
        XCTAssertFalse(config.permitsLocalSampleTest(arguments: [], isPreview: false))
        XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads=true"], isPreview: false))
        XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads"], isPreview: true))
        XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads", "--spyclash-ui-preview"], isPreview: false))
    }

    func testLocalSampleViewingRejectsPhysicalReleaseDisabledAndOwnedConfigurations() {
        let sampleApp = RewardedGenerationAdConfiguration.testAppID
        let sampleUnit = RewardedGenerationAdConfiguration.testAdUnitID
        for config in [
            make(debug: true, app: sampleApp, unit: sampleUnit, simulator: false),
            make(debug: false, app: sampleApp, unit: sampleUnit, simulator: true),
            make(debug: true, app: sampleApp, unit: sampleUnit, enabled: "NO", simulator: true),
            make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: true),
            make(debug: false, app: liveApp, unit: liveUnit, simulator: true),
            make(debug: true, app: sampleApp, unit: liveUnit, simulator: true),
            make(debug: true, app: liveApp, unit: sampleUnit, simulator: true),
        ] {
            XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads"], isPreview: false))
        }
    }

    func testIntegratedSampleViewingPersistsWithoutLaunchArgumentsAndStillRejectsPreview() {
        let config = make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true, integratedSampleTest: "YES")
        XCTAssertTrue(config.permitsLocalSampleTest(arguments: [], isPreview: false))
        XCTAssertFalse(config.permitsLocalSampleTest(arguments: [], isPreview: true))
        XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-ui-preview"], isPreview: false))
        let disabled = make(debug: true, app: RewardedGenerationAdConfiguration.testAppID, unit: RewardedGenerationAdConfiguration.testAdUnitID, simulator: true, integratedSampleTest: "NO")
        XCTAssertFalse(disabled.permitsLocalSampleTest(arguments: [], isPreview: false))
        XCTAssertTrue(disabled.permitsLocalSampleTest(arguments: ["--spyclash-test-ads"], isPreview: false))
    }

    func testIntegratedSampleBuildSettingCannotBypassConfigurationGates() {
        let sampleApp = RewardedGenerationAdConfiguration.testAppID
        let sampleUnit = RewardedGenerationAdConfiguration.testAdUnitID
        for config in [
            make(debug: true, app: sampleApp, unit: sampleUnit, simulator: false, integratedSampleTest: true),
            make(debug: false, app: sampleApp, unit: sampleUnit, simulator: true, integratedSampleTest: true),
            make(debug: true, app: sampleApp, unit: sampleUnit, enabled: "NO", simulator: true, integratedSampleTest: true),
            make(debug: true, app: liveApp, unit: liveUnit, simulator: true, ownedSimulatorTest: true, integratedSampleTest: true),
            make(debug: false, app: liveApp, unit: liveUnit, simulator: true, integratedSampleTest: true),
        ] {
            XCTAssertFalse(config.permitsLocalSampleTest(arguments: [], isPreview: false))
            XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads"], isPreview: false))
        }
    }

    private func make(debug: Bool, app: String, unit: String, enabled: String = "YES", simulator: Bool = false, ownedSimulatorTest: Any? = nil, integratedSampleTest: Any? = nil) -> RewardedGenerationAdConfiguration {
        var infoDictionary: [String: Any] = [
            "GADApplicationIdentifier": app,
            "SpyClashRewardedAdUnitID": unit,
            "SpyClashAdsEnabled": enabled,
        ]
        infoDictionary["SpyClashOwnedAdMobSimulatorTestEnabled"] = ownedSimulatorTest
        infoDictionary["SpyClashIntegratedTestAdsEnabled"] = integratedSampleTest
        return RewardedGenerationAdConfiguration(infoDictionary: infoDictionary, isDebugBuild: debug, isSimulator: simulator)
    }
}

@MainActor
final class RewardedGenerationAdTransitionTests: XCTestCase {
    func testBlackoutStaysInsideAppContentAndPreservesSDKLayer() async throws {
        let presentationContainer = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let appContent = UIView(frame: presentationContainer.bounds)
        let sheetContent = UIView(frame: CGRect(x: 0, y: 60, width: 390, height: 784))
        let appControl = UIButton()
        appContent.addSubview(appControl)
        presentationContainer.addSubview(appContent)
        presentationContainer.addSubview(sheetContent)
        let transition = RewardedGenerationAdTransition(contentViews: [appContent, sheetContent])
        await transition.fadeToBlack(reduceMotion: true)

        let black = try XCTUnwrap(sheetContent.subviews.last)
        XCTAssertEqual(black.frame, sheetContent.bounds)
        XCTAssertEqual(black.alpha, 1)
        XCTAssertEqual(black.backgroundColor, .black)
        XCTAssertTrue(black.accessibilityElementsHidden)
        XCTAssertEqual(presentationContainer.subviews.count, 2, "Overlays cannot be attached to the shared modal container.")

        // Model the SDK adding its own modal above the existing app content.
        let sdkContent = UIView(frame: presentationContainer.bounds)
        let closeControl = UIButton()
        sdkContent.addSubview(closeControl)
        presentationContainer.addSubview(sdkContent)
        await transition.revealContent(reduceMotion: true, animated: true)
        XCTAssertTrue(presentationContainer.subviews.last === sdkContent)
        XCTAssertEqual(sdkContent.subviews, [closeControl])
        XCTAssertEqual(appContent.subviews, [appControl])
        XCTAssertTrue(sheetContent.subviews.isEmpty)
    }

    func testCancellationDuringFadeRemovesBlackoutAndResumesWaiter() async {
        let content = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let transition = RewardedGenerationAdTransition(contentViews: [content])
        var started = false
        let fade = Task {
            started = true
            await transition.fadeToBlack(reduceMotion: false)
        }
        while !started { await Task.yield() }
        transition.remove()
        transition.remove()
        await fade.value
        XCTAssertTrue(content.subviews.isEmpty)
        await transition.revealContent(reduceMotion: false, animated: true)
        XCTAssertTrue(content.subviews.isEmpty, "A late dismissal must not recreate a cancelled overlay.")
    }

    func testBackgroundCleanupDuringReturnFinishesWithoutBlackScreen() async {
        let content = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let transition = RewardedGenerationAdTransition(contentViews: [content])
        await transition.fadeToBlack(reduceMotion: true)
        var started = false
        let reveal = Task {
            started = true
            await transition.revealContent(reduceMotion: false, animated: true)
        }
        while !started { await Task.yield() }
        transition.remove()
        await reveal.value
        XCTAssertTrue(content.subviews.isEmpty)
    }
}
