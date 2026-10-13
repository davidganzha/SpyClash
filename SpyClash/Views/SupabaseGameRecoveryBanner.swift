#if SPYCLASH_SUPABASE_TEST || SPYCLASH_SUPABASE
import SwiftUI

/// Recovery augments the original game surface without replacing its controls.
struct SupabaseGameRecoveryBanner: View {
    @Environment(AppState.self) private var appState
    var onRecovered: (JSONValue) async -> Void = { _ in }
    @State private var retrying = false
    @State private var message = ""
    private var adapter: SupabaseGameAdapter { .shared }

    var body: some View {
        if adapter.hasPendingRecovery && !adapter.store.commandInFlight {
            VStack(spacing: 8) {
                Text(appState.language == .ru ? "Действие сохранено. Восстанови связь и повтори." : "Your action is saved. Reconnect and retry.")
                    .font(.caption)
                if !message.isEmpty { Text(message).font(.caption2) }
                Button(appState.language == .ru ? "Повторить действие" : "Retry saved action") {
                    guard !retrying else { return }
                    retrying = true
                    Task { @MainActor in
                        defer { retrying = false }
                        do {
                            let response = try await adapter.retrySavedCommand()
                            appState.synchronizeSupabaseTestRoom()
                            message = ""
                            await onRecovered(response)
                        } catch { message = error.localizedDescription }
                    }
                }
                .buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
                .disabled(retrying)
                .accessibilityIdentifier("supabase.fullGameRetry")
            }
            .foregroundStyle(SpyTheme.amber)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(SpyTheme.black)
            .accessibilityIdentifier("supabase.fullGameRecovery")
        }
    }
}
#endif
