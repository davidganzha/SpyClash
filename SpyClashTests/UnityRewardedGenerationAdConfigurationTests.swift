import XCTest
@testable import SpyClash

final class UnityRewardedGenerationAdConfigurationTests: XCTestCase {
    private var info: [String: Any] {
        ["SpyClashAdsEnabled": "YES", "SpyClashRewardedAdProvider": "unity",
         "SpyClashUnityGameID": "800429660", "SpyClashUnityRewardedAdUnitID": "BP_Rewarded_iOS",
         "SpyClashUnityTestMode": "NO"]
    }

    private func attempt(game: String = "800429660", unit: String = "BP_Rewarded_iOS", provider: GenerationRewardProvider = .unity, sid: String? = "opaque-attempt.legacy.strong-server-nonce", customData: String = "opaque-attempt.legacy.strong-server-nonce") -> GenerationRewardAttempt {
        .init(attemptID: UUID(), customData: customData, adUnitID: unit, userID: "opaque-owner", provider: provider, unityGameID: game, serverID: sid)
    }

    func testOwnedReleaseConfigurationPinsGamePlacementAndServerContext() {
        let config = UnityRewardedGenerationAdConfiguration(infoDictionary: info)
        XCTAssertTrue(config.isConfigured)
        XCTAssertTrue(config.permits(attempt()))
        XCTAssertFalse(config.permits(attempt(game: "999999")))
        XCTAssertFalse(config.permits(attempt(unit: "Other_Placement")))
        XCTAssertFalse(config.permits(attempt(provider: .admob)))
        XCTAssertFalse(config.permits(attempt(sid: nil)))
        XCTAssertFalse(config.permits(attempt(sid: "a-different-server-attempt")))
        for value in ["", "short", "person@example.com", "space in a server nonce", String(repeating: "a", count: 2_049)] {
            XCTAssertFalse(config.permits(attempt(sid: value, customData: value)))
        }
    }

    func testReleaseRejectsDisabledSampleMalformedAndTestConfigurations() {
        XCTAssertFalse(UnityRewardedGenerationAdConfiguration(infoDictionary: [:]).isConfigured)
        for (key, value) in [
            ("SpyClashAdsEnabled", "NO"), ("SpyClashRewardedAdProvider", "admob"),
            ("SpyClashUnityGameID", "14850"), ("SpyClashUnityGameID", "00014850"),
            ("SpyClashUnityGameID", "0"), ("SpyClashUnityGameID", "$(GAME_ID)"),
            ("SpyClashUnityRewardedAdUnitID", ""), ("SpyClashUnityRewardedAdUnitID", "bad placement"),
            ("SpyClashUnityTestMode", "YES"), ("SpyClashUnityTestMode", "$(TEST_MODE)"),
        ] {
            var candidate = info; candidate[key] = value
            XCTAssertFalse(UnityRewardedGenerationAdConfiguration(infoDictionary: candidate).isConfigured, "Must reject \(key)=\(value)")
        }
        var missing = info; missing.removeValue(forKey: "SpyClashUnityTestMode")
        XCTAssertFalse(UnityRewardedGenerationAdConfiguration(infoDictionary: missing).isConfigured)
    }

    func testUnityProviderCannotAccidentallyInitializeGoogleSampleOrOwnedUnits() {
        var candidate = info
        candidate["GADApplicationIdentifier"] = RewardedGenerationAdConfiguration.testAppID
        candidate["SpyClashRewardedAdUnitID"] = RewardedGenerationAdConfiguration.testAdUnitID
        for debug in [true, false] {
            let config = RewardedGenerationAdConfiguration(infoDictionary: candidate, isDebugBuild: debug, isSimulator: true)
            XCTAssertFalse(config.isConfigured)
            XCTAssertFalse(config.isTestConfiguration)
            XCTAssertFalse(config.permitsLocalSampleTest(arguments: ["--spyclash-test-ads"], isPreview: false))
        }
    }

    func testAttemptDecodingPreservesUnityTokenAndOldAdMobResponses() throws {
        let id = UUID().uuidString
        let body: [String: Any] = ["attempt_id": id, "custom_data": "opaque-attempt.legacy.strong-server-nonce",
            "ad_unit_id": "BP_Rewarded_iOS", "user_id": "opaque-owner", "provider": "unity",
            "unity_game_id": "800429660", "server_id": "opaque-attempt.legacy.strong-server-nonce"]
        let decoded = try JSONDecoder().decode(GenerationRewardAttempt.self, from: JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(decoded.attemptID, UUID(uuidString: id))
        XCTAssertEqual(decoded.provider, .unity)
        XCTAssertTrue(UnityRewardedGenerationAdConfiguration(infoDictionary: info).permits(decoded))
        var legacy = body
        legacy.removeValue(forKey: "provider")
        XCTAssertEqual(try JSONDecoder().decode(GenerationRewardAttempt.self, from: JSONSerialization.data(withJSONObject: legacy)).provider, .admob)
        var unknown = body; unknown["provider"] = "unknown"
        XCTAssertThrowsError(try JSONDecoder().decode(GenerationRewardAttempt.self, from: JSONSerialization.data(withJSONObject: unknown)))
    }

    func testReleaseCapabilityOptsInWithNumericBuildOnlyWhenUnityCanServeRewards() throws {
        var release = info
        release["CFBundleIdentifier"] = "com.spyclash.ios"
        release["CFBundleVersion"] = "228"
        let fields = GenerationRewardClientCapabilities.enrollmentFields(infoDictionary: release, isDebugBuild: false)
        XCTAssertEqual(fields, ["supported_reward_provider": .string("unity"), "client_build": .number(228)])
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) as? [String: Any])
        XCTAssertEqual(wire["client_build"] as? Int, 228)
        XCTAssertNil(wire["client_build"] as? String, "The server capability contract requires an integer build.")
        release["CFBundleVersion"] = "229"
        XCTAssertEqual(GenerationRewardClientCapabilities.enrollmentFields(infoDictionary: release, isDebugBuild: false)["client_build"], .number(229))
    }

    func testDebugSyntheticDisabledAndOldClientsCannotEnrollIntoNewQuota() {
        var release = info
        release["CFBundleIdentifier"] = "com.spyclash.ios"
        release["CFBundleVersion"] = "228"
        XCTAssertTrue(GenerationRewardClientCapabilities.enrollmentFields(infoDictionary: release, isDebugBuild: true).isEmpty)
        XCTAssertTrue(GenerationRewardClientCapabilities.enrollmentFields(infoDictionary: [:], isDebugBuild: false).isEmpty)
        for (key, value) in [
            ("CFBundleIdentifier", "com.spyclash.ios.supabasetest"),
            ("CFBundleVersion", "200"), ("CFBundleVersion", "218"), ("CFBundleVersion", "227"),
            ("CFBundleVersion", "228.0"), ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)"),
            ("SpyClashAdsEnabled", "NO"), ("SpyClashUnityTestMode", "YES"),
            ("SpyClashRewardedAdProvider", "admob"), ("SpyClashUnityGameID", "14850"),
        ] {
            var candidate = release; candidate[key] = value
            XCTAssertTrue(GenerationRewardClientCapabilities.enrollmentFields(infoDictionary: candidate, isDebugBuild: false).isEmpty, "Must not enroll \(key)=\(value)")
        }
    }
}
