import Foundation

/// Backend selection is an immutable build choice, never a downloaded switch.
enum SupabaseAppRuntime {
#if SPYCLASH_SUPABASE
    static let isEnabled = true
    static let callbackScheme = "spyclash-supabasetest"
#else
    static let isEnabled = false
    static let callbackScheme = "spyclash"
#endif
    static var permitsPurchases: Bool { !SupabaseTestEnvironment.isEnabled && !isEnabled }
    static var permitsPush: Bool { !SupabaseTestEnvironment.isEnabled && !isEnabled }
    @MainActor static var permitsAppleSignIn: Bool {
#if SPYCLASH_SUPABASE
        (try? SupabaseAppSession.shared.configuration().appleSignInEnabled) == true
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
    var emailOTPLength: Int? = nil
    var resolvedEmailOTPLength: Int { 6 }

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "SupabaseAppConfiguration", withExtension: "json") else {
            throw Base44Error(message: "The staging backend configuration is missing.", code: "staging_configuration_missing")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        return try value.validated()
    }

    func validated() throws -> Self {
        guard backendURL == "https://bbkfsgnordtdiblgdzkg.supabase.co",
              publishableKey.hasPrefix("sb_publishable_"), !publishableKey.contains(where: { $0.isWhitespace }),
              emailOTPLength == nil || emailOTPLength == 6 else {
            throw Base44Error(message: "The staging backend configuration is invalid.", code: "staging_configuration_invalid")
        }
        return self
    }
}
#endif
