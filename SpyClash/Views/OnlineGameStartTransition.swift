import SwiftUI

/// Keeps the menu, cinematic and prepared role card on one continuous surface.
/// Only this layer owns their dissolve; authoritative room state stays untouched.
struct OnlineGameStartTransition<Content: View>: View {
    let room: GameRoom?
    let accountID: String?
    let language: AppLanguage
    @ViewBuilder let content: (GameRoom?, Bool) -> Content

    @SpyReduceMotion private var reduceMotion
    @State private var presentation = OnlineIntroPresentation(duration: Base44Client.gameIntroDuration)
    @State private var lastLobbyRoom: GameRoom?

    var body: some View {
        ZStack {
            content(displayedRoom, presentation.active != nil)
                .allowsHitTesting(presentation.active == nil)
                .accessibilityHidden(presentation.active != nil)
                .animation(presentation.active == nil && !reduceMotion ? SpyMotion.page : nil, value: sceneKey)
                .zIndex(0)

            if let session = presentation.active {
                OnlineIntroDissolveLayer(
                    room: session.room,
                    language: language,
                    startedAt: session.startedAt,
                    isExiting: session.exitingAt != nil,
                    revealDuration: presentation.revealDuration
                )
                .id(session.startedAt)
                .zIndex(10)
            }
        }
        .background(SpyTheme.black)
        .onChange(of: room, initial: true) { _, _ in synchronizePresentation() }
        .onChange(of: accountID) { _, _ in
            lastLobbyRoom = nil
            synchronizePresentation()
        }
        .task(id: revealTaskKey) {
            await revealPreparedGame()
        }
        .onDisappear {
            presentation.cancel()
            lastLobbyRoom = nil
        }
    }

    private var displayedRoom: GameRoom? {
        // Retain A underneath the opaque arrival of B. Never rebuild the lobby
        // as the old roulette UI while its controls are fading out.
        if room?.normalizedStatus == "roulette", let lastLobbyRoom,
           lastLobbyRoom.id == room?.id {
            return lastLobbyRoom
        }
        return room
    }

    private var sceneKey: String {
        guard let room else { return "empty" }
        let phase = room.allRoleCardsRead && room.gameStartedAt != nil ? "active" : "role-gate"
        return "\(room.id)|\(room.normalizedStatus)|\(phase)"
    }

    private var revealTaskKey: String {
        [accountID ?? "", presentation.active?.id ?? "", room?.id ?? "",
         room?.normalizedStatus ?? "", room?.introStartedAt ?? ""].joined(separator: "|")
    }

    private func synchronizePresentation() {
        if let room, ["waiting", "ready_voting"].contains(room.normalizedStatus) {
            lastLobbyRoom = room
        } else if room?.id != lastLobbyRoom?.id {
            lastLobbyRoom = nil
        }
        presentation.update(room: room, accountID: accountID, now: .now)
    }

    @MainActor
    private func revealPreparedGame() async {
        guard let id = presentation.active?.id,
              let delay = presentation.revealDelay(room: room, accountID: accountID, now: .now) else { return }
        do {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try Task.checkCancellation()
            guard presentation.active?.id == id,
                  presentation.beginRevealIfReady(room: room, accountID: accountID, now: .now) else { return }
            try await Task.sleep(for: .seconds(presentation.revealDuration))
            try Task.checkCancellation()
            presentation.finishReveal(id: id, now: .now)
            lastLobbyRoom = nil
        } catch {
            // SwiftUI cancels this task for a different account, room or intro.
        }
    }
}

private struct OnlineIntroDissolveLayer: View {
    let room: GameRoom
    let language: AppLanguage
    let startedAt: Date
    let isExiting: Bool
    let revealDuration: TimeInterval
    @State private var hasCoveredMenu = false

    var body: some View {
        ZStack {
            SpyTheme.black
            OnlineGameIntroScene(room: room, language: language, presentationStartedAt: startedAt)
                .opacity(isExiting ? 0 : 1)
                .animation(.easeInOut(duration: revealDuration * 0.4), value: isExiting)
        }
        .ignoresSafeArea()
        .opacity(hasCoveredMenu ? 1 : 0)
        .opacity(isExiting ? 0 : 1)
        .animation(
            .easeInOut(duration: revealDuration * 0.6)
                .delay(isExiting ? revealDuration * 0.4 : 0),
            value: isExiting
        )
        .allowsHitTesting(true)
        .task {
            withAnimation(.easeInOut(duration: 0.34)) {
                hasCoveredMenu = true
            }
        }
    }
}
