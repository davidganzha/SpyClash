import Foundation

/// An explicit, build-time gate. A server response cannot enable advertising or
/// replace the configured ad unit. Debug builds can only request Google's test ad.
struct RewardedGenerationAdConfiguration {
    static let testAppID = "ca-app-pub-3940256099942544~1458002511"
    static let testAdUnitID = "ca-app-pub-3940256099942544/1712485313"

    let appID: String
    let adUnitID: String
    let isConfigured: Bool
    let isTestConfiguration: Bool

    init(infoDictionary: [String: Any], isDebugBuild: Bool) {
        appID = (infoDictionary["GADApplicationIdentifier"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        adUnitID = (infoDictionary["SpyClashRewardedAdUnitID"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled: Bool
        if let value = infoDictionary["SpyClashAdsEnabled"] as? String {
            enabled = ["YES", "TRUE", "1"].contains(value.uppercased())
        } else {
            enabled = (infoDictionary["SpyClashAdsEnabled"] as? Bool) == true
        }
        let isTest = appID == Self.testAppID && adUnitID == Self.testAdUnitID
        isTestConfiguration = isDebugBuild && enabled && isTest
        if isDebugBuild {
            isConfigured = isTestConfiguration
        } else {
            let validApp = appID.range(of: #"^ca-app-pub-[0-9]{16}~[0-9]{10}$"#, options: .regularExpression) != nil
            let validUnit = adUnitID.range(of: #"^ca-app-pub-[0-9]{16}/[0-9]{10}$"#, options: .regularExpression) != nil
            let samePublisher = appID.split(separator: "~").first == adUnitID.split(separator: "/").first
            let isSamplePublisher = appID.hasPrefix("ca-app-pub-3940256099942544") || adUnitID.hasPrefix("ca-app-pub-3940256099942544")
            isConfigured = enabled && validApp && validUnit && samePublisher && !isSamplePublisher
        }
    }

    func permits(adUnitID: String) -> Bool {
        isConfigured && adUnitID == self.adUnitID
    }

    static var current: Self {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return Self(infoDictionary: Bundle.main.infoDictionary ?? [:], isDebugBuild: isDebugBuild)
    }
}
