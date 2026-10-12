import Foundation

/// A separately signed test target selects this at compile time. Production has
/// no runtime switch that can replace its backend or accept fixture credentials.
enum SupabaseTestEnvironment {
#if SPYCLASH_SUPABASE_TEST
    static let isEnabled = true
#else
    static let isEnabled = false
#endif

    static var configurationURL: URL {
        if let path = ProcessInfo.processInfo.environment["LAB_CONFIG_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupabaseTest/config.json")
    }

    static let unavailableMessage = "Unavailable in the Supabase game test build."
}
