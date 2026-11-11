import Foundation

/// Public build identifiers pin the provider. The callback signing secret lives
/// only on the server and must never be bundled in the application.
struct UnityRewardedGenerationAdConfiguration {
    let gameID: String
    let adUnitID: String
    let isConfigured: Bool

    init(infoDictionary: [String: Any]) {
        gameID = (infoDictionary["SpyClashUnityGameID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        adUnitID = (infoDictionary["SpyClashUnityRewardedAdUnitID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let validGame = gameID.range(of: #"^[0-9]{1,32}$"#, options: .regularExpression) != nil
            && gameID.contains(where: { $0 != "0" })
            && String(gameID.drop(while: { $0 == "0" })) != "14850"
        let validUnit = adUnitID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
        let testMode = Self.flag(infoDictionary["SpyClashUnityTestMode"])
        isConfigured = Self.flag(infoDictionary["SpyClashAdsEnabled"]) == true
            && (infoDictionary["SpyClashRewardedAdProvider"] as? String) == "unity"
            && validGame && validUnit && testMode == false
        // A missing, malformed or unresolved test-mode setting fails closed.
        // Viewing-only Debug experiments use UnityAdsTestPresenter separately.
    }

    func permits(_ attempt: GenerationRewardAttempt) -> Bool {
        guard isConfigured, attempt.provider == .unity,
              attempt.unityGameID == gameID, attempt.adUnitID == adUnitID,
              let sid = attempt.serverID, sid == attempt.customData,
              (16...2_048).contains(sid.utf8.count),
              sid.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else { return false }
        return true
    }

    private static func flag(_ value: Any?) -> Bool? {
        if let value = value as? String {
            switch value.uppercased() {
            case "YES", "TRUE", "1": return true
            case "NO", "FALSE", "0": return false
            default: return nil
            }
        }
        return value as? Bool
    }

    static var current: Self { Self(infoDictionary: Bundle.main.infoDictionary ?? [:]) }
}

/// Capability declaration for the server's persistent per-account rollout.
/// It is not proof of a viewing or a membership grant. Older/debug clients omit
/// it, so they cannot accidentally opt an account into unavailable advertising.
enum GenerationRewardClientCapabilities {
    static func enrollmentFields(infoDictionary: [String: Any], isDebugBuild: Bool) -> [String: JSONValue] {
        guard !isDebugBuild,
              infoDictionary["CFBundleIdentifier"] as? String == "com.spyclash.ios",
              UnityRewardedGenerationAdConfiguration(infoDictionary: infoDictionary).isConfigured,
              let rawBuild = infoDictionary["CFBundleVersion"] as? String,
              rawBuild.range(of: #"^[0-9]{1,9}$"#, options: .regularExpression) != nil,
              let build = Int(rawBuild), build >= 228 else { return [:] }
        return ["supported_reward_provider": .string("unity"), "client_build": .number(Double(build))]
    }

    static var current: [String: JSONValue] {
#if DEBUG
        let isDebugBuild = true
#else
        let isDebugBuild = false
#endif
        return enrollmentFields(infoDictionary: Bundle.main.infoDictionary ?? [:], isDebugBuild: isDebugBuild)
    }
}
