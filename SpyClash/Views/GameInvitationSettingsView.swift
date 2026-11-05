import SwiftUI

struct GameInvitationSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionRow(
                title: t("Friends", "Друзья", "Amigos", "Друзі"),
                detail: t("Invitations from accepted friends", "Приглашения от добавленных друзей", "Invitaciones de amigos aceptados", "Запрошення від доданих друзів"),
                symbol: "person.2.fill", value: appState.user?.friendInvitationsAllowed ?? true,
                identifier: "settings.invitations.friends"
            ) { save(friends: $0, strangers: appState.user?.strangerInvitationsAllowed ?? false) }
            permissionRow(
                title: t("Community", "Незнакомцы", "Comunidad", "Незнайомці"),
                detail: t("Allow players outside your friend list", "Разрешить игрокам не из списка друзей", "Permitir jugadores fuera de tus amigos", "Дозволити гравцям не зі списку друзів"),
                symbol: "person.crop.circle.badge.questionmark", value: appState.user?.strangerInvitationsAllowed ?? false,
                identifier: "settings.invitations.strangers"
            ) { save(friends: appState.user?.friendInvitationsAllowed ?? true, strangers: $0) }
            permissionRow(
                title: t("Radar", "Радар", "Radar", "Радар"),
                detail: t("Invitations from nearby players", "Приглашения от игроков рядом", "Invitaciones de jugadores cercanos", "Запрошення від гравців поруч"),
                symbol: "dot.radiowaves.left.and.right", value: appState.radarNearby.invitePolicy != .blocked,
                identifier: "settings.invitations.radar"
            ) { appState.setRadarInvitePolicy($0 ? .ask : .blocked) }
            Text(t("Blocked community players cannot invite you. Radar access and automatic joining are configured below.",
                   "Заблокированные игроки не могут приглашать через сообщество. Доступ к радару и автоматический вход настраиваются ниже.",
                   "Los jugadores bloqueados no pueden invitarte por la comunidad. Configura el acceso al radar y la entrada automática abajo.",
                   "Заблоковані гравці не можуть запрошувати через спільноту. Доступ до радара й автоматичний вхід налаштовуються нижче."))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SpyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if isSaving { ProgressView().tint(SpyTheme.red) }
        }
    }

    private func permissionRow(title: String, detail: String, symbol: String, value: Bool,
                               identifier: String, onChange: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { onChange($0) })) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(SpyTheme.red).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(SpyTheme.muted)
                }
            }
        }
        .tint(SpyTheme.red)
        .disabled(isSaving || appState.user == nil)
        .accessibilityIdentifier(identifier)
    }

    private func save(friends: Bool, strangers: Bool) {
        guard !isSaving, let userID = appState.user?.id else { return }
#if DEBUG
        if appState.shouldUsePreviewData {
            appState.user?.friendInvitationsAllowed = friends
            appState.user?.strangerInvitationsAllowed = strangers
            return
        }
#endif
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let updated = try await appState.client.updateGameInvitationPermissions(friends: friends, strangers: strangers)
                guard appState.user?.id == userID else { return }
                appState.user = updated
                appState.showToast(t("Invitation settings saved", "Настройки приглашений сохранены", "Preferencias guardadas", "Налаштування запрошень збережено"), kind: .success)
            } catch {
                guard appState.user?.id == userID else { return }
                appState.showToast(t("Could not save invitation settings. Try again.", "Не удалось сохранить настройки приглашений. Попробуйте ещё раз.", "No se guardaron las preferencias. Inténtalo de nuevo.", "Не вдалося зберегти налаштування запрошень. Спробуйте ще раз."), kind: .error)
            }
        }
    }

    private func t(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch appState.language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
}
