#if SPYCLASH_SUPABASE_TEST
import SwiftUI

/// The actual app's game route, using its cinematic role/voting scenes with the
/// deliberately smaller authoritative protocol available in the test project.
struct SupabaseGameTestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false
    @State private var busy = false
    @State private var message = ""
    private var adapter: SupabaseGameAdapter { .shared }
    private var russian: Bool { appState.language == .ru }
    private var isHost: Bool { adapter.latestSnapshot["host_id"].string == adapter.store.userID }
    private var role: MissionRoleCardContent {
        adapter.latestSnapshot["own_role"].string == "spy" ? .spy : .detective(word: adapter.latestSnapshot["own_word"].string ?? "—")
    }

    var body: some View {
        screenContent
        .safeAreaInset(edge: .bottom, spacing: 0) { connectionStrip }
        .onChange(of: adapter.latestSnapshot["match_id"].string) { _, _ in revealed = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
            else { revealed = false }
        }
        .onAppear { appState.isShellChromeSuppressed = adapter.phase == "playing" || adapter.phase == "voting" }
        .onChange(of: adapter.phase) { _, phase in
            appState.isShellChromeSuppressed = phase == "playing" || phase == "voting"
        }
        .onDisappear { appState.isShellChromeSuppressed = false }
    }

    @ViewBuilder private var screenContent: some View {
        if let room = adapter.currentRoom {
            if adapter.phase == "playing" && !adapter.ownRoleConfirmed {
                roleScene(room)
            } else if adapter.phase == "playing" || adapter.phase == "voting" {
                activeScene(room)
            } else {
                roomPanel(room)
            }
        } else {
            VStack(spacing: 24) {
                SpyWordmark(fontSize: 36)
                Text(russian ? "Создай комнату на главном экране" : "Create a room from Home")
                Button(russian ? "На главную" : "Home") { appState.selectedTab = .home }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
            }.padding(24)
        }
    }

    private func roleScene(_ room: GameRoom) -> OnlineRoleRevealScene {
        OnlineRoleRevealScene(room: room, language: appState.language, role: role,
            cardTheme: .field, cardAccent: SpyTheme.red, currentUserEmail: appState.user?.email,
            isRevealed: revealed, onReveal: { revealed.toggle() },
            onConfirm: {
                do { appState.activeRoom = try adapter.confirmOwnRole(roomID: room.id); revealed = false }
                catch { message = error.localizedDescription }
            }, onLeave: leave)
    }

    private func activeScene(_ room: GameRoom) -> OnlineActiveGameScene {
        let hasVoted = room.detectiveVotesList.contains { $0.voterEmail == appState.user?.email }
        return OnlineActiveGameScene(room: room, language: appState.language, role: role,
            currentUserEmail: appState.user?.email, isHost: isHost, isRoleRevealed: revealed,
            roundCommand: nil, isRoundTransitioning: false, canStopAssociationSpin: false,
            showsVoteRequest: isHost && adapter.phase == "playing",
            canRequestVote: !busy && !adapter.hasPendingRecovery, canSpyGuess: false,
            canCastVote: !busy && !adapter.hasPendingRecovery && !hasVoted,
            onToggleRole: { revealed.toggle() }, onTogglePause: {}, onRoundCommand: { _ in },
            onCountdownElapsed: {}, onAssociationSpinElapsed: {},
            onRequestVote: { perform { _ = try await adapter.openVoting(roomID: room.id) } },
            onCastVote: { target in perform { _ = try await adapter.vote(roomID: room.id, targetEmail: target) } },
            onSpyGuess: {}, onLeave: leave)
    }

    private func roomPanel(_ room: GameRoom) -> some View {
        PageChrome(eyebrow: "SUPABASE TEST", status: adapter.phase.uppercased()) {
            VStack(alignment: .leading, spacing: 20) {
                Text(adapter.phase == "finished" ? winnerTitle : (russian ? "ТЕСТОВАЯ КОМНАТА" : "TEST ROOM"))
                    .font(SpyTheme.brandFont(size: 32))
                Text(room.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("supabase.roomID")
                Button(russian ? "Скопировать ID комнаты" : "Copy room ID") { UIPasteboard.general.string = room.code }
                    .buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
                ForEach(room.playersList) { player in
                    HStack {
                        Text(player.avatar).font(.title)
                        Text(player.name).font(SpyTheme.brandFont(size: 22))
                        Spacer()
                        if (room.readyPlayers ?? []).contains(player.email) { Image(systemName: "checkmark.circle.fill").foregroundStyle(SpyTheme.green) }
                    }.padding(12).background(SpyTheme.control, in: CutCornerShape(cut: 8))
                }
                if adapter.phase == "lobby" {
                    Text(russian ? "Один шпион, один раунд. Слово выбирает сервер. Остальные режимы пока недоступны в этой тестовой сборке." : "One spy, one round. The server chooses the word. Other modes are unavailable in this test build.")
                        .font(.caption).foregroundStyle(SpyTheme.dim)
                    Button(isReady(room) ? (russian ? "Отменить готовность" : "Not ready") : (russian ? "Я готов" : "Ready")) {
                        perform { _ = try await adapter.setReady(!isReady(room)) }
                    }.buttonStyle(SpyCinematicButtonStyle(variant: .secondary))
                        .accessibilityIdentifier("supabase.ready")
                    if isHost {
                        Button(russian ? "Начать игру" : "Start game") { perform { _ = try await adapter.startGame(roomID: room.id) } }
                            .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                            .disabled(room.playersList.count < 3 || (room.readyPlayers ?? []).count != room.playersList.count)
                            .accessibilityIdentifier("supabase.start")
                    }
                } else if adapter.phase == "finished", isHost {
                    Button(russian ? "Вернуться в лобби" : "Return to lobby") { perform { _ = try await adapter.returnToLobby(roomID: room.id) } }
                        .buttonStyle(SpyCinematicButtonStyle(variant: .primary))
                        .accessibilityIdentifier("supabase.returnToLobby")
                }
                Button(russian ? "Выйти из комнаты" : "Leave room", action: leave)
                    .buttonStyle(SpyCinematicButtonStyle(variant: .quiet))
                    .accessibilityIdentifier("supabase.leave")
            }.padding(20).disabled(busy || adapter.hasPendingRecovery)
        }
    }

    private var winnerTitle: String {
        adapter.latestSnapshot["winner"].string == "civilians"
            ? (russian ? "МИРНЫЕ ПОБЕДИЛИ" : "CIVILIANS WIN")
            : (russian ? "ШПИОН ПОБЕДИЛ" : "SPY WINS")
    }
    private func isReady(_ room: GameRoom) -> Bool { (room.readyPlayers ?? []).contains(appState.user?.email ?? "") }
    private var connectionStrip: some View {
        VStack(spacing: 5) {
            HStack {
                Text("r\(adapter.latestSnapshot["revision"].integer) · \(adapter.store.realtime)")
                Spacer()
                Button(russian ? "Обновить" : "Refresh", action: refresh).disabled(busy)
                if adapter.hasPendingRecovery {
                    Button(russian ? "Повторить" : "Retry") {
                        perform { _ = try await adapter.retryPending() }
                    }.disabled(busy).accessibilityIdentifier("supabase.retry")
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(SpyTheme.amber) }
            if adapter.hasPendingRecovery {
                Text(russian ? "Действие сохранено. Восстанови связь и повтори." : "Action saved. Reconnect and retry.")
                    .accessibilityIdentifier("supabase.pending")
            }
        }.font(.caption2).padding(10).background(Color.black)
    }
    private func refresh() {
        guard let id = adapter.store.roomID else { return }
        perform { _ = try await adapter.refreshRoom(id: id) }
    }
    private func leave() {
        guard let room = adapter.currentRoom, let user = appState.user else { return }
        perform {
            try await appState.client.leaveRoom(room: room, user: user)
            appState.activeRoom = nil
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = ""
        Task { @MainActor in
            defer { busy = false }
            do { try await operation(); appState.activeRoom = adapter.currentRoom }
            catch { message = error.localizedDescription }
        }
    }
}
#endif
