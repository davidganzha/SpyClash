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

    private func make(debug: Bool, app: String, unit: String, enabled: String = "YES") -> RewardedGenerationAdConfiguration {
        RewardedGenerationAdConfiguration(infoDictionary: [
            "GADApplicationIdentifier": app,
            "SpyClashRewardedAdUnitID": unit,
            "SpyClashAdsEnabled": enabled,
        ], isDebugBuild: debug)
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
