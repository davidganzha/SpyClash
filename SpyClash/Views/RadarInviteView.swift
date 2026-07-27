import SwiftUI

struct RadarInviteView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let room: GameRoom

    @State private var scanPulse = false

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10),
        GridItem(.flexible(minimum: 0), spacing: 10)
    ]

    private var radar: RadarNearbyService {
        appState.radarNearby
    }

    var body: some View {
        ZStack {
            SpyBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    identityGrid
                    privacyNote

                    Button {
                        dismiss()
                    } label: {
                        Label(localized(en: "CLOSE NEARBY", ru: "ЗАКРЫТЬ ПОИСК", es: "CERRAR CERCANOS"), systemImage: "xmark")
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                    .accessibilityIdentifier("radar.close")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
        }
        .task {
            radar.startScanning()
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                scanPulse = true
            }
        }
        .onDisappear {
            radar.stopScanning()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized(en: "// LOCAL ACCESS", ru: "// ЛОКАЛЬНЫЙ ДОСТУП", es: "// ACCESO LOCAL"))
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)

                Text(localized(en: "NEARBY", ru: "РЯДОМ", es: "CERCA"))
                    .font(SpyTheme.brandFont(size: 42))
                    .tracking(1.5)
                    .foregroundStyle(.white)

                Text(localized(
                    en: "Select a local SpyID to send room access.",
                    ru: "Выбери локальный SpyID, чтобы открыть доступ в комнату.",
                    es: "Selecciona un SpyID local para enviar acceso a la sala."
                ))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.control, in: CutCornerShape(cut: 8))
                    .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close nearby", ru: "Закрыть поиск рядом", es: "Cerrar cercanos"))
        }
    }

    @ViewBuilder
    private var identityGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Spacer()

                Text(String(format: "%02d", radar.peers.count))
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(radar.peers.isEmpty ? SpyTheme.faint : SpyTheme.green)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                if radar.peers.isEmpty {
                    ForEach(0..<4, id: \.self) { index in
                        NearbySpyIDPlaceholder(
                            index: index,
                            isActive: scanPulse && index < 2
                        )
                    }
                } else {
                    ForEach(radar.peers) { peer in
                        NearbySpyIDCard(
                            peer: peer,
                            language: appState.language,
                            invitationState: radar.invitationState(for: peer.id)
                        ) {
                            invite(peer)
                        }
                        .transition(.radarPeerPresence)
                    }
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.48, dampingFraction: 0.88),
                value: radar.peers.map(\.id)
            )

            if radar.peers.isEmpty {
                Text(localized(
                    en: "WAITING FOR OPEN SPYCLASH DEVICES NEARBY",
                    ru: "ЖДЁМ УСТРОЙСТВА С ОТКРЫТЫМ SPYCLASH РЯДОМ",
                    es: "ESPERANDO DISPOSITIVOS CON SPYCLASH ABIERTO"
                ))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.35)
                .foregroundStyle(SpyTheme.dim)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(SpyTheme.green)
                .frame(width: 26, height: 26)
                .background(SpyTheme.green.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(localized(en: "LOCAL DISCOVERY", ru: "ЛОКАЛЬНОЕ ОБНАРУЖЕНИЕ", es: "DETECCIÓN LOCAL"))
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text(localized(
                    en: "Only open SpyClash devices appear here. Exact coordinates are not used.",
                    ru: "Здесь видны только устройства с открытым SpyClash. Точные координаты не используются.",
                    es: "Solo aparecen dispositivos con SpyClash abierto. No se usan coordenadas exactas."
                ))
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .lineSpacing(2)
                .foregroundStyle(SpyTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.34), in: NearbyStatusShape())
        .overlay(NearbyStatusShape().stroke(SpyTheme.strokeDim, lineWidth: 1))
    }

    private func invite(_ peer: RadarNearbyPeer) {
        HapticManager.shared.fire(.buttonPress)
        Task { @MainActor in
            let result = await radar.invite(peer, to: room)
            switch result {
            case .sent:
                HapticManager.shared.fire(.navigation)
            case .blocked:
                HapticManager.shared.fire(.notification(.error))
            case .unavailable:
                HapticManager.shared.fire(.notification(.error))
            }
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }
}

private enum NearbySpyCardState: Equatable {
    case available
    case waiting
    case declined
    case accepted
    case inGame
    case blocked
    case unavailable

    var isActionable: Bool { self == .available }
}

struct NearbySpyIDCard: View {
    let peer: RadarNearbyPeer
    let language: AppLanguage
    let invitationState: RadarOutgoingInvitationState?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                let scale = max(proxy.size.width / 355, 0.44)
                let cardShape = RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        SpyBrandMark()
                            .frame(width: 28 * scale, height: 36 * scale)
                            .offset(x: -2 * scale)

                        HStack(spacing: 6 * scale) {
                            Text(badgeGlyph)
                                .foregroundStyle(identityAccent)
                            Text(badgeTitle)
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                        }
                        .font(.system(size: 7 * scale, weight: .black, design: .monospaced))
                        .tracking(0.6 * scale)
                        .padding(.horizontal, 9 * scale)
                        .frame(height: 24 * scale)
                        .background(identityAccent.opacity(0.075), in: Capsule())
                        .overlay(Capsule().stroke(identityAccent.opacity(0.30), lineWidth: 0.75))

                        Spacer(minLength: 5 * scale)

                        HStack(spacing: 5 * scale) {
                            Image(systemName: peer.source == .iphone ? "iphone" : "globe")
                                .font(.system(size: 7 * scale, weight: .black))
                                .foregroundStyle(Color.white.opacity(0.30))
                            Circle()
                                .fill(stateAccent)
                                .frame(width: 5 * scale, height: 5 * scale)
                            Text(statusWord)
                                .font(.system(size: 8 * scale, weight: .black, design: .monospaced))
                                .tracking(0.12 * scale)
                                .foregroundStyle(stateAccent)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 13 * scale)
                    .padding(.trailing, 17 * scale)
                    .frame(height: 50 * scale)

                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.12), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 1)

                    VStack(alignment: .leading, spacing: 7 * scale) {
                        HStack(spacing: 13 * scale) {
                            Text(peer.avatar)
                                .font(.system(size: 29 * scale))
                                .frame(width: 52 * scale, height: 52 * scale)
                                .background(
                                    Color.black.opacity(0.30),
                                    in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                                        .stroke(identityAccent.opacity(0.38), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 4 * scale) {
                                Text(peer.callSign.uppercased())
                                    .font(SpyTheme.brandFont(size: 24 * scale))
                                    .tracking(0.9 * scale)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.62)

                                Text("SPYID • \(peer.spyID)")
                                    .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                                    .tracking(0.08 * scale)
                                    .foregroundStyle(Color.white.opacity(0.38))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.60)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 5 * scale) {
                            Text(policyTitle)
                                .font(.system(size: 7 * scale, weight: .black, design: .monospaced))
                                .tracking(0.18 * scale)
                                .foregroundStyle(policyColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.52)

                            Spacer(minLength: 3 * scale)

                            Text(actionTitle)
                                .font(.system(size: 7 * scale, weight: .black, design: .monospaced))
                                .tracking(0.18 * scale)
                                .lineLimit(1)
                                .minimumScaleFactor(0.58)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8 * scale, weight: .black))
                        }
                        .foregroundStyle(policyColor)
                    }
                    .padding(.horizontal, 17 * scale)
                    .padding(.top, 14 * scale)
                    .padding(.bottom, 16 * scale)
                }
                .frame(width: proxy.size.width, height: proxy.size.width / 1.50)
                .background {
                    ZStack {
                        cardShape
                            .fill(.ultraThinMaterial)
                            .opacity(peer.spyCardTheme == .field ? 1 : 0.46)
                        cardShape
                            .fill(Color.black.opacity(peer.spyCardTheme == .blacksite ? 0.78 : 0.34))
                        cardShape
                            .fill(
                                LinearGradient(
                                    colors: identityThemeColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        cardShape
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.10), .clear],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: proxy.size.width * 0.58
                                )
                            )
                        cardShape
                            .fill(
                                RadialGradient(
                                    colors: [identityAccent.opacity(0.11), .clear],
                                    center: .bottomTrailing,
                                    startRadius: 0,
                                    endRadius: proxy.size.width * 0.66
                                )
                            )
                        SpyCardSurfacePattern(theme: peer.spyCardTheme, accent: identityAccent)
                            .clipShape(cardShape)
                    }
                }
                .clipShape(cardShape)
                .overlay {
                    cardShape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.white.opacity(0.07),
                                identityAccent.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .overlay {
                    cardShape
                        .inset(by: 1.5)
                        .stroke(Color.white.opacity(0.035), lineWidth: 0.75)
                }
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.20), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 1)
                    .padding(.horizontal, 30 * scale)
                }
                .overlay(alignment: .bottomTrailing) {
                    LinearGradient(
                        colors: [.clear, identityAccent.opacity(0.68), Color.white.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 76 * scale, height: 1.5)
                    .padding(.trailing, 22 * scale)
                    .padding(.bottom, 1)
                        .shadow(color: identityAccent.opacity(0.18), radius: 5)
                }
                .overlay {
                    if cardState != .available {
                        statusOverlay(shape: cardShape, scale: scale)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .background {
                    ZStack {
                        cardShape
                            .stroke(Color.black.opacity(0.90), lineWidth: 1)
                            .shadow(color: .black.opacity(0.38), radius: 14)
                        cardShape
                            .stroke(identityAccent.opacity(0.18), lineWidth: 1)
                            .shadow(color: identityAccent.opacity(0.11), radius: 10)
                    }
                }
                .contentShape(cardShape)
            }
            .aspectRatio(1.50, contentMode: .fit)
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.97))
        .disabled(!cardState.isActionable)
        .animation(.smooth(duration: 0.32), value: cardState)
        .accessibilityIdentifier("radar.peer.\(peer.id)")
        .accessibilityLabel(accessibilityLabel)
    }

    private var cardState: NearbySpyCardState {
        if peer.invitePolicy == .blocked { return .blocked }

        if let invitationState {
            return switch invitationState {
            case .waiting: .waiting
            case .declined: .declined
            case .accepted: .accepted
            case .inGame: .inGame
            case .blocked: .blocked
            case .unavailable: .unavailable
            }
        }

        if peer.availability == .inGame { return .inGame }
        return .available
    }

    private var stateAccent: Color {
        switch cardState {
        case .available: policyColor
        case .waiting: SpyTheme.amber
        case .accepted, .inGame: SpyTheme.green
        case .declined, .blocked: SpyTheme.red
        case .unavailable: Color.white.opacity(0.54)
        }
    }

    private func statusOverlay(
        shape: RoundedRectangle,
        scale: CGFloat
    ) -> some View {
        ZStack {
            shape.fill(Color.black.opacity(cardState == .blocked ? 0.76 : 0.68))

            LinearGradient(
                colors: [stateAccent.opacity(0.18), .clear, Color.black.opacity(0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(shape)

            VStack(spacing: 6 * scale) {
                if cardState == .waiting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(stateAccent)
                        .frame(width: 22 * scale, height: 22 * scale)
                } else {
                    Image(systemName: stateIcon)
                        .font(.system(size: 18 * scale, weight: .black))
                        .foregroundStyle(stateAccent)
                        .frame(width: 25 * scale, height: 25 * scale)
                        .background(stateAccent.opacity(0.12), in: Circle())
                        .overlay(Circle().stroke(stateAccent.opacity(0.36), lineWidth: 1))
                }

                Text(stateTitle)
                    .font(SpyTheme.brandFont(size: 20 * scale))
                    .tracking(0.7 * scale)
                    .foregroundStyle(stateAccent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)

                Text(stateDetail)
                    .font(.system(size: 7 * scale, weight: .black, design: .monospaced))
                    .tracking(0.16 * scale)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20 * scale)
        }
        .allowsHitTesting(false)
    }

    private var identityAccent: Color {
        switch peer.spyCardAccent {
        case .signalRed: SpyTheme.red
        case .clearanceAmber: SpyTheme.amber
        case .verifiedGreen: SpyTheme.green
        }
    }

    private var identityThemeColors: [Color] {
        switch peer.spyCardTheme {
        case .field:
            [Color.white.opacity(0.085), Color.white.opacity(0.018), Color.black.opacity(0.24)]
        case .blacksite:
            [Color.white.opacity(0.035), Color.black.opacity(0.42), Color.black.opacity(0.82)]
        case .dossier:
            [SpyTheme.red.opacity(0.14), Color.white.opacity(0.025), Color.black.opacity(0.46)]
        }
    }

    private var policyColor: Color {
        switch peer.invitePolicy {
        case .ask: SpyTheme.amber
        case .automatic: SpyTheme.green
        case .blocked: SpyTheme.red
        }
    }

    private var badgeGlyph: String {
        switch peer.spyCardBadge {
        case .operative: "◆"
        case .ghost: "◌"
        case .analyst: "⌁"
        case .handler: "▲"
        }
    }

    private var badgeTitle: String {
        switch (peer.spyCardBadge, language) {
        case (.operative, .ru): "ОПЕРАТИВ"
        case (.ghost, .ru): "ПРИЗРАК"
        case (.analyst, .ru): "АНАЛИТИК"
        case (.handler, .ru): "КУРАТОР"
        case (.operative, .es): "OPERATIVO"
        case (.ghost, .es): "FANTASMA"
        case (.analyst, .es): "ANALISTA"
        case (.handler, .es): "CONTROL"
        case (.operative, _): "OPERATIVE"
        case (.ghost, _): "GHOST"
        case (.analyst, _): "ANALYST"
        case (.handler, _): "HANDLER"
        }
    }

    private var statusWord: String {
        switch (language, cardState) {
        case (.ru, .waiting): "ОЖИДАНИЕ"
        case (.ru, .declined): "ОТКАЗ"
        case (.ru, .accepted): "ПРИНЯТО"
        case (.ru, .inGame): "В ИГРЕ"
        case (.ru, .blocked): "ЗАКРЫТ"
        case (.ru, .unavailable): "НЕТ СВЯЗИ"
        case (.es, .waiting): "ESPERA"
        case (.es, .declined): "RECHAZADO"
        case (.es, .accepted): "ACEPTADO"
        case (.es, .inGame): "EN JUEGO"
        case (.es, .blocked): "CERRADO"
        case (.es, .unavailable): "SIN SEÑAL"
        case (_, .waiting): "PENDING"
        case (_, .declined): "DECLINED"
        case (_, .accepted): "ACCEPTED"
        case (_, .inGame): "IN GAME"
        case (_, .blocked): "CLOSED"
        case (_, .unavailable): "NO SIGNAL"
        case (_, .available): "LIVE"
        }
    }

    private var stateIcon: String {
        switch cardState {
        case .available: "antenna.radiowaves.left.and.right"
        case .waiting: "ellipsis"
        case .declined: "xmark"
        case .accepted: "checkmark"
        case .inGame: "gamecontroller.fill"
        case .blocked: "hand.raised.fill"
        case .unavailable: "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var stateTitle: String {
        switch (language, cardState) {
        case (.ru, .waiting): "ОЖИДАЕМ ИГРОКА"
        case (.ru, .declined): "ИГРОК ОТКАЗАЛСЯ"
        case (.ru, .accepted): "ПРИГЛАШЕНИЕ\nПРИНЯТО"
        case (.ru, .inGame): "УЖЕ В ИГРЕ"
        case (.ru, .blocked): "ПРИГЛАШЕНИЯ\nЗАПРЕЩЕНЫ"
        case (.ru, .unavailable): "НЕТ ОТВЕТА"
        case (.es, .waiting): "ESPERANDO AL JUGADOR"
        case (.es, .declined): "INVITACIÓN RECHAZADA"
        case (.es, .accepted): "INVITACIÓN\nACEPTADA"
        case (.es, .inGame): "YA ESTÁ JUGANDO"
        case (.es, .blocked): "INVITACIONES\nBLOQUEADAS"
        case (.es, .unavailable): "SIN RESPUESTA"
        case (_, .waiting): "WAITING FOR PLAYER"
        case (_, .declined): "INVITATION DECLINED"
        case (_, .accepted): "INVITATION\nACCEPTED"
        case (_, .inGame): "ALREADY IN GAME"
        case (_, .blocked): "INVITATIONS\nBLOCKED"
        case (_, .unavailable): "NO RESPONSE"
        case (_, .available): "AVAILABLE"
        }
    }

    private var stateDetail: String {
        switch (language, cardState) {
        case (.ru, .waiting): "ПРИГЛАШЕНИЕ ОТПРАВЛЕНО"
        case (.ru, .declined): "МОЖНО ПРИГЛАСИТЬ ПОЗЖЕ"
        case (.ru, .accepted): "ПОДКЛЮЧАЕМ К ИГРЕ"
        case (.ru, .inGame): "ПРИГЛАСИТЬ НЕЛЬЗЯ"
        case (.ru, .blocked): "ИГРОК ОТКЛЮЧИЛ ИХ В НАСТРОЙКАХ"
        case (.ru, .unavailable): "ПОПРОБУЙ ЕЩЁ РАЗ"
        case (.es, .waiting): "INVITACIÓN ENVIADA"
        case (.es, .declined): "PUEDES INVITAR MÁS TARDE"
        case (.es, .accepted): "CONECTANDO A LA PARTIDA"
        case (.es, .inGame): "NO SE PUEDE INVITAR"
        case (.es, .blocked): "DESACTIVADAS EN AJUSTES"
        case (.es, .unavailable): "INTÉNTALO DE NUEVO"
        case (_, .waiting): "INVITATION SENT"
        case (_, .declined): "YOU CAN INVITE AGAIN LATER"
        case (_, .accepted): "CONNECTING TO THE GAME"
        case (_, .inGame): "UNAVAILABLE TO INVITE"
        case (_, .blocked): "DISABLED IN PLAYER SETTINGS"
        case (_, .unavailable): "TRY AGAIN"
        case (_, .available): "TAP TO INVITE"
        }
    }

    private var policyTitle: String {
        switch (language, peer.invitePolicy) {
        case (.ru, .ask): "ВХОД С ПОДТВЕРЖДЕНИЕМ"
        case (.ru, .automatic): "АВТОМАТИЧЕСКИЙ ВХОД"
        case (.ru, .blocked): "ПРИГЛАШЕНИЯ ОТКЛЮЧЕНЫ"
        case (.es, .ask): "ENTRADA CON CONFIRMACIÓN"
        case (.es, .automatic): "ENTRADA AUTOMÁTICA"
        case (.es, .blocked): "INVITACIONES DESACTIVADAS"
        case (_, .ask): "CONFIRMATION REQUIRED"
        case (_, .automatic): "AUTOMATIC ENTRY"
        case (_, .blocked): "INVITATIONS DISABLED"
        }
    }

    private var actionTitle: String {
        switch (language, peer.invitePolicy) {
        case (.ru, .ask): "ПРИГЛАСИТЬ"
        case (.ru, .automatic): "ПОДКЛЮЧИТЬ"
        case (.ru, .blocked): "НЕДОСТУПЕН"
        case (.es, .ask): "INVITAR"
        case (.es, .automatic): "CONECTAR"
        case (.es, .blocked): "NO DISPONIBLE"
        case (_, .ask): "INVITE"
        case (_, .automatic): "CONNECT"
        case (_, .blocked): "UNAVAILABLE"
        }
    }

    private var accessibilityLabel: String {
        "\(peer.callSign), SpyID \(peer.spyID), \(cardState == .available ? policyTitle : stateTitle)"
    }
}

private struct RadarPeerPresenceModifier: ViewModifier {
    let opacity: Double
    let saturation: Double
    let brightness: Double
    let scale: CGFloat
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .saturation(saturation)
            .brightness(brightness)
            .scaleEffect(scale)
            .blur(radius: blurRadius)
    }
}

extension AnyTransition {
    static var radarPeerPresence: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: RadarPeerPresenceModifier(
                    opacity: 0,
                    saturation: 0.18,
                    brightness: -0.08,
                    scale: 0.96,
                    blurRadius: 5
                ),
                identity: RadarPeerPresenceModifier(
                    opacity: 1,
                    saturation: 1,
                    brightness: 0,
                    scale: 1,
                    blurRadius: 0
                )
            ),
            removal: .modifier(
                active: RadarPeerPresenceModifier(
                    opacity: 0,
                    saturation: 0.10,
                    brightness: -0.16,
                    scale: 0.985,
                    blurRadius: 3
                ),
                identity: RadarPeerPresenceModifier(
                    opacity: 1,
                    saturation: 1,
                    brightness: 0,
                    scale: 1,
                    blurRadius: 0
                )
            )
        )
    }
}

struct NearbySpyIDPlaceholder: View {
    let index: Int
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let scale = max(proxy.size.width / 355, 0.44)
            let cardShape = RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)

            VStack(spacing: 0) {
                HStack(spacing: 6 * scale) {
                    SpyBrandMark()
                        .frame(width: 28 * scale, height: 36 * scale)
                    Text("SLOT // \(String(format: "%02d", index + 1))")
                    Spacer()
                    Circle()
                        .fill(isActive ? SpyTheme.amber : SpyTheme.strokeStrong)
                        .frame(width: 5 * scale, height: 5 * scale)
                }
                .font(.system(size: 7 * scale, weight: .black, design: .monospaced))
                .foregroundStyle(isActive ? SpyTheme.amber : SpyTheme.faint)
                .padding(.horizontal, 13 * scale)
                .frame(height: 50 * scale)

                LinearGradient(colors: [.clear, Color.white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)

                HStack(spacing: 13 * scale) {
                    NearbyPlaceholderLine(width: 52 * scale, isActive: isActive)
                        .frame(height: 52 * scale)
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        NearbyPlaceholderLine(width: nil, isActive: isActive).frame(height: 9 * scale)
                        NearbyPlaceholderLine(width: 68 * scale, isActive: isActive).frame(height: 6 * scale)
                    }
                }
                .padding(.horizontal, 17 * scale)
                .padding(.top, 14 * scale)
                .padding(.bottom, 16 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.width / 1.50)
            .background(SpyTheme.card.opacity(0.58), in: cardShape)
            .overlay(
                cardShape.stroke(
                    isActive ? SpyTheme.amber.opacity(0.24) : SpyTheme.strokeDim,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 5])
                )
            )
        }
        .aspectRatio(1.50, contentMode: .fit)
        .opacity(isActive ? 0.82 : 0.46)
        .animation(.easeInOut(duration: 0.9), value: isActive)
        .accessibilityHidden(true)
    }
}

private struct NearbyPlaceholderLine: View {
    let width: CGFloat?
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isActive ? SpyTheme.amber.opacity(0.11) : Color.white.opacity(0.035))
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
    }
}

private struct NearbyStatusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + 12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 12))
        path.closeSubpath()
        return path
    }
}

struct RadarPolicySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(en: "// RADAR ACCESS", ru: "// ДОСТУП ПО РАДАРУ", es: "// ACCESO POR RADAR"))
                .font(SpyTheme.micro)
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker(lines: 2)

            Text(localized(
                en: "What should happen when a nearby host taps your signal?",
                ru: "Что делать, когда находящийся рядом хост нажимает на твой сигнал?",
                es: "¿Qué ocurre cuando un anfitrión cercano toca tu señal?"
            ))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(SpyTheme.faint)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 7) {
                ForEach(RadarInvitePolicy.allCases) { policy in
                    policyButton(policy)
                }
            }

            syncStatus
        }
        .padding(12)
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SpyTheme.stroke, lineWidth: 1)
        )
    }

    private func policyButton(_ policy: RadarInvitePolicy) -> some View {
        let selected = appState.radarNearby.invitePolicy == policy
        return Button {
            appState.setRadarInvitePolicy(policy)
            HapticManager.shared.fire(.tabSelection)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon(for: policy))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(selected ? .white : SpyTheme.red)
                    .frame(width: 32, height: 32)
                    .background(selected ? SpyTheme.red : SpyTheme.red.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: policy))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(detail(for: policy))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SpyTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(selected ? SpyTheme.red : SpyTheme.strokeStrong)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(selected ? SpyTheme.red.opacity(0.07) : SpyTheme.panelDeep, in: CutCornerShape(cut: 8))
            .overlay(CutCornerShape(cut: 8).stroke(selected ? SpyTheme.red.opacity(0.58) : SpyTheme.stroke, lineWidth: 1))
            .contentShape(CutCornerShape(cut: 8))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier("profile.radarPolicy.\(policy.rawValue)")
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch appState.radarInvitePolicySyncState {
        case .localOnly:
            syncStatusLabel(
                icon: "iphone",
                text: localized(
                    en: "Saved on this iPhone. Sign in to sync it with your SpyClash account.",
                    ru: "Сохранено на этом iPhone. Войди, чтобы синхронизировать с аккаунтом SpyClash.",
                    es: "Guardado en este iPhone. Inicia sesión para sincronizarlo con tu cuenta de SpyClash."
                )
            )
        case .syncing:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(SpyTheme.red)
                Text(localized(
                    en: "Saved on this iPhone. Syncing your account…",
                    ru: "Сохранено на этом iPhone. Синхронизируем аккаунт…",
                    es: "Guardado en este iPhone. Sincronizando tu cuenta…"
                ))
            }
            .syncStatusStyle()
        case .synced:
            syncStatusLabel(
                icon: "checkmark.circle.fill",
                text: localized(
                    en: "Saved to your SpyClash account.",
                    ru: "Сохранено в аккаунте SpyClash.",
                    es: "Guardado en tu cuenta de SpyClash."
                )
            )
        case .pendingRetry:
            Button {
                appState.retryRadarInvitePolicySync()
                HapticManager.shared.fire(.buttonPress)
            } label: {
                syncStatusLabel(
                    icon: "arrow.clockwise",
                    text: localized(
                        en: "Saved on this iPhone. Account sync is waiting — tap to retry.",
                        ru: "Сохранено на этом iPhone. Синхронизация ожидает — нажми, чтобы повторить.",
                        es: "Guardado en este iPhone. La sincronización está pendiente; toca para reintentar."
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.radarPolicy.retrySync")
        }
    }

    private func syncStatusLabel(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .syncStatusStyle()
    }

    private func title(for policy: RadarInvitePolicy) -> String {
        switch (appState.language, policy) {
        case (.ru, .ask): "СПРАШИВАТЬ"
        case (.ru, .automatic): "ВХОДИТЬ АВТОМАТИЧЕСКИ"
        case (.ru, .blocked): "НЕ ПРИНИМАТЬ"
        case (.es, .ask): "PREGUNTAR"
        case (.es, .automatic): "ENTRAR AUTOMÁTICAMENTE"
        case (.es, .blocked): "NO ACEPTAR"
        case (_, .ask): "ASK FIRST"
        case (_, .automatic): "JOIN AUTOMATICALLY"
        case (_, .blocked): "DO NOT ACCEPT"
        }
    }

    private func detail(for policy: RadarInvitePolicy) -> String {
        switch (appState.language, policy) {
        case (.ru, .ask): "Показать приглашение перед входом"
        case (.ru, .automatic): "Сразу войти в комнату, если ты свободен"
        case (.ru, .blocked): "Показать хосту, что приглашения отключены"
        case (.es, .ask): "Mostrar la invitación antes de entrar"
        case (.es, .automatic): "Entrar si no estás en otra sala"
        case (.es, .blocked): "Indicar que desactivaste las invitaciones"
        case (_, .ask): "Show an invitation before joining"
        case (_, .automatic): "Join immediately when you are free"
        case (_, .blocked): "Tell the host that invitations are disabled"
        }
    }

    private func icon(for policy: RadarInvitePolicy) -> String {
        switch policy {
        case .ask: "questionmark.bubble.fill"
        case .automatic: "bolt.fill"
        case .blocked: "hand.raised.fill"
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }
}

private extension View {
    func syncStatusStyle() -> some View {
        font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(SpyTheme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RadarIncomingInvitationOverlay: View {
    @Environment(AppState.self) private var appState
    let invitation: RadarIncomingInvitation

    @State private var isJoining = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack {
                        Spacer(minLength: 18)

                        invitationPanel

                        Spacer(minLength: 18)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(500)
        .accessibilityIdentifier("radar.incomingInvitation")
    }

    private var invitationPanel: some View {
        VStack(spacing: 15) {
            RadarIncomingSpyCard(invitation: invitation, language: appState.language)

            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(SpyTheme.red)
                        .frame(width: 5, height: 5)
                        .shadow(color: SpyTheme.red.opacity(0.55), radius: 5)

                    Text(localized(
                        en: "RADAR INVITATION",
                        ru: "ПРИГЛАШЕНИЕ ПО РАДАРУ",
                        es: "INVITACIÓN POR RADAR"
                    ))
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.75)
                    .foregroundStyle(SpyTheme.red)
                }

                Text(localized(
                    en: "FOUND ON RADAR",
                    ru: "ВАС НАШЛИ ПО РАДАРУ",
                    es: "LOCALIZADO POR RADAR"
                ))
                .font(SpyTheme.brandFont(size: 25))
                .tracking(0.8)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.72)

                Text(localized(
                    en: "\(invitation.hostCallSign) invites you to room \(invitation.roomCode).",
                    ru: "\(invitation.hostCallSign) приглашает вас в комнату \(invitation.roomCode).",
                    es: "\(invitation.hostCallSign) te invita a la sala \(invitation.roomCode)."
                ))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 10) {
                Button {
                    appState.declineRadarInvitation()
                } label: {
                    Text(localized(en: "DECLINE", ru: "ОТКЛОНИТЬ", es: "RECHAZAR"))
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isJoining)

                Button {
                    Task {
                        isJoining = true
                        _ = await appState.acceptRadarInvitation()
                        isJoining = false
                    }
                } label: {
                    Text(localized(
                        en: isJoining ? "JOINING..." : "JOIN",
                        ru: isJoining ? "ВХОДИМ..." : "ВОЙТИ",
                        es: isJoining ? "ENTRANDO..." : "ENTRAR"
                    ))
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isJoining)
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(SpyTheme.card, in: CutCornerShape(cut: 16))
        .overlay(CutCornerShape(cut: 16).stroke(SpyTheme.red.opacity(0.72), lineWidth: 1))
        .padding(.horizontal, 8)
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }
}

private struct RadarIncomingSpyCard: View {
    let invitation: RadarIncomingInvitation
    let language: AppLanguage

    var body: some View {
        GeometryReader { proxy in
            let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SpyBrandMark()
                        .frame(width: 28, height: 36)
                        .offset(x: -2)

                    HStack(spacing: 6) {
                        Text(badgeGlyph)
                            .foregroundStyle(accent)
                        Text(badgeTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.6)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(accent.opacity(0.075), in: Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.30), lineWidth: 0.75))

                    Spacer(minLength: 12)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                        Text("RADAR")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.12)
                            .foregroundStyle(accent)
                    }
                }
                .padding(.leading, 13)
                .padding(.trailing, 17)
                .frame(height: 50)

                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)

                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 13) {
                        Text(invitation.hostAvatar)
                            .font(.system(size: 29))
                            .frame(width: 52, height: 52)
                            .background(
                                Color.black.opacity(0.30),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(accent.opacity(0.38), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(invitation.hostCallSign.uppercased())
                                .font(SpyTheme.brandFont(size: 24))
                                .tracking(0.9)
                                .foregroundStyle(.white)
                                .spyFitted(lines: 1, scale: 0.62)

                            Text("SPYID • \(invitation.hostSpyID)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .tracking(0.08)
                                .foregroundStyle(Color.white.opacity(0.38))
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 9) {
                        metric(
                            metricTitle(.rating),
                            value: "\(invitation.hostRating >= 0 ? "+" : "")\(invitation.hostRating)",
                            color: SpyTheme.red
                        )
                        metric(
                            metricTitle(.games),
                            value: "\(invitation.hostGamesPlayed)",
                            color: SpyTheme.amber
                        )
                        metric(
                            metricTitle(.rate),
                            value: "\(invitation.hostWinRate)%",
                            color: SpyTheme.green
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 17)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .frame(width: proxy.size.width, height: proxy.size.width / 1.50)
            .background {
                ZStack {
                    cardShape
                        .fill(.ultraThinMaterial)
                        .opacity(invitation.hostSpyCardTheme == .field ? 1 : 0.46)
                    cardShape
                        .fill(Color.black.opacity(invitation.hostSpyCardTheme == .blacksite ? 0.78 : 0.34))
                    cardShape
                        .fill(
                            LinearGradient(
                                colors: themeColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    cardShape
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.10), .clear],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.58
                            )
                        )
                    cardShape
                        .fill(
                            RadialGradient(
                                colors: [accent.opacity(0.11), .clear],
                                center: .bottomTrailing,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.66
                            )
                        )
                    SpyCardSurfacePattern(theme: invitation.hostSpyCardTheme, accent: accent)
                        .clipShape(cardShape)
                }
            }
            .clipShape(cardShape)
            .overlay {
                cardShape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.07),
                            accent.opacity(0.22)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .overlay {
                cardShape
                    .inset(by: 1.5)
                    .stroke(Color.white.opacity(0.035), lineWidth: 0.75)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.20), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 30)
            }
            .overlay(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [.clear, accent.opacity(0.68), Color.white.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 76, height: 1.5)
                .padding(.trailing, 22)
                .padding(.bottom, 1)
                .shadow(color: accent.opacity(0.18), radius: 5)
            }
            .background {
                ZStack {
                    cardShape
                        .stroke(Color.black.opacity(0.90), lineWidth: 1)
                        .shadow(color: .black.opacity(0.38), radius: 14)
                    cardShape
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                        .shadow(color: accent.opacity(0.11), radius: 10)
                }
            }
        }
        .aspectRatio(1.50, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private enum Metric {
        case rating
        case games
        case rate
    }

    private var accent: Color {
        switch invitation.hostSpyCardAccent {
        case .signalRed: SpyTheme.red
        case .clearanceAmber: SpyTheme.amber
        case .verifiedGreen: SpyTheme.green
        }
    }

    private var themeColors: [Color] {
        switch invitation.hostSpyCardTheme {
        case .field:
            [Color.white.opacity(0.085), Color.white.opacity(0.018), Color.black.opacity(0.24)]
        case .blacksite:
            [Color.white.opacity(0.035), Color.black.opacity(0.42), Color.black.opacity(0.82)]
        case .dossier:
            [SpyTheme.red.opacity(0.14), Color.white.opacity(0.025), Color.black.opacity(0.46)]
        }
    }

    private var badgeGlyph: String {
        switch invitation.hostSpyCardBadge {
        case .operative: "◆"
        case .ghost: "◌"
        case .analyst: "⌁"
        case .handler: "▲"
        }
    }

    private var badgeTitle: String {
        switch (invitation.hostSpyCardBadge, language) {
        case (.operative, .ru): "ОПЕРАТИВНИК"
        case (.ghost, .ru): "ПРИЗРАК"
        case (.analyst, .ru): "АНАЛИТИК"
        case (.handler, .ru): "КУРАТОР"
        case (.operative, .es): "OPERATIVO"
        case (.ghost, .es): "FANTASMA"
        case (.analyst, .es): "ANALISTA"
        case (.handler, .es): "CONTROL"
        case (.operative, _): "OPERATIVE"
        case (.ghost, _): "GHOST"
        case (.analyst, _): "ANALYST"
        case (.handler, _): "HANDLER"
        }
    }

    private func metricTitle(_ metric: Metric) -> String {
        switch (metric, language) {
        case (.rating, .ru): "РЕЙТИНГ"
        case (.games, .ru): "ИГРЫ"
        case (.rate, .ru): "ВИНРЕЙТ"
        case (.rating, .es): "RANGO"
        case (.games, .es): "JUEGOS"
        case (.rate, .es): "TASA VICT."
        case (.rating, _): "RATING"
        case (.games, _): "GAMES"
        case (.rate, _): "WIN RATE"
        }
    }

    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SpyTheme.brandFont(size: 20))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.20), radius: 6)
            Text(title)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(color.opacity(0.58))
                .spyFitted(scale: 0.60)
        }
        .frame(width: 58, alignment: .leading)
    }

    private var accessibilityLabel: String {
        switch language {
        case .ru:
            "SPYCARD, \(invitation.hostCallSign), SPYID \(invitation.hostSpyID), игр \(invitation.hostGamesPlayed), винрейт \(invitation.hostWinRate) процентов"
        case .es:
            "SPYCARD, \(invitation.hostCallSign), SPYID \(invitation.hostSpyID), \(invitation.hostGamesPlayed) juegos, \(invitation.hostWinRate) por ciento de victorias"
        default:
            "SPYCARD, \(invitation.hostCallSign), SPYID \(invitation.hostSpyID), \(invitation.hostGamesPlayed) games, \(invitation.hostWinRate) percent win rate"
        }
    }
}
