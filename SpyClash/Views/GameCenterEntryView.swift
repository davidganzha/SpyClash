#if SPYCLASH_SUPABASE
import SwiftUI

struct GameCenterEntryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            SpyBrandMark()
                .frame(width: 112, height: 112)
                .padding(.bottom, 36)
            ProgressView()
                .tint(.white)
                .padding(.bottom, 22)
            Text(title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("gamecenter.entry.title")
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Spacer()
            Button {
                appState.cancelGameCenterSignIn()
            } label: {
                Text(classicAction)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gamecenter.entry.classic")
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SpyBackground())
    }

    private var title: String {
        switch appState.language {
        case .ru: "Вход через Game Center…"
        case .uk: "Вхід через Game Center…"
        case .es: "Conectando con Game Center…"
        case .en: "Signing in with Game Center…"
        }
    }

    private var subtitle: String {
        switch appState.language {
        case .ru: "Подготавливаем твой профиль SpyClash"
        case .uk: "Готуємо твій профіль SpyClash"
        case .es: "Preparando tu perfil de SpyClash"
        case .en: "Getting your SpyClash profile ready"
        }
    }

    private var classicAction: String {
        switch appState.language {
        case .ru: "Обычная регистрация или вход"
        case .uk: "Звичайна реєстрація або вхід"
        case .es: "Registrarse o iniciar sesión de otra forma"
        case .en: "Register or sign in another way"
        }
    }
}
#endif
