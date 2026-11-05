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
    let onDecline: () -> Void
    let onJoin: () -> Void
    @State private var isVisible = false
    @State private var signalExpanded = false
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(isVisible ? 0.82 : 0).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack {
                        Spacer(minLength: 24)
                        panel
                            .opacity(isVisible ? 1 : 0)
                            .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : 0.9))
                            .offset(y: reduceMotion || isVisible ? 0 : 24)
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
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.52, dampingFraction: 0.84)) {
                isVisible = true
            }
            if !reduceMotion {
                withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { signalExpanded = true }
            }
            titleFocused = true
        }
    }

    private var panel: some View {
        VStack(spacing: 22) {
            HStack {
                SpyBrandMark().frame(width: 23, height: 30)
                Spacer()
                Label(sourceTitle, systemImage: source.symbol)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(SpyTheme.red.opacity(0.09), in: Capsule())
                    .overlay(Capsule().stroke(SpyTheme.red.opacity(0.28)))
            }

            ZStack {
                Circle().stroke(SpyTheme.red.opacity(0.14), lineWidth: 1).frame(width: 112, height: 112)
                Circle().stroke(SpyTheme.red.opacity(signalExpanded ? 0 : 0.5), lineWidth: 1)
                    .frame(width: 80, height: 80).scaleEffect(signalExpanded ? 1.65 : 1)
                Circle().fill(SpyTheme.red.opacity(0.07)).frame(width: 94, height: 94)
                Text(avatar).font(.system(size: 46)).frame(width: 80, height: 80)
                    .background(SpyTheme.black, in: Circle())
                    .overlay(Circle().stroke(SpyTheme.red.opacity(0.45), lineWidth: 1))
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(SpyTheme.red, in: Circle())
                    .offset(x: 32, y: 31)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(t("MISSION INVITATION", "ПРИГЛАШЕНИЕ В ИГРУ", "INVITACIÓN A MISIÓN", "ЗАПРОШЕННЯ ДО ГРИ"))
                    .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.6)
                    .foregroundStyle(SpyTheme.red)
                Text(callSign)
                    .font(SpyTheme.brandFont(size: 32)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                    .accessibilityFocused($titleFocused)
                Text(t("invites you to join the operation", "приглашает присоединиться к операции", "te invita a unirte a la operación", "запрошує приєднатися до операції"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(SpyTheme.muted)
                    .multilineTextAlignment(.center)
                Text("SPYID / \(spyID)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(SpyTheme.faint)
            }

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("ROOM FREQUENCY", "ЧАСТОТА КОМНАТЫ", "FRECUENCIA DE SALA", "ЧАСТОТА КІМНАТИ"))
                        .font(.system(size: 8, weight: .black, design: .monospaced)).tracking(1)
                        .foregroundStyle(SpyTheme.muted)
                    Text(roomCode).font(.system(size: 25, weight: .bold, design: .monospaced)).tracking(5).foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundStyle(SpyTheme.red)
            }
            .padding(15)
            .background(SpyTheme.black.opacity(0.7), in: CutCornerShape(cut: 9))
            .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.strokeStrong, lineWidth: 1))

            VStack(spacing: 9) {
                Button(action: onJoin) {
                    HStack(spacing: 9) {
                        if isBusy { ProgressView().tint(.white) }
                        Text(isBusy ? t("CONNECTING…", "ПОДКЛЮЧАЕМСЯ…", "CONECTANDO…", "ПІДКЛЮЧАЄМОСЯ…") : t("JOIN GAME", "ПРИСОЕДИНИТЬСЯ", "UNIRSE", "ПРИЄДНАТИСЯ"))
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .accessibilityIdentifier("gameInvitation.join")
                Button(t("DECLINE", "ОТКЛОНИТЬ", "RECHAZAR", "ВІДХИЛИТИ"), action: onDecline)
                    .buttonStyle(SpyButtonStyle(variant: .outline))
                    .accessibilityIdentifier("gameInvitation.decline")
            }
            .disabled(isBusy)
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(LinearGradient(colors: [Color(red: 0.13, green: 0.055, blue: 0.065), SpyTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing), in: CutCornerShape(cut: 22))
        .overlay(CutCornerShape(cut: 22).stroke(SpyTheme.red.opacity(0.5), lineWidth: 1))
        .shadow(color: SpyTheme.red.opacity(0.12), radius: 35)
        .shadow(color: .black.opacity(0.7), radius: 24, y: 16)
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
