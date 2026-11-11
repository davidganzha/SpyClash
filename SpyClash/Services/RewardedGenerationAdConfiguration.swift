import Foundation

/// An explicit, build-time gate. A server response cannot enable advertising or
/// replace the configured ad unit. Debug defaults to Google's sample pair. An
/// explicit local gate permits owned IDs on Simulator, which Google treats as
/// a test device. Physical Debug builds remain limited to the sample pair.
struct RewardedGenerationAdConfiguration {
    static let testAppID = "ca-app-pub-3940256099942544~1458002511"
    static let testAdUnitID = "ca-app-pub-3940256099942544/1712485313"

    let appID: String
    let adUnitID: String
    let isConfigured: Bool
    let isTestConfiguration: Bool
    let isOwnedSimulatorTestConfiguration: Bool
    private let permitsSampleSimulatorTesting: Bool
    private let integratedSampleTestingEnabled: Bool

    init(infoDictionary: [String: Any], isDebugBuild: Bool, isSimulator: Bool = false) {
        appID = (infoDictionary["GADApplicationIdentifier"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        adUnitID = (infoDictionary["SpyClashRewardedAdUnitID"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = infoDictionary["SpyClashRewardedAdProvider"] as? String ?? "admob"
        let enabled = Self.isEnabled(infoDictionary["SpyClashAdsEnabled"]) && provider == "admob"
        let isTest = appID == Self.testAppID && adUnitID == Self.testAdUnitID
        isTestConfiguration = isDebugBuild && enabled && isTest
        permitsSampleSimulatorTesting = isDebugBuild && isSimulator && enabled && isTest
        integratedSampleTestingEnabled = Self.isEnabled(infoDictionary["SpyClashIntegratedTestAdsEnabled"])
        let validApp = appID.range(of: #"^ca-app-pub-[0-9]{16}~[0-9]{10}$"#, options: .regularExpression) != nil
        let validUnit = adUnitID.range(of: #"^ca-app-pub-[0-9]{16}/[0-9]{10}$"#, options: .regularExpression) != nil
        let samePublisher = appID.split(separator: "~").first == adUnitID.split(separator: "/").first
        let isSamplePublisher = appID.hasPrefix("ca-app-pub-3940256099942544") || adUnitID.hasPrefix("ca-app-pub-3940256099942544")
        let validOwnedPair = validApp && validUnit && samePublisher && !isSamplePublisher
        let ownedSimulatorTestEnabled = Self.isEnabled(infoDictionary["SpyClashOwnedAdMobSimulatorTestEnabled"])
        isOwnedSimulatorTestConfiguration = isDebugBuild && isSimulator && ownedSimulatorTestEnabled && enabled && validOwnedPair
        if isDebugBuild {
            isConfigured = isTestConfiguration || isOwnedSimulatorTestConfiguration
        } else {
            // A local test configuration must fail closed if used to archive.
            isConfigured = enabled && validOwnedPair && !ownedSimulatorTestEnabled
        }
    }

    func permits(adUnitID: String) -> Bool {
        isConfigured && adUnitID == self.adUnitID
    }

    /// A local viewing control in the normal app; it cannot grant account credits.
    func permitsLocalSampleTest(arguments: [String], isPreview: Bool) -> Bool {
        permitsSampleSimulatorTesting && !isPreview
            && (integratedSampleTestingEnabled || arguments.contains("--spyclash-test-ads"))
            && !arguments.contains("--spyclash-ui-preview")
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        if let string = value as? String {
            return ["YES", "TRUE", "1"].contains(string.uppercased())
        }
        return (value as? Bool) == true
    }

    static var current: Self {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return Self(infoDictionary: Bundle.main.infoDictionary ?? [:], isDebugBuild: isDebugBuild, isSimulator: isSimulator)
    }
}
