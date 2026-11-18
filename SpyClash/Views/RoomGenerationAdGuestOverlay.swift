import SwiftUI

/// Guests may choose an ad now or explicitly opt in to the next host signal.
/// Declining stays local and cannot delay the host's reward.
struct RoomGenerationAdGuestPresentation: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var consent = RoomGenerationAdGuestConsent()
    @State private var now = Date()
    @State private var watchOperationID: UUID?
    @State private var dismissedSessionID: UUID?
    @State private var watchingSessionID: UUID?
    @State private var watchTask: Task<Void, Never>?
    @State private var failed = false
    @State private var hasStartedViewing = false

    private var copy: RoomGenerationAdGuestCopy { .init(language: appState.language) }
    private var guestAdsAvailable: Bool { !appState.shouldUsePreviewData && UnityRewardedGenerationAdConfiguration.current.isConfigured }

    private var offer: RoomGenerationAdOffer? {
        RoomGenerationAdOfferPolicy.guestOffer(in: appState.activeRoom, viewerEmail: appState.user?.email, now: now)
    }

    private var scope: RoomGenerationAdGuestScope? {
        guard let room = appState.activeRoom, room.normalizedStatus == "waiting", let user = appState.user,
              room.hostEmail?.lowercased() != user.email.lowercased(),
              room.playersList.contains(where: { $0.email.lowercased() == user.email.lowercased() }) else { return nil }
        return .init(roomID: room.id, userID: user.id)
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if scope != nil, offer == nil, guestAdsAvailable {
                    Button {
                        consent.setArmed(!consent.isArmed, currentOfferID: offer?.id, isForeground: scenePhase == .active)
                        if consent.isArmed { Task { await RewardedGenerationAdPresenter.shared.preloadUnityAd() } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: consent.isArmed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(consent.isArmed ? SpyTheme.red : SpyTheme.muted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(copy.nextAd).font(SpyTheme.gameFont(size: 11, weight: .bold, relativeTo: .caption2)).foregroundStyle(SpyTheme.bodyText)
                                Text(copy.teamBonus).font(SpyTheme.gameFont(size: 11, relativeTo: .caption2)).foregroundStyle(SpyTheme.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(SpyTheme.dark)
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("roomGenerationAd.nextAdConsent")
                    .accessibilityValue(consent.isArmed ? "on" : "off")
                    .accessibilityHint(copy.detail)
                }
            }
            .overlay { prompt }
            .onChange(of: scope, initial: true) { _, _ in synchronizeOffer() }
            .onChange(of: offer?.id, initial: true) { _, _ in synchronizeOffer() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { consent.enteredBackground(); cancelPendingViewing() }
                if phase == .active { now = Date() }
                synchronizeOffer()
            }
            .task(id: appState.activeRoom?.roomGenerationAd) {
                now = Date()
                guard let offer = appState.activeRoom?.roomGenerationAd,
                      let expiry = RoomGenerationAdOfferPolicy.expiration(of: offer) else { return }
                let remaining = expiry.timeIntervalSinceNow
                guard remaining > 0, remaining <= 210 else { return }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard !Task.isCancelled else { return }
                now = Date()
            }
            .onDisappear { consent.enteredBackground(); cancelPendingViewing() }
    }

    @ViewBuilder private var prompt: some View {
        if let offer, dismissedSessionID != offer.id {
            ZStack {
                Color.black.opacity(0.90).ignoresSafeArea()
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 20) {
                            Image(systemName: "play.rectangle.fill").font(.system(size: 42)).foregroundStyle(SpyTheme.red)
                            Text(copy.title).font(SpyTheme.gameFont(size: 28, weight: .bold, relativeTo: .title2)).foregroundStyle(SpyTheme.text).multilineTextAlignment(.center)
                            Text(copy.detail).font(SpyTheme.gameFont(size: 17)).foregroundStyle(SpyTheme.bodyText).multilineTextAlignment(.center)
                            if watchingSessionID == offer.id {
                                ProgressView().tint(SpyTheme.red)
                                Text(copy.loading).font(SpyTheme.gameFont(size: 11, weight: .bold, relativeTo: .caption2)).foregroundStyle(SpyTheme.muted)
                            } else {
                                if failed || !guestAdsAvailable { Text(copy.unavailable).font(SpyTheme.gameFont(size: 11, weight: .bold, relativeTo: .caption2)).foregroundStyle(SpyTheme.red).multilineTextAlignment(.center) }
                                if guestAdsAvailable { Button { watch(offer) } label: {
                                    Text(copy.watch).font(SpyTheme.gameFont(size: 19, weight: .bold, relativeTo: .headline)).frame(maxWidth: .infinity).padding(.vertical, 15)
                                }
                                .foregroundStyle(.white).background(SpyTheme.red, in: CutCornerShape(cut: 8))
                                .buttonStyle(SpyWebPressStyle())
                                .accessibilityIdentifier("roomGenerationAd.watch") }
                            }
                            Button { dismiss(offer) } label: {
                                Text(copy.skip).font(SpyTheme.gameFont(size: 17)).frame(maxWidth: .infinity).padding(.vertical, 13)
                            }
                            .foregroundStyle(SpyTheme.muted).buttonStyle(SpyWebPressStyle())
                            .accessibilityIdentifier("roomGenerationAd.skip")
                        }
                        .padding(28).frame(maxWidth: 440)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("roomGenerationAd.offer")
        }
    }

    private func synchronizeOffer() {
        if consent.scope != scope {
            now = Date()
            cancelPendingViewing(); dismissedSessionID = nil
            consent.bind(scope, currentOfferID: offer?.id)
        }
        guard scope != nil else { return }
        if let watchingSessionID, watchingSessionID != offer?.id, !hasStartedViewing { cancelPendingViewing() }
        if let automaticID = consent.receive(offer?.id, isForeground: scenePhase == .active), let offer, automaticID == offer.id {
            watch(offer)
        }
    }

    private func watch(_ offer: RoomGenerationAdOffer) {
        guard guestAdsAvailable, scenePhase == .active, watchTask == nil,
              RoomGenerationAdOfferPolicy.guestOffer(in: appState.activeRoom, viewerEmail: appState.user?.email)?.id == offer.id else { return }
        failed = false; hasStartedViewing = false; watchingSessionID = offer.id
        let operationID = UUID(); watchOperationID = operationID
        let roomID = appState.activeRoom?.id, userID = appState.user?.id
        watchTask = Task { @MainActor in
            defer { if watchOperationID == operationID { watchTask = nil; watchingSessionID = nil; watchOperationID = nil; hasStartedViewing = false } }
            do {
                _ = try await RewardedGenerationAdPresenter.shared.presentGuestUnityAd(onStarted: {
                    if watchOperationID == operationID { hasStartedViewing = true; dismissedSessionID = offer.id }
                })
                guard !Task.isCancelled, appState.activeRoom?.id == roomID, appState.user?.id == userID else { return }
                dismissedSessionID = offer.id
            } catch {
                guard !Task.isCancelled, appState.activeRoom?.id == roomID, appState.user?.id == userID else { return }
                failed = true
            }
        }
    }

    private func dismiss(_ offer: RoomGenerationAdOffer) {
        dismissedSessionID = offer.id
        cancelPendingViewing()
    }

    private func cancelPendingViewing() {
        // A visible SDK ad retains its delegate/operation through terminal.
        // Inactive callbacks from ad interaction must not make it replayable.
        guard !hasStartedViewing else { return }
        if watchTask != nil, RewardedGenerationAdPresenter.shared.isPresentingUnityAd {
            hasStartedViewing = true
            dismissedSessionID = watchingSessionID
            return
        }
        if watchTask != nil {
            dismissedSessionID = watchingSessionID
            RewardedGenerationAdPresenter.shared.cancelPendingPresentation()
        }
        watchTask?.cancel(); watchTask = nil; watchingSessionID = nil; watchOperationID = nil; hasStartedViewing = false; failed = false
    }
}

private struct RoomGenerationAdGuestCopy {
    let title: String, detail: String, watch: String, skip: String, loading: String, unavailable: String, nextAd: String, teamBonus: String
    init(language: AppLanguage) {
        switch language {
        case .en:
            nextAd = "Watch the next ad with the host"
            teamBonus = "+1 goes to the host for a room theme."
            title = "AN AD WITH THE HOST"
            detail = "The host earns one generation for a room theme by completing an ad. You can watch your own ad together or skip."
            watch = "WATCH AN AD"; skip = "SKIP"; loading = "Preparing your ad…"; unavailable = "Your ad is unavailable. You can skip and stay in the room."
        case .es:
            nextAd = "Ver el próximo anuncio con el anfitrión"
            teamBonus = "+1 para el anfitrión y un tema de la sala."
            title = "UN ANUNCIO CON EL ANFITRIÓN"
            detail = "El anfitrión gana una generación para un tema de la sala al completar el anuncio. Puedes ver tu propio anuncio o saltarlo."
            watch = "VER UN ANUNCIO"; skip = "SALTAR"; loading = "Preparando tu anuncio…"; unavailable = "Tu anuncio no está disponible. Puedes saltarlo y seguir en la sala."
        case .ru:
            nextAd = "Смотреть следующую рекламу с хостом"
            teamBonus = "+1 хосту на тему комнаты."
            title = "РЕКЛАМА ВМЕСТЕ С ХОСТОМ"
            detail = "За полный просмотр хост получит одну генерацию для темы комнаты. Ты можешь посмотреть свой ролик вместе с ним или пропустить."
            watch = "СМОТРЕТЬ РЕКЛАМУ"; skip = "ПРОПУСТИТЬ"; loading = "Готовим твою рекламу…"; unavailable = "Твоя реклама недоступна. Можно пропустить и остаться в комнате."
        case .uk:
            nextAd = "Дивитися наступну рекламу з хостом"
            teamBonus = "+1 хосту на тему кімнати."
            title = "РЕКЛАМА РАЗОМ ІЗ ХОСТОМ"
            detail = "За повний перегляд хост отримає одну генерацію для теми кімнати. Ти можеш переглянути свій ролик разом із ним або пропустити."
            watch = "ДИВИТИСЯ РЕКЛАМУ"; skip = "ПРОПУСТИТИ"; loading = "Готуємо твою рекламу…"; unavailable = "Твоя реклама недоступна. Можна пропустити й залишитися в кімнаті."
        }
    }
}
