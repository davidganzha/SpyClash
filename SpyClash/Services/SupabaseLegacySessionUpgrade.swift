#if SPYCLASH_SUPABASE
import Foundation

/// An upgrade may finish its network exchange after logout or a new sign-in.
/// Only the still-owning restore attempt may commit the paired credentials.
enum SupabaseLegacySessionUpgrade {
    @MainActor static func restore(
        token: String,
        ownsAttempt: () -> Bool,
        exchange: (String) async throws -> LoginResponse,
        commit: (LoginResponse) async throws -> Void
    ) async throws {
        guard ownsAttempt(), !Task.isCancelled else { throw CancellationError() }
        let response = try await exchange(token)
        guard ownsAttempt(), !Task.isCancelled else { throw CancellationError() }
        try await commit(response)
        guard ownsAttempt(), !Task.isCancelled else { throw CancellationError() }
    }
}
#endif
