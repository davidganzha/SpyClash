import SwiftUI
import UIKit

struct GameView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var status = ""
    @State private var isStarting = false
    @State private var isAdvancing = false
    @State private var isRequestingVote = false
    @State private var isCastingVote = false
    @State private var isMarkingCardRead = false
    @State private var isTogglingGamePause = false
    @State private var isFinalizingExpiredRoom = false
    @State private var isTogglingReady = false
    @State private var lobbyPackLoadState = RoomPackLoadState.idle
    @State private var isSubmittingSpyGuess = false
    @State private var isVotingReplay = false
    @State private var isResettingRoom = false
    @State private var copiedRoomCode = false
    @State private var showsThemeBuilder = false
    @State private var isUpdatingGameMode = false
    @State private var isUpdatingDuration = false
    @State private var roomAccessPage = 0
    @State private var isRoomCodeVisible = false
    @State private var isRoomQRVisible = false
    @State private var roomQRFlipProgress = 0.0
    @State private var isRoomQRFlipping = false
    @State private var roomQRFlipID = UUID()
    @State private var roomQRSheenProgress: CGFloat = -1
    @State private var roomQRIsLifted = false
    @State private var preparedRoomQR: PreparedRoomQRCode?
    @State private var revealRole = false
    @State private var showSpyGuess = false
    @State private var now = Date()
    @State private var selectedGameMode = SpyGameMode.questions
    @State private var selectedDurationMinutes = 15.0
    @State private var roomWordSource = RoomWordSource.none
    @State private var lobbyWordPacks: [WordPack] = []
    @State private var roomTheme = ""
    @State private var roomGeneratedPack: GeneratedWordPack?
    @State private var roomThemeFallbackSource = RoomWordSource.none
    @State private var roomThemeError = ""
    @State private var roomWordCount = 25.0
    @State private var roomCustomWordCount = 25.0
    @State private var roomWordCountMode = RoomWordCountMode.recommended
    @State private var showsAllRoomPoolWords = false
    @State private var disabledRoomPoolWordKeys: Set<String> = []
    @State private var roomThemeOperation: RoomThemeOperation?
    @State private var isSavingRoomThemePack = false
    @State private var configuredRoomID: String?
    @State private var pendingStartPlan: GameStartPlan?
    @State private var rouletteCompletionKey: String?
    @State private var isDraggingOnlineDuration = false
    @FocusState private var focusedOnlineSetupField: OnlineSetupField?

    private var copy: GameCopy {
        appState.language.game
    }

    private var roomQRTargetBinding: Binding<RoomQRTarget> {
        Binding(
            get: { appState.roomQRTarget },
            set: { appState.roomQRTarget = $0 }
        )
    }

    private var roomRadar: RadarNearbyService {
        appState.radarNearby
    }

    private var selectedPackID: String? {
        switch roomWordSource {
        case .none:
            nil
        case .generated:
            "generated"
        case let .saved(id):
            id
        }
    }

    private var isLoadingLobbyPacks: Bool {
        lobbyPackLoadState == .loading
    }

    private var roomPackLoadError: String? {
        guard case let .failed(message) = lobbyPackLoadState else { return nil }
        return message
    }

    var body: some View {
        Group {
            if let room = appState.activeRoom, showsImmersiveGameExperience(for: room) {
                immersiveGameExperience(room)
            } else {
                standardGameSurface
            }
        }
        .animation(reduceMotion ? nil : SpyMotion.page, value: roomSceneKey)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let room = appState.activeRoom,
               showsWaitingFooter(for: room),
               !isOnlineTextInputFocused {
                waitingActionBar(room)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(reduceMotion ? nil : SpyMotion.page, value: waitingFooterSceneKey)
        .task(id: appState.activeRoom?.id) {
            while !Task.isCancelled, appState.activeRoom != nil {
                now = Date()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .task(id: expiredRoomTaskKey) {
            guard let room = appState.activeRoom,
                  room.normalizedStatus == "playing",
                  isTimeExpired(room),
                  !room.isGamePaused else { return }
            await finalizeExpiredRoomIfNeeded(room)
        }
        .onChange(of: appState.activeRoom?.gameMode) { _, rawMode in
            guard let rawMode else { return }
            selectedGameMode = SpyGameMode(rawValue: rawMode.lowercased()) ?? .questions
        }
        .onChange(of: appState.activeRoom?.gameDurationSeconds) { _, seconds in
            guard let seconds, !isUpdatingDuration, !isDraggingOnlineDuration else { return }
            selectedDurationMinutes = Double(max(1, min(seconds / 60, 15)))
        }
        .onAppear {
            updateOnlineShellChromeSuppression()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--spyclash-preview-reveal-role") {
                revealRole = true
            }
#endif
        }
        .onChange(of: appState.activeRoom?.normalizedStatus) { _, _ in
            updateOnlineShellChromeSuppression()
        }
        .onDisappear {
            appState.isShellChromeSuppressed = false
        }
        .onChange(of: status) { _, message in
            publishGameToast(message)
        }
        .onChange(of: roomThemeError) { _, message in
            publishRoomThemeError(message)
        }
        .onChange(of: lobbyPackLoadState) { _, state in
            guard case let .failed(message) = state else { return }
            appState.showToast(userFacingStatus(message) ?? message, kind: .error)
        }
        .sheet(isPresented: $showSpyGuess) {
            if let room = appState.activeRoom {
                SpyGuessSheet(
                    room: room,
                    isSubmitting: isSubmittingSpyGuess,
                    copy: copy
                ) { word in
                    Task { await submitSpyGuess(room, word: word) }
                }
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
            }
        }
    }

    private var standardGameSurface: some View {
        PageChrome(eyebrow: copy.eyebrow, status: appState.activeRoom.map(roomStateLabel) ?? copy.standby) {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if let room = appState.activeRoom {
                        switch room.normalizedStatus {
                        case "ready_voting":
                            readyVotingRoom(room)
                        case "roulette":
                            rouletteRoom(room)
                        case "playing":
                            playingRoom(room)
                        case "ended", "finished":
                            finishedRoom(room)
                        default:
                            waitingRoom(room)
                        }
                    } else {
                        emptyRoom
                    }
                }
                .id(roomSceneKey)
                .transition(.opacity)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .animation(SpyMotion.page, value: roomSceneKey)
        }
    }

    private var roomSceneKey: String {
        guard let room = appState.activeRoom else { return "empty" }
        if room.normalizedStatus == "playing" {
            let phase = room.allRoleCardsRead && room.gameStartedAt != nil ? "active" : "role-gate"
            return "\(room.id)-playing-\(phase)"
        }
        return "\(room.id)-\(room.normalizedStatus)"
    }

    private var waitingFooterSceneKey: String {
        guard let room = appState.activeRoom,
              showsWaitingFooter(for: room),
              !isOnlineTextInputFocused
        else { return "hidden" }
        return "waiting-\(room.id)"
    }

    private var expiredRoomTaskKey: String {
        guard let room = appState.activeRoom,
              room.normalizedStatus == "playing",
              room.gameStartedAt != nil else { return "inactive" }
        return "\(room.id)-\(room.gameStartedAt ?? "")-\(room.isGamePaused)-\(isTimeExpired(room))"
    }

    private var isOnlineTextInputFocused: Bool {
        focusedOnlineSetupField != nil
    }

    private func updateOnlineShellChromeSuppression() {
        guard let status = appState.activeRoom?.normalizedStatus else {
            appState.isShellChromeSuppressed = false
            return
        }
        appState.isShellChromeSuppressed = status == "roulette" || status == "playing"
    }

    private func showsImmersiveGameExperience(for room: GameRoom) -> Bool {
        room.normalizedStatus == "roulette" || room.normalizedStatus == "playing"
    }

    @ViewBuilder
    private func immersiveGameExperience(_ room: GameRoom) -> some View {
        switch room.normalizedStatus {
        case "roulette":
            OnlineGameIntroScene(room: room, language: appState.language)
                .transition(.opacity)
                .task(id: "intro-\(room.id)-\(room.introStartedAt ?? "pending")") {
                    await completeRouletteIfNeeded(room)
                }

        case "playing" where !room.allRoleCardsRead || room.gameStartedAt == nil:
            OnlineRoleRevealScene(
                room: room,
                language: appState.language,
                role: onlineRoleContent(for: room),
                cardTheme: onlineCardTheme,
                cardAccent: onlineCardAccent,
                currentUserEmail: appState.user?.email,
                isRevealed: revealRole,
                isConfirming: isMarkingCardRead,
                onReveal: revealOnlineRole,
                onConfirm: {
                    Task { await markCardRead(room) }
                },
                onLeave: {
                    Task { await leaveRoom(room) }
                }
            )
            .transition(.opacity)

        case "playing":
            OnlineActiveGameScene(
                room: room,
                language: appState.language,
                role: onlineRoleContent(for: room),
                cardTheme: onlineCardTheme,
                cardAccent: onlineCardAccent,
                currentUserEmail: appState.user?.email,
                isHost: isHost(room),
                isRoleRevealed: revealRole,
                canAdvance: canCurrentUserAdvance(room),
                canRequestVote: canCurrentUserRequestVote(room),
                canSpyGuess: canCurrentUserGuess(room),
                canCastVote: canCurrentUserCastVote(room),
                onToggleRole: revealOnlineRole,
                onTogglePause: {
                    Task { await toggleGamePause(room) }
                },
                onAdvance: {
                    Task { await advance(room) }
                },
                onRequestVote: {
                    Task { await requestVote(room) }
                },
                onCastVote: { targetEmail in
                    Task { await castVote(room, targetEmail: targetEmail) }
                },
                onSpyGuess: {
                    showSpyGuess = true
                    HapticManager.shared.fire(.buttonPress)
                },
                onLeave: {
                    Task { await leaveRoom(room) }
                }
            )
            .transition(.opacity)

        default:
            standardGameSurface
        }
    }

    private func revealOnlineRole() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.72, dampingFraction: 0.78)) {
            revealRole.toggle()
        }
        HapticManager.shared.fire(revealRole ? .reveal : .buttonPress)
    }

    private func onlineRoleContent(for room: GameRoom) -> MissionRoleCardContent {
        if isCurrentUserSpectator(room) {
            return .spectator
        }
        if currentUserIsSpy(room) {
            return .spy
        }
        return .detective(word: room.displayWord ?? copy.classified)
    }

    private var onlineCardTheme: SpyCardThemeID {
        SpyCardThemeID(rawValue: appState.user?.spyCardTheme ?? "") ?? .field
    }

    private var onlineCardAccent: Color {
        switch SpyCardAccentID(rawValue: appState.user?.spyCardAccent ?? "") ?? .signalRed {
        case .signalRed:
            SpyTheme.red
        case .clearanceAmber:
            SpyTheme.amber
        case .verifiedGreen:
            SpyTheme.green
        }
    }

    private func canCurrentUserAdvance(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return !room.isGamePaused &&
            !isTimeExpired(room) &&
            !room.isVotingActive &&
            !isAdvancing &&
            !isCurrentUserSpectator(room) &&
            room.currentAskerEmail == email
    }

    private func canCurrentUserRequestVote(_ room: GameRoom) -> Bool {
        !room.isGamePaused &&
            !isTimeExpired(room) &&
            !room.isVotingActive &&
            !isRequestingVote &&
            !isCurrentUserSpectator(room) &&
            !hasCurrentUserRequestedVote(room)
    }

    private func canCurrentUserGuess(_ room: GameRoom) -> Bool {
        !room.isGamePaused &&
            !isSubmittingSpyGuess &&
            !room.enabledWordPool.isEmpty &&
            currentUserIsSpy(room) &&
            (!isTimeExpired(room) || postGameGuessSecondsRemaining(room) > 0) &&
            !isCurrentUserSpectator(room)
    }

    private func canCurrentUserCastVote(_ room: GameRoom) -> Bool {
        !room.isGamePaused &&
            !isTimeExpired(room) &&
            room.isVotingActive &&
            !isCastingVote &&
            !isCurrentUserSpectator(room) &&
            myVote(in: room) == nil
    }

    private func showsWaitingFooter(for room: GameRoom) -> Bool {
        switch room.normalizedStatus {
        case "ready_voting", "roulette", "playing", "ended", "finished":
            false
        default:
            true
        }
    }

    private func waitingRoom(_ room: GameRoom) -> some View {
        ZStack(alignment: .top) {
            if onlineSetupHasActiveCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissOnlineSetupCapture()
                    }
            }

            VStack(alignment: .leading, spacing: 14) {
                onlineSetupSlot(.mission, content: AnyView(onlineMissionPanel(room)))
                onlineSetupSlot(
                    .mode,
                    content: AnyView(
                        onlineModePanel(room)
                            .spyWebEntrance(delay: 0.04, duration: 0.42, y: 14)
                    )
                )
                onlineSetupSlot(
                    .timing,
                    content: AnyView(
                        onlineTimingPanel(room)
                            .spyWebEntrance(delay: 0.08, duration: 0.42, y: 14)
                    )
                )
                onlineSetupSlot(
                    .players,
                    content: AnyView(
                        onlinePlayersPanel(room)
                            .spyWebEntrance(delay: 0.12, duration: 0.42, y: 14)
                    )
                )
                if isHost(room) {
                    onlineSetupSlot(
                        .intel,
                        content: AnyView(
                            onlineIntelPanel
                                .spyWebEntrance(delay: 0.16, duration: 0.42, y: 14)
                        )
                    )
                } else {
                    onlineSetupSlot(
                        .intel,
                        content: AnyView(
                            onlineGuestIntelPanel(room)
                                .spyWebEntrance(delay: 0.16, duration: 0.42, y: 14)
                        )
                    )
                }
                onlineSetupSlot(
                    .controls,
                    content: AnyView(
                        onlineControls(room)
                            .spyWebEntrance(delay: 0.20, duration: 0.42, y: 14)
                    )
                )
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .transition(.opacity)
        .onDisappear {
            focusedOnlineSetupField = nil
            isDraggingOnlineDuration = false
        }
        .task(id: room.id) {
            await configureLobby(room)
        }
    }

    private func onlineSetupSlot(
        _ panel: OnlineSetupPanel,
        content: AnyView
    ) -> OnlineSetupSlotView {
        OnlineSetupSlotView(
            content: content,
            dimmed: onlineShouldDimPanel(panel),
            onDismiss: dismissOnlineSetupCapture
        )
    }

    private var onlineSetupHasActiveCapture: Bool {
        focusedOnlineSetupField != nil || isDraggingOnlineDuration
    }

    private func dismissOnlineSetupCapture() {
        focusedOnlineSetupField = nil
        isDraggingOnlineDuration = false
    }

    private var focusedOnlineSetupPanel: OnlineSetupPanel? {
        if isDraggingOnlineDuration {
            return .timing
        }

        switch focusedOnlineSetupField {
        case .theme:
            return .intel
        case nil:
            return nil
        }
    }

    private func onlineShouldDimPanel(_ panel: OnlineSetupPanel) -> Bool {
        guard let focusedOnlineSetupPanel else { return false }
        return focusedOnlineSetupPanel != panel
    }

    private func onlineMissionPanel(_ room: GameRoom) -> some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $roomAccessPage) {
                onlineRoomCodePage(room)
                    .tag(0)

                onlineRoomQRPage(room)
                    .tag(1)

                onlineRoomRadarPage(room)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 270)
            .accessibilityValue(localized(
                en: "Page \(roomAccessPage + 1) of 3",
                ru: "Страница \(roomAccessPage + 1) из 3",
                es: "Pagina \(roomAccessPage + 1) de 3"
            ))

            roomAccessPageIndicator
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 270)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: roomAccessPage)
        .onChange(of: roomAccessPage) { previousPage, nextPage in
            HapticManager.shared.fire(.tabSelection)
            updateRoomRadarScanning(from: previousPage, to: nextPage)
        }
        .onAppear {
            roomAccessPage = initialRoomAccessPage
            isRoomCodeVisible = false
            isRoomQRVisible = false
            roomQRFlipProgress = 0
            isRoomQRFlipping = false
            roomQRFlipID = UUID()
            roomQRSheenProgress = -1
            roomQRIsLifted = false
            if roomAccessPage == 2 {
                roomRadar.startScanning()
            }
        }
        .onChange(of: room.id) { _, _ in
            if roomAccessPage == 2 {
                roomRadar.stopScanning()
            }
            roomAccessPage = 0
            isRoomCodeVisible = false
            isRoomQRVisible = false
            roomQRFlipProgress = 0
            isRoomQRFlipping = false
            roomQRFlipID = UUID()
            roomQRSheenProgress = -1
            roomQRIsLifted = false
            preparedRoomQR = nil
        }
        .onDisappear {
            if roomAccessPage == 2 {
                roomRadar.stopScanning()
            }
        }
        .task(id: roomQRPayload(for: room)) {
            await prepareRoomQRCode(payload: roomQRPayload(for: room))
        }
        .spyWebEntrance(delay: 0, duration: 0.46, y: 12)
    }

    private func onlineRoomCodePage(_ room: GameRoom) -> some View {
        roomAccessCardSurface {
            VStack(spacing: 0) {
                roomAccessHeader(
                    room,
                    title: localized(en: "ROOM ACCESS", ru: "ДОСТУП В КОМНАТУ", es: "ACCESO A SALA")
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                VStack(spacing: 9) {
                    Text(roomCodePlainLabel)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.10)
                        .foregroundStyle(SpyTheme.dim)

                    Button {
                        if isRoomCodeVisible {
                            HapticManager.shared.fire(.buttonPress)
                        } else {
                            HapticManager.shared.fire(.reveal)
                        }
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .timingCurve(0.4, 0, 0.2, 1, duration: 0.55)
                        ) {
                            isRoomCodeVisible.toggle()
                        }
                    } label: {
                        ZStack {
                            if isRoomCodeVisible {
                                Text(room.code.uppercased())
                                    .font(SpyTheme.brandFont(size: 42))
                                    .tracking(8)
                                    .foregroundStyle(SpyTheme.red)
                                    .minimumScaleFactor(0.54)
                                    .lineLimit(1)
                                    .transition(.opacity.combined(with: .scale(scale: 0.90)))
                            } else {
                                RoomCodeSpoilerField(isActive: roomAccessPage == 0)
                                    .frame(maxWidth: 246, minHeight: 72)
                                    .transition(.opacity.combined(with: .scale(scale: 1.34)))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.roomCodeReveal")
                    .accessibilityLabel(
                        isRoomCodeVisible
                            ? localized(en: "Room code \(room.code). Tap to hide", ru: "Код комнаты \(room.code). Нажмите, чтобы скрыть", es: "Codigo \(room.code). Toca para ocultar")
                            : localized(en: "Room code hidden. Tap to reveal", ru: "Код комнаты скрыт. Нажмите, чтобы показать", es: "Codigo oculto. Toca para mostrar")
                    )

                    Text(isRoomCodeVisible ? tapToHideRoomCode : tapToRevealRoomCode)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.dim)

                    Button {
                        copyRoomCode(room)
                    } label: {
                        roomAccessActionLabel(
                            title: copiedRoomCode ? roomCopiedTitle : roomCopyTitle,
                            systemImage: copiedRoomCode ? "checkmark" : "doc.on.doc",
                            accent: copiedRoomCode ? SpyTheme.red : SpyTheme.muted
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .frame(maxWidth: 184)
                    .accessibilityIdentifier("onlineRoom.copyCode")
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    private func onlineRoomQRPage(_ room: GameRoom) -> some View {
        let payload = roomQRPayload(for: room)
        let targetTitle = appState.roomQRTarget == .web ? "WEB" : "iOS"
        let edgeProgress = CGFloat(sin(roomQRFlipProgress * .pi))

        return ZStack(alignment: .topTrailing) {
            ZStack {
                roomQRHiddenFace(room)
                    .modifier(
                        RoomQRFlipFace(
                            progress: roomQRFlipProgress,
                            isBack: false,
                            reduceMotion: reduceMotion
                        )
                    )

                roomQRVisibleFace(room, payload: payload)
                    .modifier(
                        RoomQRFlipFace(
                            progress: roomQRFlipProgress,
                            isBack: true,
                            reduceMotion: reduceMotion
                        )
                    )
            }
            .overlay {
                RoomQRFlipSheen(progress: roomQRSheenProgress)
                    .opacity(isRoomQRFlipping && !reduceMotion ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 270)
            .scaleEffect(roomQRIsLifted ? 1.018 : 1)
            .offset(y: roomQRIsLifted ? -4 : 0)
            .shadow(
                color: SpyTheme.red.opacity(isRoomQRFlipping ? 0.16 : 0.05),
                radius: isRoomQRFlipping ? 24 : 12,
                y: isRoomQRFlipping ? 10 : 6
            )
            .brightness(isRoomQRFlipping ? Double(edgeProgress) * 0.025 : 0)
            .clipShape(CutCornerShape(cut: 12))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Button {
                flipRoomQR()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 270)
                    .contentShape(CutCornerShape(cut: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onlineRoom.flipQR")
            .accessibilityLabel(
                isRoomQRVisible
                    ? localized(en: "Room \(targetTitle) QR visible. Tap the card to hide", ru: "\(targetTitle) QR комнаты открыт. Нажмите на карточку, чтобы скрыть", es: "QR \(targetTitle) visible. Toca la tarjeta para ocultar")
                    : localized(en: "Room QR hidden. Tap the card to flip", ru: "QR комнаты скрыт. Нажмите на карточку, чтобы перевернуть", es: "QR oculto. Toca la tarjeta para girar")
            )

            if isRoomQRVisible && !isRoomQRFlipping {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color.white.opacity(0.64))
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.54), in: CutCornerShape(cut: 7))
                            .overlay(
                                CutCornerShape(cut: 7)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .contentShape(CutCornerShape(cut: 7))
                    }
                    .buttonStyle(SpyWebPressStyle(pressedScale: 0.95))
                    .accessibilityIdentifier("onlineRoom.openQR")
                    .accessibilityLabel(localized(en: "Open large \(targetTitle) room QR", ru: "Открыть большой \(targetTitle) QR комнаты", es: "Abrir QR \(targetTitle) grande"))

                    RoomQRTargetToggle(
                        target: roomQRTargetBinding,
                        language: appState.language,
                        width: 44,
                        controlHeight: 76,
                        axis: .vertical
                    )
                }
                .padding(.top, 38)
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 270)
    }

    private func onlineRoomRadarPage(_ room: GameRoom) -> some View {
        let columns = [
            GridItem(.flexible(minimum: 0), spacing: 8),
            GridItem(.flexible(minimum: 0), spacing: 8)
        ]

        return roomAccessCardSurface {
            VStack(spacing: 0) {
                roomRadarHeader
                    .padding(.horizontal, 18)
                    .padding(.top, 15)

                Text(roomRadarStatusText)
                    .font(.system(size: 7.5, weight: .black, design: .monospaced))
                    .tracking(0.16)
                    .foregroundStyle(roomRadarStatusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
                    .padding(.horizontal, 18)
                    .contentTransition(.opacity)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        if roomRadar.peers.isEmpty {
                            ForEach(0..<4, id: \.self) { index in
                                NearbySpyIDPlaceholder(
                                    index: index,
                                    isActive: roomAccessPage == 2 && index < 2
                                )
                            }
                        } else {
                            ForEach(roomRadar.peers) { peer in
                                NearbySpyIDCard(
                                    peer: peer,
                                    language: appState.language,
                                    invitationState: roomRadar.invitationState(for: peer.id)
                                ) {
                                    inviteRoomRadarPeer(peer, to: room)
                                }
                                .transition(.radarPeerPresence)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 30)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.14)
                            : .spring(response: 0.48, dampingFraction: 0.88),
                        value: roomRadar.peers.map(\.id)
                    )
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .accessibilityIdentifier("onlineRoom.radarDirectory")
            }
        }
        .clipShape(CutCornerShape(cut: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized(
            en: "Radar, \(roomRadar.peers.count) nearby operatives",
            ru: "Радар, игроков рядом: \(roomRadar.peers.count)",
            es: "Radar, agentes cercanos: \(roomRadar.peers.count)"
        ))
    }

    private var roomRadarHeader: some View {
        HStack(spacing: 8) {
            Text("//")
                .foregroundStyle(SpyTheme.red)
            Text("RADAR")
                .foregroundStyle(Color.white.opacity(0.56))

            Spacer(minLength: 8)

            Circle()
                .fill(roomRadarStatusColor)
                .frame(width: 7, height: 7)
                .shadow(color: roomRadarStatusColor.opacity(0.42), radius: 5)
            Text(localized(en: "NEARBY", ru: "РЯДОМ", es: "CERCA"))
                .foregroundStyle(Color.white.opacity(0.52))
            Text(String(format: "%02d", roomRadar.peers.count))
                .foregroundStyle(Color.white.opacity(0.90))
                .contentTransition(.numericText())
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(0.08)
    }

    private var roomRadarStatusColor: Color {
        if case .unavailable = roomRadar.scanState { return SpyTheme.red }
        return roomRadar.peers.isEmpty ? SpyTheme.amber : SpyTheme.green
    }

    private var roomRadarStatusText: String {
        if case .unavailable = roomRadar.scanState {
            return localized(
                en: "LOCAL SEARCH UNAVAILABLE",
                ru: "ЛОКАЛЬНЫЙ ПОИСК НЕДОСТУПЕН",
                es: "BÚSQUEDA LOCAL NO DISPONIBLE"
            )
        }
        if roomRadar.peers.isEmpty {
            return localized(
                en: "SCANNING FOR OPEN SPYCLASH DEVICES",
                ru: "ИЩЕМ УСТРОЙСТВА С ОТКРЫТЫМ SPYCLASH",
                es: "BUSCANDO DISPOSITIVOS CON SPYCLASH"
            )
        }
        return localized(
            en: "TAP A SPYCARD TO SEND ROOM ACCESS",
            ru: "НАЖМИ SPYCARD, ЧТОБЫ ОТПРАВИТЬ ДОСТУП",
            es: "TOCA UNA SPYCARD PARA ENVIAR ACCESO"
        )
    }

    private func updateRoomRadarScanning(from previousPage: Int, to nextPage: Int) {
        if previousPage == 2, nextPage != 2 {
            roomRadar.stopScanning()
        }
        if nextPage == 2 {
            roomRadar.startScanning()
        }
    }

    private var initialRoomAccessPage: Int {
#if DEBUG
        if appState.shouldUsePreviewData,
           ProcessInfo.processInfo.arguments.contains("--spyclash-preview-room-access=radar") {
            return 2
        }
#endif
        return 0
    }

    private func inviteRoomRadarPeer(_ peer: RadarNearbyPeer, to room: GameRoom) {
        HapticManager.shared.fire(.buttonPress)

        Task { @MainActor in
            let result = await roomRadar.invite(peer, to: room)
            guard roomAccessPage == 2, appState.activeRoom?.id == room.id else { return }

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

    private func flipRoomQR() {
        guard !isRoomQRFlipping else { return }

        HapticManager.shared.fire(.reveal)
        let revealsQR = !isRoomQRVisible
        let targetProgress = revealsQR ? 1.0 : 0.0
        let flipID = UUID()
        roomQRFlipID = flipID
        isRoomQRFlipping = true

        if reduceMotion {
            Task { @MainActor in
                await Task.yield()
                guard roomQRFlipID == flipID else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    roomQRFlipProgress = targetProgress
                }

                try? await Task.sleep(for: .milliseconds(180))
                guard roomQRFlipID == flipID else { return }
                isRoomQRVisible = revealsQR
                withAnimation(.easeOut(duration: 0.14)) {
                    isRoomQRFlipping = false
                }
            }
            return
        }

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            roomQRSheenProgress = revealsQR ? -1.12 : 1.12
        }

        withAnimation(.easeOut(duration: 0.09)) {
            roomQRIsLifted = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(45))
            guard roomQRFlipID == flipID else { return }

            withAnimation(.timingCurve(0.25, 0.75, 0.15, 1, duration: 0.58)) {
                roomQRFlipProgress = targetProgress
                roomQRSheenProgress = revealsQR ? 1.12 : -1.12
            }

            try? await Task.sleep(for: .milliseconds(290))
            guard roomQRFlipID == flipID else { return }
            isRoomQRVisible = revealsQR

            try? await Task.sleep(for: .milliseconds(290))
            guard roomQRFlipID == flipID else { return }

            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                roomQRIsLifted = false
            }

            try? await Task.sleep(for: .milliseconds(140))
            guard roomQRFlipID == flipID else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                isRoomQRFlipping = false
            }
        }
    }

    private func roomQRPayload(for room: GameRoom) -> String {
        appState.client
            .roomJoinURL(code: room.code, target: appState.roomQRTarget)
            .absoluteString
    }

    private func prepareRoomQRCode(payload: String) async {
        guard preparedRoomQR?.payload != payload else { return }

        let prepared = await Task.detached(priority: .userInitiated) {
            PreparedRoomQRCode(
                payload: payload,
                image: QRCodeFactory.image(from: payload)
            )
        }.value

        guard !Task.isCancelled, prepared.payload == payload else { return }
        preparedRoomQR = prepared
    }

    private func roomQRHiddenFace(_ room: GameRoom) -> some View {
        roomAccessCardSurface {
            VStack(spacing: 0) {
                roomAccessHeader(
                    room,
                    title: localized(en: "QR INVITATION", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR")
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                Spacer(minLength: 6)

                ZStack {
                    RoomQRScanBeam(
                        isActive: roomAccessPage == 1 && !isRoomQRVisible && !isRoomQRFlipping
                    )

                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color.white.opacity(0.46))
                        .shadow(color: SpyTheme.red.opacity(0.16), radius: 12)
                }
                .frame(width: 96, height: 76)

                VStack(spacing: 9) {
                    Text(qrHiddenTitle)
                        .font(SpyTheme.brandFont(size: 18))
                        .tracking(2.7)
                        .foregroundStyle(Color.white.opacity(0.86))

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, SpyTheme.red.opacity(0.72), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 46, height: 1)

                    Text(tapToFlipQR)
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(Color.white.opacity(0.34))
                }

                Spacer(minLength: 22)
            }
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private func roomQRVisibleFace(_ room: GameRoom, payload: String) -> some View {
        roomAccessCardSurface {
            VStack(spacing: 0) {
                roomAccessHeader(
                    room,
                    title: localized(en: "QR INVITATION", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR")
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                Spacer(minLength: 4)

                ZStack {
                    SpyTheme.dark

                    if let preparedRoomQR, preparedRoomQR.payload == payload {
                        Image(uiImage: preparedRoomQR.image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .accessibilityHidden(true)
                    } else {
                        SpySpinner(size: 26, accent: SpyTheme.red)
                    }
                }
                .frame(width: 158, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .spyQRCodeFrame(cut: 9, inset: 10)
                .accessibilityIdentifier("onlineRoom.qrCode")

                Spacer(minLength: 3)

                Text(localized(
                    en: appState.roomQRTarget == .web
                        ? "SCAN WITH ANY CAMERA · TAP TO HIDE"
                        : "OPENS IN SPYCLASH · TAP TO HIDE",
                    ru: appState.roomQRTarget == .web
                        ? "СКАНИРУЙ ЛЮБОЙ КАМЕРОЙ · ТАП — СКРЫТЬ"
                        : "ОТКРОЕТСЯ В SPYCLASH · ТАП — СКРЫТЬ",
                    es: appState.roomQRTarget == .web
                        ? "ESCANEA CON CUALQUIER CÁMARA · TOCA PARA OCULTAR"
                        : "ABRE EN SPYCLASH · TOCA PARA OCULTAR"
                ))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.05)
                .foregroundStyle(Color.white.opacity(0.38))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                Spacer(minLength: 23)
            }
            .padding(.bottom, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private func roomAccessCardSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 270)
            .background(SpyTheme.panel, in: CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(SpyTheme.red.opacity(0.92))
                    .frame(width: 34, height: 3)
                    .padding(.top, 1)
                    .padding(.leading, 18)
            }
            .shadow(color: SpyTheme.red.opacity(0.06), radius: 14)
            .shadow(color: .black.opacity(0.30), radius: 18, y: 9)
    }

    private func roomAccessHeader(_ room: GameRoom, title: String) -> some View {
        let primary = Color.white.opacity(0.56)
        let secondary = Color.white.opacity(0.52)
        let count = Color.white.opacity(0.90)

        return HStack(spacing: 8) {
            Text("//")
                .foregroundStyle(SpyTheme.red)
            Text(title)
                .foregroundStyle(primary)

            Spacer(minLength: 8)

            Circle()
                .fill(SpyTheme.red)
                .frame(width: 7, height: 7)
                .shadow(color: SpyTheme.red.opacity(0.42), radius: 5)
            Text(localized(en: "LIVE", ru: "В СЕТИ", es: "EN LINEA"))
                .foregroundStyle(secondary)
            Text(String(format: "%02d", room.playersList.count))
                .foregroundStyle(count)
                .contentTransition(.numericText())
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(0.08)
    }

    private func roomAccessActionLabel(title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.05)
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.white.opacity(0.035), in: CutCornerShape(cut: 7))
            .overlay(CutCornerShape(cut: 7).stroke(accent.opacity(0.34), lineWidth: 1))
            .contentShape(CutCornerShape(cut: 7))
    }

    private var roomAccessPageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { page in
                Capsule()
                    .fill(page == roomAccessPage ? SpyTheme.red : Color.white.opacity(0.20))
                    .frame(width: page == roomAccessPage ? 24 : 10, height: 3)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
            value: roomAccessPage
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func onlineSetupPanel<Content: View>(
        accent: Color = SpyTheme.muted,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(SpyTheme.panel, in: CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(accent.opacity(0.88))
                    .frame(width: 34, height: 3)
                    .padding(.top, 1)
                    .padding(.leading, horizontalPadding)
            }
            .shadow(color: accent.opacity(0.06), radius: 14)
            .shadow(color: .black.opacity(0.30), radius: 18, y: 9)
    }

    private func onlineSectionHeader(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(SpyTheme.dim)
                .frame(width: 16)

            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.muted)
                .spyFitted(lines: 2, scale: 0.68)
        }
    }

    private func onlineModePanel(_ room: GameRoom) -> some View {
        let accent = selectedGameMode == .questions ? SpyTheme.red : SpyTheme.amber

        return onlineSetupPanel(accent: accent) {
            VStack(alignment: .leading, spacing: 14) {
                onlineSectionHeader(
                    systemImage: "gearshape.fill",
                    title: localized(en: "GAME MODE", ru: "РЕЖИМ ИГРЫ", es: "MODO DE JUEGO")
                )

                HStack(spacing: 10) {
                    onlineModeOption(room, mode: .questions, symbol: "?")
                    onlineModeOption(room, mode: .associations, symbol: "💭")
                }
            }
        }
    }

    private func onlineModeOption(_ room: GameRoom, mode: SpyGameMode, symbol: String) -> some View {
        let isSelected = selectedGameMode == mode

        return Button {
            guard isHost(room), !isSelected else { return }
            HapticManager.shared.fire(.tabSelection)
            Task { await updateMode(room, mode: mode) }
        } label: {
            VStack(spacing: 7) {
                Text(symbol)
                    .font(.system(size: mode == .questions ? 22 : 20, weight: .black, design: .default))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : SpyTheme.dim)

                Text(copy.modeTitle(mode))
                    .font(.system(size: 11, weight: .black, design: .default))
                    .tracking(copy.modeTitle(mode).count > 10 ? 0 : 0.08)
                    .foregroundStyle(isSelected ? .white : SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(isSelected ? SpyTheme.red : Color.clear, in: CutCornerShape(cut: 9))
            .overlay(CutCornerShape(cut: 9).stroke(isSelected ? SpyTheme.red : SpyTheme.stroke, lineWidth: 1))
            .contentShape(CutCornerShape(cut: 9))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(!isHost(room) || isUpdatingGameMode)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isSelected)
        .accessibilityIdentifier("onlineRoom.mode.\(mode.rawValue)")
    }

    private func onlinePlayersPanel(_ room: GameRoom) -> some View {
        let missingPlayers = max(3 - room.playersList.count, 0)

        return onlineSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                onlineSectionHeader(
                    systemImage: "person.2.fill",
                    title: "\(localized(en: "PLAYERS", ru: "ИГРОКИ", es: "JUGADORES")) (\(room.playersList.count) / 3+)"
                )

                VStack(spacing: 8) {
                    ForEach(Array(room.playersList.enumerated()), id: \.element.id) { index, player in
                        onlinePlayerRow(player, index: index, room: room)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                if missingPlayers > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .black))
                        Text(copy.minimumOperatives(room.playersList.count))
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(0.02)
                            .spyFitted(lines: 2, scale: 0.62)
                        Spacer()
                    }
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .spyCutCard(cut: 8, fill: SpyTheme.red.opacity(0.05), stroke: SpyTheme.red.opacity(0.24))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: room.playersList.map(\.id))
    }

    private func onlinePlayerRow(_ player: Player, index: Int, room: GameRoom) -> some View {
        let isCurrentUser = player.email == appState.user?.email
        let isRoomHost = player.email == room.hostEmail

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.78))
                .frame(width: 16)

            Text(player.avatar)
                .font(.system(size: 23))
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SpyTheme.strokeStrong.opacity(0.74), lineWidth: 1)
                }

            HStack(spacing: 8) {
                Text(player.name.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.56)

                Spacer(minLength: 4)

                if isRoomHost {
                    onlinePlayerBadge(copy.hostBadge, color: SpyTheme.red)
                } else if isCurrentUser {
                    onlinePlayerBadge(youLabel, color: SpyTheme.muted)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SpyTheme.strokeStrong.opacity(0.78), lineWidth: 1)
            }
        }
    }

    private func onlinePlayerBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.06)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(color.opacity(0.07))
            .overlay(Rectangle().stroke(color.opacity(0.28), lineWidth: 1))
            .lineLimit(1)
    }

    private var onlineIntelPanel: some View {
        onlineSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    onlineSectionHeader(
                        systemImage: "paintpalette.fill",
                        title: localized(en: "THEME", ru: "ТЕМА", es: "TEMA")
                    )
                    Spacer()
                    Text(localized(en: "AI INTEL", ru: "AI INTEL", es: "IA INTEL"))
                        .font(.system(size: 10, weight: .black, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.62, alignment: .trailing)
                }

                roomThemeInput

                if roomHasCustomTheme {
                    if !roomHasGeneratedTheme {
                        roomWordCountModeSelector
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    roomAnalyzeButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !roomHasCustomTheme {
                    roomPackSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if roomHasCustomTheme && roomHasGeneratedTheme {
                    roomWordsSlider
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    roomExpandThemePoolButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if roomShouldShowPoolPreview {
                    roomPoolPreview
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if roomGeneratedWords.count >= 2 && roomHasCustomTheme {
                    roomSaveAsWordPackButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background {
                if focusedOnlineSetupField == .theme {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismissOnlineSetupCapture()
                        }
                }
            }
            .animation(.smooth(duration: 0.28), value: roomHasCustomTheme)
            .animation(.smooth(duration: 0.28), value: roomHasGeneratedTheme)
            .animation(.smooth(duration: 0.28), value: roomGeneratedPack)
        }
    }

    private func onlineGuestIntelPanel(_ room: GameRoom) -> some View {
        onlineSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                onlineSectionHeader(
                    systemImage: "paintpalette.fill",
                    title: localized(en: "THEME", ru: "ТЕМА", es: "TEMA")
                )
                HStack(spacing: 12) {
                    SpySpinner(size: 18, accent: SpyTheme.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.waitingForHost)
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(SpyTheme.muted)
                        Text(copy.waitingForHostSignal)
                            .font(.system(size: 10, weight: .semibold, design: .default))
                            .foregroundStyle(SpyTheme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func onlineControls(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            if isHost(room), room.playersList.count >= 3 {
                Button {
                    Task { await beginReadyCheck(room) }
                } label: {
                    SpyActionLabel(title: copy.readyCheckAction, systemImage: "checkmark.seal", tracking: 0.02, lines: 2)
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isStarting || isGeneratingRoomTheme || !roomThemeSelectionIsReady)
                .opacity(roomThemeSelectionIsReady && !isGeneratingRoomTheme ? 1 : 0.34)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("onlineRoom.readyCheck")
            } else {
                if !isHost(room) {
                    onlineSetupPanel(accent: SpyTheme.muted, verticalPadding: 16) {
                        HStack(spacing: 12) {
                            SpySpinner(size: 18, accent: SpyTheme.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(copy.waitingForHost)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .foregroundStyle(SpyTheme.muted)
                                Text(copy.minimumOperatives(room.playersList.count))
                                    .font(.system(size: 9, weight: .semibold, design: .default))
                                    .foregroundStyle(SpyTheme.dim)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Button(role: .destructive) {
                Task { await leaveRoom(room) }
            } label: {
                SpyActionLabel(
                    title: isHost(room) ? closeRoomTitle : copy.leaveRoom,
                    systemImage: "chevron.left",
                    tracking: 0.02
                )
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .accessibilityIdentifier("onlineRoom.leave")

            statusLine
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: room.playersList.count >= 3)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: userFacingStatus(status) ?? "")
    }

    private func onlineTimingPanel(_ room: GameRoom) -> some View {
        onlineSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    onlineSectionHeader(systemImage: "timer", title: copy.duration)
                    Spacer()
                    Text("\(Int(selectedDurationMinutes)) \(copy.minuteSuffix)")
                        .font(.system(size: 22, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.66, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.22),
                            value: Int(selectedDurationMinutes)
                        )
                }

                SpyWebSlider(
                    value: $selectedDurationMinutes,
                    range: 1...15,
                    step: 1,
                    onEditingChanged: { isEditing in
                        guard !isEditing, isHost(room), !isUpdatingDuration else { return }
                        let minutes = Int(selectedDurationMinutes)
                        Task { await updateDuration(room, minutes: minutes) }
                    },
                    onInteractionChanged: { isInteracting in
                        isDraggingOnlineDuration = isInteracting
                    },
                    accessibilityIdentifier: "onlineRoom.durationSlider"
                )
                .opacity(isDurationSyncActive ? 0.34 : 1)
                .disabled(!isHost(room) || isDurationSyncActive)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isDurationSyncActive)
            }
        }
    }

    private func onlineRoomGlassCard<Content: View>(
        horizontalPadding: CGFloat = 20,
        verticalPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 20, y: 8)
    }

    private func onlineRoomCardTitle(
        systemImage: String,
        title: String,
        trailing: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .foregroundStyle(SpyTheme.dim)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(2.2)
        .foregroundStyle(.white.opacity(0.64))
    }

    private func roomSectionLabel(
        title: String,
        detail: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Rectangle()
                .fill(accent)
                .frame(width: 18, height: 2)
            Text(title)
                .foregroundStyle(.white.opacity(0.88))
            Spacer(minLength: 8)
            Text(detail)
                .foregroundStyle(accent)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.58)
        }
        .font(.system(size: 10, weight: .black, design: .monospaced))
        .tracking(0.07)
        .lineLimit(2)
        .padding(.top, 2)
    }

    private func missionSetupPanel(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            onlineRoomGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    onlineRoomCardTitle(
                        systemImage: "paintpalette",
                        title: roomThemeTitle,
                        trailing: roomUnlimitedLabel
                    )

                    roomIntelSourceMenu

                    Button {
                        HapticManager.shared.fire(.tabSelection)
                        withAnimation(.smooth(duration: 0.24)) {
                            showsThemeBuilder.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SpyTheme.red)
                            Text(localized(en: "AI THEME BUILDER", ru: "AI-КОНСТРУКТОР ТЕМЫ", es: "CREADOR IA"))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                                .minimumScaleFactor(0.64)
                            Spacer()
                            Image(systemName: showsThemeBuilder ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SpyTheme.dim)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.toggleThemeBuilder")

                    if showsThemeBuilder {
                        roomThemeBuilderCompact
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            onlineRoomGlassCard {
                roomDurationControl(room)
            }
        }
        .spyWebEntrance(delay: 0.10, duration: 0.45, y: 12)
    }

    private var roomIntelSourceMenu: some View {
        Menu {
            Button {
                selectRoomPack(nil)
                status = localized(en: "WORD PACK CLEARED", ru: "КОЛОДА НЕ ВЫБРАНА", es: "PACK NO SELECCIONADO")
            } label: {
                Label(
                    localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado."),
                    systemImage: "circle.dashed"
                )
            }

            ForEach(lobbyWordPacks) { pack in
                Button {
                    selectRoomPack(pack.id)
                    status = localized(en: "WORD PACK SELECTED", ru: "ПАК СЛОВ ВЫБРАН", es: "PACK SELECCIONADO")
                } label: {
                    Label(pack.name, systemImage: "shippingbox.fill")
                }
            }

            Button {
                withAnimation(.smooth(duration: 0.24)) {
                    showsThemeBuilder = true
                }
            } label: {
                Label(localized(en: "Build AI theme", ru: "Создать AI-тему", es: "Crear tema IA"), systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedPackID == nil ? "circle.dashed" : "shippingbox.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.wordSource)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(SpyTheme.dim)
                    Text(selectedPackSummary)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SpyTheme.dim)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(isLoadingLobbyPacks)
        .accessibilityIdentifier("onlineRoom.intelSource")
    }

    private func roomDurationControl(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            onlineRoomCardTitle(
                systemImage: "timer",
                title: copy.duration,
                trailing: "\(Int(selectedDurationMinutes)) \(copy.minuteSuffix)"
            )

            HStack(spacing: 12) {
                durationStepButton(systemImage: "minus", enabled: selectedDurationMinutes > 1 && !isUpdatingDuration) {
                    Task { await updateDuration(room, minutes: Int(selectedDurationMinutes) - 1) }
                }
                .accessibilityIdentifier("onlineRoom.durationDecrease")

                GeometryReader { proxy in
                    let fraction = (selectedDurationMinutes - 1) / 14
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 2)
                        Capsule()
                            .fill(SpyTheme.red)
                            .frame(width: proxy.size.width * fraction, height: 2)
                            .shadow(color: SpyTheme.red.opacity(0.55), radius: 5)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 36)

                durationStepButton(systemImage: "plus", enabled: selectedDurationMinutes < 15 && !isUpdatingDuration) {
                    Task { await updateDuration(room, minutes: Int(selectedDurationMinutes) + 1) }
                }
                .accessibilityIdentifier("onlineRoom.durationIncrease")
            }

            HStack {
                Text("1 \(copy.minuteSuffix)")
                Spacer()
                Text("15 \(copy.minuteSuffix)")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(SpyTheme.dim.opacity(0.55))
        }
    }

    private func durationStepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? .white.opacity(0.82) : SpyTheme.dim)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(enabled ? 0.05 : 0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(enabled ? Color.white.opacity(0.13) : Color.white.opacity(0.05), lineWidth: 1)
                }
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(!enabled)
    }

    private var roomThemeBuilderCompact: some View {
        VStack(alignment: .leading, spacing: 12) {
            roomThemeInput

            if roomHasCustomTheme && !roomHasGeneratedTheme {
                roomWordCountModeSelector
            }

            roomAnalyzeButton

            if roomHasGeneratedTheme, let generated = roomGeneratedPack {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(SpyTheme.green)
                    Text("\(generated.category.uppercased()) · \(roomGeneratedWords.count) \(copy.wordsSuffix)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                    Spacer()
                }
                .padding(10)
                .background(SpyTheme.green.opacity(0.06))
                .overlay(Rectangle().stroke(SpyTheme.green.opacity(0.24), lineWidth: 1))

                roomWordsSlider
                roomExpandThemePoolButton
                roomSaveAsWordPackButton
            }
        }
    }

    private func guestMissionSummary(_ room: GameRoom) -> some View {
        onlineRoomGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                onlineRoomCardTitle(
                    systemImage: "doc.text",
                    title: localized(en: "MISSION BRIEF", ru: "ПАРАМЕТРЫ МИССИИ", es: "RESUMEN"),
                    trailing: copy.waitingForHost
                )
                HStack(spacing: 12) {
                    missionBriefValue(title: gameModeTitle, value: copy.modeTitle(room.gameModeValue), systemImage: "switch.2")
                    missionBriefValue(
                        title: copy.duration,
                        value: "\(max((room.gameDurationSeconds ?? 900) / 60, 1)) \(copy.minuteSuffix)",
                        systemImage: "timer"
                    )
                }
            }
        }
        .spyWebEntrance(delay: 0.10, duration: 0.45, y: 12)
    }

    private func missionBriefValue(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(SpyTheme.red)
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
            Text(value.uppercased())
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roomExitControl(_ room: GameRoom) -> some View {
        Button(role: .destructive) {
            Task { await leaveRoom(room) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left")
                Text(isHost(room) ? closeRoomTitle : copy.leaveRoom)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier("onlineRoom.leave")
    }

    private func waitingActionBar(_ room: GameRoom) -> some View {
        let hasMinimumPlayers = room.playersList.count >= 3
        let canStart = hasMinimumPlayers
            && roomThemeSelectionIsReady
            && !isGeneratingRoomTheme
            && !isDurationSyncActive

        return VStack(spacing: 0) {
            if isHost(room) {
                HStack(spacing: 8) {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        inviteActionBarLabel(
                            title: localized(en: "INVITE PLAYERS", ru: "ПРИГЛАСИТЬ ИГРОКОВ", es: "INVITAR JUGADORES")
                        )
                    }
                    .buttonStyle(WaitingFooterPressStyle())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(localized(en: "Invite players", ru: "Пригласить игроков", es: "Invitar jugadores"))
                    .accessibilityHint(localized(
                        en: "Opens code, QR, share, and nearby radar options",
                        ru: "Открывает код, QR, отправку и поиск по радару",
                        es: "Abre codigo, QR, compartir y radar cercano"
                    ))
                    .accessibilityIdentifier("onlineRoom.inviteMore")

                    Button {
                        Task { await start(room) }
                    } label: {
                        startActionBarLabel(
                            title: isStarting
                                ? localized(en: "ARMING", ru: "ЗАПУСК", es: "INICIANDO")
                                : copy.startNow,
                            detail: roomStartActionDetail(room),
                            isEnabled: canStart
                        )
                    }
                    .buttonStyle(WaitingFooterPressStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(!canStart || isStarting)
                    .accessibilityHint(roomStartActionDetail(room))
                    .accessibilityIdentifier("onlineRoom.startNow")
                }
            } else {
                HStack(spacing: 10) {
                    SpySpinner(size: 18, accent: SpyTheme.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(copy.waitingForHost)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(copy.minimumOperatives(room.playersList.count))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(SpyTheme.dim)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(SpyTheme.card, in: CutCornerShape(cut: 9))
                .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background {
            Color.black
                .opacity(0.97)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [SpyTheme.red.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 16, y: -5)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: canStart)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: isStarting)
    }

    private func inviteActionBarLabel(title: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 19)
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(2)
                .minimumScaleFactor(0.58)
            Spacer(minLength: 0)
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white.opacity(0.58))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(
            LinearGradient(
                colors: [SpyTheme.red.opacity(0.14), Color.white.opacity(0.035)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: CutCornerShape(cut: 9)
        )
        .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.red.opacity(0.62), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            CornerStroke(color: SpyTheme.red.opacity(0.84))
                .frame(width: 14, height: 14)
        }
        .shadow(color: SpyTheme.red.opacity(0.10), radius: 12, y: 4)
        .contentShape(CutCornerShape(cut: 9))
    }

    private func startActionBarLabel(title: String, detail: String, isEnabled: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .black))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .lineLimit(2)
                    .minimumScaleFactor(0.58)
                Text(detail)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(isEnabled ? Color.white.opacity(0.72) : SpyTheme.dim)
                    .lineLimit(2)
                    .minimumScaleFactor(0.54)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(isEnabled ? Color.white : SpyTheme.red.opacity(0.48))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(isEnabled ? SpyTheme.red : SpyTheme.red.opacity(0.035), in: CutCornerShape(cut: 9))
        .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.red.opacity(isEnabled ? 1 : 0.24), lineWidth: 1))
        .shadow(color: isEnabled ? SpyTheme.red.opacity(0.18) : .clear, radius: 12, y: 4)
        .contentShape(CutCornerShape(cut: 9))
    }

    private func webRoomCodePanel(_ room: GameRoom) -> some View {
        let inviteText = roomInviteText(room)

        return onlineRoomGlassCard(verticalPadding: 26) {
            VStack(spacing: 14) {
                Text(roomCodePlainLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(2.8)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))

                Button {
                    if isRoomCodeVisible {
                        HapticManager.shared.fire(.buttonPress)
                    } else {
                        HapticManager.shared.fire(.reveal)
                    }
                    withAnimation(.easeInOut(duration: 0.20)) {
                        isRoomCodeVisible.toggle()
                    }
                } label: {
                    ZStack {
                        if isRoomCodeVisible {
                            Text(room.code.uppercased())
                                .font(SpyTheme.brandFont(size: 52))
                                .tracking(9)
                                .foregroundStyle(SpyTheme.red)
                                .minimumScaleFactor(0.54)
                                .transition(.opacity)
                        } else {
                            Text("••••")
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .tracking(8)
                                .foregroundStyle(.white.opacity(0.76))
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .lineLimit(1)
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityLabel(localized(en: "Room code \(room.code)", ru: "Код комнаты \(room.code)", es: "Codigo de sala \(room.code)"))

                Text(isRoomCodeVisible ? tapToHideRoomCode : tapToRevealRoomCode)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.7)
                    .foregroundStyle(SpyTheme.dim.opacity(0.48))

                HStack(spacing: 8) {
                    Button {
                        copyRoomCode(room)
                    } label: {
                        roomHeaderActionLabel(
                            title: copiedRoomCode ? roomCopiedTitle : roomCopyTitle,
                            systemImage: copiedRoomCode ? "checkmark" : "doc.on.doc",
                            accent: copiedRoomCode ? SpyTheme.green : .white.opacity(0.70)
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.copyCode")

                    ShareLink(item: inviteText) {
                        roomHeaderActionLabel(
                            title: localized(en: "SHARE", ru: "ОТПРАВИТЬ", es: "COMPARTIR"),
                            systemImage: "square.and.arrow.up",
                            accent: .white.opacity(0.70)
                        )
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        HapticManager.shared.fire(.buttonPress)
                    })
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.shareInvite")
                }
            }
        }
        .spyWebEntrance(delay: 0, duration: 0.45, y: 12)
    }

    private func roomAccessMenu(_ room: GameRoom) -> some View {
        Menu {
            Button {
                appState.presentedSheet = .roomQR(room)
            } label: {
                Label(localized(en: "Open QR", ru: "Открыть QR", es: "Abrir QR"), systemImage: "qrcode")
            }

            Button(role: .destructive) {
                Task { await leaveRoom(room) }
            } label: {
                Label(isHost(room) ? closeRoomTitle : copy.leaveRoom, systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(SpyTheme.muted)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("onlineRoom.accessMenu")
    }

    private func roomInviteText(_ room: GameRoom) -> String {
        localized(
            en: "Join my SpyClash room \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)",
            ru: "Присоединяйся к комнате SpyClash \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)",
            es: "Unete a mi sala SpyClash \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)"
        )
    }

    private func roomHeaderActionLabel(title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.58)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func roomStageUtilityButton(
        title: String,
        systemImage: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.06)
                .foregroundStyle(accent)
                .spyFitted(lines: 2, scale: 0.60, alignment: .center)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.white.opacity(0.025))
                .overlay(Rectangle().stroke(accent.opacity(0.30), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var hiddenRoomCodeDots: some View {
        HStack(spacing: 9) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index.isMultiple(of: 2) ? 0.82 : 0.52))
                    .frame(width: index.isMultiple(of: 3) ? 7 : 5, height: index.isMultiple(of: 3) ? 7 : 5)
                    .shadow(color: .white.opacity(0.35), radius: 5)
                    .offset(y: index.isMultiple(of: 2) ? -3 : 4)
            }
        }
    }

    private func webRoomQRPanel(_ room: GameRoom) -> some View {
        let payload = appState.client.roomJoinURL(code: room.code).absoluteString

        return onlineRoomGlassCard(verticalPadding: 24) {
            VStack(spacing: 16) {
                Text("// \(localized(en: "QR INVITATION", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR"))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2.8)
                    .foregroundStyle(SpyTheme.dim.opacity(0.70))

                Button {
                    appState.presentedSheet = .roomQR(room)
                } label: {
                    QRCodeImageView(payload: payload, cornerRadius: 2)
                        .frame(width: 204, height: 204)
                        .spyQRCodeFrame(cut: 8, inset: 7)
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityIdentifier("onlineRoom.openQR")
                .accessibilityLabel(localized(en: "Open large room QR", ru: "Открыть большой QR комнаты", es: "Abrir QR grande de la sala"))
            }
        }
        .spyWebEntrance(delay: 0.02, duration: 0.45, y: 12)
    }

    private func qrVisibleFace(payload: String) -> some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0, animatesEntrance: false) {
            VStack(spacing: 12) {
                QRCodeImageView(payload: payload, cornerRadius: 2)
                    .frame(width: 190, height: 190)
                    .spyQRCodeFrame(cut: 12, inset: 10)

                Text(webQRHint)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var qrHiddenFace: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0, animatesEntrance: false) {
            VStack(spacing: 10) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white.opacity(0.70))

                Text(qrHiddenTitle)
                    .font(.system(size: 13, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)

                Text(tapToFlipQR)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                        }
            .frame(maxWidth: .infinity)
            .frame(height: 232)
            }
    }

    private func webWaitingRoomModePanel(_ room: GameRoom) -> some View {
        onlineRoomGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                onlineRoomCardTitle(systemImage: "gearshape", title: isHost(room) ? gameModeTitle : modeTitle)

                if isHost(room) {
                    HStack(spacing: 10) {
                        webModeButton(mode: .questions, selected: selectedGameMode == .questions) {
                            Task { await updateMode(room, mode: .questions) }
                        }
                        webModeButton(mode: .associations, selected: selectedGameMode == .associations) {
                            Task { await updateMode(room, mode: .associations) }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: room.gameModeValue == .questions ? "questionmark.bubble" : "bubble.left.and.bubble.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SpyTheme.red)
                        Text(copy.modeTitle(room.gameModeValue))
                            .font(SpyTheme.brandFont(size: 18))
                            .tracking(2)
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(scale: 0.58)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
            }
        }
        .spyWebEntrance(delay: 0.04, duration: 0.45, y: 12)
    }

    private func webModeButton(mode: SpyGameMode, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode == .questions ? "questionmark.bubble" : "bubble.left.and.bubble.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? .white.opacity(0.78) : SpyTheme.dim.opacity(0.72))

                Text(copy.modeTitle(mode))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .foregroundStyle(selected ? .white : SpyTheme.dim)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(selected ? SpyTheme.red : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? SpyTheme.red : Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(selected || isStarting || isUpdatingGameMode)
        .accessibilityIdentifier("onlineRoom.mode.\(mode.rawValue)")
    }

    private func webPanelTitle(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .black))
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .default))
                .tracking(0.08)
                .spyFitted(lines: 2, scale: 0.68)
        }
        .foregroundStyle(SpyTheme.muted)
    }

    private func readyVotingRoom(_ room: GameRoom) -> some View {
        let isReady = currentUserIsReady(room)
        let readyCount = room.readyPlayers?.count ?? 0

        return VStack(alignment: .leading, spacing: 16) {
            roomCompactHeader(room)
            readyCheckPanel(room, isReady: isReady, readyCount: readyCount)
            readyRosterPanel(room)
            readyVotingControls(room)
            roomExitControl(room)
        }
    }

    private func readyBreadcrumb(_ room: GameRoom) -> some View {
        HStack(spacing: 8) {
            Text(localized(en: "HOME", ru: "ДОМ", es: "INICIO"))
                .foregroundStyle(SpyTheme.red)
            Text("//")
            Text(localized(en: "LOBBY", ru: "ЛОББИ", es: "SALA"))
            Text("//")
            Text(room.code.uppercased())
        }
        .font(.system(size: 10, weight: .black, design: .monospaced))
        .tracking(0.08)
        .foregroundStyle(SpyTheme.dim.opacity(0.58))
        .lineLimit(1)
        .minimumScaleFactor(0.74)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func rouletteRoom(_ room: GameRoom) -> some View {
        VStack(spacing: 18) {
            SpyPanel(accent: SpyTheme.red) {
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .stroke(SpyTheme.stroke, lineWidth: 1)
                            .frame(width: 230, height: 230)
                        Circle()
                            .trim(from: 0.08, to: 0.72)
                            .stroke(SpyTheme.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 230, height: 230)
                            .rotationEffect(.degrees(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: now)

                        VStack(spacing: 10) {
                            Text(rouletteTarget(room)?.avatar ?? "🕵️")
                                .font(.system(size: 58))
                            Text(rouletteTarget(room)?.name.uppercased() ?? copy.selecting)
                                .font(.system(size: 22, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                        }
                        .padding(28)
                    }
                    .frame(maxWidth: .infinity)

                    Text(copy.firstQuestionVector)
                        .font(.system(size: 10, weight: .bold, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.red)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                        .frame(maxWidth: 260)

                    Text(isHost(room) ? copy.armingFinalPayload : copy.waitingForHostSignal)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.muted)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.72, alignment: .center)

                    statusLine
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 38)
        .task(id: "\(room.id)-\(room.rouletteTargetEmail ?? "")") {
            await completeRouletteIfNeeded(room)
        }
    }

    private func playingRoom(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if room.allRoleCardsRead {
                webActiveGamePhase(room)
            } else {
                webCardRevealPhase(room)
            }
        }
    }

    private func webActiveGamePhase(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            webPlayingHeader(room)
            webTimerStrip(room)

            if room.questionPhase == "results", !room.isVotingActive {
                votingPanel(room)
            } else {
                webTurnCard(room)
            }

            webActiveRoleCard(room)
            webEarlySpyGuessPanel(room)

            if !isTimeExpired(room) {
                if isCurrentUserSpectator(room), room.isVotingActive {
                    webSpectatorVotingPanel(room)
                } else if !isCurrentUserSpectator(room) {
                    webVoteRequestPanel(room)
                }
            }

            webAgentsStrip(room)

            if isCurrentUserSpectator(room) {
                webSpectatorBanner(room)
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private func webPlayingHeader(_ room: GameRoom) -> some View {
        HStack {
            Text("// \(localized(en: "PLAYING", ru: "ИГРА", es: "JUEGO"))")
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.72)

            Spacer()

            roomActionsMenu(room)
        }
    }

    private func webTimerStrip(_ room: GameRoom) -> some View {
        let remaining = remainingSeconds(room)
        let urgent = remaining <= 60

        return HStack(spacing: 12) {
            Text(webTimeLeftTitle)
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.68)
                .layoutPriority(1)

            Spacer()

            Text(timeString(remaining))
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(urgent ? SpyTheme.red : SpyTheme.green)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(SpyTheme.dark, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func webAgentsStrip(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(webAgentsTitle) (\(room.activePlayers.count))")
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.72)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(room.playersList) { player in
                    let isOut = room.spectatorsList.contains(player.email)
                    let isAsker = player.email == room.currentAskerEmail
                    let isAnswerer = player.email == room.currentAnswererEmail
                    let isCurrent = player.email == appState.user?.email
                    HStack(spacing: 5) {
                        Text(isOut ? "👁" : player.avatar)
                            .font(.system(size: 16))
                        Text(compactPlayerName(player.name))
                            .font(.system(size: 10, weight: .bold, design: .default))
                            .foregroundStyle(isCurrent ? SpyTheme.green : (isOut ? SpyTheme.dim.opacity(0.45) : SpyTheme.muted))
                            .spyFitted(scale: 0.64)
                        if isCurrent {
                            Text(youLabel)
                                .font(.system(size: 8, weight: .black, design: .default))
                                .foregroundStyle(SpyTheme.green)
                                .spyFitted(scale: 0.58)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SpyTheme.control, in: Rectangle())
                    .overlay(Rectangle().stroke(isOut ? SpyTheme.red.opacity(0.28) : (isAsker || isAnswerer ? SpyTheme.red.opacity(0.38) : SpyTheme.stroke), lineWidth: 1))
                    .opacity(isOut ? 0.55 : 1)
                }
            }
        }
        .padding(12)
        .background(SpyTheme.dark, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.dim, edges: [.top, .leading])
        }
    }

    private func webActiveRoleCard(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            ZStack {
                if revealRole {
                    webRevealedRoleCard(
                        room,
                        isSpy: currentUserIsSpy(room),
                        isSpectator: isCurrentUserSpectator(room)
                    )
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else {
                    webHiddenRoleCard
                        .transition(.scale(scale: 1.03).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.80), value: revealRole)

            if revealRole {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        revealRole = false
                    }
                } label: {
                    SpyActionLabel(
                        title: localized(en: "HIDE CARD", ru: "СКРЫТЬ КАРТУ", es: "OCULTAR CARTA"),
                        systemImage: "eye.slash.fill",
                        tracking: 0.02,
                        lines: 2
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func webSpectatorBanner(_ room: GameRoom) -> some View {
        let spy = player(for: room.spyEmail, in: room)

        return VStack(spacing: 7) {
            Text(copy.spectatorMode)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.68, alignment: .center)

            Text(copy.spyResult(spy?.name ?? copy.pending))
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(SpyTheme.red)
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)

            Text(copy.wordResult(room.displayWord))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.06)
                .foregroundStyle(SpyTheme.dim.opacity(0.72))
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(SpyTheme.dark, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private func webTurnCard(_ room: GameRoom) -> some View {
        if room.gameModeValue == .associations {
            webAssociationTurnCard(room)
        } else {
            webQuestionTurnCard(room)
        }
    }

    private func webQuestionTurnCard(_ room: GameRoom) -> some View {
        let asker = player(for: room.currentAskerEmail, in: room)
        let answerer = player(for: room.currentAnswererEmail, in: room)

        return VStack(spacing: 14) {
            Text(webActivePairTitle)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.74, alignment: .center)

            HStack(spacing: 12) {
                webPairAgent(player: asker, label: copy.asker, color: SpyTheme.red)

                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .symbolEffect(.pulse, options: .repeating)

                webPairAgent(player: answerer, label: copy.answer, color: .white)
            }

            Button {
                Task { await advance(room) }
            } label: {
                if isAdvancing {
                    SpySpinner(size: 20, accent: .white)
                } else {
                    SpyActionLabel(title: webNextPairTitle, systemImage: "forward.end.fill", tracking: 0.06)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: .outline))
            .disabled(isAdvancing || isCurrentUserSpectator(room))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(SpyTheme.card, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.red, edges: [.top, .leading])
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: SpyTheme.red, edges: [.bottom, .trailing])
        }
    }

    private func webAssociationTurnCard(_ room: GameRoom) -> some View {
        let speaker = player(for: room.currentAskerEmail, in: room)

        return VStack(spacing: 12) {
            Text(copy.associationDrum)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.74, alignment: .center)

            Text(speaker?.avatar ?? "🕵️")
                .font(.system(size: 56))

            Text(speaker?.name.uppercased() ?? copy.spinToStart)
                .font(.system(size: 22, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.red)
                .spyFitted(scale: 0.58, alignment: .center)

            Text(copy.roundAssociation(room.roundNumber ?? 1))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(SpyTheme.card, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.red, edges: [.top, .leading])
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: SpyTheme.red, edges: [.bottom, .trailing])
        }
    }

    private func webPairAgent(player: Player?, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(player?.avatar ?? "🕵️")
                .font(.system(size: 40))

            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.72, alignment: .center)

            Text(player?.name.uppercased() ?? copy.pending)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(color)
                .spyFitted(scale: 0.54, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func webEarlySpyGuessPanel(_ room: GameRoom) -> some View {
        if currentUserIsSpy(room), revealRole, !isCurrentUserSpectator(room), !room.enabledWordPool.isEmpty {
            SpyPanel(accent: SpyTheme.red) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(webEarlyGuessTitle)
                        .font(SpyTheme.micro)
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.68)

                    Text(webEarlyGuessDescription)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(4)
                        .spyFitted(lines: 3, scale: 0.64)

                    Button {
                        showSpyGuess = true
                    } label: {
                        SpyActionLabel(title: webEarlyGuessButtonTitle, systemImage: "scope", tracking: 0.02, lines: 2)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(isSubmittingSpyGuess)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func webVoteRequestPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: room.isVotingActive ? SpyTheme.red : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                Text(webVoteTitle)
                    .font(SpyTheme.micro)
                    .tracking(0.02)
                    .foregroundStyle(room.isVotingActive ? SpyTheme.red : SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.68)

                if !room.isVotingActive {
                    Text(webVoteDescription(room))
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(4)
                        .spyFitted(lines: 3, scale: 0.62)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                        ForEach(room.activePlayers) { player in
                            voteRequestChip(player: player, requested: room.voteRequestsList.contains(player.email), current: player.email == appState.user?.email)
                        }
                    }

                    if hasCurrentUserRequestedVote(room) {
                        Text(webVoteRequestedTitle)
                            .font(.system(size: 11, weight: .black, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(SpyTheme.green)
                            .frame(maxWidth: .infinity)
                            .spyFitted(lines: 2, scale: 0.68, alignment: .center)
                    } else {
                        Button {
                            Task { await requestVote(room) }
                        } label: {
                            if isRequestingVote {
                                SpySpinner(size: 20, accent: .white)
                            } else {
                                SpyActionLabel(title: webVoteRequestButtonTitle, systemImage: "megaphone.fill", tracking: 0.02, lines: 2)
                            }
                        }
                        .buttonStyle(SpyButtonStyle(variant: .outline))
                        .disabled(isRequestingVote)
                    }
                } else if let vote = myVote(in: room), let target = player(for: vote.votedForEmail, in: room) {
                    Text(copy.voteLocked(target.name))
                        .font(.system(size: 12, weight: .black, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.green)
                        .frame(maxWidth: .infinity)
                        .spyFitted(lines: 2, scale: 0.64, alignment: .center)
                } else {
                    Text(webVoteStartedTitle)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.text)
                        .lineSpacing(4)
                        .spyFitted(lines: 3, scale: 0.62)

                    VStack(spacing: 8) {
                        ForEach(room.activePlayers.filter { $0.email != appState.user?.email }) { candidate in
                            Button {
                                HapticManager.shared.fire(.buttonPress)
                                Task { await castVote(room, targetEmail: candidate.email) }
                            } label: {
                                voteCandidateRow(candidate)
                            }
                            .buttonStyle(SpyButtonStyle(variant: .ghost))
                            .disabled(isCastingVote)
                        }
                    }
                }

                statusLine
            }
        }
    }

    private func webSpectatorVotingPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: SpyTheme.dim) {
            VStack(alignment: .leading, spacing: 12) {
                Text(webVotingInProgressTitle)
                    .font(SpyTheme.micro)
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.68)

                VStack(spacing: 8) {
                    ForEach(room.activePlayers) { player in
                        let votes = room.detectiveVotesList.filter { $0.votedForEmail == player.email }.count
                        HStack(spacing: 10) {
                            Text(player.avatar)
                                .font(.system(size: 19))
                                .frame(width: 30, height: 30)
                                .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 6))

                            Text(player.name.uppercased())
                                .font(.system(size: 12, weight: .black, design: .default))
                                .foregroundStyle(SpyTheme.muted)
                                .spyFitted(scale: 0.58)

                            Spacer()

                            if votes > 0 {
                                Text("▲ \(votes)")
                                    .font(.system(size: 11, weight: .black, design: .default))
                                    .foregroundStyle(SpyTheme.red)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(SpyTheme.control, in: CutCornerShape(cut: 9))
                        .overlay(
                            CutCornerShape(cut: 9)
                                .stroke(SpyTheme.stroke, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func voteRequestChip(player: Player, requested: Bool, current: Bool) -> some View {
        HStack(spacing: 5) {
            Text(requested ? "✓" : "·")
                .font(.system(size: 11, weight: .black, design: .default))
                .foregroundStyle(requested ? SpyTheme.green : SpyTheme.dim)

            Text(compactPlayerName(current ? youLabel : player.name))
                .font(.system(size: 10, weight: .black, design: .default))
                .foregroundStyle(requested ? SpyTheme.green : SpyTheme.dim)
                .spyFitted(scale: 0.58)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(requested ? SpyTheme.green.opacity(0.08) : SpyTheme.black.opacity(0.48), in: CutCornerShape(cut: 7))
        .overlay(
            CutCornerShape(cut: 7)
                .stroke(requested ? SpyTheme.green.opacity(0.28) : SpyTheme.stroke, lineWidth: 1)
        )
    }

    private func voteCandidateRow(_ candidate: Player) -> some View {
        HStack(spacing: 10) {
            Text(candidate.avatar)
                .font(.system(size: 21))
                .frame(width: 32, height: 32)

            Text(candidate.name.uppercased())
                .font(.system(size: 12, weight: .black, design: .default))
                .foregroundStyle(SpyTheme.text)
                .spyFitted(scale: 0.58)

            Spacer()

            Text(webVoteSpyQuestion)
                .font(.system(size: 10, weight: .bold, design: .default))
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.62, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private func legacyPlayingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            if currentUserIsSpy(room), !room.enabledWordPool.isEmpty {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    showSpyGuess = true
                } label: {
                    SpyActionLabel(title: copy.guessWord, systemImage: "scope", tracking: 0.06)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isSubmittingSpyGuess || isCurrentUserSpectator(room))
            }

            Button {
                Task { await requestVote(room) }
            } label: {
                if isRequestingVote {
                    SpySpinner(size: 20, accent: .white)
                } else {
                    SpyActionLabel(title: voteButtonTitle(room), systemImage: "checkmark.seal.fill", tracking: 0.02, lines: 2)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: room.isVotingActive ? .ghost : .outline))
            .disabled(isRequestingVote || hasCurrentUserRequestedVote(room) || isCurrentUserSpectator(room))

            statusLine
        }
    }

    private func webCardRevealPhase(_ room: GameRoom) -> some View {
        let email = appState.user?.email
        let isSpectator = email.map { room.spectatorsList.contains($0) } ?? false
        let isSpy = email == room.spyEmail
        let currentRead = currentUserHasReadCard(room)

        return VStack(spacing: 24) {
            Text(webCardPhaseTitle)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .frame(maxWidth: .infinity)
                .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                .padding(.top, 38)

            ZStack {
                if revealRole {
                    webRevealedRoleCard(room, isSpy: isSpy, isSpectator: isSpectator)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else {
                    webHiddenRoleCard
                        .transition(.scale(scale: 1.03).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.80), value: revealRole)

            if revealRole {
                if !currentRead {
                    Button {
                        Task { await markCardRead(room) }
                    } label: {
                        if isMarkingCardRead {
                            SpySpinner(size: 20, accent: .white)
                        } else {
                            Text(webReadyToPlayTitle)
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .tracking(0.08)
                                .spyFitted(lines: 2, scale: 0.52, alignment: .center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(isMarkingCardRead)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Text(webWaitingOthersTitle)
                        .font(.system(size: 11, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.green)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                        .transition(.opacity)
                }
            }

            webCardsReadPanel(room)

            statusLine
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var webHiddenRoleCard: some View {
        Button {
            HapticManager.shared.fire(.reveal)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                revealRole = true
            }
        } label: {
            VStack(spacing: 16) {
                Text("🃏")
                    .font(.system(size: 60))
                    .symbolEffect(.pulse, options: .repeating)

                Text(webTapToRevealRoleTitle)
                    .font(.system(size: 18, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .spyFitted(lines: 3, scale: 0.62, alignment: .center)

                Text(webDontShowOthersTitle)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))
                    .spyFitted(lines: 2, scale: 0.70, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal, 28)
            .background(SpyTheme.card, in: Rectangle())
            .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                cornerMark(color: SpyTheme.dim, edges: [.top, .leading])
            }
            .overlay(alignment: .bottomTrailing) {
                cornerMark(color: SpyTheme.dim, edges: [.bottom, .trailing])
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func webRevealedRoleCard(_ room: GameRoom, isSpy: Bool, isSpectator: Bool) -> some View {
        let accent = isSpectator ? SpyTheme.dim : (isSpy ? SpyTheme.red : SpyTheme.green)

        return VStack(spacing: 14) {
            Text(isSpy ? "🕵️" : "🔍")
                .font(.system(size: 52))

            Text(roleTitle(isSpy: isSpy, isSpectator: isSpectator))
                .font(.system(size: 24, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(accent)
                .spyFitted(lines: 2, scale: 0.58, alignment: .center)

            if isSpy || isSpectator {
                Text(roleSubtitle(isSpy: isSpy, isSpectator: isSpectator, room: room))
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            } else {
                VStack(spacing: 8) {
                    Text(webSecretWordLabel)
                        .font(.system(size: 10, weight: .bold, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.dim.opacity(0.62))
                        .spyFitted(scale: 0.70, alignment: .center)

                    Text(room.displayWord?.uppercased() ?? copy.classified)
                        .font(.system(size: 40, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.44, alignment: .center)

                    Text("\(copy.categoryLabel.uppercased()): \(room.category?.uppercased() ?? copy.classicCategory)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.28)
                        .foregroundStyle(SpyTheme.dim.opacity(0.58))
                        .spyFitted(lines: 2, scale: 0.62, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background((isSpy ? SpyTheme.red : Color.white).opacity(isSpy ? 0.05 : 0.025), in: Rectangle())
        .overlay(Rectangle().stroke(accent.opacity(isSpy ? 0.35 : 0.22), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: accent, edges: [.top, .leading])
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: accent, edges: [.bottom, .trailing])
        }
    }

    private func webCardsReadPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(webCardsReadTitle) \(room.cardsReadList.count)/\(room.playersList.count)")
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.70)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(room.playersList) { player in
                        let isRead = room.cardsReadList.contains(player.email)
                        HStack(spacing: 6) {
                            Text(player.avatar)
                            Text(player.name.uppercased())
                                .spyFitted(scale: 0.58)
                            if isRead {
                                Text("✓")
                            }
                        }
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(0.04)
                        .foregroundStyle(isRead ? SpyTheme.green : SpyTheme.dim.opacity(0.62))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(isRead ? SpyTheme.green.opacity(0.06) : SpyTheme.black.opacity(0.42), in: Rectangle())
                        .overlay(Rectangle().stroke(isRead ? SpyTheme.green.opacity(0.25) : SpyTheme.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func cornerMark(color: Color, edges: Edge.Set) -> some View {
        ZStack {
            if edges.contains(.top) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if edges.contains(.bottom) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }

            if edges.contains(.leading) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if edges.contains(.trailing) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func finishedRoom(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SpyPanel(accent: room.winner == "spy" ? SpyTheme.red : SpyTheme.green) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(copy.result)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker()
                    Text(room.winner == "spy" ? copy.spyWins : copy.detectivesWin)
                        .font(.system(size: 34, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(room.winner == "spy" ? SpyTheme.red : SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.54)
                    Text(copy.wordResult(room.displayWord))
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.58)
                    if let spy = player(for: room.spyEmail, in: room) {
                        Text(copy.spyResult(spy.name))
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(lines: 2, scale: 0.58)
                    }
                }
            }
            playersPanel(room)
            replayPanel(room)
            Button {
                leaveLocally(providesFeedback: false)
            } label: {
                Label(copy.leaveRoom, systemImage: "house.fill")
            }
            .buttonStyle(SpyButtonStyle(variant: .outline))
        }
    }

    private func roomKeyPanel(_ room: GameRoom, showsMetrics: Bool = true) -> some View {
        SpyPanel(accent: room.normalizedStatus == "playing" ? SpyTheme.green : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                            Text(roomBreadcrumb)
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(0.10)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(scale: 0.64)
                        Text(roomCodeLabel)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker(lines: 2)
                    }

                    Spacer()

                    roomActionsMenu(room)
                }

                Text(room.code)
                    .font(.system(size: 62, weight: .black, design: .monospaced))
                    .tracking(5.5)
                    .foregroundStyle(SpyTheme.red)
                    .minimumScaleFactor(0.46)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                Text(roomCodeShare)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if showsMetrics {
                    HStack(spacing: 10) {
                        metric(copy.activeMetric, "\(room.activePlayers.count)")
                        metric(copy.mode, copy.modeTitle(room.gameModeValue))
                        metric(copy.votesMetric, "\(room.activeVoteRequests.count)/\(room.voteThreshold)")
                    }
                }
            }
        }
    }

    private func roomActionsMenu(_ room: GameRoom) -> some View {
        Menu {
            Button {
                copyRoomCode(room)
            } label: {
                Label(copiedRoomCode ? roomCopiedTitle : roomCopyTitle, systemImage: copiedRoomCode ? "checkmark" : "doc.on.doc.fill")
            }

            Button {
                appState.presentedSheet = .roomQR(room)
            } label: {
                Label(localized(en: "QR INVITE", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR"), systemImage: "qrcode")
            }

            if room.normalizedStatus == "ready_voting", isHost(room) {
                Button {
                    Task { await returnToWaiting(room) }
                } label: {
                    Label(copy.returnToLobby, systemImage: "arrow.uturn.left")
                }
                .disabled(isStarting)
            }

            Button(role: .destructive) {
                Task { await leaveRoom(room) }
            } label: {
                Label(isHost(room) ? closeRoomTitle : copy.leaveRoom, systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            HStack(spacing: 8) {
                roomStatePill(room)

                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(SpyTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.dark)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(isStarting)
    }

    private func roomStatePill(_ room: GameRoom) -> some View {
        let isLive = room.normalizedStatus == "playing"
        let color = isLive ? SpyTheme.green : SpyTheme.red

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                Text(roomStateLabel(room))
                    .font(.system(size: 10, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(color)
                    .spyFitted(scale: 0.70)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(color.opacity(0.07))
        .overlay(Rectangle().stroke(color.opacity(0.22), lineWidth: 1))
    }

    private func roomCompactHeader(_ room: GameRoom) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(roomBreadcrumb)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.64)
                Text(room.code)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(SpyTheme.red)
            }

            Spacer()

            roomActionsMenu(room)
        }
        .padding(.vertical, 4)
    }

    private func readyCheckPanel(_ room: GameRoom, isReady: Bool, readyCount: Int) -> some View {
        SpyPanel(accent: SpyTheme.red) {
            VStack(spacing: 16) {
                Text(readyCheckingTitle)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.70, alignment: .center)

                Text(copy.areYouReady)
                    .font(.system(size: 20, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)

                Button {
                    Task { await toggleReady(room) }
                } label: {
                    if isTogglingReady {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        Text(isReady
                            ? localized(en: "REMOVE READY", ru: "СНЯТЬ ГОТОВНОСТЬ", es: "QUITAR LISTO")
                            : localized(en: "I'M READY", ru: "Я ГОТОВ", es: "ESTOY LISTO"))
                            .font(.system(size: 13, weight: .black, design: .default))
                            .tracking(0.04)
                            .spyFitted(scale: 0.68, alignment: .center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: isReady ? .red : .outline))
                .disabled(isTogglingReady)
                .accessibilityIdentifier("onlineRoom.toggleReady")

                Text("\(readyCount) / \(room.playersList.count) \(readyCountTitle)")
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))
                    .spyFitted(scale: 0.70, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func readyRosterPanel(_ room: GameRoom) -> some View {
        let ready = Set(room.readyPlayers ?? [])

        return SpyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                Text(readyAgentsStatusTitle)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.70)

                ForEach(room.playersList) { player in
                    readyPlayerRow(player, isReady: ready.contains(player.email))
                }
            }
        }
    }

    private func readyPlayerRow(_ player: Player, isReady: Bool) -> some View {
        HStack(spacing: 12) {
            Text(player.avatar)
                .font(.system(size: 24))
                .frame(width: 34, height: 34)

            Text(player.name.uppercased())
                .font(.system(size: 12, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(.white.opacity(0.82))
                .spyFitted(scale: 0.56)

            Spacer()

            Text(isReady ? readyYesTitle : readyWaitingTitle)
                .font(.system(size: 10, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(isReady ? SpyTheme.green : SpyTheme.dim.opacity(0.50))
                .spyFitted(scale: 0.64, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(SpyTheme.dark, in: CutCornerShape(cut: 7))
        .overlay {
            CutCornerShape(cut: 7)
                .stroke(isReady ? SpyTheme.red.opacity(0.55) : SpyTheme.strokeStrong, lineWidth: 1)
        }
    }

    private func readyVotingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            if isHost(room) && allPlayersReady(room) {
                Button {
                    Task { await start(room) }
                } label: {
                    if isStarting {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        SpyActionLabel(title: copy.startGame, systemImage: "play.fill", tracking: 0.02)
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isStarting)
            }

            if isHost(room) {
                Button {
                    Task { await returnToWaiting(room) }
                } label: {
                    SpyActionLabel(title: copy.returnToLobby, systemImage: "arrow.uturn.left", tracking: 0.02)
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isStarting)
                .accessibilityIdentifier("onlineRoom.returnToLobby")
            }

            statusLine
        }
    }

    private func lobbyConfigurationPanel(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if isHost(room) {
                webThemeSourcePanel
                webDurationPanel
            } else {
                SpyPanel(accent: SpyTheme.muted, motionDelay: 0.10) {
                    HStack(spacing: 12) {
                        SpySpinner(size: 22, accent: SpyTheme.red)

                        VStack(alignment: .leading, spacing: 5) {
                            webPanelTitle(systemImage: "hourglass", title: copy.waitingForHost)
                            Text(copy.waitingForHostSignal)
                                .font(.system(size: 12, weight: .semibold, design: .default))
                                .tracking(0.02)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 2, scale: 0.68)
                        }

                        Spacer()
                    }
                }
            }
        }
    }

    private var webThemeSourcePanel: some View {
        SpyPanel(accent: SpyTheme.muted, motionDelay: 0.10) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    webPanelTitle(systemImage: "paintpalette.fill", title: roomThemeTitle)
                    Spacer()
                    Text(roomUnlimitedLabel)
                        .font(.system(size: 10, weight: .black, design: .default))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.62, alignment: .trailing)
                }

                roomThemeInput

                if roomHasCustomTheme && !roomHasGeneratedTheme {
                    roomWordCountModeSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                roomAnalyzeButton

                if !roomHasCustomTheme {
                    roomPackSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if roomHasCustomTheme && roomHasGeneratedTheme {
                    roomWordsSlider
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    roomExpandThemePoolButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                roomPoolPreview

                if roomGeneratedWords.count >= 2 && roomHasCustomTheme {
                    roomSaveAsWordPackButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.smooth(duration: 0.26), value: roomHasCustomTheme)
            .animation(.smooth(duration: 0.26), value: roomHasGeneratedTheme)
            .animation(.smooth(duration: 0.26), value: roomGeneratedPack)
        }
    }

    private var roomThemeInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(focusedOnlineSetupField == .theme ? SpyTheme.red : SpyTheme.dim)
                    .frame(width: 18)

                TextField("", text: $roomTheme, prompt: Text(roomThemePlaceholder).foregroundStyle(SpyTheme.dim))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .font(SpyTheme.mono)
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .tint(SpyTheme.red)
                    .focused($focusedOnlineSetupField, equals: .theme)
                    .onSubmit {
                        dismissOnlineSetupCapture()
                    }
                    .accessibilityIdentifier("onlineRoom.themeInput")

                if roomHasCustomTheme {
                    Button {
                        withAnimation(.smooth(duration: 0.20)) {
                            roomTheme = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(SpyTheme.dim)
                            .frame(width: 28, height: 36)
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .spyHitTarget()
                    .accessibilityLabel(localized(en: "Clear theme", ru: "Очистить тему", es: "Limpiar tema"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
            .overlay(
                CutCornerShape(cut: 9)
                    .stroke(
                        focusedOnlineSetupField == .theme ? SpyTheme.red.opacity(0.86) : SpyTheme.inputBorder,
                        lineWidth: 1
                    )
            )
            .shadow(color: focusedOnlineSetupField == .theme ? SpyTheme.red.opacity(0.12) : .clear, radius: 8)
            .animation(.smooth(duration: 0.18), value: focusedOnlineSetupField == .theme)

            AIThemeSuggestionStrip(
                language: appState.language,
                selectedTheme: roomTheme,
                accessibilityIdentifier: "onlineRoom.themeSuggestions"
            ) { suggestion in
                roomTheme = suggestion
            }
        }
        .onChange(of: roomTheme) { previousTheme, currentTheme in
            updateRoomThemeDraft(from: previousTheme, to: currentTheme)
        }
    }

    private var roomWordCountModeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(RoomWordCountMode.allCases) { mode in
                    let isActive = roomWordCountMode == mode
                    Button {
                        withAnimation(.smooth(duration: 0.18)) {
                            roomWordCountMode = mode
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(roomWordCountModeTitle(mode))
                                .font(.system(size: 10, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(isActive ? .white : SpyTheme.muted)
                                .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                            Text(roomWordCountModeHint(mode))
                                .font(.system(size: 9, weight: .bold, design: .default))
                                .tracking(0.02)
                                .foregroundStyle(isActive ? .white.opacity(0.72) : SpyTheme.dim)
                                .spyFitted(scale: 0.58, alignment: .center)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                    }
                    .buttonStyle(SpyButtonStyle(variant: isActive ? .red : .ghost))
                }
            }

            if roomWordCountMode == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(roomCountLabel)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker()
                        Spacer()
                        Text("\(Int(roomCustomWordCount)) / 80")
                            .font(.system(size: 15, weight: .black, design: .default))
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(scale: 0.66, alignment: .trailing)
                    }

                    SpyWebSlider(value: $roomCustomWordCount, range: 10...80, step: 1)
                }
                .padding(12)
                .background(SpyTheme.dark)
                .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
            }
        }
    }

    private var roomAnalyzeButton: some View {
        Button {
            dismissOnlineSetupCapture()
            Task {
                await generateRoomTheme(usingInitialTarget: !roomHasGeneratedTheme)
            }
        } label: {
            if roomThemeOperation == .generate {
                SpyLoadingLabel(title: roomThemeActionTitle, accent: .white)
                    .frame(height: 52)
            } else {
                SpyActionLabel(
                    title: roomThemeActionTitle,
                    systemImage: roomThemeActionIcon,
                    tracking: 0.02,
                    lines: 2
                )
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .disabled(!roomHasCustomTheme || isGeneratingRoomTheme)
        .opacity(roomHasCustomTheme ? 1 : 0.42)
    }

    private var roomPackSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lobbyPackLoadState == .idle || isLoadingLobbyPacks {
                HStack(spacing: 10) {
                    SpySpinner(size: 16, accent: SpyTheme.red)
                    Text(localized(en: "LOADING WORD PACKS", ru: "ЗАГРУЗКА КОЛОД", es: "CARGANDO PACKS"))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.dim)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 12)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
            } else if let roomPackLoadError {
                VStack(alignment: .leading, spacing: 9) {
                    Text(localized(en: "COULDN'T LOAD YOUR DECKS", ru: "НЕ УДАЛОСЬ ЗАГРУЗИТЬ КОЛОДЫ", es: "NO SE PUDIERON CARGAR LOS PACKS"))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                    Text(roomPackLoadError)
                        .font(.system(size: 9, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .lineLimit(2)
                    Button {
                        Task { await loadLobbyWordPacks(force: true) }
                    } label: {
                        Label(
                            localized(en: "TRY AGAIN", ru: "ПОВТОРИТЬ", es: "REINTENTAR"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(SpyTheme.red.opacity(0.06), in: CutCornerShape(cut: 7))
                        .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.red.opacity(0.38), lineWidth: 1))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.retryWordPacks")
                }
                .padding(12)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.red.opacity(0.28), lineWidth: 1))
            } else if lobbyWordPacks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SpyTheme.dim)
                    Text(localized(
                        en: "You haven't created any decks.",
                        ru: "Вы не создавали своих колод.",
                        es: "No has creado ningun pack."
                    ))
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
                .accessibilityIdentifier("onlineRoom.noSavedWordPacks")
            } else {
                Text("\(localized(en: "WORD PACKS", ru: "КОЛОДЫ", es: "PACKS")) \(lobbyWordPacks.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                    roomPackOption(
                        id: nil,
                        title: localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado."),
                        subtitle: nil,
                        systemImage: "circle.dashed",
                        accessibilityIdentifier: "onlineRoom.noPackSource"
                    ) {
                        selectRoomPack(nil)
                    }

                    ForEach(lobbyWordPacks) { pack in
                        roomPackOption(
                            id: pack.id,
                            title: pack.name,
                            subtitle: "\(pack.words?.roomCleanWords.count ?? 0)",
                            systemImage: "shippingbox.fill"
                        ) {
                            selectRoomPack(pack.id)
                        }
                    }
                }
            }
        }
        .disabled(isLoadingLobbyPacks)
        .opacity(isLoadingLobbyPacks ? 0.58 : 1)
    }

    private func roomPackOption(
        id: String?,
        title: String,
        subtitle: String?,
        systemImage: String,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = selectedPackID == id

        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(isSelected ? .white : SpyTheme.red)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .tracking(0.02)
                        .foregroundStyle(isSelected ? .white : SpyTheme.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.54)

                    if let subtitle {
                        Text("\(subtitle) \(copy.wordsSuffix)")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.02)
                            .foregroundStyle(isSelected ? .white.opacity(0.70) : SpyTheme.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.60)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? SpyTheme.red : SpyTheme.dark, in: CutCornerShape(cut: 8))
            .overlay(
                CutCornerShape(cut: 8)
                    .stroke(isSelected ? Color.clear : SpyTheme.strokeStrong, lineWidth: 1)
            )
            .shadow(color: isSelected ? SpyTheme.red.opacity(0.18) : .black.opacity(0.12), radius: isSelected ? 12 : 8, y: 6)
            .contentShape(CutCornerShape(cut: 8))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private var roomWordsSlider: some View {
        let maxWords = roomThemeMaxWords
        let selectedWords = min(Int(roomWordCount), activeRoomWords(roomGeneratedPack?.words ?? []).count)
        let lowerBound = Double(min(5, maxWords))
        let upperBound = Double(maxWords)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(roomWordsLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Spacer()
                Text("\(selectedWords) / \(maxWords)")
                    .font(.system(size: 16, weight: .black, design: .default))
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.66, alignment: .trailing)
            }

            Text(roomThemeMetaLabel(maxWords: maxWords))
                .font(.system(size: 9, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.60)

            SpyWebSlider(
                value: $roomWordCount,
                range: lowerBound...upperBound,
                step: 1,
                accent: SpyTheme.red
            )
            .disabled(lowerBound == upperBound)
        }
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private var roomExpandThemePoolButton: some View {
        Button {
            Task { await pushRoomThemeMax() }
        } label: {
            if roomThemeOperation == .expand {
                SpyLoadingLabel(title: roomAddMoreWordsLabel, accent: SpyTheme.amber)
                    .frame(height: 50)
            } else {
                SpyActionLabel(
                    title: roomAddMoreWordsLabel,
                    systemImage: "plus.circle.fill",
                    fontSize: 10,
                    iconSize: 13,
                    tracking: 0.02,
                    lines: 2
                )
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .outline))
        .disabled(isGeneratingRoomTheme || roomThemeMaxWords >= 200)
        .accessibilityIdentifier("onlineRoom.addMoreThemeWords")
    }

    @ViewBuilder
    private var roomPoolPreview: some View {
        if let snapshot = roomPoolSnapshot {
            roomPoolPreviewCard(snapshot)
        }
    }

    private func roomPoolPreviewCard(_ snapshot: RoomPoolSnapshot) -> some View {
        let collapsedWordLimit = 8
        let compactWords = Array(snapshot.words.prefix(collapsedWordLimit))
        let additionalWords = Array(snapshot.words.dropFirst(collapsedWordLimit))
        let canToggleWordList = snapshot.words.count > collapsedWordLimit

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(roomPoolPreviewLabel)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker()
                    Text(snapshot.category.uppercased())
                        .font(.system(size: 18, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.56)
                }

                Spacer()

                Text(snapshot.countLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.10)
                    .foregroundStyle(snapshot.words.isEmpty ? SpyTheme.red : SpyTheme.green)
                    .spyFitted(scale: 0.62, alignment: .trailing)
            }

            if snapshot.words.isEmpty {
                Text(snapshot.emptyMessage)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(SpyTheme.panelDeep)
                    .overlay(Rectangle().stroke(SpyTheme.stroke))
            } else {
                roomPoolWordGrid(compactWords)

                if showsAllRoomPoolWords {
                    roomPoolWordGrid(additionalWords)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            HStack(spacing: 8) {
                Text(snapshot.source.uppercased())
                    .font(.system(size: 9, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.50)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(SpyTheme.dark)
                    .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))

                Spacer()
            }

            if !snapshot.words.isEmpty, canToggleWordList {
                Button {
                    HapticManager.shared.fire(.tabSelection)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        showsAllRoomPoolWords.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(showsAllRoomPoolWords ? roomShowLessWordsLabel : roomShowAllWordsLabel(snapshot.words.count))
                        Spacer(minLength: 8)
                        Image(systemName: showsAllRoomPoolWords ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .black))
                    }
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.muted)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    .background(SpyTheme.panelDeep)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityIdentifier("onlineRoom.toggleAllThemeWords")
            }
        }
        .padding(12)
        .background(SpyTheme.dark)
        .overlay(
            Rectangle()
                .stroke(snapshot.words.isEmpty ? SpyTheme.red.opacity(0.22) : SpyTheme.green.opacity(0.14), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill((snapshot.words.isEmpty ? SpyTheme.red : SpyTheme.green).opacity(0.32))
                .frame(width: snapshot.words.isEmpty ? 28 : 76, height: 1)
        }
    }

    private func roomPoolWordGrid(_ words: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(words, id: \.self) { word in
                let isEnabled = !disabledRoomPoolWordKeys.contains(roomWordKey(word))

                Button {
                    toggleRoomPoolWord(word)
                } label: {
                    Text(word.uppercased())
                        .font(.system(size: 10, weight: .black, design: .default))
                        .tracking(0.02)
                        .strikethrough(!isEnabled, color: SpyTheme.dim)
                        .foregroundStyle(isEnabled ? SpyTheme.bodyText : SpyTheme.dim.opacity(0.38))
                        .spyFitted(scale: 0.50, alignment: .center)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(isEnabled ? SpyTheme.control : SpyTheme.black)
                        .overlay(
                            Rectangle()
                                .stroke(isEnabled ? SpyTheme.stroke : SpyTheme.strokeDim, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityLabel(word)
                .accessibilityValue(
                    isEnabled
                        ? localized(en: "In game", ru: "В игре", es: "En juego")
                        : localized(en: "Crossed out", ru: "Вычеркнуто", es: "Tachada")
                )
            }
        }
    }

    private var roomSaveAsWordPackButton: some View {
        Button {
            Task { await saveRoomThemePack() }
        } label: {
            if isSavingRoomThemePack {
                SpyLoadingLabel(title: roomSaveAsWordPackLabel, accent: SpyTheme.green)
                    .frame(height: 50)
            } else {
                SpyActionLabel(title: roomSaveAsWordPackLabel, systemImage: "tray.and.arrow.down.fill", fontSize: 10, iconSize: 13, tracking: 0.02, lines: 2)
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .disabled(isSavingRoomThemePack || roomGeneratedWords.count < 2)
    }

    private var webDurationPanel: some View {
        SpyPanel(accent: SpyTheme.muted, motionDelay: 0.15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    webPanelTitle(systemImage: "timer", title: copy.duration)
                    Spacer()
                    Text("\(Int(selectedDurationMinutes)) \(copy.minuteSuffix)")
                        .font(.system(size: 22, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.66, alignment: .trailing)
                }

                SpyWebSlider(value: $selectedDurationMinutes, range: 1...15, step: 1)

                HStack {
                    Text("1 \(copy.minuteSuffix)")
                    Spacer()
                    Text("15 \(copy.minuteSuffix)")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.52))
            }
        }
    }

    private func timerPanel(_ room: GameRoom) -> some View {
        let remaining = remainingSeconds(room)
        let expired = remaining == 0

        return SpyPanel(accent: expired ? SpyTheme.red : SpyTheme.green) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(copy.missionTimer)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker(lines: 2)
                    Spacer()
                    Text(expired ? copy.timeUp : copy.liveStatus)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(expired ? SpyTheme.red : SpyTheme.green)
                        .spyFitted(scale: 0.68, alignment: .trailing)
                }
                Text(timeString(remaining))
                    .font(.system(size: 40, weight: .black, design: .monospaced))
                    .tracking(0.12)
                    .foregroundStyle(expired ? SpyTheme.red : .white)
                    .contentTransition(.numericText())
                Text(expired ? copy.callFinalVote : copy.timerHintLive)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.70)
            }
        }
    }

    private func rolePanel(_ room: GameRoom) -> some View {
        let email = appState.user?.email
        let isSpectator = email.map { room.spectatorsList.contains($0) } ?? false
        let isSpy = email == room.spyEmail

        return SpyPanel(accent: isSpectator ? SpyTheme.dim : (isSpy ? SpyTheme.red : SpyTheme.green)) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(copy.roleCard)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                    Button {
                        if revealRole {
                            HapticManager.shared.fire(.buttonPress)
                        } else {
                            HapticManager.shared.fire(.reveal)
                        }
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                            revealRole.toggle()
                        }
                    } label: {
                        Image(systemName: revealRole ? "eye.slash.fill" : "eye.fill")
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                    .frame(width: 58)
                    .contentShape(Rectangle())
                }

                ZStack {
                    if revealRole {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(roleTitle(isSpy: isSpy, isSpectator: isSpectator))
                                .font(.system(size: 30, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(isSpectator ? SpyTheme.dim : (isSpy ? SpyTheme.red : SpyTheme.green))
                                .spyFitted(lines: 2, scale: 0.58)
                            Text(roleSubtitle(isSpy: isSpy, isSpectator: isSpectator, room: room))
                                .font(SpyTheme.micro)
                                .tracking(0.12)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 3, scale: 0.66)
                            if !isSpy && !isSpectator {
                                Text(room.displayWord?.uppercased() ?? copy.classified)
                                    .font(.system(size: 38, weight: .black, design: .default))
                                    .tracking(0.04)
                                    .foregroundStyle(SpyTheme.red)
                                    .spyFitted(lines: 2, scale: 0.48)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(SpyTheme.red)
                                .symbolEffect(.pulse, options: .repeating)
                            Text(copy.tapEyeToReveal)
                                .font(SpyTheme.micro)
                                .tracking(0.12)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 132)
                        .transition(.scale(scale: 1.04).combined(with: .opacity))
                    }
                }
                .frame(minHeight: 148)
            }
        }
    }

    private func roleReadinessPanel(_ room: GameRoom) -> some View {
        let readCount = room.cardsReadList.count
        let total = max(room.playersList.count, 1)
        let progress = Double(readCount) / Double(total)
        let currentRead = currentUserHasReadCard(room)

        return SpyPanel(accent: currentRead ? SpyTheme.green : SpyTheme.amber) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                        Text(copy.cardCheck)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                        Text("\(readCount)/\(room.playersList.count)")
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(currentRead ? SpyTheme.green : SpyTheme.amber)
                }

                Text(currentRead ? copy.cardConfirmed : copy.readYourRole)
                    .font(.system(size: 26, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(currentRead ? SpyTheme.green : .white)
                    .spyFitted(lines: 2, scale: 0.62)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(SpyTheme.panelDeep)
                        Rectangle()
                            .fill(SpyTheme.red)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 6)
                .overlay(Rectangle().stroke(SpyTheme.stroke))

                ForEach(room.playersList) { player in
                    HStack(spacing: 10) {
                        Image(systemName: room.cardsReadList.contains(player.email) ? "checkmark.seal.fill" : "circle.dotted")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(room.cardsReadList.contains(player.email) ? SpyTheme.green : SpyTheme.dim)
                            .frame(width: 24)
                        Text(player.name.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(.white.opacity(0.86))
                            .spyFitted(scale: 0.58)
                        Spacer()
                        Text(room.cardsReadList.contains(player.email) ? copy.readyShort : copy.waitShort)
                            .font(.system(size: 10, weight: .black, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(room.cardsReadList.contains(player.email) ? SpyTheme.green : SpyTheme.dim)
                            .spyFitted(scale: 0.68, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }

                Text(copy.cardTimerHint)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineSpacing(3)

                Button {
                    Task { await markCardRead(room) }
                } label: {
                    if isMarkingCardRead {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        SpyActionLabel(
                            title: currentRead ? copy.waitingForTeam : copy.confirmCardRead,
                            systemImage: currentRead ? "hourglass" : "checkmark.seal.fill",
                            tracking: 0.02,
                            lines: 2
                        )
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: currentRead ? .ghost : .red))
                .disabled(currentRead || !revealRole || isMarkingCardRead)
            }
        }
    }

    @ViewBuilder
    private func turnPanel(_ room: GameRoom) -> some View {
        if room.gameModeValue == .associations {
            SpyPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(copy.associationDrum)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)

                    HStack(spacing: 12) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SpyTheme.red)
                            .symbolEffect(.pulse, options: .repeating)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(player(for: room.currentAskerEmail, in: room)?.name.uppercased() ?? copy.spinToStart)
                                .font(.system(size: 24, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(.white)
                                .spyFitted(scale: 0.58)
                            Text(copy.roundAssociation(room.roundNumber ?? 1))
                                .font(SpyTheme.micro)
                                .tracking(0.12)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(scale: 0.68)
                        }
                        Spacer()
                    }
                }
            }
        } else {
            SpyPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(copy.questionVector)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    HStack(spacing: 12) {
                        turnAgent(title: copy.asker, player: player(for: room.currentAskerEmail, in: room), color: SpyTheme.red)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(SpyTheme.dim)
                        turnAgent(title: copy.answer, player: player(for: room.currentAnswererEmail, in: room), color: SpyTheme.green)
                    }
                }
            }
        }
    }

    private func votingPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: SpyTheme.red) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                        Text(copy.voteProtocol)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                    Text("\(room.activeVoteRequests.count)/\(room.voteThreshold)")
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.red)
                }

                Text(room.isVotingActive ? copy.whoIsSpy : copy.questionCycleComplete)
                    .font(.system(size: 27, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.58)

                if !room.isVotingActive {
                    Text(copy.requestVoteHint)
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                } else if isCurrentUserSpectator(room) {
                    Text(copy.spectatorVoteHint)
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                } else if let vote = myVote(in: room), let target = player(for: vote.votedForEmail, in: room) {
                        Text(copy.voteLocked(target.name))
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.68)
                } else {
                    ForEach(room.activePlayers) { candidate in
                        Button {
                            HapticManager.shared.fire(.buttonPress)
                            Task { await castVote(room, targetEmail: candidate.email) }
                        } label: {
                            HStack {
                                Text(candidate.avatar)
                                    .font(.system(size: 22))
                                Text(candidate.name.uppercased())
                                    .font(.system(size: 11, weight: .bold, design: .default))
                                    .tracking(0.04)
                                    .spyFitted(scale: 0.68)
                                Spacer()
                                Image(systemName: "scope")
                            }
                        }
                        .buttonStyle(SpyButtonStyle(variant: .ghost))
                        .disabled(isCastingVote)
                    }
                }
            }
        }
    }

    private func replayPanel(_ room: GameRoom) -> some View {
        let votes = Set(room.readyPlayers ?? [])
        let hasVoted = appState.user.map { votes.contains($0.email) } ?? false
        let total = max(room.playersList.count, 1)
        let allVoted = room.playersList.count > 0 && room.playersList.allSatisfy { votes.contains($0.email) }

        return SpyPanel(accent: allVoted ? SpyTheme.green : SpyTheme.amber) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                        Text(copy.playAgainEyebrow)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                    Text("\(votes.count)/\(total)")
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(allVoted ? SpyTheme.green : SpyTheme.amber)
                }

                Text(allVoted ? copy.teamReadyAnotherRun : copy.voteForNewGame)
                    .font(.system(size: 23, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.58)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(room.playersList) { player in
                        let accepted = votes.contains(player.email)
                        HStack(spacing: 5) {
                            Text(accepted ? "✓" : "·")
                            Text(player.name.uppercased())
                                .spyFitted(scale: 0.58)
                        }
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.02)
                        .foregroundStyle(accepted ? SpyTheme.green : SpyTheme.dim)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .background(accepted ? SpyTheme.green.opacity(0.16) : SpyTheme.black.opacity(0.72), in: CutCornerShape(cut: 6))
                        .overlay(CutCornerShape(cut: 6).stroke(accepted ? SpyTheme.green.opacity(0.58) : SpyTheme.stroke.opacity(0.95), lineWidth: 1))
                        .shadow(color: accepted ? SpyTheme.green.opacity(0.12) : .clear, radius: 10, y: 4)
                    }
                }

                if !hasVoted {
                    Button {
                        Task { await voteReplay(room) }
                    } label: {
                        if isVotingReplay {
                            SpySpinner(size: 20, accent: .white)
                        } else {
                            Label(copy.voteForNewGame, systemImage: "arrow.clockwise")
                                .lineLimit(2)
                                .minimumScaleFactor(0.58)
                        }
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(isVotingReplay || isResettingRoom)
                } else {
                    Text(copy.replayVoteLocked)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.62, alignment: .center)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }

                if isHost(room) {
                    Button {
                        Task { await resetRoom(room) }
                    } label: {
                        if isResettingRoom {
                            SpySpinner(size: 20, accent: .white)
                        } else {
                        Label(allVoted ? copy.playAgain : copy.backToLobby, systemImage: allVoted ? "play.fill" : "arrow.uturn.left")
                                .lineLimit(2)
                                .minimumScaleFactor(0.58)
                        }
                    }
                    .buttonStyle(SpyButtonStyle(variant: allVoted ? .red : .outline))
                    .disabled(isResettingRoom || isVotingReplay)
                } else if allVoted {
                    Text(copy.waitingHostResetLobby)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.muted)
                        .spyFitted(lines: 2, scale: 0.68)
                }
            }
        }
    }

    private func playersPanel(_ room: GameRoom) -> some View {
        let missingPlayers = max(3 - room.playersList.count, 0)

        return onlineRoomGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                onlineRoomCardTitle(
                    systemImage: "person.2",
                    title: localized(en: "PLAYERS", ru: "ИГРОКИ", es: "JUGADORES"),
                    trailing: "\(room.playersList.count) / 3+"
                )

                VStack(alignment: .leading, spacing: 8) {
                    if room.playersList.isEmpty {
                        Text(copy.waiting)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(SpyTheme.dim)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        ForEach(Array(room.playersList.enumerated()), id: \.element.id) { index, player in
                            playerRow(player, index: index, room: room)
                                .spyWebEntrance(
                                    delay: Double(index) * 0.04,
                                    duration: 0.36,
                                    x: -10,
                                    y: 0
                                )
                        }
                    }
                }

                if missingPlayers > 0 {
                    Text(copy.minimumOperatives(room.playersList.count))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(SpyTheme.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(SpyTheme.red.opacity(0.20), lineWidth: 1)
                        }
                }
            }
        }
        .spyWebEntrance(delay: 0.05, duration: 0.45, y: 12)
    }

    private func playerRow(_ player: Player, index: Int, room: GameRoom) -> some View {
        let isCurrentUser = player.email == appState.user?.email
        let isRoomHost = player.email == room.hostEmail

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.58))
                .frame(width: 16)

            Text(player.avatar)
                .font(.system(size: 24))
                .frame(width: 30, height: 30)

            Text(player.name.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.58)

            Spacer(minLength: 8)

            if isRoomHost {
                Text(copy.hostBadge)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(SpyTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(SpyTheme.red.opacity(0.26), lineWidth: 1)
                    }
            } else if isCurrentUser {
                Text(youLabel)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(SpyTheme.dim)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(Color.white.opacity(isCurrentUser ? 0.045 : 0.026), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isCurrentUser ? 0.10 : 0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func webWaitingRoomActions(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            if isHost(room) {
                if room.playersList.count < 3 {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        webWaitingActionLabel(
                            title: localized(en: "INVITE OPERATIVES", ru: "ПРИГЛАСИТЬ ИГРОКОВ", es: "INVITAR AGENTES"),
                            systemImage: "person.badge.plus",
                            filled: false
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.inviteMore")
                } else {
                    HStack(spacing: 10) {
                        Button {
                            Task { await beginReadyCheck(room) }
                        } label: {
                            webWaitingActionLabel(
                                title: copy.readyCheckAction,
                                systemImage: "checkmark.seal",
                                filled: false
                            )
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .disabled(isStarting)
                        .accessibilityIdentifier("onlineRoom.readyCheck")

                        Button {
                            Task { await start(room) }
                        } label: {
                            webWaitingActionLabel(
                                title: isStarting
                                    ? localized(en: "STARTING", ru: "ЗАПУСК", es: "INICIANDO")
                                    : copy.startNow,
                                systemImage: "play.fill",
                                filled: true
                            )
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .disabled(isStarting)
                        .accessibilityIdentifier("onlineRoom.startNow")
                    }
                }
            } else {
                onlineRoomGlassCard(verticalPadding: 16) {
                    HStack(spacing: 10) {
                        SpySpinner(size: 16, accent: SpyTheme.red)
                        Text(copy.waitingForHost)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.58))
                        Spacer()
                    }
                }
            }

            statusLine
        }
        .spyWebEntrance(delay: 0.18, duration: 0.45, y: 12)
    }

    private func webWaitingActionLabel(title: String, systemImage: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .lineLimit(2)
                .minimumScaleFactor(0.58)
        }
        .foregroundStyle(filled ? Color.white : SpyTheme.red)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(filled ? SpyTheme.red : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SpyTheme.red.opacity(filled ? 1 : 0.62), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func waitingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            if isHost(room) {
                if room.playersList.count < 3 {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        SpyPrimaryCommandLabel(
                            title: localized(en: "INVITE OPERATIVES", ru: "ПРИГЛАСИТЬ ОПЕРАТИВНИКОВ", es: "INVITAR AGENTES"),
                            detail: copy.minimumOperatives(room.playersList.count),
                            systemImage: "person.badge.plus"
                        )
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .accessibilityIdentifier("onlineRoom.inviteMore")
                } else {
                    Button {
                        Task { await start(room) }
                    } label: {
                        if isStarting {
                            SpyPrimaryCommandLabel(
                                title: localized(en: "ARMING MISSION", ru: "ЗАПУСК МИССИИ", es: "INICIANDO MISION"),
                                detail: copy.minimumOperatives(room.playersList.count),
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                        } else {
                            SpyPrimaryCommandLabel(
                                title: copy.startNow,
                                detail: localized(en: "BEGIN IMMEDIATELY", ru: "НАЧАТЬ НЕМЕДЛЕННО", es: "COMENZAR AHORA"),
                                systemImage: "play.fill"
                            )
                        }
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .disabled(isStarting)
                    .accessibilityIdentifier("onlineRoom.startNow")

                    Button {
                        Task { await beginReadyCheck(room) }
                    } label: {
                        SpyActionLabel(title: copy.readyCheckAction, systemImage: "checkmark.seal", tracking: 0.02, lines: 2)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .outline))
                    .disabled(isStarting)
                    .accessibilityIdentifier("onlineRoom.readyCheck")
                }
            } else {
                HStack(spacing: 12) {
                    SpySpinner(size: 22, accent: SpyTheme.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.waitingForHost)
                            .font(.system(size: 12, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(.white)
                            .spyFitted(scale: 0.68)
                        Text(copy.minimumOperatives(room.playersList.count))
                            .font(.system(size: 10, weight: .bold, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(lines: 2, scale: 0.62)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SpyTheme.strokeDim).frame(height: 1)
                }
            }

            statusLine
        }
        .spyWebEntrance(delay: 0.20, duration: 0.45, y: 16)
    }

    private func preTimerControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            statusLine
        }
    }

    private func playingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            if currentUserIsSpy(room), !room.enabledWordPool.isEmpty {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    showSpyGuess = true
                } label: {
                    SpyActionLabel(title: copy.guessWord, systemImage: "scope", tracking: 0.02)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isSubmittingSpyGuess || isCurrentUserSpectator(room))
            }

            if !room.isVotingActive && room.questionPhase != "results" {
                Button {
                    Task { await advance(room) }
                } label: {
                    if isAdvancing {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        SpyActionLabel(
                            title: room.gameModeValue == .associations ? copy.nextAssociation : copy.nextQuestion,
                            systemImage: "forward.end.fill",
                            tracking: 0.02,
                            lines: 2
                        )
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isAdvancing || isCurrentUserSpectator(room))
            }

            Button {
                Task { await requestVote(room) }
            } label: {
                if isRequestingVote {
                    SpySpinner(size: 20, accent: .white)
                } else {
                        SpyActionLabel(title: voteButtonTitle(room), systemImage: "checkmark.seal.fill", tracking: 0.02, lines: 2)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: room.isVotingActive ? .ghost : .outline))
            .disabled(isRequestingVote || hasCurrentUserRequestedVote(room) || isCurrentUserSpectator(room))

            statusLine
        }
    }

    private var statusLine: some View {
        EmptyView()
    }

    private func publishGameToast(_ rawStatus: String) {
        guard !rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard status == rawStatus,
                  let message = userFacingStatus(rawStatus) else { return }
            appState.showToast(message, kind: toastKind(for: rawStatus))
            status = ""
        }
    }

    private func publishRoomThemeError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard roomThemeError == message else { return }
            appState.showToast(trimmed, kind: .error)
            roomThemeError = ""
        }
    }

    private func toastKind(for rawStatus: String) -> AppToastKind {
        let upper = rawStatus.uppercased()
        let errorMarkers = [
            "ERROR", "FAILED", "COULDN'T", "UNABLE", "EXPIRED", "TRACEBACK", "[401]",
            "ОШИБ", "НЕ УДАЛ", "ИСТЕКЛ", "NO SE PUDO", "ERROR DE"
        ]
        if errorMarkers.contains(where: upper.contains) {
            return .error
        }

        let warningMarkers = [
            "SELECT A DECK", "NEED AT LEAST", "CHOOSE", "ВЫБЕРИ", "НУЖНО МИНИМУМ", "ELIGE"
        ]
        if warningMarkers.contains(where: upper.contains) {
            return .warning
        }

        let successMarkers = [
            "READY", "SAVED", "SELECTED", "CLEARED", "SYNCED", "LOCKED", "SENT", "RESTORED", "EXPANDED",
            "ГОТОВ", "СОХРАН", "ВЫБРАН", "НЕ ВЫБРАН", "СИНХРОНИЗ", "ОТПРАВ", "ВОССТАНОВ", "РАСШИРЕН",
            "LISTO", "GUARDADO", "SELECCIONADO", "SINCRONIZADO", "ENVIADO", "RESTAURADO", "AMPLIADO"
        ]
        if isPositiveStatus(rawStatus) || successMarkers.contains(where: upper.contains) {
            return .success
        }

        return .info
    }

    private func userFacingStatus(_ rawStatus: String) -> String? {
        let trimmed = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        if upper.contains("AUTHENTICATION") || upper.contains("[401]") {
            return localized(en: "SESSION EXPIRED. LOG IN AGAIN", ru: "СЕССИЯ ИСТЕКЛА. ВОЙДИ СНОВА", es: "SESION EXPIRADA. INICIA SESION")
        }
        if upper.contains("HTTP") || upper.contains("TRACEBACK") || upper.contains("REQUEST_ID") {
            return localized(en: "SERVER SYNC FAILED. TRY AGAIN", ru: "СИНХРОНИЗАЦИЯ НЕ УДАЛАСЬ. ПОВТОРИ", es: "ERROR DE SINCRONIZACION")
        }
        return trimmed.count > 72 ? "\(trimmed.prefix(69))..." : trimmed
    }

    private func isPositiveStatus(_ status: String) -> Bool {
        [
            copy.modeSynced,
            durationSyncedStatus,
            copy.readyCheckSent,
            copy.lobbyRestored,
            copy.roomSynced,
            copy.readyRemoved,
            copy.readyLocked,
            copy.replayVoteLocked,
            copy.rouletteArmed,
            copy.gameReady,
            copy.associationSpun,
            copy.questionSent,
            roomCopiedTitle,
            copy.cardConfirmedStatus,
            copy.voteRequestedStatus,
            copy.voteLockedStatus,
            copy.spyGuessLocked
        ].contains(status)
    }

    private var emptyRoom: some View {
        SpyPanel {
            VStack(spacing: 16) {
                Image(systemName: "scope")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(SpyTheme.red)
                Text(copy.noActiveRoom)
                    .font(.system(size: 24, weight: .black, design: .default))
                    .tracking(0.04)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                Button {
                    appState.selectedTab = .home
                } label: {
                    Label(copy.openHome, systemImage: "house.fill")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 80)
    }

    private var roomBreadcrumb: String {
        localized(en: "HOME / LOBBY", ru: "ДОМ / ЛОББИ", es: "INICIO / SALA")
    }

    private var roomCodeLabel: String {
        localized(en: "// ROOM CODE", ru: "// КОД КОМНАТЫ", es: "// CODIGO")
    }

    private var roomCodePlainLabel: String {
        localized(en: "ROOM CODE", ru: "КОД КОМНАТЫ", es: "CODIGO")
    }

    private var roomCodeShare: String {
        localized(en: "Share the code with your team or open the QR invite.", ru: "Передай код команде или открой QR-приглашение.", es: "Comparte el codigo o abre el QR.")
    }

    private var roomCopyTitle: String {
        localized(en: "COPY", ru: "КОПИРОВАТЬ", es: "COPIAR")
    }

    private var roomCopiedTitle: String {
        localized(en: "COPIED", ru: "СКОПИРОВАНО", es: "COPIADO")
    }

    private var tapToHideRoomCode: String {
        localized(en: "TAP TO HIDE", ru: "ТАП ЧТОБЫ СКРЫТЬ", es: "TOCA PARA OCULTAR")
    }

    private var tapToRevealRoomCode: String {
        localized(en: "TAP TO REVEAL", ru: "ТАП ЧТОБЫ ПОКАЗАТЬ", es: "TOCA PARA MOSTRAR")
    }

    private var webQRHint: String {
        localized(en: "TAP TO FLIP", ru: "ТАП ЧТОБЫ ПЕРЕВЕРНУТЬ", es: "TOCA PARA GIRAR")
    }

    private var qrHiddenTitle: String {
        localized(en: "QR HIDDEN", ru: "QR СКРЫТ", es: "QR OCULTO")
    }

    private var tapToFlipQR: String {
        localized(en: "TAP TO FLIP", ru: "ТАП ЧТОБЫ ПЕРЕВЕРНУТЬ", es: "TOCA PARA GIRAR")
    }

    private var gameModeTitle: String {
        localized(en: "GAME MODE", ru: "РЕЖИМ ИГРЫ", es: "MODO DE JUEGO")
    }

    private var modeTitle: String {
        localized(en: "MODE", ru: "РЕЖИМ", es: "MODO")
    }

    private var agentsLabel: String {
        localized(en: "// AGENTS", ru: "// АГЕНТЫ", es: "// AGENTES")
    }

    private var readyCheckingTitle: String {
        localized(en: "READY CHECK", ru: "ПРОВЕРКА", es: "CHECK")
    }

    private var readyYesTitle: String {
        localized(en: "YES", ru: "ДА", es: "SI")
    }

    private var readyNoTitle: String {
        localized(en: "NO", ru: "НЕТ", es: "NO")
    }

    private var readyWaitingTitle: String {
        localized(en: "WAITING", ru: "ЖДЕМ", es: "ESPERA")
    }

    private var readyCountTitle: String {
        localized(en: "READY", ru: "ГОТОВЫ", es: "LISTOS")
    }

    private var readyAgentsStatusTitle: String {
        localized(en: "AGENTS STATUS", ru: "СТАТУС АГЕНТОВ", es: "ESTADO AGENTES")
    }

    private var webCardPhaseTitle: String {
        localized(en: "// CARD REVEAL PHASE", ru: "// ФАЗА ОТКРЫТИЯ КАРТ", es: "// FASE DE CARTAS")
    }

    private var webTapToRevealRoleTitle: String {
        localized(en: "TAP TO REVEAL ROLE", ru: "НАЖМИ, ЧТОБЫ ОТКРЫТЬ РОЛЬ", es: "TOCA PARA REVELAR ROL")
    }

    private var webDontShowOthersTitle: String {
        localized(en: "DON'T SHOW OTHERS", ru: "НЕ ПОКАЗЫВАЙ ДРУГИМ", es: "NO LO MUESTRES")
    }

    private var webReadyToPlayTitle: String {
        localized(en: "✓ READ, READY TO PLAY", ru: "✓ ПРОЧИТАЛ, ГОТОВ ИГРАТЬ", es: "✓ LEIDO, LISTO")
    }

    private var webWaitingOthersTitle: String {
        localized(en: "✓ You're ready. Waiting for others...", ru: "✓ Ты готов. Ждем остальных...", es: "✓ Listo. Esperando...")
    }

    private var webCardsReadTitle: String {
        localized(en: "// CARDS READ", ru: "// КАРТЫ ПРОЧИТАНЫ", es: "// CARTAS LEIDAS")
    }

    private var webSecretWordLabel: String {
        localized(en: "SECRET WORD", ru: "СЕКРЕТНОЕ СЛОВО", es: "PALABRA SECRETA")
    }

    private var webTimeLeftTitle: String {
        localized(en: "// TIME REMAINING", ru: "// ОСТАЛОСЬ ВРЕМЕНИ", es: "// TIEMPO RESTANTE")
    }

    private var webAgentsTitle: String {
        localized(en: "// AGENTS", ru: "// АГЕНТЫ", es: "// AGENTES")
    }

    private var webActivePairTitle: String {
        localized(en: "ACTIVE PAIR", ru: "АКТИВНАЯ ПАРА", es: "PAREJA ACTIVA")
    }

    private var webNextPairTitle: String {
        localized(en: "NEXT PAIR", ru: "СЛЕДУЮЩАЯ ПАРА", es: "SIGUIENTE PAREJA")
    }

    private var webEarlyGuessTitle: String {
        localized(en: "// EARLY GUESS", ru: "// ДОСРОЧНОЕ УГАДЫВАНИЕ", es: "// PISTA TEMPRANA")
    }

    private var webEarlyGuessDescription: String {
        localized(
            en: "Think you know the secret word? Guess early. Correct answer wins the game.",
            ru: "Думаешь, что знаешь секретное слово? Угадай досрочно. Верный ответ выигрывает игру.",
            es: "Crees saber la palabra secreta? Adivina antes. Respuesta correcta gana."
        )
    }

    private var webEarlyGuessButtonTitle: String {
        localized(en: "GUESS WORD EARLY", ru: "УГАДАТЬ СЛОВО ДОСРОЧНО", es: "ADIVINAR ANTES")
    }

    private var webVoteTitle: String {
        localized(en: "// VOTE FOR SPY", ru: "// ГОЛОСОВАНИЕ ЗА ШПИОНА", es: "// VOTAR AL ESPIA")
    }

    private var webVoteDescriptionLead: String {
        localized(en: "Want to start a vote?", ru: "Хочешь начать голосование?", es: "Quieres iniciar votacion?")
    }

    private var webVoteAgreementSuffix: String {
        localized(en: "players must agree.", ru: "игроков должны согласиться.", es: "jugadores deben aceptar.")
    }

    private var webVoteRequestButtonTitle: String {
        localized(en: "VOTE TO START", ru: "ХОЧУ ГОЛОСОВАТЬ", es: "VOTAR PARA INICIAR")
    }

    private var webVoteRequestedTitle: String {
        localized(en: "✓ You voted to start", ru: "✓ Ты проголосовал за начало", es: "✓ Votaste para iniciar")
    }

    private var webVoteStartedTitle: String {
        localized(
            en: "Voting started. Who do you vote as the spy?",
            ru: "Голосование началось. За кого голосуешь как за шпиона?",
            es: "La votacion empezo. A quien marcas como espia?"
        )
    }

    private var webVotingInProgressTitle: String {
        localized(en: "// VOTING IN PROGRESS", ru: "// ГОЛОСОВАНИЕ ИДЕТ", es: "// VOTACION EN CURSO")
    }

    private var webVoteSpyQuestion: String {
        localized(en: "SPY?", ru: "ШПИОН?", es: "ESPIA?")
    }

    private func webVoteDescription(_ room: GameRoom) -> String {
        "\(webVoteDescriptionLead) \(room.activeVoteRequests.count)/\(room.voteThreshold) \(webVoteAgreementSuffix)"
    }

    private var youLabel: String {
        localized(en: "YOU", ru: "ТЫ", es: "TU")
    }

    private var closeRoomTitle: String {
        localized(en: "CLOSE", ru: "ЗАКРЫТЬ", es: "CERRAR")
    }

    private var durationSyncedStatus: String {
        localized(en: "DURATION SYNCED", ru: "ДЛИТЕЛЬНОСТЬ СОХРАНЕНА", es: "DURACION GUARDADA")
    }

    private var selectedPackSummary: String {
        switch roomWordSource {
        case .none:
            if lobbyPackLoadState == .loaded, lobbyWordPacks.isEmpty {
                return localized(
                    en: "You haven't created any decks.",
                    ru: "Вы не создавали своих колод.",
                    es: "No has creado ningun pack."
                )
            }
            return localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado.")

        case .generated:
            guard let roomGeneratedPack else {
                return localized(en: "Not generated yet.", ru: "Ещё не сгенерировано.", es: "Aun no generado.")
            }
            return copy.selectedPackSummary(
                name: roomGeneratedPack.category.nilIfBlank ?? roomTheme.nilIfBlank ?? "CUSTOM",
                words: roomGeneratedWords.count
            )

        case let .saved(id):
            guard let pack = lobbyWordPacks.first(where: { $0.id == id }) else {
                return localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado.")
            }
            return copy.selectedPackSummary(name: pack.name, words: pack.words?.roomCleanWords.count ?? 0)
        }
    }

    private var roomHasCustomTheme: Bool {
        roomTheme.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil
    }

    private var roomHasGeneratedTheme: Bool {
        (roomGeneratedPack?.words.roomCleanWords.count ?? 0) >= 2
    }

    private var isGeneratingRoomTheme: Bool {
        roomThemeOperation != nil
    }

    private var isDurationSyncActive: Bool {
        guard let operation = appState.roomSyncOperation else { return isUpdatingDuration }
        if case .updatingDuration = operation { return true }
        return isUpdatingDuration
    }

    private var roomThemeSelectionIsReady: Bool {
        if roomHasCustomTheme {
            return roomWordSource == .generated && roomGeneratedWords.count >= 2
        }

        switch roomWordSource {
        case .none:
            return false
        case .generated:
            return roomGeneratedWords.count >= 2
        case let .saved(id):
            guard lobbyPackLoadState == .loaded else { return false }
            let words = lobbyWordPacks.first(where: { $0.id == id })?.words?.roomCleanWords ?? []
            return activeRoomWords(words).count >= 2
        }
    }

    private func roomStartActionDetail(_ room: GameRoom) -> String {
        if room.playersList.count < 3 {
            return copy.minimumOperatives(room.playersList.count)
        }
        if isGeneratingRoomTheme {
            return localized(en: "GENERATING WORDS", ru: "ГЕНЕРАЦИЯ СЛОВ", es: "GENERANDO PALABRAS")
        }
        if !roomThemeSelectionIsReady {
            switch roomWordSource {
            case .none:
                return localized(
                    en: "SELECT DECK / THEME",
                    ru: "ВЫБЕРИ КОЛОДУ / ТЕМУ",
                    es: "ELIGE PACK / TEMA"
                )
            case .generated:
                return localized(en: "GENERATE WORDS FIRST", ru: "СНАЧАЛА СГЕНЕРИРУЙ СЛОВА", es: "GENERA PALABRAS PRIMERO")
            case .saved:
                return localized(en: "THIS DECK NEEDS MORE WORDS", ru: "В КОЛОДЕ НЕДОСТАТОЧНО СЛОВ", es: "ESTE PACK NECESITA MAS PALABRAS")
            }
        }
        return localized(en: "START NOW", ru: "НАЧАТЬ СРАЗУ", es: "INICIAR AHORA")
    }

    private var roomThemeMaxWords: Int {
        max(roomGeneratedPack?.words.roomCleanWords.count ?? 0, 2)
    }

    private var roomShouldShowPoolPreview: Bool {
        roomPoolSnapshot != nil
    }

    private func roomWordKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func activeRoomWords(_ words: [String]) -> [String] {
        words.roomCleanWords.filter { !disabledRoomPoolWordKeys.contains(roomWordKey($0)) }
    }

    private func toggleRoomPoolWord(_ word: String) {
        let key = roomWordKey(word)
        if disabledRoomPoolWordKeys.contains(key) {
            disabledRoomPoolWordKeys.remove(key)
        } else {
            disabledRoomPoolWordKeys.insert(key)
        }
        HapticManager.shared.fire(.tabSelection)
    }

    private var roomGeneratedWords: [String] {
        Array(activeRoomWords(roomGeneratedPack?.words ?? []).prefix(Int(max(roomWordCount, 1))))
    }

    private var lobbyWordPacksForStart: [WordPack] {
        if roomWordSource == .generated, let pack = generatedRoomWordPack {
            return [pack] + lobbyWordPacks.filter { $0.id != pack.id }
        }

        if case let .saved(id) = roomWordSource,
           var pack = lobbyWordPacks.first(where: { $0.id == id }) {
            pack.words = activeRoomWords(pack.words ?? [])
            return [pack] + lobbyWordPacks.filter { $0.id != id }
        }

        return lobbyWordPacks
    }

    private var generatedRoomWordPack: WordPack? {
        guard let roomGeneratedPack else { return nil }
        let words = roomGeneratedWords
        guard words.count >= 2 else { return nil }
        let name = roomGeneratedPack.name?.nilIfBlank ?? roomGeneratedPack.category.nilIfBlank ?? roomTheme.nilIfBlank ?? "Custom"
        return WordPack(
            id: "generated",
            name: name,
            category: roomGeneratedPack.category.nilIfBlank ?? name,
            words: words,
            ownerEmail: appState.user?.email,
            isPublic: false
        )
    }

    private var roomPoolSnapshot: RoomPoolSnapshot? {
        if roomWordSource == .generated, let roomGeneratedPack {
            let words = roomGeneratedPack.words.roomCleanWords
            let inGameCount = min(max(Int(roomWordCount), 0), activeRoomWords(words).count)
            return RoomPoolSnapshot(
                category: roomGeneratedPack.category.nilIfBlank ?? roomTheme.nilIfBlank ?? "CUSTOM",
                source: localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO"),
                words: words,
                countLabel: localized(
                    en: "\(inGameCount)/\(words.count) IN GAME",
                    ru: "\(inGameCount)/\(words.count) В ИГРЕ",
                    es: "\(inGameCount)/\(words.count) EN JUEGO"
                ),
                emptyMessage: localized(en: "Generate a theme before starting.", ru: "Сгенерируй тему перед стартом.", es: "Genera un tema antes de iniciar.")
            )
        }

        if case let .saved(id) = roomWordSource,
           let pack = lobbyWordPacks.first(where: { $0.id == id }) {
            let words = pack.words?.roomCleanWords ?? []
            let inGameCount = activeRoomWords(words).count
            return RoomPoolSnapshot(
                category: pack.category?.nilIfBlank ?? pack.name,
                source: localized(en: "WORD PACK", ru: "WORDPACK", es: "WORDPACK"),
                words: words,
                countLabel: localized(
                    en: "\(inGameCount)/\(words.count) IN GAME",
                    ru: "\(inGameCount)/\(words.count) В ИГРЕ",
                    es: "\(inGameCount)/\(words.count) EN JUEGO"
                ),
                emptyMessage: localized(en: "This pack is empty. Choose another source.", ru: "Этот пак пуст. Выбери другой источник.", es: "Este pack esta vacio. Elige otra fuente.")
            )
        }

        return nil
    }

    private var roomThemeTitle: String {
        localized(en: "THEME / WORD PACK", ru: "ТЕМА / ПАК СЛОВ", es: "TEMA / PACK")
    }

    private var roomUnlimitedLabel: String {
        localized(en: "∞ UNLIMITED", ru: "∞ UNLIMITED", es: "∞ ILIMITADO")
    }

    private var roomThemePlaceholder: String {
        localized(en: "European Countries, Marvel...", ru: "Страны Европы, Marvel...", es: "Paises, Marvel...")
    }

    private var roomCountLabel: String {
        localized(en: "// WORDS TO CREATE", ru: "// СОЗДАТЬ СЛОВ", es: "// PALABRAS A CREAR")
    }

    private var roomWordsLabel: String {
        localized(en: "WORDS IN GAME", ru: "СЛОВ В ИГРЕ", es: "PALABRAS EN JUEGO")
    }

    private var roomPoolPreviewLabel: String {
        localized(en: "// POOL PREVIEW", ru: "// ПРЕВЬЮ ПУЛА", es: "// PREVIEW BANCO")
    }

    private var roomAddMoreWordsLabel: String {
        if roomThemeMaxWords >= 200 {
            return localized(en: "WORD POOL MAXED", ru: "ДОСТИГНУТ МАКСИМУМ", es: "BANCO AL MAXIMO")
        }
        return localized(en: "EXPAND POOL · +50", ru: "РАСШИРИТЬ ПУЛ · +50", es: "AMPLIAR BANCO · +50")
    }

    private func roomShowAllWordsLabel(_ count: Int) -> String {
        localized(
            en: "SHOW ALL · \(count)",
            ru: "ПОКАЗАТЬ ВСЕ · \(count)",
            es: "MOSTRAR TODO · \(count)"
        )
    }

    private var roomShowLessWordsLabel: String {
        localized(en: "SHOW LESS", ru: "ПОКАЗАТЬ МЕНЬШЕ", es: "MOSTRAR MENOS")
    }

    private var roomSaveAsWordPackLabel: String {
        localized(en: "SAVE AS WORDPACK", ru: "СОХРАНИТЬ КАК WORDPACK", es: "GUARDAR WORDPACK")
    }

    private var roomThemeActionTitle: String {
        if roomHasGeneratedTheme {
            return localized(en: "REGENERATE", ru: "СГЕНЕРИРОВАТЬ ЗАНОВО", es: "REGENERAR")
        }
        return localized(en: "GENERATE WORDS", ru: "СГЕНЕРИРОВАТЬ СЛОВА", es: "GENERAR PALABRAS")
    }

    private var roomThemeActionIcon: String {
        if roomHasGeneratedTheme { return "arrow.clockwise" }
        return "sparkles"
    }

    private func roomWordCountModeTitle(_ mode: RoomWordCountMode) -> String {
        switch mode {
        case .recommended:
            localized(en: "RECOMMENDED", ru: "РЕКОМЕНДОВАНО", es: "RECOMENDADO")
        case .custom:
            localized(en: "CUSTOM", ru: "СВОЙ ВЫБОР", es: "CUSTOM")
        }
    }

    private func roomWordCountModeHint(_ mode: RoomWordCountMode) -> String {
        switch mode {
        case .recommended:
            localized(en: "100 words", ru: "100 слов", es: "100 palabras")
        case .custom:
            localized(
                en: "\(Int(roomCustomWordCount)) words",
                ru: "\(Int(roomCustomWordCount)) слов",
                es: "\(Int(roomCustomWordCount)) palabras"
            )
        }
    }

    private func roomThemeMetaLabel(maxWords: Int) -> String {
        return localized(
            en: "AI POOL · \(maxWords) AVAILABLE",
            ru: "AI-ПУЛ · \(maxWords) ДОСТУПНО",
            es: "BANCO IA · \(maxWords) DISPONIBLES"
        )
    }

    private func configTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker(lines: 2)
            Text(value)
                .font(.system(size: 15, weight: .black, design: .default))
                .tracking(value.count > 10 ? 0.0 : 0.08)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .spyCutCard(cut: 8, fill: SpyTheme.panelDeep, stroke: SpyTheme.stroke)
    }

    private func setupMenuLabel(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker(lines: 2)
                    Text(isLoadingLobbyPacks ? copy.syncingWordPacks : value)
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(SpyTheme.dim)
        }
        .padding(12)
        .spyCutCard(cut: 8, fill: SpyTheme.panelDeep, stroke: SpyTheme.stroke)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.66, alignment: .trailing)
            }
            SpyWebSlider(value: value, range: range, step: 1)
        }
    }

    private func turnAgent(title: String, player: Player?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()
            Text(player?.name.uppercased() ?? copy.pending)
                .font(.system(size: 18, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func inlineBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .black, design: .default))
            .tracking(0.02)
            .foregroundStyle(color)
            .spyFitted(scale: 0.66, alignment: .center)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(color.opacity(0.08))
            .overlay(Rectangle().stroke(color.opacity(0.35)))
    }

    private func copyRoomCode(_ room: GameRoom) {
        UIPasteboard.general.string = room.code
        copiedRoomCode = true
        status = roomCopiedTitle
        HapticManager.shared.fire(.notification(.success))

        Task {
            try? await Task.sleep(for: .milliseconds(2800))
            await MainActor.run {
                copiedRoomCode = false
            }
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru:
            ru
        case .es:
            es
        default:
            en
        }
    }

    private func player(for email: String?, in room: GameRoom) -> Player? {
        guard let email else { return nil }
        return room.playersList.first { $0.email == email }
    }

    private func compactPlayerName(_ name: String) -> String {
        let uppercased = name.uppercased()
        guard uppercased.count > 7 else { return uppercased }
        return "\(uppercased.prefix(6))…"
    }

    private func rouletteTarget(_ room: GameRoom) -> Player? {
        player(for: room.rouletteTargetEmail ?? room.currentAskerEmail, in: room)
    }

    private func isHost(_ room: GameRoom) -> Bool {
        room.hostEmail == appState.user?.email
    }

    private func currentUserIsReady(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return (room.readyPlayers ?? []).contains(email)
    }

    private func currentUserIsSpy(_ room: GameRoom) -> Bool {
        appState.user?.email == room.spyEmail
    }

    private func allPlayersReady(_ room: GameRoom) -> Bool {
        let ready = Set(room.readyPlayers ?? [])
        return room.playersList.count >= 3 && room.playersList.allSatisfy { ready.contains($0.email) }
    }

    private func isCurrentUserSpectator(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return room.spectatorsList.contains(email)
    }

    private func hasCurrentUserRequestedVote(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return room.voteRequestsList.contains(email)
    }

    private func myVote(in room: GameRoom) -> VoteRecord? {
        guard let email = appState.user?.email else { return nil }
        return room.detectiveVotesList.first { $0.voterEmail == email }
    }

    private func currentUserHasReadCard(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return room.cardsReadList.contains(email)
    }

    private func roomStateLabel(_ room: GameRoom) -> String {
        if room.normalizedStatus == "playing" && !room.allRoleCardsRead { return copy.dealing }
        if room.isGamePaused { return localized(en: "PAUSED", ru: "ПАУЗА", es: "PAUSA") }
        if room.isVotingActive { return copy.voting }
        if room.questionPhase == "results" { return copy.results }
        return copy.statusLabel(room.normalizedStatus)
    }

    private func voteButtonTitle(_ room: GameRoom) -> String {
        if hasCurrentUserRequestedVote(room) { return copy.voteRequestedStatus }
        if room.isVotingActive { return copy.votingOpen }
        return copy.requestVote(room.activeVoteRequests.count, threshold: room.voteThreshold)
    }

    private func roleTitle(isSpy: Bool, isSpectator: Bool) -> String {
        if isSpectator { return copy.spectatorMode }
        return isSpy ? copy.youAreSpy : copy.youAreDetective
    }

    private func roleSubtitle(isSpy: Bool, isSpectator: Bool, room: GameRoom) -> String {
        if isSpectator { return copy.spectatorSubtitle }
        if isSpy { return copy.categorySubtitle(room.category) }
        return copy.secretWord
    }

    private func remainingSeconds(_ room: GameRoom) -> Int {
        guard let duration = room.gameDurationSeconds,
              let elapsed = elapsedGameSeconds(room) else {
            return room.gameDurationSeconds ?? 0
        }
        return max(0, duration - elapsed)
    }

    private func elapsedGameSeconds(_ room: GameRoom) -> Int? {
        guard let started = room.gameStartedAt,
              let startDate = parseDate(started) else { return nil }
        let effectiveNow = room.gamePausedAt.flatMap(parseDate) ?? now
        let pausedSeconds = max(room.gamePausedTotalSeconds ?? 0, 0)
        return max(Int(effectiveNow.timeIntervalSince(startDate)) - pausedSeconds, 0)
    }

    private func postGameGuessSecondsRemaining(_ room: GameRoom) -> Int {
        guard let duration = room.gameDurationSeconds,
              let elapsed = elapsedGameSeconds(room) else { return 30 }
        return max(30 - max(elapsed - duration, 0), 0)
    }

    private func isTimeExpired(_ room: GameRoom) -> Bool {
        guard room.gameStartedAt != nil, room.gameDurationSeconds != nil else {
            return false
        }
        return remainingSeconds(room) == 0
    }

    private func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func timeString(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        let remainder = max(seconds, 0) % 60
        return "\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    private func updateRoomThemeDraft(from previousTheme: String, to currentTheme: String) {
        let previousValue = previousTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentValue = currentTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previousValue != currentValue else { return }

        let previouslyHadTheme = previousValue.nilIfBlank != nil
        let hasTheme = currentValue.nilIfBlank != nil

        if !previouslyHadTheme, hasTheme {
            roomThemeFallbackSource = roomWordSource == .generated ? .none : roomWordSource
        }

        roomGeneratedPack = nil
        roomThemeError = ""
        showsAllRoomPoolWords = false
        disabledRoomPoolWordKeys.removeAll()

        if hasTheme {
            roomWordSource = .generated
        } else if previouslyHadTheme {
            roomWordSource = resolvedRoomFallbackSource
            roomThemeFallbackSource = .none
        }
    }

    private func selectRoomPack(_ id: String?) {
        let source = id.map(RoomWordSource.saved) ?? .none
        roomThemeFallbackSource = roomHasCustomTheme ? source : .none
        roomWordSource = source
        roomTheme = ""
        roomGeneratedPack = nil
        roomThemeError = ""
        showsAllRoomPoolWords = false
        disabledRoomPoolWordKeys.removeAll()
    }

    private var resolvedRoomFallbackSource: RoomWordSource {
        guard case let .saved(id) = roomThemeFallbackSource else { return .none }
        return lobbyWordPacks.contains(where: { $0.id == id }) ? .saved(id) : .none
    }

    private func generateRoomTheme(usingInitialTarget: Bool) async {
        let theme = roomTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.isEmpty, roomThemeOperation == nil else { return }
        let requestID = UUID()

        let targetCount: Int
        if usingInitialTarget {
            targetCount = roomWordCountMode == .custom ? Int(roomCustomWordCount) : 100
        } else {
            targetCount = roomThemeMaxWords
        }

        roomThemeOperation = .generate
        roomThemeError = ""
        defer { roomThemeOperation = nil }

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                generated = GeneratedWordPack(
                    name: "\(theme) Kit",
                    category: theme,
                    words: (1...max(targetCount, 5)).map { "\(theme) \($0)" },
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
            } else {
                generated = try await appState.client.generateWordPack(
                    theme: theme,
                    count: max(targetCount, 5),
                    requestID: requestID,
                    preferFresh: !usingInitialTarget
                )
            }
            appState.recordAIUsage(
                used: generated.aiGenerationsToday,
                remaining: generated.aiRemaining
            )

            guard roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }

            let words = generated.words.roomCleanWords
            guard words.count >= 2 else {
                roomThemeError = localized(
                    en: "Couldn't recognize this theme. Try another.",
                    ru: "Не удалось распознать тему. Попробуй другую.",
                    es: "No se pudo reconocer el tema. Prueba otro."
                )
                HapticManager.shared.fire(.notification(.warning))
                return
            }

            let cleanGenerated = GeneratedWordPack(
                name: generated.name,
                category: generated.category.nilIfBlank ?? theme,
                words: words,
                aiLimit: generated.aiLimit,
                aiGenerationsToday: generated.aiGenerationsToday,
                aiRemaining: generated.aiRemaining
            )
            roomGeneratedPack = cleanGenerated
            disabledRoomPoolWordKeys.removeAll()
            if usingInitialTarget {
                roomWordCount = Double(min(words.count, roomWordCountMode == .custom ? Int(roomCustomWordCount) : max(25, min(words.count, 100))))
            } else {
                roomWordCount = Double(min(max(Int(roomWordCount), 2), words.count))
            }
            roomWordSource = .generated
            showsAllRoomPoolWords = false
            status = localized(en: "AI WORD POOL READY", ru: "AI-ПУЛ СЛОВ ГОТОВ", es: "BANCO IA LISTO")
            HapticManager.shared.fire(.milestone)
        } catch {
            guard roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }
            roomThemeError = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func pushRoomThemeMax() async {
        let theme = roomTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPack = roomGeneratedPack
        let current = currentPack?.words.roomCleanWords ?? []
        let selectedWordCount = Int(roomWordCount)
        let wasUsingEntirePool = selectedWordCount >= current.count
        guard !theme.isEmpty, current.count >= 2, roomThemeOperation == nil else { return }
        let requestID = UUID()

        let additionalCount = min(50, 200 - current.count)
        roomThemeOperation = .expand
        roomThemeError = ""
        defer { roomThemeOperation = nil }

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                generated = GeneratedWordPack(
                    name: "\(theme) Kit",
                    category: theme,
                    words: (1...additionalCount).map { "\(theme) \(current.count + $0)" },
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
            } else {
                generated = try await appState.client.generateWordPack(
                    theme: theme,
                    count: additionalCount,
                    requestID: requestID,
                    excluding: current,
                    preferFresh: false
                )
            }
            appState.recordAIUsage(
                used: generated.aiGenerationsToday,
                remaining: generated.aiRemaining
            )

            guard roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }

            var seen = Set(current.map { $0.lowercased() })
            let additions = generated.words.roomCleanWords.filter { seen.insert($0.lowercased()).inserted }
            let merged = Array((current + additions).prefix(200))
            guard merged.count > current.count else {
                roomThemeError = localized(
                    en: "Couldn't find more unique words.",
                    ru: "Больше уникальных слов найти не удалось.",
                    es: "No se encontraron mas palabras unicas."
                )
                HapticManager.shared.fire(.notification(.warning))
                return
            }

            roomGeneratedPack = GeneratedWordPack(
                name: generated.name ?? currentPack?.name,
                category: generated.category.nilIfBlank ?? currentPack?.category ?? theme,
                words: merged,
                aiLimit: generated.aiLimit,
                aiGenerationsToday: generated.aiGenerationsToday,
                aiRemaining: generated.aiRemaining
            )
            disabledRoomPoolWordKeys = disabledRoomPoolWordKeys.filter { key in
                merged.contains { roomWordKey($0) == key }
            }
            roomWordCount = Double(
                wasUsingEntirePool
                    ? merged.count
                    : min(merged.count, max(selectedWordCount, 2))
            )
            roomWordSource = .generated
            showsAllRoomPoolWords = false
            status = localized(en: "AI WORD POOL EXPANDED", ru: "AI-ПУЛ СЛОВ РАСШИРЕН", es: "BANCO IA AMPLIADO")
            HapticManager.shared.fire(.milestone)
        } catch {
            guard roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }
            roomThemeError = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func saveRoomThemePack() async {
        guard let email = appState.user?.email else { return }
        guard let roomGeneratedPack else { return }
        let words = activeRoomWords(roomGeneratedPack.words)
        guard words.count >= 2 else { return }
        let name = roomGeneratedPack.name?.nilIfBlank
            ?? roomGeneratedPack.category.nilIfBlank
            ?? roomTheme.nilIfBlank
            ?? "Custom"
        let pack = WordPack(
            id: "generated",
            name: name,
            category: roomGeneratedPack.category.nilIfBlank ?? name,
            words: words,
            ownerEmail: email,
            isPublic: false
        )

        isSavingRoomThemePack = true
        defer { isSavingRoomThemePack = false }

        if appState.shouldUsePreviewData {
            let previewPack = WordPack(
                id: "preview-saved-\(UUID().uuidString)",
                name: pack.name,
                category: pack.category,
                words: pack.words,
                ownerEmail: email,
                isPublic: false
            )
            lobbyWordPacks.append(previewPack)
            lobbyPackLoadState = .loaded
            status = localized(en: "WORDPACK SAVED", ru: "WORDPACK СОХРАНЕН", es: "WORDPACK GUARDADO")
            HapticManager.shared.fire(.milestone)
            return
        }

        do {
            let saved = try await appState.client.createWordPack(
                name: pack.name,
                category: pack.category ?? pack.name,
                words: pack.words ?? [],
                ownerEmail: email
            )
            lobbyWordPacks.append(saved)
            lobbyWordPacks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lobbyPackLoadState = .loaded
            status = localized(en: "WORDPACK SAVED", ru: "WORDPACK СОХРАНЕН", es: "WORDPACK GUARDADO")
            HapticManager.shared.fire(.milestone)
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func configureLobby(_ room: GameRoom) async {
        if configuredRoomID != room.id {
            configuredRoomID = room.id
            selectedGameMode = room.gameModeValue
            selectedDurationMinutes = Double(max((room.gameDurationSeconds ?? 900) / 60, 1))
            roomAccessPage = 0
            isRoomCodeVisible = false
            isRoomQRVisible = false
            roomThemeFallbackSource = .none
            roomWordSource = .none
            roomTheme = ""
            roomGeneratedPack = nil
            roomThemeError = ""
            roomWordCount = 25
            roomCustomWordCount = 25
            roomWordCountMode = .recommended
            showsAllRoomPoolWords = false
            disabledRoomPoolWordKeys.removeAll()
            pendingStartPlan = nil
            rouletteCompletionKey = nil
        }

        if appState.shouldUsePreviewData {
            lobbyWordPacks = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-no-wordpacks")
                ? []
                : WordPack.previewPacks
            lobbyPackLoadState = .loaded
            return
        }

        await loadLobbyWordPacks()
    }

    private func loadLobbyWordPacks(force: Bool = false) async {
        if appState.shouldUsePreviewData {
            lobbyWordPacks = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-no-wordpacks")
                ? []
                : WordPack.previewPacks
            lobbyPackLoadState = .loaded
            return
        }

        guard force || lobbyPackLoadState != .loaded else { return }
        guard let email = appState.user?.email else {
            lobbyPackLoadState = .failed(localized(
                en: "Sign in again to load your decks.",
                ru: "Войдите снова, чтобы загрузить колоды.",
                es: "Inicia sesion de nuevo para cargar tus packs."
            ))
            return
        }

        lobbyPackLoadState = .loading
        do {
            lobbyWordPacks = try await appState.client.wordPacks(ownerEmail: email)
            if case let .saved(id) = roomWordSource,
               !lobbyWordPacks.contains(where: { $0.id == id }) {
                roomWordSource = .none
                showsAllRoomPoolWords = false
                disabledRoomPoolWordKeys.removeAll()
            } else if case let .saved(id) = roomWordSource,
                      let selectedPack = lobbyWordPacks.first(where: { $0.id == id }) {
                let availableKeys = Set((selectedPack.words ?? []).roomCleanWords.map(roomWordKey))
                disabledRoomPoolWordKeys.formIntersection(availableKeys)
            }
            lobbyPackLoadState = .loaded
        } catch {
            lobbyPackLoadState = .failed(error.localizedDescription)
        }
    }

    private func updateMode(_ room: GameRoom, mode: SpyGameMode) async {
        let operation = RoomSyncOperation.updatingMode(mode)
        guard appState.beginRoomSync(operation) else { return }
        let previousMode = selectedGameMode
        selectedGameMode = mode
        isUpdatingGameMode = true
        defer {
            isUpdatingGameMode = false
            appState.endRoomSync(operation)
        }
        await Task.yield()

        if appState.shouldUsePreviewData {
            var previewRoom = room
            previewRoom.gameMode = mode.rawValue
            appState.activeRoom = previewRoom
            status = copy.modeSynced
            HapticManager.shared.fire(.notification(.success))
            return
        }
        do {
            appState.activeRoom = try await appState.client.updateGameMode(room: room, mode: mode)
            selectedGameMode = appState.activeRoom?.gameModeValue ?? mode
            status = copy.modeSynced
            HapticManager.shared.fire(.notification(.success))
        } catch {
            selectedGameMode = previousMode
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func updateDuration(_ room: GameRoom, minutes: Int) async {
        let clampedMinutes = max(1, min(minutes, 15))
        let operation = RoomSyncOperation.updatingDuration(minutes: clampedMinutes)
        guard appState.beginRoomSync(operation) else { return }
        let previousMinutes = Double(max(1, min((room.gameDurationSeconds ?? Int(selectedDurationMinutes * 60)) / 60, 15)))
        selectedDurationMinutes = Double(clampedMinutes)
        isUpdatingDuration = true
        defer {
            isUpdatingDuration = false
            appState.endRoomSync(operation)
        }
        await Task.yield()

        if appState.shouldUsePreviewData {
            var previewRoom = room
            previewRoom.gameDurationSeconds = clampedMinutes * 60
            appState.activeRoom = previewRoom
            status = durationSyncedStatus
            HapticManager.shared.fire(.tabSelection)
            return
        }

        do {
            appState.activeRoom = try await appState.client.updateGameDuration(
                room: room,
                durationSeconds: clampedMinutes * 60
            )
            selectedDurationMinutes = Double(max((appState.activeRoom?.gameDurationSeconds ?? clampedMinutes * 60) / 60, 1))
            status = durationSyncedStatus
            HapticManager.shared.fire(.tabSelection)
        } catch {
            selectedDurationMinutes = previousMinutes
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func beginReadyCheck(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "ready_voting")
            status = copy.readyCheckSent
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            appState.activeRoom = try await appState.client.beginReadyCheck(room: room)
            status = copy.readyCheckSent
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func toggleReady(_ room: GameRoom) async {
        guard let user = appState.user else { return }
        let wasReady = currentUserIsReady(room)
        if appState.shouldUsePreviewData {
            var previewRoom = room
            var ready = Set(room.readyPlayers ?? [])
            if wasReady {
                ready.remove(user.email)
                status = copy.readyRemoved
            } else {
                ready.insert(user.email)
                status = copy.readyLocked
            }
            previewRoom.readyPlayers = Array(ready)
            appState.activeRoom = previewRoom
            HapticManager.shared.fire(
                .notification(.success)
            )
            return
        }
        isTogglingReady = true
        defer { isTogglingReady = false }
        do {
            appState.activeRoom = try await appState.client.toggleReady(room: room, user: user)
            status = wasReady ? copy.readyRemoved : copy.readyLocked
            HapticManager.shared.fire(
                .notification(.success)
            )
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func returnToWaiting(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "waiting")
            status = copy.lobbyRestored
            HapticManager.shared.fire(.buttonPress)
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            appState.activeRoom = try await appState.client.returnToWaiting(room: room)
            status = copy.lobbyRestored
            HapticManager.shared.fire(.buttonPress)
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func voteReplay(_ room: GameRoom) async {
        guard let user = appState.user else { return }
        if appState.shouldUsePreviewData {
            status = copy.replayVoteLocked
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isVotingReplay = true
        defer { isVotingReplay = false }

        do {
            let updated = try await appState.client.votePlayAgain(room: room, user: user)
            appState.activeRoom = updated
            status = copy.replayVoteLocked
            HapticManager.shared.fire(.notification(.success))

            if isHost(updated), allPlayersReady(updated) {
                try await Task.sleep(for: .milliseconds(300))
                await resetRoom(updated)
            }
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func resetRoom(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "waiting")
            pendingStartPlan = nil
            rouletteCompletionKey = nil
            revealRole = false
            showSpyGuess = false
            status = copy.lobbyRestored
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isResettingRoom = true
        defer { isResettingRoom = false }

        do {
            appState.activeRoom = try await appState.client.resetRoomForReplay(room: room)
            selectedGameMode = appState.activeRoom?.gameModeValue ?? selectedGameMode
            selectedDurationMinutes = Double(max((appState.activeRoom?.gameDurationSeconds ?? 900) / 60, 1))
            pendingStartPlan = nil
            rouletteCompletionKey = nil
            revealRole = false
            showSpyGuess = false
            status = copy.lobbyRestored
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func start(_ room: GameRoom) async {
        guard appState.user?.email != nil else { return }
        guard !isDurationSyncActive else { return }
        guard roomThemeSelectionIsReady, !isGeneratingRoomTheme else {
            status = localized(
                en: "SELECT A DECK OR GENERATE THE THEME WORDS BEFORE STARTING",
                ru: "ПЕРЕД СТАРТОМ ВЫБЕРИ КОЛОДУ ИЛИ СГЕНЕРИРУЙ СЛОВА ТЕМЫ",
                es: "ELIGE UN PACK O GENERA LAS PALABRAS ANTES DE EMPEZAR"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "roulette")
            status = copy.rouletteArmed
            revealRole = false
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            if lobbyPackLoadState != .loaded {
                await loadLobbyWordPacks()
            }
            guard roomThemeSelectionIsReady, let selectedPackID else {
                throw Base44Error(
                    message: localized(
                        en: "Select a deck or create a theme first.",
                        ru: "Сначала выбери колоду или создай тему.",
                        es: "Elige un pack o crea un tema primero."
                    ),
                    statusCode: nil
                )
            }
            let packs = lobbyWordPacksForStart
            let plan = try appState.client.makeGameStartPlan(
                room: room,
                wordPacks: packs,
                selectedPackID: selectedPackID,
                gameMode: selectedGameMode,
                durationSeconds: Int(selectedDurationMinutes * 60),
                forcedAskerEmail: room.rouletteTargetEmail
            )
            pendingStartPlan = plan
            appState.activeRoom = try await appState.client.armRoulette(room: room, plan: plan)
            status = copy.rouletteArmed
            revealRole = false
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func completeRouletteIfNeeded(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            try? await Task.sleep(for: .seconds(8))
            guard appState.activeRoom?.normalizedStatus == "roulette" else { return }
            appState.activeRoom = GameRoom.previewRoom(status: "cards-last")
            status = copy.gameReady
            return
        }
        guard room.normalizedStatus == "roulette",
              let userEmail = appState.user?.email,
              room.playersList.contains(where: { $0.email == userEmail }) else { return }
        let key = "\(room.id)-\(room.introStartedAt ?? room.rouletteTargetEmail ?? "")"
        guard rouletteCompletionKey != key else { return }
        rouletteCompletionKey = key

        isStarting = true
        defer { isStarting = false }

        do {
            let elapsed = room.introStartedAt
                .flatMap(parseDate)
                .map { max(Date().timeIntervalSince($0), 0) } ?? 0
            let delay = max(8.2 - elapsed, 0)
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            let currentRoom = (try? await appState.client.refreshRoom(id: room.id)) ?? room
            guard currentRoom.normalizedStatus == "roulette" else { return }

            appState.activeRoom = try await appState.client.completeGameStart(room: currentRoom)
            pendingStartPlan = nil
            status = copy.gameReady
            revealRole = false
            HapticManager.shared.fire(.milestone)
        } catch {
            rouletteCompletionKey = nil
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func advance(_ room: GameRoom) async {
        guard !room.isGamePaused, !isTimeExpired(room) else { return }
        if appState.shouldUsePreviewData {
            status = room.gameModeValue == .associations ? copy.associationSpun : copy.questionSent
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            if room.gameModeValue == .associations {
                appState.activeRoom = try await appState.client.advanceAssociation(room: room)
                status = copy.associationSpun
            } else {
                appState.activeRoom = try await appState.client.advanceQuestion(room: room)
                status = copy.questionSent
            }
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func markCardRead(_ room: GameRoom) async {
        guard let user = appState.user else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            var cardsRead = previewRoom.cardsReadList
            if !cardsRead.contains(user.email) {
                cardsRead.append(user.email)
            }
            previewRoom.cardsRead = cardsRead
            if previewRoom.playersList.allSatisfy({ cardsRead.contains($0.email) }) {
                previewRoom.gameStartedAt = ISO8601DateFormatter().string(from: Date())
                previewRoom.gamePausedAt = nil
                previewRoom.gamePausedTotalSeconds = 0
            }
            appState.activeRoom = previewRoom
            revealRole = false
            status = copy.cardConfirmedStatus
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isMarkingCardRead = true
        defer { isMarkingCardRead = false }
        do {
            appState.activeRoom = try await appState.client.markRoleCardRead(room: room, user: user)
            revealRole = false
            status = copy.cardConfirmedStatus
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func toggleGamePause(_ room: GameRoom) async {
        guard isHost(room), room.gameStartedAt != nil, !isTogglingGamePause else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            if room.isGamePaused {
                if let pausedAt = room.gamePausedAt.flatMap(parseDate) {
                    let additionalPause = max(Int(Date().timeIntervalSince(pausedAt)), 0)
                    previewRoom.gamePausedTotalSeconds = max(room.gamePausedTotalSeconds ?? 0, 0) + additionalPause
                }
                previewRoom.gamePausedAt = nil
            } else {
                previewRoom.gamePausedAt = ISO8601DateFormatter().string(from: Date())
            }
            appState.activeRoom = previewRoom
            HapticManager.shared.fire(.buttonPress)
            return
        }

        isTogglingGamePause = true
        defer { isTogglingGamePause = false }
        do {
            let updatedRoom: GameRoom
            if room.isGamePaused {
                updatedRoom = try await appState.client.resumeGame(room: room)
            } else {
                updatedRoom = try await appState.client.pauseGame(room: room)
            }
            appState.activeRoom = updatedRoom
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func finalizeExpiredRoomIfNeeded(_ room: GameRoom) async {
        guard room.normalizedStatus == "playing",
              room.gameStartedAt != nil,
              !room.isGamePaused,
              isTimeExpired(room),
              !isFinalizingExpiredRoom else { return }

        if appState.shouldUsePreviewData {
            return
        }

        isFinalizingExpiredRoom = true
        defer { isFinalizingExpiredRoom = false }
        do {
            let graceSeconds = postGameGuessSecondsRemaining(room)
            if graceSeconds > 0 {
                try await Task.sleep(for: .seconds(graceSeconds))
            }
            guard !Task.isCancelled,
                  let currentRoom = appState.activeRoom,
                  currentRoom.id == room.id,
                  currentRoom.normalizedStatus == "playing",
                  !currentRoom.isGamePaused,
                  isTimeExpired(currentRoom) else { return }
            appState.activeRoom = try await appState.client.finalizeExpiredRoom(room: currentRoom)
        } catch is CancellationError {
            return
        } catch {
            // Another participant may have already committed the terminal state.
            if let refreshed = try? await appState.client.refreshRoom(id: room.id) {
                appState.activeRoom = refreshed
            } else {
                status = error.localizedDescription.uppercased()
            }
        }
    }

    private func requestVote(_ room: GameRoom) async {
        guard !room.isGamePaused, !isTimeExpired(room) else { return }
        guard let user = appState.user else { return }
        if appState.shouldUsePreviewData {
            status = copy.voteRequestedStatus
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isRequestingVote = true
        defer { isRequestingVote = false }
        do {
            appState.activeRoom = try await appState.client.requestVote(room: room, user: user)
            status = copy.voteRequestedStatus
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func castVote(_ room: GameRoom, targetEmail: String) async {
        guard !room.isGamePaused, !isTimeExpired(room) else { return }
        guard let user = appState.user else { return }
        guard targetEmail.caseInsensitiveCompare(user.email) != .orderedSame else { return }
        if appState.shouldUsePreviewData {
            status = copy.voteLockedStatus
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isCastingVote = true
        defer { isCastingVote = false }
        do {
            appState.activeRoom = try await appState.client.castDetectiveVote(room: room, user: user, targetEmail: targetEmail)
            status = copy.voteLockedStatus
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func submitSpyGuess(_ room: GameRoom, word: String) async {
        guard !room.isGamePaused else { return }
        guard !isTimeExpired(room) || postGameGuessSecondsRemaining(room) > 0 else { return }
        guard let user = appState.user else { return }
        if appState.shouldUsePreviewData {
            showSpyGuess = false
            status = copy.spyGuessLocked
            let isFinished = room.normalizedStatus == "ended" || room.normalizedStatus == "finished"
            if isFinished {
                HapticManager.shared.fire(.notification(.success))
            } else {
                HapticManager.shared.fire(.notification(.success))
            }
            return
        }
        isSubmittingSpyGuess = true
        defer { isSubmittingSpyGuess = false }
        do {
            let updated = try await appState.client.submitSpyGuess(room: room, user: user, guess: word)
            appState.activeRoom = updated
            showSpyGuess = false
            status = copy.spyGuessLocked
            let isFinished = updated.normalizedStatus == "ended" || updated.normalizedStatus == "finished"
            if isFinished {
                HapticManager.shared.fire(.notification(.success))
            } else {
                HapticManager.shared.fire(.notification(.success))
            }
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func leaveRoom(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            leaveLocally()
            return
        }
        guard let user = appState.user else {
            leaveLocally()
            return
        }

        let operation = isHost(room) ? RoomSyncOperation.closingRoom : .leavingRoom
        guard appState.beginRoomSync(operation) else { return }
        defer { appState.endRoomSync(operation) }
        await Task.yield()

        do {
            try await appState.client.leaveRoom(room: room, user: user)
            leaveLocally()
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func leaveLocally(providesFeedback: Bool = true) {
        if providesFeedback {
            HapticManager.shared.fire(.buttonPress)
        }
        appState.activeRoom = nil
        appState.selectedTab = .home
        status = ""
        revealRole = false
    }
}

private struct PreparedRoomQRCode: @unchecked Sendable {
    let payload: String
    let image: UIImage
}

private struct RoomQRFlipFace: @MainActor AnimatableModifier {
    var progress: Double
    let isBack: Bool
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let angle = isBack
            ? -180 + (clampedProgress * 180)
            : clampedProgress * 180
        let faceOpacity = reduceMotion
            ? (isBack ? clampedProgress : 1 - clampedProgress)
            : (isBack
                ? (clampedProgress >= 0.5 ? 1.0 : 0.0)
                : (clampedProgress < 0.5 ? 1.0 : 0.0))

        content
            .opacity(faceOpacity)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.72
            )
    }
}

private struct RoomQRFlipSheen: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let normalizedProgress = min(max((progress + 1.12) / 2.24, 0), 1)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.035),
                            SpyTheme.red.opacity(0.18),
                            Color.white.opacity(0.075),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 84, height: proxy.size.height + 28)
                .rotationEffect(.degrees(11))
                .blur(radius: 3)
                .offset(
                    x: -110 + (normalizedProgress * (proxy.size.width + 220)),
                    y: -14
                )
                .blendMode(.screen)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RoomQRScanBeam: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    @State private var beamAtEnd = false

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            SpyTheme.red.opacity(0.12),
                            SpyTheme.red.opacity(0.68),
                            SpyTheme.red.opacity(0.12),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .shadow(color: SpyTheme.red.opacity(0.62), radius: 7)
                .offset(y: beamAtEnd ? (proxy.size.height / 2) + 14 : -(proxy.size.height / 2) - 14)
        }
        .mask {
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(isActive ? 1 : 0.34)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isActive) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                beamAtEnd = false
            }

            guard isActive, !reduceMotion else { return }
            await Task.yield()

            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                beamAtEnd = true
            }
        }
    }
}

private struct RoomCodeSpoilerField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isActive)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                for index in 0..<80 {
                    let seed = Double(index)
                    let column = CGFloat(index % 20)
                    let row = CGFloat(index / 20)
                    let xJitter = CGFloat((sin(seed * 2.41) + 1) * 0.26)
                    let yJitter = CGFloat((cos(seed * 1.73) + 1) * 0.22)
                    let xUnit = (column + 0.22 + xJitter) / 20
                    let yUnit = (row + 0.28 + yJitter) / 4
                    let speed = 0.72 + (seed.truncatingRemainder(dividingBy: 9.0) * 0.07)
                    let phase = seed * 1.71
                    let driftX = CGFloat(sin((time * speed) + phase) * (5 + seed.truncatingRemainder(dividingBy: 8.0)))
                    let driftY = CGFloat(cos((time * speed * 0.72) + phase) * (3 + seed.truncatingRemainder(dividingBy: 5.0)))
                    let diameter = CGFloat(2.6 + seed.truncatingRemainder(dividingBy: 3.0))
                    let pulse = 0.58 + (sin((time * 1.35) + phase) + 1) * 0.18
                    let rect = CGRect(
                        x: (xUnit * max(size.width - diameter, 0)) + driftX,
                        y: (yUnit * max(size.height - diameter, 0)) + driftY,
                        width: diameter,
                        height: diameter
                    )

                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(min(max(pulse, 0.34), 0.94)))
                    )
                }
            }
        }
        .mask {
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .shadow(color: .white.opacity(0.34), radius: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WaitingFooterPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

private enum RoomWordSource: Equatable {
    case none
    case generated
    case saved(String)
}

private enum RoomPackLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private enum OnlineSetupField: Hashable {
    case theme
}

private enum OnlineSetupPanel: Hashable {
    case mission
    case mode
    case timing
    case players
    case intel
    case controls
}

/// Erases each large setup panel at a stable boundary. On physical iOS 26.4,
/// nesting all six concrete panel types inside the former generic helper could
/// recurse through Swift metadata instantiation and overflow the main stack.
private struct OnlineSetupSlotView: View {
    let content: AnyView
    let dimmed: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            content
                .modifier(OnlineSetupFocusEffect(dimmed: dimmed))

            if dimmed {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
            }
        }
    }
}

private struct OnlineSetupFocusEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.20 : 1)
            .scaleEffect(dimmed ? 0.94 : 1)
            .blur(radius: dimmed ? 2 : 0)
            .allowsHitTesting(!dimmed)
            .animation(
                reduceMotion ? nil : .smooth(duration: dimmed ? 0.20 : 0.24),
                value: dimmed
            )
    }
}

private enum RoomWordCountMode: String, CaseIterable, Identifiable {
    case recommended
    case custom

    var id: String { rawValue }
}

private enum RoomThemeOperation {
    case generate
    case expand
}

private struct RoomPoolSnapshot {
    let category: String
    let source: String
    let words: [String]
    let countLabel: String
    let emptyMessage: String
}

private extension Array where Element == String {
    var roomCleanWords: [String] {
        var seen = Set<String>()
        return compactMap { raw in
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            let key = word.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return word
        }
    }
}

private struct SpyGuessSheet: View {
    let room: GameRoom
    let isSubmitting: Bool
    let copy: GameCopy
    let onGuess: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var words: [WordPoolEntry] {
        room.enabledWordPool.sorted {
            $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
        }
    }

    var body: some View {
        ZStack {
            SpyTheme.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(copy.spyGuessEyebrow)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker()
                        Text(copy.chooseWord)
                            .font(.system(size: 28, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(lines: 2, scale: 0.58)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                    .frame(width: 54)
                }

                Text(copy.spyGuessHint)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineSpacing(3)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(words) { entry in
                            Button {
                                onGuess(entry.word)
                            } label: {
                                HStack {
                                    Text(entry.word.uppercased())
                                        .font(.system(size: 11, weight: .bold, design: .default))
                                        .tracking(0.04)
                                        .foregroundStyle(.white)
                                        .spyFitted(lines: 2, scale: 0.54)
                                    Spacer()
                                    if isSubmitting {
                                        SpySpinner(size: 18, accent: SpyTheme.red)
                                    } else {
                                        Image(systemName: "scope")
                                            .foregroundStyle(SpyTheme.red)
                                    }
                                }
                            }
                            .buttonStyle(SpyButtonStyle(variant: .ghost))
                            .disabled(isSubmitting)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
            .padding(20)
        }
    }
}
