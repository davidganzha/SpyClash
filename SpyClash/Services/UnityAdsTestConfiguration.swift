import Foundation

/// A local visual comparison only. Unity's test mode is also hardcoded in the
/// presenter; no configuration here can turn this into monetized ad delivery.
struct UnityAdsTestConfiguration {
    // Public sample defaults from Unity-Technologies/unity-ads-ios/Example.
    static let sampleGameID = "14850"
    static let sampleAdUnitID = "rewardedVideo"

    let gameID: String
    let adUnitID: String
    let isEnabled: Bool
    let opensPreview: Bool

    init(infoDictionary: [String: Any], arguments: [String], isDebugBuild: Bool) {
        gameID = (infoDictionary["SpyClashUnityTestGameID"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        adUnitID = (infoDictionary["SpyClashUnityTestAdUnitID"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let flag = infoDictionary["SpyClashUnityTestAdsEnabled"]
        let embedded = (flag as? Bool) == true
            || ["YES", "TRUE", "1"].contains((flag as? String ?? "").uppercased())
        let requested = embedded || arguments.contains("--spyclash-test-unity-ads")
            || arguments.contains("--spyclash-unity-ad-preview")
        let validGame = gameID.range(of: #"^[0-9]{1,32}$"#, options: .regularExpression) != nil
            && gameID.contains(where: { $0 != "0" })
        let validUnit = !adUnitID.isEmpty && adUnitID.utf8.count <= 128
            && adUnitID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !adUnitID.contains("$(")
        isEnabled = isDebugBuild && requested && validGame && validUnit
            && !arguments.contains("--spyclash-ui-preview")
        opensPreview = isEnabled && arguments.contains("--spyclash-unity-ad-preview")
    }

    static var current: Self {
#if DEBUG
        let isDebugBuild = true
#else
        let isDebugBuild = false
#endif
        return Self(infoDictionary: Bundle.main.infoDictionary ?? [:],
                    arguments: ProcessInfo.processInfo.arguments, isDebugBuild: isDebugBuild)
    }
}
