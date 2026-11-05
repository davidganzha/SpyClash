import SwiftUI

enum GameInvitationSource {
    case radar, friend, community

    var symbol: String {
        switch self { case .radar: "dot.radiowaves.left.and.right"; case .friend: "person.2.fill"; case .community: "globe" }
    }
}

struct SocialGameInvitationOverlay: View {
    @Environment(AppState.self) private var appState
    let invitation: CommunityRoomInvite

    var body: some View {
        GameInvitationOverlay(
            source: appState.gameInvitations.friendIDs.contains(invitation.sender.id) ? .friend : .community,
            callSign: invitation.sender.displayName, avatar: invitation.sender.avatar,
            spyID: invitation.sender.spyID, roomCode: invitation.roomCode,
            isBusy: appState.gameInvitations.busyInviteID != nil || appState.isRadarInvitationJoinInProgress,
            errorMessage: appState.gameInvitations.errorMessage,
            onDecline: { appState.gameInvitations.decide(invitation, accept: false) },
            onJoin: { appState.gameInvitations.decide(invitation, accept: true) }
        )
        .accessibilityIdentifier("social.incomingInvitation")
    }
}

/// Shared visual language for every invitation transport. The transport owns
/// joining; this screen never joins merely because it becomes visible.
struct GameInvitationOverlay: View {
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion
    let source: GameInvitationSource
    let callSign: String
    let avatar: String
    let spyID: String
    let roomCode: String
    let isBusy: Bool
    var errorMessage: String? = nil
    let onDecline: () -> Void
    let onJoin: () -> Void
    @State private var isVisible = false
    @AccessibilityFocusState private var titleFocused: Bool
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(isVisible ? 0.7 : 0).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack {
                        Spacer(minLength: 24)
                        panel
                            .opacity(isVisible ? 1 : 0)
                            .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : 0.97))
                            .offset(y: reduceMotion || isVisible ? 0 : 14)
                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.45, dampingFraction: 0.9)) {
                isVisible = true
            }
            titleFocused = true
        }
        .onChange(of: errorMessage) { _, message in
            errorFocused = message?.isEmpty == false
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(sourceTitle, systemImage: source.symbol)
                    .foregroundStyle(SpyTheme.red)
                Spacer(minLength: 8)
                Text(roomCode)
                    .foregroundStyle(.white.opacity(0.35))
                    .accessibilityLabel(t("Room \(roomCode)", "Комната \(roomCode)", "Sala \(roomCode)", "Кімната \(roomCode)"))
            }
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .tracking(1.1)
            .padding(.bottom, 22)

            HStack(spacing: 14) {
                Text(avatar)
                    .font(.system(size: 39))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(callSign)
                        .font(.custom("Rajdhani-Bold", size: 30, relativeTo: .title2))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($titleFocused)
                    Text(t("invites you to play", "приглашает тебя в игру", "te invita a jugar", "запрошує тебе до гри"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("SPYID \(spyID)")
            .padding(.bottom, 24)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                    .accessibilityFocused($errorFocused)
                    .accessibilityIdentifier("gameInvitation.error")
            }

            Button(action: onJoin) {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(.white).controlSize(.small) }
                    Text(isBusy
                         ? t("Joining…", "Подключаемся…", "Conectando…", "Приєднуємось…")
                         : t("Join game", "Присоединиться", "Unirse", "Приєднатися"))
                }
            }
            .buttonStyle(InvitationActionStyle())
            .accessibilityIdentifier("gameInvitation.join")

            Button(t("Not now", "Не сейчас", "Ahora no", "Не зараз"), action: onDecline)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityLabel(t("Decline invitation", "Отклонить приглашение", "Rechazar invitación", "Відхилити запрошення"))
                .accessibilityIdentifier("gameInvitation.decline")
        }
        .disabled(isBusy)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 6)
        .frame(maxWidth: 340)
        .background(SpyTheme.card, in: CutCornerShape(cut: 16))
        .overlay(CutCornerShape(cut: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Rectangle().fill(SpyTheme.red).frame(width: 28, height: 2).padding(.leading, 22)
        }
        .shadow(color: .black.opacity(0.6), radius: 28, y: 14)
    }

    private var sourceTitle: String {
        switch source {
        case .radar: t("RADAR", "РАДАР", "RADAR", "РАДАР")
        case .friend: t("FRIEND", "ДРУГ", "AMIGO", "ДРУГ")
        case .community: t("COMMUNITY", "СООБЩЕСТВО", "COMUNIDAD", "СПІЛЬНОТА")
        }
    }

    private func t(_ en: String, _ ru: String, _ es: String, _ uk: String) -> String {
        switch appState.language { case .en: en; case .ru: ru; case .es: es; case .uk: uk }
    }
}

private struct InvitationActionStyle: ButtonStyle {
    @SpyReduceMotion private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(SpyTheme.red, in: CutCornerShape(cut: 8))
            .contentShape(CutCornerShape(cut: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : SpyMotion.press, value: configuration.isPressed)
    }
}
