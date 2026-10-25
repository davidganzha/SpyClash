import Foundation

/// Backend selection is an immutable build choice, never a downloaded switch.
enum SupabaseAppRuntime {
#if SPYCLASH_SUPABASE
    static let isEnabled = true
#if SPYCLASH_GAME_CENTER_EXPERIMENT
    static let callbackScheme = "spyclash-gamecenter000"
    static let isMainHybrid = false
#elseif SPYCLASH_SUPABASE_MAIN_CANDIDATE
    static let callbackScheme = "spyclash"
    static let isMainHybrid = true
#else
    static let callbackScheme = "spyclash-supabasetest"
    static let isMainHybrid = false
#endif
#else
    static let isEnabled = false
    static let callbackScheme = "spyclash"
    static let isMainHybrid = false
#endif
    @MainActor static var permitsPurchases: Bool {
#if SPYCLASH_SUPABASE
        isMainHybrid && (try? SupabaseAppSession.shared.configuration().permitsLegacyBilling) == true
#else
        !SupabaseTestEnvironment.isEnabled
#endif
    }
    @MainActor static var permitsPush: Bool {
#if SPYCLASH_SUPABASE
        isMainHybrid && (try? SupabaseAppSession.shared.configuration().permitsLegacyPush) == true
#else
        !SupabaseTestEnvironment.isEnabled
#endif
    }
    static var roomLinkScheme: String {
        SupabaseTestEnvironment.isEnabled ? "spyclash-supabasetest" : callbackScheme
    }
    static var permitsWebRoomLinks: Bool { !isEnabled && !SupabaseTestEnvironment.isEnabled }
    static var radarServiceType: String {
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        return "spy-gc000"
#else
        isEnabled || SupabaseTestEnvironment.isEnabled ? "spy-bbkfsg" : "spyclash-radar"
#endif
    }
    static var radarBackendNamespace: String {
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        return "supabase:" + SupabaseAppConfiguration.configuredProjectReference
#else
        isEnabled || SupabaseTestEnvironment.isEnabled ? "supabase:bbkfsgnordtdiblgdzkg" : "base44"
#endif
    }
    static func acceptsRadarBackend(_ namespace: String?) -> Bool {
        if isEnabled || SupabaseTestEnvironment.isEnabled { return namespace == radarBackendNamespace }
        return namespace == nil || namespace == "base44"
    }
    @MainActor static var deletesOriginalAccount: Bool {
#if SPYCLASH_SUPABASE
        isMainHybrid && (try? SupabaseAppSession.shared.configuration().mainAccountDeletionEnabled) == true
#else
        !SupabaseTestEnvironment.isEnabled
#endif
    }
    @MainActor static var permitsAppleSignIn: Bool {
#if SPYCLASH_SUPABASE
        (try? SupabaseAppSession.shared.configuration().appleSignInEnabled) == true
#else
        !SupabaseTestEnvironment.isEnabled
#endif
    }
    @MainActor static var permitsGoogleSignIn: Bool {
#if SPYCLASH_SUPABASE
        (try? SupabaseAppSession.shared.configuration().googleSignInEnabled) == true
#else
        !SupabaseTestEnvironment.isEnabled
#endif
    }
    @MainActor static var emailOTPLength: Int {
#if SPYCLASH_SUPABASE
        6
#else
        6
#endif
    }
    static func acceptsEmailOTP(_ code: String, length: Int) -> Bool {
        code.utf8.count == length && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func localURL(forServerLink url: URL) -> URL {
        guard isEnabled, url.scheme?.lowercased() == "spyclash",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = callbackScheme
        return components.url ?? url
    }
}

#if SPYCLASH_SUPABASE
struct SupabaseAppConfiguration: Codable, Equatable, Sendable {
    let backendURL: String
    let publishableKey: String
    var appleSignInEnabled: Bool = false
    var googleSignInEnabled: Bool = false
    var permitsLegacyBilling: Bool = false
    var permitsLegacyPush: Bool = false
    var mainAccountDeletionEnabled: Bool = false
    var emailOTPLength: Int? = nil
    var resolvedEmailOTPLength: Int { 6 }
    var projectReference: String {
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        backendURL == "http://127.0.0.1:56330" ? "gamecenter000-local" : "ovowoixuyabccgkxcexp"
#else
        "bbkfsgnordtdiblgdzkg"
#endif
    }
    static var configuredProjectReference: String {
        (try? bundled().projectReference) ?? "invalid-configuration"
    }

    static func bundled() throws -> Self {
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        let resource = "GameCenterAppConfiguration"
#elseif SPYCLASH_SUPABASE_MAIN_CANDIDATE
        let resource = "SupabaseMainCandidateConfiguration"
#else
        let resource = "SupabaseAppConfiguration"
#endif
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw Base44Error(message: "The staging backend configuration is missing.", code: "staging_configuration_missing")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        return try value.validated()
    }

    func validated() throws -> Self {
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        // Exact allowlist: local QA and the separate user-selected test project.
        // The working game's project can never be selected by this target.
        guard ["http://127.0.0.1:56330", "https://ovowoixuyabccgkxcexp.supabase.co"].contains(backendURL),
              Self.isPublicLocalKey(publishableKey),
              !appleSignInEnabled, !googleSignInEnabled,
              !permitsLegacyBilling, !permitsLegacyPush, !mainAccountDeletionEnabled,
              emailOTPLength == nil || emailOTPLength == 6 else {
            throw Base44Error(message: "The isolated test server configuration is invalid.", code: "experiment_configuration_invalid")
        }
#else
        guard backendURL == "https://bbkfsgnordtdiblgdzkg.supabase.co",
              publishableKey.hasPrefix("sb_publishable_"), !publishableKey.contains(where: { $0.isWhitespace }),
              emailOTPLength == nil || emailOTPLength == 6 else {
            throw Base44Error(message: "The staging backend configuration is invalid.", code: "staging_configuration_invalid")
        }
#endif
        return self
    }

#if SPYCLASH_GAME_CENTER_EXPERIMENT
    private static func isPublicLocalKey(_ key: String) -> Bool {
        guard !key.contains(where: { $0.isWhitespace }) else { return false }
        if key.hasPrefix("sb_publishable_") { return true }
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return claims["role"] as? String == "anon"
    }
#endif
}

extension SupabaseAppConfiguration {
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        backendURL = try fields.decode(String.self, forKey: .backendURL)
        publishableKey = try fields.decode(String.self, forKey: .publishableKey)
        appleSignInEnabled = try fields.decodeIfPresent(Bool.self, forKey: .appleSignInEnabled) ?? false
        googleSignInEnabled = try fields.decodeIfPresent(Bool.self, forKey: .googleSignInEnabled) ?? false
        permitsLegacyBilling = try fields.decodeIfPresent(Bool.self, forKey: .permitsLegacyBilling) ?? false
        permitsLegacyPush = try fields.decodeIfPresent(Bool.self, forKey: .permitsLegacyPush) ?? false
        mainAccountDeletionEnabled = try fields.decodeIfPresent(Bool.self, forKey: .mainAccountDeletionEnabled) ?? false
        emailOTPLength = try fields.decodeIfPresent(Int.self, forKey: .emailOTPLength)
    }
}
#endif
