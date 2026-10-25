#if SPYCLASH_SUPABASE_PUBLIC
import XCTest
@testable import SpyClash

@MainActor
final class SupabasePublicReleaseTests: XCTestCase {
    func testPublicBundleUsesMainIdentityAndOnlyPublicConfiguration() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.spyclash.ios")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SpyClashBackendMode") as? String, "supabase-public")
        XCTAssertTrue(SupabaseAppRuntime.isEnabled)
        XCTAssertTrue(SupabaseAppRuntime.isMainHybrid)
        XCTAssertEqual(SupabaseAppRuntime.callbackScheme, "spyclash")
        XCTAssertNotNil(Bundle.main.url(forResource: "SupabasePublicConfiguration", withExtension: "json"))
        XCTAssertNil(Bundle.main.url(forResource: "SupabaseMainCandidateConfiguration", withExtension: "json"))
        XCTAssertNil(Bundle.main.url(forResource: "BackendAllowlist", withExtension: "json"))

        let configuration = try SupabaseAppConfiguration.bundled()
        XCTAssertEqual(configuration.backendURL, "https://bbkfsgnordtdiblgdzkg.supabase.co")
        XCTAssertTrue(configuration.mainAccountDeletionEnabled)
        XCTAssertTrue(configuration.appleSignInEnabled)
        XCTAssertTrue(configuration.googleSignInEnabled)
        XCTAssertTrue(configuration.permitsLegacyBilling)
        XCTAssertFalse(configuration.permitsLegacyPush)
    }

    func testPublicConfigurationRejectsUnavailableAccountDeletion() throws {
        var configuration = try SupabaseAppConfiguration.bundled()
        configuration.mainAccountDeletionEnabled = false
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual((error as? Base44Error)?.code, "public_configuration_invalid")
        }
    }

    func testPublicConfigurationRejectsMissingProviderCapabilities() throws {
        let original = try SupabaseAppConfiguration.bundled()
        for keyPath in [\SupabaseAppConfiguration.appleSignInEnabled, \.googleSignInEnabled, \.permitsLegacyBilling] {
            var configuration = original
            configuration[keyPath: keyPath] = false
            XCTAssertThrowsError(try configuration.validated())
        }
    }
}
#endif
