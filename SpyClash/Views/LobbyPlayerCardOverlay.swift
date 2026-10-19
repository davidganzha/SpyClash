import SwiftUI

struct LobbyPlayerCardOverlay: View {
    let selection: LobbyPlayerCardSelection
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion
    @State private var detail: CommunityProfileDetail?
    @State private var relationship: CommunityRelationshipSummary?
    @State private var loading = true
    @State private var message: String?
    @State private var confirmation: ManagementAction?
    @State private var loadAttempt = 0

    private enum ManagementAction { case transfer, kick }
    private var isCurrent: Bool {
        appState.lobbyPlayerCardSelection?.id == selection.id
            && selection.currentPlayer(room: appState.activeRoom, accountID: appState.user?.id) != nil
    }
    private var canManage: Bool { selection.canManage(room: appState.activeRoom, accountID: appState.user?.id) }
    private var busy: Bool { appState.lobbyPlayerActionInFlight != nil }
    private var canAddFriend: Bool {
        guard let detail, !detail.isSelf, !selection.isSelf, !busy else { return false }
        guard let relationship else { return true }
        return relationship.status == "declined" || (relationship.status == "pending" && relationship.direction == "incoming")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Button(action: close) { Color.black.opacity(0.82) }
                    .buttonStyle(.plain)
                    .ignoresSafeArea()
                    .accessibilityLabel(text("Close card", "Закрыть карточку", "Cerrar tarjeta", "Закрити картку"))
                    .accessibilityIdentifier("lobby.playerCard.backdrop")

                ViewThatFits(in: .vertical) {
                    panel
                    ScrollView { panel.padding(.vertical, 16) }
                        .scrollIndicators(.hidden)
                }
                .frame(maxWidth: min(geometry.size.width - 40, 430))
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .task(id: loadAttempt) { await loadProfile() }
        .onChange(of: isCurrent) { _, valid in if !valid { close() } }
        .onChange(of: appState.selectedTab) { _, tab in if tab != .game { close() } }
        .onChange(of: appState.shellRoute) { _, _ in close() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action == .kick ? kickTitle : transferTitle, role: action == .kick ? .destructive : nil) {
                    confirmation = nil
                    beginManagement(action)
                }
            }
            Button(text("Cancel", "Отмена", "Cancelar", "Скасувати"), role: .cancel) { confirmation = nil }
        }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Rectangle().fill(SpyTheme.red).frame(width: 18, height: 2)
                Text("SPYCARD / 3D")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityLabel(closeTitle)
            }
            .padding(.horizontal, 4)

            card

            if let message {
                Text(message).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    .accessibilityIdentifier("lobby.playerCard.message")
            }
            actions
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.055, green: 0.055, blue: 0.065))
                .overlay { RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.10), lineWidth: 1) }
                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
        }
    }

    @ViewBuilder private var card: some View {
        if let detail {
            PlayerSpyCard3DView(profile: detail.profile, language: appState.language, reduceMotion: reduceMotion)
        } else {
            VStack(spacing: 16) {
                Text(selection.player.avatar).font(.system(size: 48))
                Text(selection.player.name).font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                if loading {
                    ProgressView().tint(SpyTheme.red)
                        .accessibilityLabel(text("Loading profile", "Загрузка профиля", "Cargando perfil", "Завантаження профілю"))
                } else {
                    Button(text("Retry", "Повторить", "Reintentar", "Повторити")) { loadAttempt += 1 }
                        .tint(SpyTheme.red)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 230)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if !selection.isSelf {
                actionButton(friendTitle, icon: friendIcon, prominent: true, enabled: canAddFriend) {
                    beginFriendAction()
                }
                .accessibilityIdentifier("lobby.playerCard.friend")
            }
            if canManage {
                actionButton(transferTitle, icon: "crown", enabled: !busy) { confirmation = .transfer }
                    .accessibilityIdentifier("lobby.playerCard.transfer")
                actionButton(kickTitle, icon: "person.fill.xmark", enabled: !busy, destructive: true) { confirmation = .kick }
                    .accessibilityIdentifier("lobby.playerCard.kick")
            }
            if busy { ProgressView().tint(SpyTheme.red).padding(4) }
            Button(closeTitle, action: close)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("lobby.playerCard.close")
        }
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool = false, enabled: Bool,
                              destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(destructive ? SpyTheme.red : .white)
                .background(prominent ? SpyTheme.red.opacity(enabled ? 1 : 0.3) : .white.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.65)
    }

    private var closeTitle: String { text("Close", "Закрыть", "Cerrar", "Закрити") }
    private var transferTitle: String { text("Transfer leadership", "Передать лидерство", "Ceder liderazgo", "Передати лідерство") }
    private var kickTitle: String { text("Remove from room", "Выгнать из комнаты", "Expulsar de la sala", "Вигнати з кімнати") }
    private var confirmationTitle: String {
        confirmation == .kick
            ? text("Remove \(selection.player.name) from the room?", "Выгнать \(selection.player.name) из комнаты?", "¿Expulsar a \(selection.player.name)?", "Вигнати \(selection.player.name) з кімнати?")
            : text("Make \(selection.player.name) the leader?", "Сделать \(selection.player.name) ведущим?", "¿Hacer líder a \(selection.player.name)?", "Зробити \(selection.player.name) ведучим?")
    }
    private var friendTitle: String {
        switch (relationship?.status, relationship?.direction) {
        case ("accepted", _): text("Friends", "Уже в друзьях", "Amigos", "Вже в друзях")
        case ("pending", "incoming"): text("Accept friend request", "Принять заявку", "Aceptar solicitud", "Прийняти запит")
        case ("pending", _): text("Request sent", "Заявка отправлена", "Solicitud enviada", "Запит надіслано")
        case ("blocked", _): text("Unavailable", "Недоступно", "No disponible", "Недоступно")
        default: text("Add friend", "Добавить в друзья", "Añadir amigo", "Додати в друзі")
        }
    }
    private var friendIcon: String { relationship?.status == "accepted" ? "person.crop.circle.badge.checkmark" : "person.badge.plus" }

    @MainActor private func loadProfile() async {
        guard isCurrent else { return }
        loading = true
        message = nil
        defer { loading = false }
        do {
            let result: CommunityProfileDetail
            if appState.shouldUsePreviewData {
                result = CommunityProfileDetail(profile: PublicSpyProfile(
                    id: selection.profileID, spyID: "700-194", displayName: selection.player.name,
                    avatar: selection.player.avatar, spyCardTheme: "obsidian", spyCardAccent: "red",
                    spyCardBadge: "agent", rating: 1420, gamesPlayed: 48, gamesWon: 31, winRate: 65
                ), isSelf: selection.isSelf, relationship: nil, friends: [], comments: [])
            } else {
                result = try await appState.client.communityProfile(userID: selection.profileID)
            }
            guard !Task.isCancelled, isCurrent, result.profile.id == selection.profileID else { return }
            detail = result
            relationship = result.relationship
        } catch {
            guard !Task.isCancelled, isCurrent else { return }
            message = text("Profile could not be loaded", "Не удалось загрузить профиль", "No se pudo cargar el perfil", "Не вдалося завантажити профіль")
        }
    }

    @MainActor private func beginFriendAction() {
        guard isCurrent, canAddFriend else { return }
        let requestID = UUID()
        appState.lobbyPlayerActionInFlight = requestID
        Task { @MainActor in
            defer { if appState.lobbyPlayerActionInFlight == requestID { appState.lobbyPlayerActionInFlight = nil } }
            guard isCurrent else { return }
            do {
                if appState.shouldUsePreviewData {
                    relationship = CommunityRelationshipSummary(id: "preview-friend", status: "pending", direction: "outgoing")
                } else {
                    let network: CommunityState
                    if let relationship, relationship.status == "pending", relationship.direction == "incoming" {
                        network = try await appState.client.communityRelationshipAction("accept", friendshipID: relationship.id)
                    } else {
                        network = try await appState.client.sendFriendRequest(userID: selection.profileID)
                    }
                    guard appState.user?.id == selection.actorID else { return }
                    if isCurrent { relationship = CommunityDirectoryRelationshipResolver.resolve(profileID: selection.profileID, network: network) }
                    await appState.notificationInbox.reconcileAfterSocialChange()
                }
                if isCurrent { HapticManager.shared.fire(.notification(.success)) }
            } catch {
                if isCurrent { message = text("Please try again", "Не удалось выполнить действие. Повтори", "Inténtalo de nuevo", "Не вдалося виконати дію. Повтори") }
            }
        }
    }

    @MainActor private func beginManagement(_ action: ManagementAction) {
        guard isCurrent, canManage, !busy, let room = appState.activeRoom,
              let target = selection.currentPlayer(room: room, accountID: appState.user?.id) else { return }
        let requestID = UUID()
        appState.lobbyPlayerActionInFlight = requestID
        Task { @MainActor in
            defer { if appState.lobbyPlayerActionInFlight == requestID { appState.lobbyPlayerActionInFlight = nil } }
            guard isCurrent, canManage,
                  selection.currentPlayer(room: appState.activeRoom, accountID: appState.user?.id) == target else { return }
            do {
                let candidate: GameRoom
                if appState.shouldUsePreviewData {
                    var preview = room
                    if action == .transfer { preview.hostEmail = target.email }
                    else { preview.players = room.playersList.filter { $0.userID != target.userID } }
                    preview.status = "waiting"
                    preview.readyPlayers = []
                    preview.roomRevision = (room.roomRevision ?? room.lobbyRevision ?? 0) + 1
                    candidate = preview
                } else if action == .transfer {
                    candidate = try await appState.client.transferRoomHost(room: room, targetPlayer: target)
                } else {
                    candidate = try await appState.client.kickPlayer(room: room, targetUserID: target.userID, targetEmail: target.email)
                }
                if adopt(candidate, action: action) { return }
                await recoverManagement(action)
            } catch {
                await recoverManagement(action)
            }
        }
    }

    @MainActor private func recoverManagement(_ action: ManagementAction) async {
        guard selection.matchesActor(room: appState.activeRoom, accountID: appState.user?.id) else { return }
        if !appState.shouldUsePreviewData,
           let snapshot = try? await appState.client.refreshRoom(id: selection.roomID,
               timeoutInterval: RoomActionTransportPolicy.timeoutInterval(for: "get_room"), allowsTypedConflictRetry: false),
           adopt(snapshot, action: action) { return }
        if isCurrent {
            message = text("Action was not confirmed. Refresh the room and try again.", "Действие не подтверждено. Обнови комнату и повтори.", "Acción sin confirmar. Actualiza la sala y reintenta.", "Дію не підтверджено. Онови кімнату та повтори.")
        }
    }

    @MainActor private func adopt(_ candidate: GameRoom, action: ManagementAction) -> Bool {
        guard let current = appState.activeRoom,
              selection.canAdopt(candidate, over: current, accountID: appState.user?.id, transferring: action == .transfer)
        else { return false }
        appState.activeRoom = candidate
        close()
        HapticManager.shared.fire(.notification(.success))
        return true
    }

    private func close() {
        guard appState.lobbyPlayerCardSelection?.id == selection.id else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.88)) {
            appState.lobbyPlayerCardSelection = nil
        }
    }

    private func text(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch appState.language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
}
