#if SPYCLASH_SUPABASE_TEST || SPYCLASH_SUPABASE
import SwiftUI

/// Saved requests recover in the store; the UI only explains a longer wait.
struct SupabaseGameRecoveryBanner: View {
    @Environment(AppState.self) private var appState
    var onRecovered: (JSONValue) async -> Void = { _ in }
    private var adapter: SupabaseGameAdapter { .shared }

    var body: some View {
        Group {
            if adapter.store.isRecoveringSavedCommand {
                HStack(spacing: 10) {
                    ProgressView().tint(SpyTheme.amber)
                    Text(recoveryMessage).font(.caption)
                }
                .foregroundStyle(SpyTheme.amber)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(SpyTheme.black)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("supabase.fullGameRecovery")
            }
        }
        .onChange(of: adapter.store.recoveryGeneration) { _, _ in
            let actor = adapter.store.userID
            let generation = adapter.store.recoveryGeneration
            guard actor == appState.user?.id else { return }
            let response = adapter.store.recoveredResponse
            appState.synchronizeSupabaseTestRoom()
            Task { @MainActor in
                guard actor == appState.user?.id, actor == adapter.store.userID,
                      generation == adapter.store.recoveryGeneration else { return }
                await onRecovered(response)
            }
        }
    }

    private var recoveryMessage: String {
        switch appState.language {
        case .ru: "Восстанавливаем связь. Действие завершится автоматически."
        case .es: "Restableciendo la conexión. La acción se completará automáticamente."
        case .uk: "Відновлюємо зв’язок. Дія завершиться автоматично."
        default: "Reconnecting. Your action will complete automatically."
        }
    }
}
#endif
