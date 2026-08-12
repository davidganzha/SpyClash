import SwiftUI

enum LocalGameDeadlineOutcome: Equatable {
    case continuePlaying(remainingSeconds: Int)
    case spyWins
}

enum LocalGameDeadlinePolicy {
    static func outcome(afterTickFrom currentSeconds: Int) -> LocalGameDeadlineOutcome {
        let remainingSeconds = max(currentSeconds - 1, 0)
        return remainingSeconds == 0
            ? .spyWins
            : .continuePlaying(remainingSeconds: remainingSeconds)
    }
}

enum LocalGameInterruptionPolicy {
    static func shouldResumeTimerAfterCardReview(
        wasRunning: Bool,
        phaseIsPlaying: Bool,
        remainingSeconds: Int
    ) -> Bool {
        wasRunning && phaseIsPlaying && remainingSeconds > 0
    }
}

enum LocalGameAccusationPolicy {
    enum Outcome: Equatable {
        case continuePlaying
        case spyWins
        case detectivesWin
        case invalidAccusation
    }

    static func caughtSpy(at index: Int, spyFlags: [Bool]) -> Bool {
        guard spyFlags.indices.contains(index) else { return false }
        return spyFlags[index]
    }

    /// Local pass-and-play follows the same elimination rule as Online: every
    /// accused active player leaves the round, regardless of role. Detectives
    /// win only after the last spy is gone; spies win when they reach parity.
    static func outcome(
        accusing index: Int,
        spyFlags: [Bool],
        eliminatedIndices: Set<Int> = []
    ) -> Outcome {
        guard spyFlags.indices.contains(index), !eliminatedIndices.contains(index) else {
            return .invalidAccusation
        }

        let remainingIndices = spyFlags.indices.filter {
            $0 != index && !eliminatedIndices.contains($0)
        }
        let remainingSpies = remainingIndices.filter { spyFlags[$0] }.count
        let remainingDetectives = remainingIndices.count - remainingSpies

        if remainingSpies == 0 { return .detectivesWin }
        if remainingSpies >= remainingDetectives { return .spyWins }
        return .continuePlaying
    }
}

enum LocalSpyAssignmentPolicy {
    static func randomSpyIndices(playerCount: Int, requestedSpyCount: Int) -> [Int] {
        guard playerCount >= 3 else { return [] }
        let count = min(
            max(requestedSpyCount, 1),
            GameRoom.maximumSpyCount(forPlayerCount: playerCount)
        )
        return Array((0..<playerCount).shuffled().prefix(count)).sorted()
    }
}

struct LocalGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var players = ["", "", ""]
    @State private var avatars = ["🕵️", "👤", "🤖"]
    @State private var duration = 10.0
    @State private var spyCount = 1.0
    @State private var spiesKnowEachOther = false
    @State private var wordCount = 25.0
    @State private var mode = LocalMode.questions
    @State private var selectedPackID = "builtin"
    @State private var builtinPreviewCategory = "CLASSIC"
    @State private var customTheme = ""
    @State private var generatedPack: GeneratedWordPack?
    @State private var localSourceBeforeCustomTheme = "builtin"
    @State private var packs: [WordPack] = []
    @State private var status = ""
    @State private var isGenerating = false
    @State private var isExpandingLocalThemePool = false
    @State private var isSavingGeneratedPack = false
    @State private var localThemeError = ""
    @State private var localWordCountMode = LocalWordCountMode.recommended
    @State private var localCustomWordCount = 25.0
    @State private var localPoolExpanded = false
    @State private var localThemeRequestID = UUID()
    @State private var localPreviewPulse = false
    @State private var localPoolDraft: LocalPoolDraft?
    @State private var localNewPoolWord = ""
    @State private var disabledPoolWordKeys: Set<String> = []
    @State private var playerIDs = [UUID(), UUID(), UUID()]
    @State private var armedPlayerID: UUID?
    @State private var draggingPlayerID: UUID?
    @State private var draggingPlayerIndex: Int?
    @State private var playerDragResidualY: CGFloat = 0
    @State private var playerLastDragLocationY: CGFloat?
    @State private var animatedLocalSetupPanel: LocalSetupPanel?
    @FocusState private var focusedLocalSetupField: LocalSetupField?

    @State private var phase = LocalPhase.setup
    @State private var session: LocalSession?
    @State private var revealIndex = 0
    @State private var cardRevealed = false
    @State private var secondsRemaining = 0
    @State private var guessSecondsRemaining = 30
    @State private var showSpyGuessOptions = false
    @State private var spyGuess: String?
    @State private var pendingSpyGuess: String?
    @State private var questionIndex = 0
    @State private var accusedIndex: Int?
    @State private var eliminatedPlayerIndices: Set<Int> = []
    @State private var winner: LocalWinner?
    @State private var timerTask: Task<Void, Never>?
    @State private var isLocalGamePaused = false
    @State private var forgotCardRequest: LocalForgotCardRequest?
    @State private var resumeTimerAfterCardReview = false
    @State private var associationOrder: [Int] = []
    @State private var associationStep = 0
    @State private var associationRouletteDone = true
    @State private var handledLocalSetupRequestID = 0

    private var copy: LocalGameCopy {
        appState.language.localGame
    }

    private var previewLocalDurationSeconds: Int? {
        guard appState.shouldUsePreviewData else { return nil }
        return ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--spyclash-preview-local-duration-seconds=") })
            .flatMap { Int($0.replacingOccurrences(of: "--spyclash-preview-local-duration-seconds=", with: "")) }
    }

    private var previewLocalGuessSeconds: Int? {
        guard appState.shouldUsePreviewData else { return nil }
        return ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--spyclash-preview-local-guess-seconds=") })
            .flatMap { Int($0.replacingOccurrences(of: "--spyclash-preview-local-guess-seconds=", with: "")) }
    }

    private var previewLocalMode: LocalMode? {
        guard appState.shouldUsePreviewData,
              let rawValue = previewArgumentValue(prefix: "--spyclash-preview-local-mode=")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return nil }

        switch rawValue {
        case "association", "associations", "classic":
            return .associations
        case "question", "questions":
            return .questions
        default:
            return nil
        }
    }

    var body: some View {
        localLifecycleBody
            .fullScreenCover(item: $forgotCardRequest, onDismiss: finishForgotCardReview) { request in
                LocalForgotCardRecoveryView(
                    request: request,
                    copy: copy,
                    language: appState.language
                )
            }
    }

    private var localLifecycleBody: some View {
        localBody
            .task {
                restoreLocalSettings()
                applyPreviewLocalOverrides()
                consumeLocalSetupRequestIfNeeded()
                await loadPacks()
            }
            .task(id: appState.wordPacksRevision) {
                guard appState.wordPacksRevision > 0 else { return }
                await loadPacks()
            }
            .onAppear {
                withAnimation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
                ) {
                    localPreviewPulse = true
                }
                updateLocalShellChromeSuppression()
            }
            .onChange(of: players) { _, _ in
                spyCount = min(spyCount, Double(localMaximumSpyCount))
                persistLocalSettings()
            }
            .onChange(of: avatars) { _, _ in persistLocalSettings() }
            .onChange(of: duration) { _, _ in persistLocalSettings() }
            .onChange(of: spyCount) { _, _ in persistLocalSettings() }
            .onChange(of: spiesKnowEachOther) { _, _ in persistLocalSettings() }
            .onChange(of: wordCount) { _, _ in persistLocalSettings() }
            .onChange(of: mode) { _, _ in persistLocalSettings() }
            .onChange(of: selectedPackID) { _, _ in persistLocalSettings() }
            .onChange(of: customTheme) { _, _ in persistLocalSettings() }
            .onChange(of: localWordCountMode) { _, _ in persistLocalSettings() }
            .onChange(of: localCustomWordCount) { _, _ in persistLocalSettings() }
            .onChange(of: phase) { _, newPhase in handleLocalPhaseChange(newPhase) }
            .onChange(of: appState.localSetupRequestID) { _, _ in consumeLocalSetupRequestIfNeeded() }
            .onChange(of: status) { _, message in publishLocalToast(message) }
            .onChange(of: localThemeError) { _, message in publishLocalThemeError(message) }
            .onDisappear(perform: handleLocalDisappear)
    }

    private func handleLocalPhaseChange(_ newPhase: LocalPhase) {
        updateLocalShellChromeSuppression()
        guard newPhase != .playing else { return }
        timerTask?.cancel()
        timerTask = nil
        isLocalGamePaused = false
        forgotCardRequest = nil
        resumeTimerAfterCardReview = false
    }

    private func handleLocalDisappear() {
        timerTask?.cancel()
        appState.isShellChromeSuppressed = false
    }

    @ViewBuilder
    private var localBody: some View {
        if phase == .cards {
            cardsScene
        } else if phase.isGameProcess {
            localProcessScene
        } else {
            chromedLocalBody
        }
    }

    private var chromedLocalBody: some View {
        PageChrome(
            eyebrow: copy.eyebrow,
            status: phase.status(copy),
            scrollTarget: localSetupScrollTarget
        ) {
            VStack(alignment: .leading, spacing: 18) {
                switch phase {
                case .setup:
                    setupView
                case .cards:
                    cardsView
                case .playing:
                    playingView
                case .spyGuess:
                    spyGuessView
                case .voting:
                    votingView
                case .results:
                    resultsView
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: phase)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if phase == .setup, focusedLocalSetupField == nil {
                localLobbyActionBar
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(reduceMotion ? nil : SpyMotion.page, value: focusedLocalSetupField)
    }

    private var cardsScene: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cardsView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private var localProcessScene: some View {
        GeometryReader { proxy in
            ZStack {
                SpyBackground()

                localProcessContent
                    .padding(.horizontal, 16)
                    .padding(.top, max(proxy.safeAreaInsets.top + 10, 32))
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom + 12, 20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var localProcessContent: some View {
        switch phase {
        case .playing:
            playingView
        case .spyGuess:
            spyGuessView
        case .voting:
            votingView
        case .results:
            resultsView
        default:
            EmptyView()
        }
    }

    private var setupView: some View {
        ZStack(alignment: .top) {
            if localSetupHasActiveCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissLocalSetupCapture()
                    }
            }

            VStack(alignment: .leading, spacing: SpyLobbyVisualLanguage.sectionSpacing) {
                localSetupSlot(.mission) {
                    localMissionPanel
                        .spyWebEntrance(
                            delay: SpyLobbyVisualLanguage.EntranceDelay.hero,
                            duration: 0.46,
                            y: 12
                        )
                }
                localSetupSlot(.mode) {
                    localModePanel
                        .spyWebEntrance(
                            delay: SpyLobbyVisualLanguage.EntranceDelay.mode,
                            duration: 0.42,
                            y: 14
                        )
                }
                if GameRoom.canChooseSpyCount(forPlayerCount: players.count) {
                    localSetupSlot(.roles) {
                        localSpySettingsPanel
                            .spyWebEntrance(
                                delay: SpyLobbyVisualLanguage.EntranceDelay.roles,
                                duration: 0.42,
                                y: 14
                            )
                    }
                }
                localSetupSlot(.timing) {
                    localTimingPanel
                        .spyWebEntrance(
                            delay: SpyLobbyVisualLanguage.EntranceDelay.timing,
                            duration: 0.42,
                            y: 14
                        )
                }
                localSetupSlot(.players) {
                    localPlayersPanel
                        .spyWebEntrance(
                            delay: SpyLobbyVisualLanguage.EntranceDelay.players,
                            duration: 0.42,
                            y: 14
                        )
                }
                .id(localPlayersScrollTarget)
                localSetupSlot(.intel) {
                    localIntelPanel
                        .spyWebEntrance(
                            delay: SpyLobbyVisualLanguage.EntranceDelay.intel,
                            duration: 0.42,
                            y: 14
                        )
                }
                .id(localIntelScrollTarget)
            }
        }
        .frame(maxWidth: SpyLobbyVisualLanguage.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .animation(reduceMotion ? nil : localSetupFocusAnimation, value: animatedLocalSetupPanel)
        .onAppear {
            animatedLocalSetupPanel = focusedLocalSetupPanel
        }
        .onChange(of: focusedLocalSetupPanel) { _, newPanel in
            withAnimation(reduceMotion ? nil : localSetupFocusAnimation) {
                animatedLocalSetupPanel = newPanel
            }
        }
    }

    private var localSetupFocusAnimation: Animation {
        .smooth(duration: 0.34)
    }

    @ViewBuilder
    private func localSetupSlot<Content: View>(_ panel: LocalSetupPanel, @ViewBuilder content: () -> Content) -> some View {
        let dimmed = localShouldDimPanel(panel)

        ZStack {
            content()
                .modifier(SpyLobbySetupFocusEffect(dimmed: dimmed))

            if dimmed {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissLocalSetupCapture()
                    }
            }
        }
    }

    private var localSetupHasActiveCapture: Bool {
        focusedLocalSetupField != nil || draggingPlayerID != nil
    }

    private func dismissLocalSetupCapture() {
        withAnimation(reduceMotion ? nil : localSetupFocusAnimation) {
            animatedLocalSetupPanel = nil
            focusedLocalSetupField = nil
        }
        resetPlayerDragState()
    }

    private var localPlayersScrollTarget: String { "local-lobby-players" }
    private var localIntelScrollTarget: String { "local-lobby-intel" }
    private var localThemeScrollTarget: String { "local-lobby-theme-input" }
    private var localPoolWordScrollTarget: String { "local-lobby-pool-word-input" }

    private func localPlayerScrollTarget(_ index: Int) -> String {
        "local-lobby-player-\(index)"
    }

    private var localSetupScrollTarget: String? {
        switch focusedLocalSetupField {
        case .player(let index):
            localPlayerScrollTarget(index)
        case .theme:
            localThemeScrollTarget
        case .poolWord:
            localPoolWordScrollTarget
        case nil:
            nil
        }
    }

    private var focusedLocalSetupPanel: LocalSetupPanel? {
        if draggingPlayerID != nil {
            return .players
        }

        switch focusedLocalSetupField {
        case .player:
            return .players
        case .theme, .poolWord:
            return .intel
        case nil:
            return nil
        }
    }

    private func localShouldDimPanel(_ panel: LocalSetupPanel) -> Bool {
        guard let animatedLocalSetupPanel else { return false }
        return animatedLocalSetupPanel != panel
    }

    private var localMissionPanel: some View {
        let accent = mode == .questions ? SpyTheme.red : SpyTheme.amber

        return SpyLobbyHeroSurface(accent: accent) {
            VStack(alignment: .leading, spacing: 0) {
                SpyLobbyHeroHeader(
                    title: localized(en: "PASS & PLAY", ru: "ПЕРЕДАВАЙ И ИГРАЙ", es: "PASA Y JUEGA", uk: "ПЕРЕДАВАЙ І ГРАЙ"),
                    status: localized(en: "OFFLINE", ru: "ОФЛАЙН", es: "SIN RED", uk: "ОФЛАЙН"),
                    count: players.count,
                    accent: accent,
                    statusAccent: SpyTheme.green
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                Spacer(minLength: 14)

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            localMissionIdentity
                            localMissionOperativeCount(alignment: .leading)
                        }
                    } else {
                        HStack(alignment: .bottom, spacing: 18) {
                            localMissionIdentity
                            Spacer(minLength: 4)
                            localMissionOperativeCount(alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 22)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    localMissionBadge(
                        mode == .questions
                            ? localized(en: "QUESTIONS", ru: "ВОПРОСЫ", es: "PREGUNTAS", uk: "ЗАПИТАННЯ")
                            : localized(en: "ASSOCIATIONS", ru: "АССОЦИАЦИИ", es: "ASOCIACIONES", uk: "АСОЦІАЦІЇ"),
                        color: accent
                    )
                    localMissionBadge(localDurationLabel, color: SpyTheme.muted)
                    Spacer(minLength: 0)
                    localMissionBadge(
                        localized(en: "1 DEVICE", ru: "1 ТЕЛЕФОН", es: "1 DISPOSITIVO", uk: "1 ПРИСТРІЙ"),
                        color: SpyTheme.green
                    )
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
    }

    private var localMissionIdentity: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(localized(en: "LOCAL MISSION", ru: "ЛОКАЛЬНАЯ МИССИЯ", es: "MISION LOCAL", uk: "ЛОКАЛЬНА МІСІЯ"))
                .font(SpyTheme.brandFont(size: 32))
                .tracking(1.2)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.66)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

            Text(localized(
                en: "One device. Secret roles. No network required.",
                ru: "Один телефон. Тайные роли. Сеть не нужна.",
                es: "Un dispositivo. Roles secretos. Sin red.",
                uk: "Один пристрій. Таємні ролі. Мережа не потрібна."
            ))
            .font(.system(size: 11, weight: .semibold, design: .default))
            .lineSpacing(3)
            .foregroundStyle(SpyTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localMissionOperativeCount(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(String(format: "%02d", players.count))
                .font(SpyTheme.brandFont(size: dynamicTypeSize.isAccessibilitySize ? 24 : 32))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Text(localized(en: "OPERATIVES", ru: "ОПЕРАТИВНИКИ", es: "AGENTES", uk: "ОПЕРАТИВНИКИ"))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized(
            en: "\(players.count) operatives",
            ru: "Оперативников: \(players.count)",
            es: "\(players.count) agentes",
            uk: "Оперативників: \(players.count)"
        ))
    }

    private func localMissionBadge(_ title: String, color: Color) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.08)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(color.opacity(0.07))
            .overlay(Rectangle().stroke(color.opacity(0.28), lineWidth: 1))
    }

    private var localModePanel: some View {
        localSetupPanel(accent: mode == .questions ? SpyTheme.red : SpyTheme.amber) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(systemImage: "gearshape.fill", title: localized(en: "GAME MODE", ru: "РЕЖИМ ИГРЫ", es: "MODO DE JUEGO", uk: "РЕЖИМ ГРИ"))

                HStack(spacing: 10) {
                    localModeOption(.questions, symbol: "?")
                    localModeOption(.associations, symbol: "💭")
                }
            }
        }
    }

    private var localMaximumSpyCount: Int {
        GameRoom.maximumSpyCount(forPlayerCount: players.count)
    }

    private var localSpySettingsPanel: some View {
        let selectedCount = min(max(Int(spyCount.rounded()), 1), localMaximumSpyCount)

        return localSetupPanel(accent: selectedCount > 1 ? SpyTheme.red : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader(
                        systemImage: "person.crop.circle.badge.questionmark",
                        title: localized(en: "SPIES", ru: "ШПИОНЫ", es: "ESPIAS", uk: "ШПИГУНИ")
                    )
                    Spacer()
                    Text("\(selectedCount)")
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundStyle(selectedCount > 1 ? SpyTheme.red : .white)
                        .contentTransition(.numericText())
                        .accessibilityHidden(true)
                }

                SpyWebSlider(
                    value: Binding(
                        get: { Double(selectedCount) },
                        set: { newValue in
                            spyCount = Double(
                                min(max(Int(newValue.rounded()), 1), localMaximumSpyCount)
                            )
                        }
                    ),
                    range: 1...Double(localMaximumSpyCount),
                    language: appState.language,
                    step: 1,
                    accessibilityLabel: localized(
                        en: "Number of spies",
                        ru: "Количество шпионов",
                        es: "Numero de espias",
                        uk: "Кількість шпигунів"
                    ),
                    accessibilityIdentifier: "localGame.spyCountSlider"
                )
                .disabled(localMaximumSpyCount == 1)

                HStack {
                    Text("1")
                    Spacer()
                    Text("\(localMaximumSpyCount)")
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .accessibilityHidden(true)

                Toggle(isOn: $spiesKnowEachOther) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localized(
                            en: "SPIES KNOW EACH OTHER",
                            ru: "ШПИОНЫ ЗНАЮТ ДРУГ ДРУГА",
                            es: "LOS ESPIAS SE CONOCEN",
                            uk: "ШПИГУНИ ЗНАЮТЬ ОДИН ОДНОГО"
                        ))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        Text(localized(
                            en: "Off by default. Teammates appear only after the spy reveals their card.",
                            ru: "По умолчанию выключено. Сообщники видны только после открытия карты шпиона.",
                            es: "Desactivado por defecto. Los aliados aparecen solo al revelar la carta.",
                            uk: "Типово вимкнено. Напарники зʼявляться лише після відкриття картки шпигуна."
                        ))
                        .font(.system(size: 9, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(SpyTheme.red)
                .accessibilityIdentifier("localGame.spiesKnowEachOtherToggle")

                if selectedCount > 1 {
                    Text(localized(
                        en: "ALL SPIES SHARE ONE WIN AND ONE GUESS",
                        ru: "У ВСЕХ ШПИОНОВ ОБЩАЯ ПОБЕДА И ОДНА ПОПЫТКА",
                        es: "TODOS LOS ESPIAS COMPARTEN VICTORIA Y UN INTENTO",
                        uk: "УСІ ШПИГУНИ МАЮТЬ СПІЛЬНУ ПЕРЕМОГУ Й ОДНУ СПРОБУ"
                    ))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(SpyTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var localPlayersPanel: some View {
        localSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(systemImage: "person.2.fill", title: "\(localized(en: "PLAYERS", ru: "ИГРОКИ", es: "JUGADORES", uk: "ГРАВЦІ")) (\(players.count))")

                VStack(spacing: 8) {
                    ForEach(localPlayerRows, id: \.id) { row in
                        localPlayerEditorRow(index: row.index, id: row.id)
                    }
                }

                if players.count < 3 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .black))
                        Text(localMinimumPlayersMessage)
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

                if players.count < 10 {
                    Button {
                        addPlayer()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .black))
                            Text(localized(en: "ADD PLAYER", ru: "ДОБАВИТЬ ИГРОКА", es: "ANADIR JUGADOR", uk: "ДОДАТИ ГРАВЦЯ"))
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(0.06)
                                .spyFitted(lines: 1, scale: 0.70, alignment: .center)
                        }
                        .foregroundStyle(SpyTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .spyCutCard(cut: 8, fill: Color.clear, stroke: SpyTheme.strokeDim)
                        .contentShape(CutCornerShape(cut: 8))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("localGame.addPlayer")
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: playerIDs)
        }
    }

    private var localPlayerRows: [(index: Int, id: UUID)] {
        players.indices.map { index in
            (index, playerIDs[safe: index] ?? UUID())
        }
    }

    private func localPlayerEditorRow(index: Int, id: UUID) -> some View {
        let isArmed = armedPlayerID == id
        let isDragging = draggingPlayerID == id

        return HStack(spacing: 8) {
            localPlayerDragHandle(id: id)

            Text("\(index + 1)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.78))
                .frame(width: 16)

            Button {
                cycleAvatar(index)
            } label: {
                Text(avatars[safe: index] ?? "🕵️")
                    .font(.system(size: 23))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SpyTheme.strokeStrong.opacity(0.74), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(
                en: "Change avatar for player \(index + 1)",
                ru: "Изменить аватар игрока \(index + 1)",
                es: "Cambiar avatar del jugador \(index + 1)",
                uk: "Змінити аватар гравця \(index + 1)"
            ))
            .accessibilityHint(localized(
                en: "Cycles through available avatars",
                ru: "Переключает доступные аватары",
                es: "Cambia entre los avatares disponibles",
                uk: "Перемикає доступні аватари"
            ))
            .accessibilityIdentifier("localGame.player.\(index).avatar")

            localPlayerNameField(index: index)

            if players.count > 2 {
                localRemovePlayerButton(index: index)
            }
        }
        .opacity(isDragging ? 0.72 : 1)
        .offset(y: isDragging ? playerDragResidualY : 0)
        .scaleEffect(isDragging ? 1.015 : (isArmed ? 0.985 : 1))
        .zIndex(isDragging ? 10 : 0)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: armedPlayerID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: draggingPlayerIndex)
        .animation(nil, value: playerDragResidualY)
    }

    private func localPlayerDragHandle(id: UUID) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.045), lineWidth: 1)
                )

            Text("⋮⋮")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .tracking(-0.08)
                .foregroundStyle(SpyTheme.dim.opacity(0.82))
                .rotationEffect(.degrees(0.01))
        }
        .frame(width: 44, height: 48)
        .contentShape(Rectangle())
        .highPriorityGesture(playerReorderGesture(playerID: id))
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(localized(en: "Reorder player", ru: "Переставить игрока", es: "Reordenar jugador", uk: "Перемістити гравця"))
        .accessibilityHint(localized(en: "Hold and drag to reorder", ru: "Зажми и перетащи, чтобы изменить порядок", es: "Mantén y arrastra para reordenar", uk: "Затисни й перетягни, щоб змінити порядок"))
        .accessibilityAction(named: Text(localized(en: "Move up", ru: "Переместить выше", es: "Mover arriba", uk: "Перемістити вище"))) {
            moveLocalPlayerForAccessibility(id: id, offset: -1)
        }
        .accessibilityAction(named: Text(localized(en: "Move down", ru: "Переместить ниже", es: "Mover abajo", uk: "Перемістити нижче"))) {
            moveLocalPlayerForAccessibility(id: id, offset: 1)
        }
    }

    private func localPlayerNameField(index: Int) -> some View {
        TextField(
            localized(en: "Player \(index + 1)", ru: "Игрок \(index + 1)", es: "Jugador \(index + 1)", uk: "Гравець \(index + 1)"),
            text: $players[index]
        )
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .font(.system(size: 14, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .tint(SpyTheme.red)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SpyTheme.strokeStrong.opacity(0.78), lineWidth: 1)
        )
        .layoutPriority(1)
        .submitLabel(.done)
        .focused($focusedLocalSetupField, equals: .player(index))
        .id(localPlayerScrollTarget(index))
        .accessibilityIdentifier("localGame.player.\(index).name")
    }

    private func moveLocalPlayerForAccessibility(id: UUID, offset: Int) {
        guard let source = playerIDs.firstIndex(of: id) else { return }
        let destination = source + offset
        guard players.indices.contains(destination) else {
            HapticManager.shared.fire(.notification(.warning))
            return
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
            movePlayer(from: source, to: destination)
        }
        HapticManager.shared.fire(.tabSelection)
    }

    private func resetPlayerDragState() {
        armedPlayerID = nil
        draggingPlayerID = nil
        draggingPlayerIndex = nil
        playerDragResidualY = 0
        playerLastDragLocationY = nil
    }

    private func syncPlayerIDsWithPlayers() {
        if playerIDs.count < players.count {
            playerIDs.append(contentsOf: (0..<(players.count - playerIDs.count)).map { _ in UUID() })
        } else if playerIDs.count > players.count {
            playerIDs = Array(playerIDs.prefix(players.count))
        }
    }

    private func updateLocalShellChromeSuppression() {
        appState.isShellChromeSuppressed = phase.isGameProcess
    }

    private func armPlayerDrag(playerID: UUID) {
        guard armedPlayerID != playerID else { return }
        armedPlayerID = playerID
        focusedLocalSetupField = nil
        HapticManager.shared.fire(.tabSelection)
    }

    private func updatePlayerDragLocation(_ locationY: CGFloat, playerID: UUID) {
        guard let liveIndex = playerIDs.firstIndex(of: playerID),
              players.indices.contains(liveIndex)
        else { return }

        if draggingPlayerID == nil {
            draggingPlayerID = playerID
            draggingPlayerIndex = liveIndex
            playerDragResidualY = 0
            playerLastDragLocationY = locationY
            return
        }

        guard draggingPlayerID == playerID,
              var currentIndex = playerIDs.firstIndex(of: playerID),
              players.indices.contains(currentIndex)
        else { return }

        let rowStride: CGFloat = 56
        guard let lastLocationY = playerLastDragLocationY else {
            playerLastDragLocationY = locationY
            return
        }

        let delta = locationY - lastLocationY
        playerLastDragLocationY = locationY
        playerDragResidualY += delta

        while playerDragResidualY > rowStride / 2, currentIndex < players.count - 1 {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.14)) {
                movePlayer(from: currentIndex, to: currentIndex + 1)
            }
            currentIndex += 1
            draggingPlayerIndex = currentIndex
            playerDragResidualY -= rowStride
            HapticManager.shared.fire(.tabSelection)
        }

        while playerDragResidualY < -rowStride / 2, currentIndex > 0 {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.14)) {
                movePlayer(from: currentIndex, to: currentIndex - 1)
            }
            currentIndex -= 1
            draggingPlayerIndex = currentIndex
            playerDragResidualY += rowStride
            HapticManager.shared.fire(.tabSelection)
        }
    }

    private func playerReorderGesture(playerID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    armPlayerDrag(playerID: playerID)
                case .second(true, let dragValue):
                    armPlayerDrag(playerID: playerID)
                    if let dragValue {
                        updatePlayerDragLocation(dragValue.location.y, playerID: playerID)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                    resetPlayerDragState()
                }
            }
    }

    private func localRemovePlayerButton(index: Int) -> some View {
        Button {
            removePlayer(at: index)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 40, height: 48)
                .background(Color.clear, in: CutCornerShape(cut: 6))
                .overlay(
                    CutCornerShape(cut: 6)
                        .stroke(SpyTheme.red.opacity(0.48), lineWidth: 1)
                )
        }
        .frame(width: 40, height: 48)
        .fixedSize()
        .buttonStyle(SpyWebPressStyle())
        .spyHitTarget()
        .contentShape(CutCornerShape(cut: 6))
        .accessibilityLabel(localized(en: "Remove player", ru: "Удалить игрока", es: "Eliminar jugador", uk: "Видалити гравця"))
    }

    private var localIntelPanel: some View {
        localSetupPanel(accent: SpyTheme.muted) {
            AnyView(localIntelContent)
        }
    }

    private var localIntelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            localIntelHeader
            localThemeInput
            AIThemeSuggestionStrip(
                language: appState.language,
                selectedTheme: customTheme,
                accessibilityIdentifier: "localGame.themeSuggestions"
            ) { suggestion in
                updateLocalThemeInput(suggestion)
            }
            localIntelThemeActions
            localIntelMessages
            localIntelPackSelection
            localIntelGeneratedPackControls
        }
        .background {
            if localIntelHasActiveCapture {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissLocalSetupCapture()
                    }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: localHasCustomTheme)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: localThemeAnalyzed)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: generatedPack)
    }

    private var localIntelHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            sectionHeader(systemImage: "paintpalette.fill", title: localThemeTitle)

            Spacer()

            Text(localUnlimitedLabel)
                .font(.system(size: 10, weight: .black, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.62, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var localIntelThemeActions: some View {
        if localHasCustomTheme {
            if !localThemeAnalyzed {
                localWordCountModeSelector
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            localGenerateButton
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var localIntelMessages: some View {
        if localHasCustomTheme, let generatedPack, !generatedPack.words.localCleanWords.isEmpty {
            Text(localAIWarning)
                .font(.system(size: 9, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .lineSpacing(2)
                .spyFitted(lines: 2, scale: 0.58)
        }
    }

    @ViewBuilder
    private var localIntelPackSelection: some View {
        if !localHasCustomTheme {
            localWordPackSelector
                .transition(.opacity.combined(with: .move(edge: .top)))

            Text(localRandomThemeHint)
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .lineSpacing(2)
                .spyFitted(lines: 2, scale: 0.58)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var localIntelGeneratedPackControls: some View {
        if localHasCustomTheme && localThemeAnalyzed {
            localWordsSlider
                .transition(.opacity.combined(with: .move(edge: .top)))

            if localThemeMaxWords < localThemeGenerationLimit {
                localAddMoreWordsButton
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }

        if localShouldShowPoolPreview {
            localPoolPreview
        }

        if (generatedPack?.words.localCleanWords.count ?? 0) >= 2, localHasCustomTheme {
            localSaveAsWordPackButton
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var localIntelHasActiveCapture: Bool {
        focusedLocalSetupField == .theme || focusedLocalSetupField == .poolWord
    }

    private func localSetupPanel<Content: View>(
        accent: Color = SpyTheme.muted,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SpyLobbyPanel(
            accent: accent,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            content: content
        )
    }

    private func localPackChip(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(0.02)
                    .spyFitted(lines: 2, scale: 0.68, alignment: .center)

                if let subtitle {
                    Text("(\(subtitle))")
                        .font(.system(size: 10, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? SpyTheme.red : SpyTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(isSelected ? SpyTheme.red.opacity(0.06) : SpyTheme.dark)
            .overlay(Rectangle().stroke(isSelected ? SpyTheme.red.opacity(0.50) : SpyTheme.strokeStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var localThemeInput: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(focusedLocalSetupField == .theme ? SpyTheme.red : SpyTheme.dim)
                .frame(width: 18)

            TextField("", text: localThemeTextBinding, prompt: Text(localThemePlaceholder).foregroundStyle(SpyTheme.dim))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .font(SpyTheme.mono)
                .tracking(0.04)
                .foregroundStyle(.white)
                .tint(SpyTheme.red)
                .focused($focusedLocalSetupField, equals: .theme)
                .onSubmit {
                    dismissLocalSetupCapture()
                }
                .accessibilityIdentifier("localGame.themeInput")

            if localHasCustomTheme {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) {
                        updateLocalThemeInput("")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SpyTheme.dim)
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(SpyWebPressStyle())
                .spyHitTarget()
                .accessibilityLabel(localized(en: "Clear theme", ru: "Очистить тему", es: "Limpiar tema", uk: "Очистити тему"))
            }
        }
        .id(localThemeScrollTarget)
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
        .overlay(
            CutCornerShape(cut: 9)
                .stroke(focusedLocalSetupField == .theme ? SpyTheme.red.opacity(0.86) : SpyTheme.inputBorder, lineWidth: 1)
        )
        .shadow(color: focusedLocalSetupField == .theme ? SpyTheme.red.opacity(0.12) : .clear, radius: 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: focusedLocalSetupField == .theme)
    }

    private var localThemeTextBinding: Binding<String> {
        Binding(
            get: { customTheme },
            set: { value in
                updateLocalThemeInput(value)
            }
        )
    }

    private func updateLocalThemeInput(_ value: String) {
        guard value != customTheme else { return }

        let hadCustomTheme = localHasCustomTheme
        let willHaveCustomTheme = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil
        if !hadCustomTheme, willHaveCustomTheme {
            localSourceBeforeCustomTheme = selectedPackID == "generated" ? "builtin" : selectedPackID
        }

        customTheme = value
        localThemeRequestID = UUID()
        isGenerating = false
        isExpandingLocalThemePool = false
        generatedPack = nil
        localThemeError = ""
        localPoolExpanded = false
        disabledPoolWordKeys.removeAll()
        clearLocalPoolDraft()
        status = ""

        if willHaveCustomTheme {
            selectedPackID = "builtin"
        } else {
            selectedPackID = resolvedLocalSourceBeforeCustomTheme
        }
    }

    private var resolvedLocalSourceBeforeCustomTheme: String {
        guard localSourceBeforeCustomTheme != "generated" else { return "builtin" }
        guard localSourceBeforeCustomTheme != "builtin" else { return "builtin" }
        return packs.contains(where: { $0.id == localSourceBeforeCustomTheme })
            ? localSourceBeforeCustomTheme
            : "builtin"
    }

    private var localWordCountModeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(LocalWordCountMode.allCases) { mode in
                    localWordCountOption(mode)
                }
            }

            if localWordCountMode == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localCountLabel)
                            .font(SpyTheme.micro)
                            .tracking(0.04)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker()
                        Spacer()
                        Text("\(Int(localCustomWordCount)) / 80")
                            .font(.system(size: 15, weight: .black, design: .default))
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(scale: 0.66, alignment: .trailing)
                    }

                    SpyWebSlider(
                        value: $localCustomWordCount,
                        range: 10...80,
                        language: appState.language,
                        step: 1,
                        accessibilityLabel: localized(
                            en: "Custom word count",
                            ru: "Количество слов",
                            es: "Cantidad de palabras",
                            uk: "Кількість слів"
                        ),
                        accessibilityIdentifier: "localGame.customWordCountSlider"
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(SpyTheme.dark.opacity(0.86), in: CutCornerShape(cut: 7))
                .overlay(
                    CutCornerShape(cut: 7)
                        .stroke(SpyTheme.strokeStrong.opacity(0.72), lineWidth: 1)
                )
            }
        }
    }

    private func localWordCountOption(_ mode: LocalWordCountMode) -> some View {
        let isActive = localWordCountMode == mode

        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                localWordCountMode = mode
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: mode == .recommended ? "wand.and.stars" : "slider.horizontal.3")
                    .font(.system(size: 13, weight: .black))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localWordCountModeTitle(mode))
                        .font(.system(size: 10.5, weight: .black, design: .default))
                        .tracking(0.02)
                        .spyFitted(lines: 1, scale: 0.58)

                    Text(localWordCountModeHint(mode))
                        .font(.system(size: 9.5, weight: .bold, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(isActive ? Color.white.opacity(0.70) : SpyTheme.dim)
                        .spyFitted(lines: 1, scale: 0.58)
                }

                Spacer(minLength: 0)

                if isActive {
                    Circle()
                        .fill(SpyTheme.green)
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(isActive ? SpyTheme.red : SpyTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(isActive ? SpyTheme.red.opacity(0.10) : SpyTheme.dark.opacity(0.76), in: CutCornerShape(cut: 7))
            .overlay(
                CutCornerShape(cut: 7)
                    .stroke(isActive ? SpyTheme.red.opacity(0.55) : SpyTheme.strokeStrong.opacity(0.78), lineWidth: 1)
            )
            .contentShape(CutCornerShape(cut: 7))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityLabel(localWordCountModeTitle(mode))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("localGame.wordCountMode.\(mode.rawValue)")
    }

    private var localGenerateButton: some View {
        Button {
            Task { await generateLocalTheme() }
        } label: {
            if isGenerating && !isExpandingLocalThemePool {
                SpyLoadingLabel(
                    title: localized(en: "GENERATING INTEL", ru: "ГЕНЕРАЦИЯ INTEL", es: "GENERANDO INTEL", uk: "ГЕНЕРАЦІЯ ДАНИХ"),
                    accent: .white
                )
                .frame(height: 52)
            } else {
                SpyActionLabel(title: localThemeActionTitle, systemImage: localThemeActionIcon, tracking: 0.02, lines: 2)
            }
        }
        .buttonStyle(SpyButtonStyle(variant: localThemeActionVariant))
        .disabled(!localHasCustomTheme || isGenerating)
        .opacity(localHasCustomTheme ? 1 : 0.42)
        .accessibilityIdentifier("localGame.generateThemeWords")
    }

    private var localWordPackSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if packs.isEmpty {
                Button {
                    appState.selectedTab = .packs
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Text("📦")
                            .font(.system(size: 24))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localized(en: "You don't have any word packs yet.", ru: "У тебя пока нет word packs.", es: "Aun no tienes word packs.", uk: "У тебе ще немає наборів слів."))
                                .font(.system(size: 12, weight: .bold, design: .default))
                                .tracking(0.02)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 2, scale: 0.62)
                            Text(localized(en: "+ Create first pack →", ru: "+ Создать первый пак →", es: "+ Crear primer pack →", uk: "+ Створити перший набір →"))
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .tracking(0.02)
                                .foregroundStyle(SpyTheme.red)
                                .spyFitted(lines: 2, scale: 0.62)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .spyCutCard(cut: 8, fill: SpyTheme.dark, stroke: SpyTheme.stroke)
                }
                .buttonStyle(SpyWebPressStyle())
            } else {
                Text("\(localized(en: "WORD PACKS", ru: "WORD PACKS", es: "WORD PACKS", uk: "НАБОРИ СЛІВ")) \(packs.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                    localPackChip(
                        title: localized(en: "RANDOM", ru: "СЛУЧАЙНО", es: "AZAR", uk: "ВИПАДКОВО"),
                        subtitle: nil,
                        isSelected: selectedPackID == "builtin",
                        accessibilityIdentifier: "localGame.pack.builtin"
                    ) {
                        selectLocalWordSource("builtin")
                    }

                    ForEach(packs) { pack in
                        localPackChip(
                            title: pack.name,
                            subtitle: "\(pack.words?.localCleanWords.count ?? 0)",
                            isSelected: selectedPackID == pack.id,
                            accessibilityIdentifier: "localGame.pack.\(pack.id)"
                        ) {
                            selectLocalWordSource(pack.id)
                        }
                    }
                }

                if selectedPackID != "builtin",
                   let selected = packs.first(where: { $0.id == selectedPackID }) {
                    Text("\(localized(en: "Selected", ru: "Выбрано", es: "Seleccionado", uk: "Обрано")) \(selected.name) · \(selected.words?.localCleanWords.count ?? 0) \(copy.wordsSuffix)")
                        .font(.system(size: 11, weight: .bold, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(lines: 2, scale: 0.62)
                }
            }
        }
    }

    private var localWordsSlider: some View {
        let maxWords = localThemeMaxWords
        let minimumWords = min(10, maxWords)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(localWordsLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Spacer()
                Text("\(Int(wordCount)) / \(maxWords)")
                    .font(.system(size: 16, weight: .black, design: .default))
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.66, alignment: .trailing)
            }

            Text(localThemeMetaLabel(maxWords: maxWords))
                .font(.system(size: 9, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.60)

            if minimumWords < maxWords {
                SpyWebSlider(
                    value: $wordCount,
                    range: Double(minimumWords)...Double(maxWords),
                    language: appState.language,
                    step: 1,
                    accent: SpyTheme.red,
                    accessibilityLabel: localized(
                        en: "Active words in this game",
                        ru: "Активные слова в этой игре",
                        es: "Palabras activas en esta partida",
                        uk: "Активні слова в цій грі"
                    ),
                    accessibilityIdentifier: "localGame.activeWordCountSlider"
                )
            }
        }
        .padding(12)
        .spyCutCard(
            cut: 8,
            fill: SpyTheme.panelDeep,
            stroke: Color.white.opacity(0.07)
        )
    }

    private var localAddMoreWordsButton: some View {
        Button {
            Task { await pushLocalThemeMax() }
        } label: {
            if isExpandingLocalThemePool {
                SpyLoadingLabel(
                    title: localized(en: "ADDING WORDS", ru: "ДОБАВЛЯЕМ СЛОВА", es: "ANADIENDO PALABRAS", uk: "ДОДАЄМО СЛОВА"),
                    accent: SpyTheme.amber
                )
                .frame(height: 50)
            } else {
                SpyActionLabel(
                    title: localized(en: "EXPAND POOL · +50", ru: "РАСШИРИТЬ ПУЛ · +50", es: "AMPLIAR BANCO · +50", uk: "РОЗШИРИТИ ПУЛ · +50"),
                    systemImage: "plus.circle.fill",
                    fontSize: 10.5,
                    iconSize: 13,
                    tracking: 0.02,
                    lines: 2
                )
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .outline))
        .disabled(isGenerating || localThemeMaxWords >= localThemeGenerationLimit)
        .accessibilityIdentifier("localGame.addMoreThemeWords")
    }

    private var localSaveAsWordPackButton: some View {
        Button {
            Task { await saveLocalThemePack() }
        } label: {
            if isSavingGeneratedPack {
                SpyLoadingLabel(
                    title: localized(en: "SAVING PACK", ru: "СОХРАНЕНИЕ ПАКА", es: "GUARDANDO PACK", uk: "ЗБЕРІГАЄМО НАБІР"),
                    accent: SpyTheme.green
                )
                .frame(height: 50)
            } else {
                SpyActionLabel(title: localSaveAsWordPackLabel, systemImage: "tray.and.arrow.down.fill", fontSize: 10.5, iconSize: 13, tracking: 0.02, lines: 2)
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .disabled(isSavingGeneratedPack || activeLocalWords(localPoolSnapshot.words).count < 2)
    }

    private var localTimingPanel: some View {
        localSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader(systemImage: "timer", title: copy.duration)

                    Spacer()

                    Text(localDurationLabel)
                        .font(.system(size: 22, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.66, alignment: .trailing)
                }

                SpyWebSlider(
                    value: $duration,
                    range: 1...15,
                    language: appState.language,
                    step: 1,
                    accessibilityLabel: localized(
                        en: "Round duration in minutes",
                        ru: "Длительность раунда в минутах",
                        es: "Duracion de la ronda en minutos",
                        uk: "Тривалість раунду у хвилинах"
                    ),
                    accessibilityIdentifier: "localGame.durationSlider"
                )
            }
        }
    }

    private var localLobbyActionBar: some View {
        SpyLobbyFooter {
            SpyLobbyActionRow {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    appState.selectedTab = .home
                } label: {
                    SpyLobbySecondaryActionLabel(
                        title: localized(en: "BACK", ru: "НАЗАД", es: "ATRAS", uk: "НАЗАД"),
                        systemImage: "chevron.left"
                    )
                }
                .buttonStyle(SpyLobbyFooterPressStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("localGame.back")
            } trailing: {
                Button {
                    startLocalGame()
                } label: {
                    SpyLobbyPrimaryActionLabel(
                        title: localPrimaryActionTitle,
                        detail: localPrimaryActionDetail,
                        systemImage: localPrimaryActionSystemImage,
                        isAvailable: localPrimaryActionIsEnabled
                    )
                }
                .buttonStyle(SpyLobbyFooterPressStyle())
                .frame(maxWidth: .infinity)
                .disabled(!localPrimaryActionIsEnabled)
                .accessibilityLabel(localPrimaryActionTitle)
                .accessibilityHint(localPrimaryActionDetail)
                .accessibilityIdentifier("localGame.start")
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: localPrimaryActionResolution)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: players.count >= 3)
    }

    private func publishLocalToast(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard status == message else { return }
            appState.showToast(trimmed, kind: localToastKind(trimmed))
            status = ""
        }
    }

    private func publishLocalThemeError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard localThemeError == message else { return }
            appState.showToast(trimmed, kind: .error)
            localThemeError = ""
        }
    }

    private func localToastKind(_ message: String) -> AppToastKind {
        let upper = message.uppercased()
        let errorMarkers = ["ERROR", "FAILED", "COULDN'T", "НЕ УДАЛ", "ОШИБ", "NO SE PUDO", "НЕ ВДАЛ", "ПОМИЛ"]
        if errorMarkers.contains(where: upper.contains) {
            return .error
        }
        let successMarkers = [
            "READY", "SAVED", "REROLLED", "EXPANDED", "ГОТОВ", "СОХРАН", "ОБНОВЛЕН", "РАСШИРЕН",
            "LISTO", "GUARDADO", "CAMBIADA", "AMPLIADO", "ЗБЕРЕЖ", "ОНОВЛ", "РОЗШИР"
        ]
        if successMarkers.contains(where: upper.contains) {
            return .success
        }
        return .warning
    }

    private var localPrimaryActionTitle: String {
        if players.count < 3 {
            return localized(en: "NEED 3 PLAYERS", ru: "НУЖНО 3 ИГРОКА", es: "SE NECESITAN 3", uk: "ПОТРІБНО 3 ГРАВЦІ")
        }

        switch localPrimaryActionResolution.action {
        case .generateRequired:
            return localized(en: "GENERATE THEME FIRST", ru: "СНАЧАЛА СГЕНЕРИРУЙ ТЕМУ", es: "GENERA EL TEMA PRIMERO", uk: "СПОЧАТКУ ЗГЕНЕРУЙ ТЕМУ")
        case .revealRandom:
            return localized(en: "RANDOM THEME", ru: "СЛУЧАЙНАЯ ТЕМА", es: "TEMA ALEATORIO", uk: "ВИПАДКОВА ТЕМА")
        case .dealCards:
            return localized(en: "DEAL CARDS", ru: "РАЗДАТЬ КАРТОЧКИ", es: "REPARTIR CARTAS", uk: "РОЗДАТИ КАРТКИ")
        }
    }

    private var localPrimaryActionDetail: String {
        if players.count < 3 {
            return localMinimumPlayersMessage
        }

        switch localPrimaryActionResolution.action {
        case .generateRequired:
            return localized(en: "COMPLETE INTEL ABOVE", ru: "ЗАВЕРШИ ПОДГОТОВКУ INTEL", es: "COMPLETA INTEL ARRIBA", uk: "ЗАВЕРШИ ПІДГОТОВКУ ДАНИХ")
        case .revealRandom:
            return localized(en: "REVEAL A RANDOM FIELD POOL", ru: "ОТКРЫТЬ СЛУЧАЙНЫЙ НАБОР", es: "REVELAR UN GRUPO ALEATORIO", uk: "ВІДКРИТИ ВИПАДКОВИЙ НАБІР")
        case .dealCards:
            return localized(en: "PASS THE DEVICE TO REVEAL ROLES", ru: "ПЕРЕДАВАЙ ТЕЛЕФОН ДЛЯ РАСКРЫТИЯ РОЛЕЙ", es: "PASA EL DISPOSITIVO PARA VER ROLES", uk: "ПЕРЕДАВАЙ ПРИСТРІЙ, ЩОБ ВІДКРИВАТИ РОЛІ")
        }
    }

    private var localPrimaryActionSystemImage: String {
        guard players.count >= 3 else { return "person.badge.plus" }
        return switch localPrimaryActionResolution.action {
        case .generateRequired: "sparkles"
        case .revealRandom: "shuffle"
        case .dealCards: "rectangle.portrait.on.rectangle.portrait.angled.fill"
        }
    }

    private var localPrimaryActionIsEnabled: Bool {
        players.count >= 3 && localPrimaryActionResolution.isEnabled
    }

    private var localPrimaryActionResolution: LocalLobbyPrimaryActionPolicy.Resolution {
        LocalLobbyPrimaryActionPolicy.resolve(
            hasCustomTheme: localHasCustomTheme,
            hasGeneratedPack: generatedPack != nil,
            source: localPrimaryActionSource
        )
    }

    private var localPrimaryActionSource: LocalLobbyPrimaryActionPolicy.Source {
        switch selectedPackID {
        case "builtin": .builtin
        case "generated": .generated
        default: .saved
        }
    }

    private var localMinimumPlayersMessage: String {
        localized(
            en: "ADD AT LEAST 3 PLAYERS TO START",
            ru: "ДОБАВЬ МИНИМУМ 3 ИГРОКОВ",
            es: "ANADA AL MENOS 3 JUGADORES",
            uk: "ДОДАЙ ЩОНАЙМЕНШЕ 3 ГРАВЦІВ"
        )
    }

    private var localDurationLabel: String {
        let seconds = max(Int((duration * 60).rounded()), 1)
        if seconds < 60 {
            return localized(en: "\(seconds) SEC", ru: "\(seconds) СЕК", es: "\(seconds) SEG", uk: "\(seconds) СЕК")
        }
        return "\(Int(duration)) \(copy.minuteSuffix)"
    }

    private var localNeedsGeneratedTheme: Bool {
        !customTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && generatedPack == nil
    }

    private var localHasCustomTheme: Bool {
        customTheme.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil
    }

    private var localThemeAnalyzed: Bool {
        localHasCustomTheme
            && selectedPackID == "generated"
            && (generatedPack?.words.localCleanWords.count ?? 0) >= 2
    }

    private var localThemeMaxWords: Int {
        let availableWords = localPoolDraft?.words.localCleanWords
            ?? generatedPack?.words.localCleanWords
            ?? []
        return max(availableWords.count, 2)
    }

    private var localShouldShowPoolPreview: Bool {
        if localHasCustomTheme {
            return (generatedPack?.words.localCleanWords.count ?? 0) >= 2
        }

        if selectedPackID == "builtin" {
            return (generatedPack?.words.localCleanWords.count ?? 0) >= 2
        }

        return true
    }

    private var localThemeTitle: String {
        localized(en: "THEME", ru: "ТЕМА", es: "TEMA", uk: "ТЕМА")
    }

    private var localUnlimitedLabel: String {
        localized(en: "AI INTEL", ru: "AI INTEL", es: "IA INTEL", uk: "AI-РОЗВІДКА")
    }

    private var localThemePlaceholder: String {
        localized(en: "Marvel, European countries...", ru: "Marvel, страны Европы...", es: "Marvel, paises...", uk: "Marvel, країни Європи...")
    }

    private var localCountLabel: String {
        localized(en: "// WORDS TO CREATE", ru: "// СОЗДАТЬ СЛОВ", es: "// PALABRAS A CREAR", uk: "// СЛІВ ДЛЯ СТВОРЕННЯ")
    }

    private var localWordsLabel: String {
        localized(en: "WORDS IN GAME", ru: "СЛОВ В ИГРЕ", es: "PALABRAS EN JUEGO", uk: "СЛІВ У ГРІ")
    }

    private var localAIWarning: String {
        localized(
            en: "AI may make mistakes. Double-check words before playing.",
            ru: "AI может ошибаться. Проверь слова перед игрой.",
            es: "IA puede fallar. Revisa las palabras antes de jugar.",
            uk: "AI може помилятися. Перевір слова перед грою."
        )
    }

    private var localAddWordPlaceholder: String {
        localized(en: "Add word...", ru: "Добавить слово...", es: "Agregar palabra...", uk: "Додати слово...")
    }

    private var localRandomThemeHint: String {
        localized(
            en: "Leave the field empty to play from a random or saved word pack.",
            ru: "Оставь поле пустым, чтобы играть со случайной темой или сохраненным паком.",
            es: "Deja el campo vacio para jugar con un tema aleatorio o pack guardado.",
            uk: "Залиш поле порожнім, щоб грати з випадковим або збереженим набором слів."
        )
    }

    private var localSaveAsWordPackLabel: String {
        localized(en: "SAVE AS WORDPACK", ru: "СОХРАНИТЬ КАК WORDPACK", es: "GUARDAR WORDPACK", uk: "ЗБЕРЕГТИ ЯК НАБІР СЛІВ")
    }

    private var localPoolIcon: String {
        if localHasCustomTheme { return "✨" }
        if selectedPackID != "builtin" { return "📦" }
        return "🎲"
    }

    private var localPoolLabel: String {
        if localHasCustomTheme {
            return localized(en: "GENERATED", ru: "СГЕНЕРИРОВАНО", es: "GENERADO", uk: "ЗГЕНЕРОВАНО")
        }
        if selectedPackID != "builtin" {
            return localized(en: "WORDPACK", ru: "WORDPACK", es: "WORDPACK", uk: "НАБІР СЛІВ")
        }
        return localized(en: "RANDOM THEME", ru: "СЛУЧАЙНАЯ ТЕМА", es: "TEMA ALEATORIO", uk: "ВИПАДКОВА ТЕМА")
    }

    private var localThemeActionTitle: String {
        if generatedPack?.words.localCleanWords.count ?? 0 >= 2 {
            return localized(en: "REGENERATE", ru: "СГЕНЕРИРОВАТЬ ЗАНОВО", es: "REGENERAR", uk: "ЗГЕНЕРУВАТИ ЗНОВУ")
        }
        return localized(en: "GENERATE WORDS", ru: "СГЕНЕРИРОВАТЬ СЛОВА", es: "GENERAR PALABRAS", uk: "ЗГЕНЕРУВАТИ СЛОВА")
    }

    private var localThemeActionIcon: String {
        if generatedPack?.words.localCleanWords.count ?? 0 >= 2 { return "arrow.clockwise" }
        return "sparkles"
    }

    private var localThemeActionVariant: SpyButtonStyle.Variant {
        .red
    }

    private func localWordCountModeTitle(_ mode: LocalWordCountMode) -> String {
        switch mode {
        case .recommended:
            localized(en: "RECOMMENDED", ru: "РЕКОМЕНДОВАНО", es: "RECOMENDADO", uk: "РЕКОМЕНДОВАНО")
        case .custom:
            localized(en: "CUSTOM", ru: "СВОЙ ВЫБОР", es: "CUSTOM", uk: "ВЛАСНИЙ ВИБІР")
        }
    }

    private func localWordCountModeHint(_ mode: LocalWordCountMode) -> String {
        switch mode {
        case .recommended:
            localized(en: "100 words", ru: "100 слов", es: "100 palabras", uk: "100 слів")
        case .custom:
            localized(
                en: "\(Int(localCustomWordCount)) words",
                ru: "\(Int(localCustomWordCount)) слов",
                es: "\(Int(localCustomWordCount)) palabras",
                uk: "\(Int(localCustomWordCount)) слів"
            )
        }
    }

    private func localThemeMetaLabel(maxWords: Int) -> String {
        return localized(
            en: "AI POOL · \(maxWords) AVAILABLE",
            ru: "AI-ПУЛ · \(maxWords) ДОСТУПНО",
            es: "BANCO IA · \(maxWords) DISPONIBLES",
            uk: "AI-ПУЛ · ДОСТУПНО \(maxWords)"
        )
    }

    private func localPoolStats(inGame: Int, active: Int, total: Int) -> String {
        localized(
            en: "\(inGame) in game · \(active)/\(total) active · tap to cross out",
            ru: "\(inGame) в игре · \(active)/\(total) активных · нажми, чтобы вычеркнуть",
            es: "\(inGame) en juego · \(active)/\(total) activas · toca para tachar",
            uk: "\(inGame) у грі · \(active)/\(total) активних · натисни, щоб викреслити"
        )
    }

    private func localPoolExpansionLabel(total: Int) -> String {
        if localPoolExpanded {
            return localized(en: "SHOW LESS", ru: "ПОКАЗАТЬ МЕНЬШЕ", es: "MOSTRAR MENOS", uk: "ПОКАЗАТИ МЕНШЕ")
        }

        return localized(
            en: "SHOW ALL \(total) WORDS",
            ru: "ПОКАЗАТЬ ВСЕ СЛОВА · \(total)",
            es: "MOSTRAR \(total) PALABRAS",
            uk: "ПОКАЗАТИ ВСІ СЛОВА · \(total)"
        )
    }

    private func localWordKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func activeLocalWords(_ words: [String]) -> [String] {
        let clean = words.localCleanWords
        return clean.filter { !disabledPoolWordKeys.contains(localWordKey($0)) }
    }

    private func playableLocalWords(_ words: [String]) -> [String] {
        Array(activeLocalWords(words).prefix(max(Int(wordCount), 1)))
    }

    private var localPlayablePool: [String] {
        playableLocalWords(localPoolSnapshot.words)
    }

    private func toggleLocalPoolWord(_ word: String) {
        let key = localWordKey(word)
        if disabledPoolWordKeys.contains(key) {
            disabledPoolWordKeys.remove(key)
        } else {
            disabledPoolWordKeys.insert(key)
        }
        let activeCount = activeLocalWords(localPoolSnapshot.words).count
        wordCount = min(wordCount, Double(max(activeCount, 2)))
        HapticManager.shared.fire(.tabSelection)
    }

    private func clearLocalPoolDraft() {
        localPoolDraft = nil
        localNewPoolWord = ""
    }

    private func selectLocalWordSource(_ id: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            selectedPackID = id
            localSourceBeforeCustomTheme = id
            generatedPack = nil
            localThemeError = ""
            localPoolExpanded = false
            disabledPoolWordKeys.removeAll()
            clearLocalPoolDraft()
            status = ""

            if id == "builtin" {
                let category = localWordPools[builtinPreviewCategory] == nil ? "CLASSIC" : builtinPreviewCategory
                wordCount = Double(max(localWordPools[category]?.localCleanWords.count ?? 0, 2))
            } else if let pack = packs.first(where: { $0.id == id }) {
                wordCount = Double(max(pack.words?.localCleanWords.count ?? 0, 2))
            }
        }
        HapticManager.shared.fire(.tabSelection)
    }

    private func setLocalPoolDraft(words: [String], category: String? = nil, source: String? = nil) {
        let snapshot = localPoolSnapshot
        let clean = words.localCleanWords
        localPoolDraft = LocalPoolDraft(
            category: category?.nilIfBlank ?? snapshot.category,
            source: source?.nilIfBlank ?? snapshot.source,
            words: clean
        )
        if selectedPackID == "generated" {
            wordCount = min(wordCount, Double(max(clean.count, 2)))
        }
        if clean.count <= localCollapsedPoolPreviewLimit {
            localPoolExpanded = false
        }
        disabledPoolWordKeys = disabledPoolWordKeys.filter { key in
            clean.contains { localWordKey($0) == key }
        }
    }

    private func removeLocalPoolWord(_ word: String) {
        let snapshot = localPoolSnapshot
        let key = localWordKey(word)
        let words = snapshot.words.filter { localWordKey($0) != key }
        setLocalPoolDraft(words: words, category: snapshot.category, source: snapshot.source)
        HapticManager.shared.fire(.buttonPress)
    }

    private func addLocalPoolWord() {
        let value = localNewPoolWord
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !value.isEmpty else { return }

        let snapshot = localPoolSnapshot
        let key = localWordKey(value)
        guard !snapshot.words.contains(where: { localWordKey($0) == key }) else {
            localNewPoolWord = ""
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        setLocalPoolDraft(words: snapshot.words + [value], category: snapshot.category, source: snapshot.source)
        localNewPoolWord = ""
        HapticManager.shared.fire(.buttonPress)
    }

    private func sectionHeader(systemImage: String, title: String) -> some View {
        SpyLobbySectionHeader(systemImage: systemImage, title: title)
    }

    private func localModeOption(_ candidate: LocalMode, symbol: String) -> some View {
        let isSelected = mode == candidate

        return SpyLobbyModeChoice(
            symbol: symbol,
            title: candidate.title(copy),
            isSelected: isSelected,
            accessibilityIdentifier: "localGame.mode.\(candidate.rawValue)"
        ) {
            HapticManager.shared.fire(.tabSelection)
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                mode = candidate
            }
        }
    }

    private func localModeSubtitle(_ mode: LocalMode) -> String {
        switch mode {
        case .questions:
            localized(
                en: "Ask direct questions in a rotating pair. Best when players want a sharper interrogation rhythm.",
                ru: "Игроки задают вопросы по очереди. Лучше для жесткого ритма допроса.",
                es: "Haz preguntas directas por turnos. Ideal para un ritmo mas tactico.",
                uk: "Ставте прямі запитання по черзі. Найкраще для гострішого ритму допиту."
            )
        case .associations:
            localized(
                en: "Each player says one association. Best when the table wants a fast, web-style clue chain.",
                ru: "Каждый говорит одну ассоциацию. Ближе к web-ритму с быстрой цепочкой подсказок.",
                es: "Cada jugador dice una asociacion. Ideal para una cadena rapida de pistas.",
                uk: "Кожен гравець називає одну асоціацію. Найкраще для швидкого ланцюжка підказок."
            )
        }
    }

    private func localModeMicrocopy(_ mode: LocalMode) -> String {
        switch mode {
        case .questions:
            localized(en: "ASK / ANSWER", ru: "ВОПРОС / ОТВЕТ", es: "PREGUNTA / RESPONDE", uk: "ЗАПИТУЄ / ВІДПОВІДАЄ")
        case .associations:
            localized(en: "ONE CLUE EACH", ru: "ПО ОДНОЙ ПОДСКАЗКЕ", es: "UNA PISTA", uk: "ПО ОДНІЙ ПІДКАЗЦІ")
        }
    }

    private var localPoolPreview: some View {
        let snapshot = localPoolSnapshot
        let compactWords = Array(snapshot.words.prefix(localCollapsedPoolPreviewLimit))
        let additionalWords = Array(snapshot.words.dropFirst(localCollapsedPoolPreviewLimit))
        let activeCount = snapshot.words.filter { !disabledPoolWordKeys.contains(localWordKey($0)) }.count
        let inGameCount = min(max(Int(wordCount), 0), activeCount)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(localPoolIcon)
                    .font(.system(size: 16))

                Text(localPoolLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.66)

                Text(snapshot.category.uppercased())
                    .font(.system(size: 10, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(SpyTheme.red.opacity(0.12), in: CutCornerShape(cut: 5))
                    .spyFitted(scale: 0.54)

                Spacer()

                if selectedPackID == "builtin", !localHasCustomTheme {
                    Button {
                        rerollBuiltinPreview()
                    } label: {
                        SpyActionLabel(
                            title: localized(en: "REROLL", ru: "ДРУГОЙ", es: "OTRO", uk: "ІНШИЙ"),
                            systemImage: "arrow.clockwise",
                            fontSize: 9,
                            iconSize: 11,
                            tracking: 0.02
                        )
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                        .frame(maxWidth: 104)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SpyTheme.red.opacity(0.15))
                    .frame(height: 1)
            }

            Text(localPoolStats(inGame: inGameCount, active: activeCount, total: snapshot.words.count))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.02)
                .foregroundStyle(snapshot.words.isEmpty ? SpyTheme.red.opacity(0.82) : SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.62)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            if snapshot.words.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(SpyTheme.red.opacity(0.78))
                        .frame(width: 18)
                        .padding(.top, 2)

                    Text(snapshot.emptyMessage)
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            } else {
                localPoolWordGrid(compactWords)

                if snapshot.words.count > localCollapsedPoolPreviewLimit {
                    Button {
                        HapticManager.shared.fire(.tabSelection)
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.30)) {
                            localPoolExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: localPoolExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .black))

                            Text(localPoolExpansionLabel(total: snapshot.words.count))
                                .font(.system(size: 10.5, weight: .black, design: .monospaced))
                                .tracking(0.04)
                                .spyFitted(lines: 1, scale: 0.62, alignment: .center)
                        }
                        .foregroundStyle(localPoolExpanded ? SpyTheme.muted : SpyTheme.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(SpyTheme.black.opacity(0.42), in: CutCornerShape(cut: 8))
                        .overlay(
                            CutCornerShape(cut: 8)
                                .stroke(localPoolExpanded ? SpyTheme.strokeStrong : SpyTheme.red.opacity(0.42), lineWidth: 1)
                        )
                        .contentShape(CutCornerShape(cut: 8))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("localGame.poolExpansion")
                }

                if localPoolExpanded {
                    localPoolWordGrid(additionalWords)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 8) {
                    TextField("", text: $localNewPoolWord, prompt: Text(localAddWordPlaceholder).foregroundStyle(SpyTheme.dim))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(addLocalPoolWord)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tint(SpyTheme.red)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                        .background(SpyTheme.black, in: CutCornerShape(cut: 8))
                        .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong.opacity(0.72), lineWidth: 1))
                        .focused($focusedLocalSetupField, equals: .poolWord)
                        .id(localPoolWordScrollTarget)

                    Button(action: addLocalPoolWord) {
                        Text("+ ADD")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(0.04)
                            .foregroundStyle(SpyTheme.red)
                            .frame(width: 72, height: 44)
                            .spyCutCard(cut: 8, fill: Color.clear, stroke: SpyTheme.red.opacity(0.55))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(localNewPoolWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(localNewPoolWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(SpyTheme.red.opacity(0.04))
        .overlay(
            CutCornerShape(cut: 10)
                .stroke(SpyTheme.red.opacity(snapshot.words.isEmpty ? 0.22 : 0.25), lineWidth: 1)
        )
        .clipShape(CutCornerShape(cut: 10))
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(SpyTheme.red.opacity(localPreviewPulse ? 0.42 : 0.14))
                .frame(width: localPreviewPulse ? 76 : 28, height: 1)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                    value: localPreviewPulse
                )
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.30), value: localPoolExpanded)
    }

    private func localPoolWordGrid(_ words: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(words, id: \.self) { word in
                let isEnabled = !disabledPoolWordKeys.contains(localWordKey(word))
                HStack(spacing: 3) {
                    Button {
                        toggleLocalPoolWord(word)
                    } label: {
                        Text(word.uppercased())
                            .font(.system(size: 10, weight: .black, design: .default))
                            .tracking(0.02)
                            .strikethrough(!isEnabled, color: SpyTheme.dim)
                            .spyFitted(scale: 0.50, alignment: .center)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .contentShape(Rectangle())
                    .accessibilityLabel(word)

                    Button {
                        removeLocalPoolWord(word)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(SpyTheme.dim.opacity(isEnabled ? 0.72 : 0.35))
                            .frame(width: 24, height: 36)
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .spyHitTarget()
                    .contentShape(Rectangle())
                    .accessibilityLabel(localized(en: "Remove \(word)", ru: "Удалить \(word)", es: "Eliminar \(word)", uk: "Видалити \(word)"))
                }
                .foregroundStyle(isEnabled ? SpyTheme.bodyText : SpyTheme.dim.opacity(0.38))
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .spyCutCard(
                    cut: 7,
                    fill: isEnabled ? SpyTheme.control : SpyTheme.black,
                    stroke: isEnabled ? SpyTheme.strokeStrong : SpyTheme.strokeDim
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var cardsView: some View {
        if let session, let player = session.players[safe: revealIndex] {
            VStack(spacing: 0) {
                Spacer(minLength: 14)

                VStack(spacing: 8) {
                    Text("\(revealIndex + 1) / \(session.players.count)")
                        .font(SpyTheme.micro)
                        .tracking(0.14)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70, alignment: .center)

                    Text(player.avatar)
                        .font(.system(size: 44))

                    Text(player.name.uppercased())
                        .font(.system(size: 26, weight: .black, design: .default))
                        .tracking(0.08)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.52, alignment: .center)

                    if !cardRevealed {
                        Text(copy.passPhone)
                            .font(SpyTheme.micro)
                            .tracking(0.10)
                            .foregroundStyle(SpyTheme.dim)
                            .multilineTextAlignment(.center)
                            .spyFitted(lines: 2, scale: 0.66, alignment: .center)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 28)
                .id(revealIndex)
                .transition(.opacity.combined(with: .move(edge: .top)))

                RoleRevealCard(
                    player: player,
                    session: session,
                    revealed: cardRevealed,
                    copy: copy,
                    language: appState.language,
                    dontShow: localized(en: "DON'T SHOW OTHERS", ru: "НЕ ПОКАЗЫВАЙ ДРУГИМ", es: "NO MUESTRES A OTROS", uk: "НЕ ПОКАЗУЙ ІНШИМ")
                )
                    .onTapGesture {
                        if !cardRevealed {
                            revealCard()
                        }
                    }

                if cardRevealed {
                    Button {
                        nextCard()
                    } label: {
                        SpyActionLabel(
                            title: nextCardTitle(session),
                            systemImage: nextCardIcon(session),
                            tracking: 0.04,
                            lines: 2
                        )
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .frame(maxWidth: 300)
                    .padding(.top, 28)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25).delay(0.50)))
                }

                cardProgressDots(session)
                    .padding(.top, 20)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.34), value: revealIndex)
            .animation(.smooth(duration: 0.34), value: cardRevealed)
        }
    }

    @ViewBuilder
    private var playingView: some View {
        if let session {
            VStack(alignment: .leading, spacing: 10) {
                localPlayingHeader
                localTimerAndRecoveryControls

                if isLocalGamePaused {
                    localPausedPanel
                } else {
                    localAgentStrip(session)

                    if session.mode == .questions {
                        localActivePairCard(session)
                    } else {
                        localAssociationCard(session)
                    }
                }
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func questionVectorPanel(_ session: LocalSession) -> some View {
        SpyPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text(copy.questionVector)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)
                HStack(spacing: 12) {
                    localTurnAgent(copy.asker, player: currentAsker(in: session), color: SpyTheme.red)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SpyTheme.dim)
                    localTurnAgent(copy.answer, player: currentAnswerer(in: session), color: SpyTheme.green)
                }
            }
        }
    }

    private func associationVectorPanel(_ session: LocalSession) -> some View {
        SpyPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text(localized(en: "// ASSOCIATION DRUM", ru: "// БАРАБАН АССОЦИАЦИЙ", es: "// TAMBOR DE ASOCIACIONES", uk: "// БАРАБАН АСОЦІАЦІЙ"))
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)

                HStack(spacing: 10) {
                    localConfigTile(title: localized(en: "SPEAKER", ru: "ГОВОРИТ", es: "HABLA", uk: "ГОВОРИТЬ"), value: currentAsker(in: session)?.name.uppercased() ?? copy.pending)
                    localConfigTile(title: localized(en: "ROUND", ru: "РАУНД", es: "RONDA", uk: "РАУНД"), value: "\(questionIndex + 1)")
                }

                Text(localized(
                    en: "Say one association for the hidden word. Keep the tempo moving, listen for weak links, then call the final vote.",
                    ru: "Назови одну ассоциацию к скрытому слову. Держи темп, слушай слабые связи и затем запускай финальный голос.",
                    es: "Di una asociacion para la palabra oculta. Mantén el ritmo, detecta enlaces debiles y llama el voto final.",
                    uk: "Назви одну асоціацію до прихованого слова. Тримай темп, слухай слабкі звʼязки, а потім починай фінальне голосування."
                ))
                .font(SpyTheme.mono)
                .foregroundStyle(SpyTheme.muted)
                .lineSpacing(3)
            }
        }
    }

    private var localPlayingHeader: some View {
        HStack {
            Text(localized(en: "// PLAYING", ru: "// ИГРА", es: "// JUGANDO", uk: "// ГРА"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.16)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.66)

            Spacer()

            Button {
                timerTask?.cancel()
                reset()
                HapticManager.shared.fire(.buttonPress)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .black))
                    Text(localized(en: "STOP", ru: "СТОП", es: "PARAR", uk: "ЗУПИНИТИ"))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.08)
                }
                .foregroundStyle(SpyTheme.muted)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(SpyTheme.dark)
                .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(SpyWebPressStyle())
        }
    }

    private var localTimerStrip: some View {
        HStack(spacing: 12) {
            Text(isLocalGamePaused
                ? localized(en: "PAUSED", ru: "ПАУЗА", es: "PAUSA", uk: "ПАУЗА")
                : localized(en: "TIME LEFT", ru: "ОСТАЛОСЬ", es: "QUEDA", uk: "ЗАЛИШИЛОСЯ"))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(isLocalGamePaused ? SpyTheme.red : SpyTheme.dim)
                .spyFitted(scale: 0.66)

            Text(timeString(secondsRemaining))
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(secondsRemaining <= 60 ? SpyTheme.red : SpyTheme.green)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 48)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private var localTimerAndRecoveryControls: some View {
        HStack(spacing: 8) {
            localTimerStrip
                .layoutPriority(1)

            localRoundUtilityButton(
                title: isLocalGamePaused
                    ? localized(en: "RESUME", ru: "ИГРАТЬ", es: "SEGUIR", uk: "ПРОДОВЖИТИ")
                    : localized(en: "PAUSE", ru: "ПАУЗА", es: "PAUSA", uk: "ПАУЗА"),
                systemImage: isLocalGamePaused ? "play.fill" : "pause.fill",
                accessibilityID: "localGame.pause"
            ) {
                toggleLocalGamePause()
            }

            localRoundUtilityButton(
                title: localized(en: "CARD", ru: "КАРТА", es: "CARTA", uk: "КАРТКА"),
                systemImage: "rectangle.portrait.on.rectangle.portrait",
                accessibilityID: "localGame.forgotCard"
            ) {
                beginForgotCardReview()
            }
        }
    }

    private func localRoundUtilityButton(
        title: String,
        systemImage: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .black))
                Text(title)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.04)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .foregroundStyle(SpyTheme.red)
            .frame(width: 58, height: 48)
            .background(SpyTheme.dark)
            .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.42), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier(accessibilityID)
    }

    private var localPausedPanel: some View {
        localCompactPanel(accent: SpyTheme.red, fillHeight: true) {
            VStack(spacing: 14) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(SpyTheme.red)

                Text(localized(en: "GAME PAUSED", ru: "ИГРА НА ПАУЗЕ", es: "JUEGO EN PAUSA", uk: "ГРУ ПРИЗУПИНЕНО"))
                    .font(.system(size: 20, weight: .black, design: .default))
                    .tracking(0.08)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.64, alignment: .center)

                Text(localized(
                    en: "The timer and round actions are stopped.",
                    ru: "Таймер и игровые действия остановлены.",
                    es: "El temporizador y las acciones estan detenidos.",
                    uk: "Таймер і дії раунду зупинено."
                ))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)

                localCompactActionButton(
                    title: localized(en: "RESUME GAME", ru: "ПРОДОЛЖИТЬ ИГРУ", es: "CONTINUAR JUEGO", uk: "ПРОДОВЖИТИ ГРУ"),
                    prefix: "▶",
                    primary: true
                ) {
                    resumeLocalGame()
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("localGame.paused")
    }

    private func localAgentStrip(_ session: LocalSession) -> some View {
        let activeIndices = activeLocalPlayerIndices(in: session)
        return localCompactPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(localized(en: "AGENTS", ru: "АГЕНТЫ", es: "AGENTES", uk: "АГЕНТИ")) (\(activeIndices.count))")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.66)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(activeIndices, id: \.self) { index in
                        localAgentChip(session.players[index])
                    }
                }
            }
        }
    }

    private func localActivePairCard(_ session: LocalSession) -> some View {
        localCompactPanel(accent: SpyTheme.red, fillHeight: true) {
            VStack(spacing: 14) {
                Text(localized(en: "ACTIVE PAIR", ru: "АКТИВНАЯ ПАРА", es: "PAREJA ACTIVA", uk: "АКТИВНА ПАРА"))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62, alignment: .center)

                HStack(alignment: .center, spacing: 12) {
                    localPairAgentCell(
                        title: localized(en: "ASKS", ru: "СПРАШИВАЕТ", es: "PREGUNTA", uk: "ЗАПИТУЄ"),
                        player: currentAsker(in: session),
                        color: SpyTheme.red
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(SpyTheme.red)
                        .symbolEffect(.pulse, value: questionIndex)

                    localPairAgentCell(
                        title: localized(en: "ANSWERS", ru: "ОТВЕЧАЕТ", es: "RESPONDE", uk: "ВІДПОВІДАЄ"),
                        player: currentAnswerer(in: session),
                        color: .white
                    )
                }

                localCompactActionButton(
                    title: localized(en: "NEXT PAIR", ru: "СЛЕДУЮЩАЯ ПАРА", es: "SIGUIENTE PAREJA", uk: "НАСТУПНА ПАРА"),
                    prefix: "↻",
                    primary: false
                ) {
                    nextQuestion(in: session)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func localAssociationCard(_ session: LocalSession) -> some View {
        let speaker = currentAsker(in: session)
        let isRoundEnd = associationStep + 1 >= max(associationOrder.count, 1)

        return localCompactPanel(accent: SpyTheme.red, fillHeight: true) {
            if !associationRouletteDone {
                localAssociationRoulette(session)
            } else {
                VStack(spacing: 12) {
                    Text(localized(en: "SAYS ASSOCIATION", ru: "ГОВОРИТ АССОЦИАЦИЮ", es: "DICE ASOCIACION", uk: "НАЗИВАЄ АСОЦІАЦІЮ"))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.18)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.62, alignment: .center)

                    Text(speaker?.avatar ?? "🕵️")
                        .font(.system(size: 54))
                        .frame(height: 60)
                        .id(questionIndex)
                        .transition(.scale.combined(with: .opacity))

                    Text((speaker?.name ?? copy.pending).uppercased())
                        .font(.system(size: 20, weight: .black, design: .default))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.58, alignment: .center)

                    localCompactActionButton(
                        title: isRoundEnd
                            ? localized(en: "NEW ROUND", ru: "НОВЫЙ РАУНД", es: "NUEVA RONDA", uk: "НОВИЙ РАУНД")
                            : localized(en: "NEXT PLAYER", ru: "СЛЕДУЮЩИЙ ИГРОК", es: "SIGUIENTE JUGADOR", uk: "НАСТУПНИЙ ГРАВЕЦЬ"),
                        prefix: isRoundEnd ? "🎲" : "↻",
                        primary: false
                    ) {
                        nextQuestion(in: session)
                    }

                    HStack(spacing: 4) {
                        ForEach(activeLocalPlayerIndices(in: session), id: \.self) { index in
                            let orderedIndex = associationOrder[safe: associationStep] ?? -1
                            Circle()
                                .fill(index == orderedIndex ? SpyTheme.red : SpyTheme.stroke)
                                .frame(width: index == orderedIndex ? 7 : 6, height: index == orderedIndex ? 7 : 6)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func localAssociationRoulette(_ session: LocalSession) -> some View {
        TimelineView(.animation) { timeline in
            let activeIndices = activeLocalPlayerIndices(in: session)
            let count = max(activeIndices.count, 1)
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate * 12) % count
            let previewIndex = activeIndices[safe: tick]
            let previewPlayer = previewIndex.flatMap { session.players[safe: $0] } ?? currentAsker(in: session)

            VStack(spacing: 12) {
                Text(localized(en: "ASSOCIATION ROULETTE", ru: "РУЛЕТКА АССОЦИАЦИЙ", es: "RULETA DE ASOCIACIONES", uk: "РУЛЕТКА АСОЦІАЦІЙ"))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62, alignment: .center)

                Text(previewPlayer?.avatar ?? "🕵️")
                    .font(.system(size: 58))
                    .frame(height: 64)
                    .shadow(color: SpyTheme.red.opacity(0.35), radius: 18)

                Text(localized(en: "SELECTING OPERATIVE", ru: "ВЫБОР ОПЕРАТИВНИКА", es: "ELIGIENDO OPERATIVO", uk: "ОБИРАЄМО ОПЕРАТИВНИКА"))
                    .font(.system(size: 14, weight: .black, design: .default))
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)

                HStack(spacing: 5) {
                    ForEach(session.players.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == tick ? SpyTheme.red : SpyTheme.stroke)
                            .frame(width: index == tick ? 22 : 10, height: 5)
                            .animation(.smooth(duration: 0.12), value: tick)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .task(id: questionIndex) {
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.28)) {
                    associationRouletteDone = true
                }
                HapticManager.shared.fire(.notification(.success))
            }
        }
    }

    private func localCompactPanel<Content: View>(
        accent: Color,
        fillHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: fillHeight ? .infinity : nil)
            .background(SpyTheme.panelDeep)
            .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(accent.opacity(0.9))
                    .frame(width: 34, height: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                Rectangle()
                    .fill(accent.opacity(0.55))
                    .frame(width: 10, height: 1)
            }
    }

    private func localAgentChip(_ player: LocalPlayer) -> some View {
        HStack(spacing: 6) {
            Text(player.avatar)
                .font(.system(size: 16))
            Text(localShortName(player.name))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.muted)
                .spyFitted(scale: 0.62)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32)
        .background(SpyTheme.dark)
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func localPairAgentCell(title: String, player: LocalPlayer?, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(player?.avatar ?? "🕵️")
                .font(.system(size: 40))
                .frame(height: 44)

            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.58, alignment: .center)

            Text(localShortName(player?.name ?? copy.pending).uppercased())
                .font(.system(size: 12, weight: .black, design: .default))
                .tracking(0.02)
                .foregroundStyle(color)
                .spyFitted(scale: 0.54, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private func localCompactActionButton(title: String, prefix: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Text(prefix)
                    .font(.system(size: 12, weight: .black, design: .default))
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .spyFitted(lines: 2, scale: 0.64, alignment: .center)
            }
            .foregroundStyle(primary ? .white : SpyTheme.red)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(primary ? SpyTheme.red : Color.clear)
            .overlay(Rectangle().stroke(primary ? SpyTheme.red : SpyTheme.red.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func localShortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? copy.pending : trimmed
        if fallback.count <= 8 { return fallback }
        return "\(fallback.prefix(7))…"
    }

    @ViewBuilder
    private var spyGuessView: some View {
        if let session {
            let spyPlayers = activeLocalSpyPlayers(in: session)
            ZStack {
                VStack(spacing: 20) {
                    Text("⏰")
                        .font(.system(size: 60))
                        .scaleEffect(guessSecondsRemaining <= 10 ? 1.05 : 1)
                        .animation(.smooth(duration: 0.2), value: guessSecondsRemaining)

                    Text(localized(en: "TIME'S UP!", ru: "ВРЕМЯ ВЫШЛО!", es: "TIEMPO TERMINADO", uk: "ЧАС ВИЙШОВ!"))
                        .font(.system(size: 36, weight: .black, design: .default))
                        .tracking(0.06)
                        .foregroundStyle(SpyTheme.red)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.56, alignment: .center)

                    localGuessCountdown

                    if !spyPlayers.isEmpty {
                        VStack(spacing: 8) {
                            Text(
                                session.spiesKnowEachOther
                                    ? localized(en: "Pass phone to the spy team:", ru: "Передай телефон команде шпионов:", es: "Pasa el telefono al equipo de espias:", uk: "Передай телефон команді шпигунів:")
                                    : localized(en: "Pass the phone to any spy.", ru: "Передай телефон любому шпиону.", es: "Pasa el telefono a cualquier espia.", uk: "Передай телефон будь-якому шпигуну.")
                            )
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(SpyTheme.dim)
                                .multilineTextAlignment(.center)
                                .spyFitted(lines: 2, scale: 0.66, alignment: .center)

                            if session.spiesKnowEachOther {
                                HStack(spacing: 10) {
                                    ForEach(spyPlayers) { spyPlayer in
                                        VStack(spacing: 3) {
                                            Text(spyPlayer.avatar)
                                                .font(.system(size: 28))
                                            Text(spyPlayer.name.uppercased())
                                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.56)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        pendingSpyGuess = nil
                        withAnimation(.smooth(duration: 0.22)) {
                            showSpyGuessOptions = true
                        }
                        HapticManager.shared.fire(.buttonPress)
                    } label: {
                        SpyActionLabel(
                            title: localized(en: "GUESS THE WORD", ru: "УГАДАТЬ СЛОВО", es: "ADIVINAR PALABRA", uk: "ВГАДАТИ СЛОВО"),
                            systemImage: "scope",
                            tracking: 0.02,
                            lines: 2
                        )
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .padding(.top, 18)

                if showSpyGuessOptions {
                    spyGuessModal(session)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
    }

    private var localGuessCountdown: some View {
        let activeSpyCount = session.map { activeLocalSpyPlayers(in: $0).count } ?? 1
        return VStack(spacing: 4) {
            Text(
                activeSpyCount > 1
                    ? localized(en: "SPY TEAM HAS", ru: "У КОМАНДЫ ШПИОНОВ", es: "EL EQUIPO DE ESPIAS TIENE", uk: "У КОМАНДИ ШПИГУНІВ Є")
                    : localized(en: "SPY HAS", ru: "У ШПИОНА", es: "EL ESPIA TIENE", uk: "У ШПИГУНА Є")
            )
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.66, alignment: .center)

            Text("\(guessSecondsRemaining)s")
                .font(.system(size: 42, weight: .black, design: .monospaced))
                .tracking(0.04)
                .foregroundStyle(guessSecondsRemaining <= 10 ? SpyTheme.red : .white)
                .contentTransition(.numericText())

            Text(localized(en: "TO GUESS", ru: "ЧТОБЫ УГАДАТЬ", es: "PARA ADIVINAR", uk: "ЩОБ ВГАДАТИ"))
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.66, alignment: .center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background((guessSecondsRemaining <= 10 ? SpyTheme.red : Color.white).opacity(guessSecondsRemaining <= 10 ? 0.12 : 0.04))
        .overlay(Rectangle().stroke((guessSecondsRemaining <= 10 ? SpyTheme.red : Color.white).opacity(guessSecondsRemaining <= 10 ? 0.5 : 0.12), lineWidth: 1))
    }

    private func spyGuessModal(_ session: LocalSession) -> some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            SpyPanel(accent: SpyTheme.red) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(localized(en: "SPY GUESS", ru: "ДОГАДКА ШПИОНА", es: "INTENTO DEL ESPIA", uk: "ЗДОГАДКА ШПИГУНА"))
                        .font(SpyTheme.micro)
                        .tracking(0.18)
                        .foregroundStyle(SpyTheme.red)
                        .spyKicker(lines: 2)

                    Text(localized(en: "CHOOSE THE SECRET WORD", ru: "ВЫБЕРИ СЕКРЕТНОЕ СЛОВО", es: "ELIGE LA PALABRA SECRETA", uk: "ОБЕРИ СЕКРЕТНЕ СЛОВО"))
                        .font(.system(size: 20, weight: .black, design: .default))
                        .tracking(0.08)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.60)

                    Text(copy.spyHint)
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .tracking(0.02)
                        .lineSpacing(3)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(lines: 3, scale: 0.62)

                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], spacing: 8) {
                            ForEach(session.pool, id: \.self) { word in
                                spyGuessWordButton(word)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 250)

                    HStack(spacing: 10) {
                        Button {
                            pendingSpyGuess = nil
                            withAnimation(.smooth(duration: 0.18)) {
                                showSpyGuessOptions = false
                            }
                            HapticManager.shared.fire(.buttonPress)
                        } label: {
                            Text(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR", uk: "СКАСУВАТИ"))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SpyButtonStyle(variant: .ghost))

                        Button {
                            guard let pendingSpyGuess else { return }
                            resolveSpyGuess(pendingSpyGuess, session: session)
                        } label: {
                            Text(pendingSpyGuess.map { "▶ \($0.uppercased())" } ?? localized(en: "CHOOSE", ru: "ВЫБРАТЬ", es: "ELEGIR", uk: "ОБРАТИ"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.54)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SpyButtonStyle(variant: .red))
                        .disabled(pendingSpyGuess == nil)
                    }
                    .font(.system(size: 11, weight: .black, design: .default))
                    .tracking(0.04)
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 4)
        }
    }

    private func spyGuessWordButton(_ word: String) -> some View {
        let selected = pendingSpyGuess == word
        return Button {
            pendingSpyGuess = word
            HapticManager.shared.fire(.tabSelection)
        } label: {
            Text(word.uppercased())
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.02)
                .foregroundStyle(selected ? .white : SpyTheme.muted)
                .spyFitted(scale: 0.54, alignment: .center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(selected ? SpyTheme.red : SpyTheme.dark)
                .overlay(Rectangle().stroke(selected ? SpyTheme.red : SpyTheme.strokeStrong, lineWidth: 1))
                .shadow(color: selected ? SpyTheme.red.opacity(0.26) : .clear, radius: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    @ViewBuilder
    private var votingView: some View {
        if let session {
            VStack(alignment: .leading, spacing: 18) {
                localSessionPanel(session)

                SpyPanel(accent: SpyTheme.red) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(copy.finalAccusation)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker(lines: 2)
                        Text(copy.whoIsSpy)
                            .font(.system(size: 32, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(.white)
                            .spyFitted(lines: 2, scale: 0.58)
                        ForEach(activeLocalPlayerIndices(in: session), id: \.self) { index in
                            Button {
                                resolveAccusation(index, session: session)
                            } label: {
                                HStack {
                                    Text(session.players[index].avatar)
                                        .font(.system(size: 22))
                                    Text(session.players[index].name.uppercased())
                                        .font(.system(size: 11, weight: .bold, design: .default))
                                        .tracking(0.04)
                                        .spyFitted(scale: 0.68)
                                    Spacer()
                                    Image(systemName: "scope")
                                }
                            }
                            .buttonStyle(SpyButtonStyle(variant: accusedIndex == index ? .red : .ghost))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if let session, let winner {
            VStack(spacing: 20) {
                Text(winner == .spy ? "🕵️" : "🔍")
                    .font(.system(size: 72))
                    .symbolEffect(.bounce, value: winner.title(copy))
                    .transition(.scale(scale: 0.35).combined(with: .opacity))

                Text(localWinnerTitle(winner, session: session))
                    .font(.system(size: 44, weight: .black, design: .default))
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.red)
                    .multilineTextAlignment(.center)
                    .spyFitted(lines: 2, scale: 0.52, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                localResultWordPanel(session)

                if !session.spyPlayers.isEmpty {
                    VStack(spacing: 6) {
                        Text(localized(en: "SPIES WERE", ru: "ШПИОНАМИ БЫЛИ", es: "LOS ESPIAS ERAN", uk: "ШПИГУНАМИ БУЛИ"))
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(0.08)
                            .foregroundStyle(SpyTheme.dim)
                        ForEach(session.spyPlayers) { spy in
                            Text("\(spy.avatar) \(spy.name.uppercased())")
                                .font(.system(size: 12, weight: .bold, design: .default))
                                .tracking(0.06)
                                .foregroundStyle(SpyTheme.red)
                        }
                    }
                    .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button {
                        startLocalGame()
                    } label: {
                        SpyActionLabel(
                            title: localized(en: "PLAY AGAIN", ru: "СЫГРАТЬ ЕЩЁ", es: "JUGAR OTRA VEZ", uk: "ЗІГРАТИ ЩЕ РАЗ"),
                            systemImage: "arrow.clockwise",
                            tracking: 0.04,
                            lines: 1
                        )
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))

                    Button {
                        reset()
                        appState.selectedTab = .home
                    } label: {
                        SpyActionLabel(
                            title: localized(en: "HOME", ru: "НА ГЛАВНУЮ", es: "INICIO", uk: "НА ГОЛОВНУ"),
                            systemImage: "chevron.left",
                            tracking: 0.04,
                            lines: 1
                        )
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                }
                .frame(maxWidth: 360)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 4)
            .padding(.vertical, 24)
        }
    }

    private func localResultWordPanel(_ session: LocalSession) -> some View {
        VStack(spacing: 8) {
                Text(localized(en: "SECRET WORD", ru: "СЕКРЕТНОЕ СЛОВО", es: "PALABRA SECRETA", uk: "СЕКРЕТНЕ СЛОВО"))
                    .font(SpyTheme.micro)
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.58, alignment: .center)

                LocalGlitchText(text: session.word.uppercased(), speedNanoseconds: 25_000_000)
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .tracking(0.16)
                    .foregroundStyle(SpyTheme.red)
                    .multilineTextAlignment(.center)
                    .spyFitted(lines: 2, scale: 0.46, alignment: .center)

                Text(session.category.uppercased())
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)

                if let spyGuess {
                    Text("\(localSpyGuessResultLabel(session)) \(spyGuess.uppercased())")
                        .font(SpyTheme.micro)
                        .tracking(0.04)
                        .foregroundStyle(localWordKey(spyGuess) == localWordKey(session.word) ? SpyTheme.green : SpyTheme.red)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.56, alignment: .center)
                        .padding(.top, 6)
                }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .background(SpyTheme.dark)
        .overlay(
            Rectangle()
                .stroke(SpyTheme.stroke, lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            CornerStroke(color: SpyTheme.red)
                .frame(width: 12, height: 12)
        }
        .overlay(alignment: .bottomTrailing) {
            CornerStroke(color: SpyTheme.red)
                .rotationEffect(.degrees(180))
                .frame(width: 12, height: 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var nextAssociationTitle: String {
        localized(en: "NEXT ASSOCIATION", ru: "СЛЕДУЮЩАЯ АССОЦИАЦИЯ", es: "SIGUIENTE ASOCIACION", uk: "НАСТУПНА АСОЦІАЦІЯ")
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(SpyTheme.micro)
                    .tracking(title.count > 12 ? 0.04 : 0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58)
                Spacer()
                Text(copy.sliderValue(value.wrappedValue, suffix: suffix))
                    .font(SpyTheme.micro)
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.62, alignment: .trailing)
            }
            SpyWebSlider(
                value: value,
                range: range,
                language: appState.language,
                step: 1
            )
        }
    }

    private var localSourceLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: selectedPackID == "builtin" ? "archivebox.fill" : "shippingbox.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.wordSource)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58)
                Text(localSourceSummary)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(localSourceSummary.count > 16 ? 0.02 : 0.08)
                    .foregroundStyle(.white.opacity(0.86))
                    .spyFitted(lines: 2, scale: 0.56)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(SpyTheme.dim)
        }
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private var localSourceSummary: String {
        if selectedPackID == "generated", let generatedPack {
            return "\(generatedPack.category.uppercased()) · \(generatedPack.words.localCleanWords.count) \(copy.wordsSuffix)"
        }

        if selectedPackID != "builtin",
           let pack = packs.first(where: { $0.id == selectedPackID }) {
            return "\(pack.name.uppercased()) · \(pack.words?.localCleanWords.count ?? 0) \(copy.wordsSuffix)"
        }

        if let generatedPack, !generatedPack.words.isEmpty {
            return "\(copy.builtinIntel) · \(generatedPack.words.localCleanWords.count) AI"
        }

        return "\(copy.builtinIntel) · \(Int(wordCount)) \(copy.wordsSuffix)"
    }

    private var localPoolSnapshot: LocalPoolSnapshot {
        if let localPoolDraft {
            let words = localPoolDraft.words.localCleanWords
            return LocalPoolSnapshot(
                category: localPoolDraft.category,
                source: localPoolDraft.source,
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Add at least one active word before dealing cards.", ru: "Добавь хотя бы одно активное слово перед раздачей.", es: "Agrega al menos una palabra activa antes de repartir.", uk: "Додай хоча б одне активне слово перед роздаванням карток.")
            )
        }

        if selectedPackID == "generated", let generatedPack {
            let words = generatedPack.words.localCleanWords
            return LocalPoolSnapshot(
                category: generatedPack.category.nilIfBlank ?? customTheme.nilIfBlank ?? customCategoryFallback,
                source: localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO", uk: "ЗГЕНЕРОВАНО AI"),
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Generate a theme before dealing cards.", ru: "Сгенерируй тему перед раздачей карт.", es: "Genera un tema antes de repartir.", uk: "Згенеруй тему перед роздаванням карток.")
            )
        }

        if !localHasCustomTheme,
           selectedPackID == "builtin",
           let generatedPack {
            let words = generatedPack.words.localCleanWords
            return LocalPoolSnapshot(
                category: generatedPack.category.nilIfBlank ?? builtinPreviewCategory,
                source: localized(en: "BUILT-IN INTEL", ru: "ВСТРОЕННЫЙ INTEL", es: "INTEL INTEGRADA", uk: "ВБУДОВАНА РОЗВІДКА"),
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Built-in pool is unavailable.", ru: "Встроенный пул недоступен.", es: "Banco integrado no disponible.", uk: "Вбудований пул недоступний.")
            )
        }

        if localHasCustomTheme {
            return LocalPoolSnapshot(
                category: customTheme.nilIfBlank ?? customCategoryFallback,
                source: localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO", uk: "ЗГЕНЕРОВАНО AI"),
                words: [],
                countLabel: "0 \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Generate a theme before dealing cards.", ru: "Сгенерируй тему перед раздачей карт.", es: "Genera un tema antes de repartir.", uk: "Згенеруй тему перед роздаванням карток.")
            )
        }

        if selectedPackID != "builtin",
           let pack = packs.first(where: { $0.id == selectedPackID }) {
            let words = pack.words?.localCleanWords ?? []
            return LocalPoolSnapshot(
                category: pack.category?.nilIfBlank ?? pack.name,
                source: localized(en: "WORD PACK", ru: "WORDPACK", es: "WORDPACK", uk: "НАБІР СЛІВ"),
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "This pack is empty. Choose another source.", ru: "Этот пак пуст. Выбери другой источник.", es: "Este pack esta vacio. Elige otra fuente.", uk: "Цей набір порожній. Обери інше джерело.")
            )
        }

        let category = localWordPools[builtinPreviewCategory] == nil ? "CLASSIC" : builtinPreviewCategory
        let words = (localWordPools[category] ?? localWordPools["CLASSIC"] ?? []).localCleanWords
        return LocalPoolSnapshot(
            category: category,
            source: localized(en: "BUILT-IN INTEL", ru: "ВСТРОЕННЫЙ INTEL", es: "INTEL INTEGRADA", uk: "ВБУДОВАНА РОЗВІДКА"),
            words: words,
            countLabel: "\(words.count) \(copy.wordsSuffix)",
            emptyMessage: localized(en: "Built-in pool is unavailable.", ru: "Встроенный пул недоступен.", es: "Banco integrado no disponible.", uk: "Вбудований пул недоступний.")
        )
    }

    private func localConfigTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.44)
            Text(value)
                .font(.system(size: 15, weight: .black, design: .default))
                .tracking(0.02)
                .foregroundStyle(.white)
                .spyFitted(scale: 0.50)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func miniIconButton(_ systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(disabled ? SpyTheme.dim : SpyTheme.red)
                .frame(width: 38, height: 34)
                .background(SpyTheme.dark)
                .overlay(
                    CutCornerShape(cut: 8)
                        .stroke(disabled ? SpyTheme.stroke : SpyTheme.red.opacity(0.55), lineWidth: 1)
                )
                .clipShape(CutCornerShape(cut: 8))
        }
        .buttonStyle(SpyWebPressStyle())
        .spyHitTarget()
        .disabled(disabled)
    }

    private func localTurnAgent(_ title: String, player: LocalPlayer?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.62)
            Text(player?.name.uppercased() ?? copy.pending)
                .font(.system(size: 18, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(color)
                .spyFitted(scale: 0.56)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func localSessionPanel(_ session: LocalSession, revealRoles: Bool = false) -> some View {
        SpyPanel(accent: revealRoles ? SpyTheme.green : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                        Text(localized(en: "// SESSION ROSTER", ru: "// СОСТАВ СЕССИИ", es: "// LISTA DE SESION", uk: "// СКЛАД СЕСІЇ"))
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)

                    Spacer()

                    Text(session.mode.title(copy))
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.62, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    localConfigTile(title: copy.categoryLabel, value: session.category.uppercased())
                    localConfigTile(title: localized(en: "OPERATIVES", ru: "ИГРОКИ", es: "AGENTES", uk: "ОПЕРАТИВНИКИ"), value: "\(session.players.count)")
                    localConfigTile(title: localized(en: "SPIES", ru: "ШПИОНЫ", es: "ESPIAS", uk: "ШПИГУНИ"), value: "\(session.spyPlayers.count)")
                }

                if revealRoles {
                    Text(copy.wordResult(session.word))
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(.white.opacity(0.9))
                        .spyFitted(lines: 2, scale: 0.62)
                }

                VStack(spacing: 8) {
                    ForEach(session.players.indices, id: \.self) { index in
                        localSessionPlayerRow(session.players[index], index: index, session: session, revealRoles: revealRoles)
                    }
                }
            }
        }
    }

    private func localSessionPlayerRow(_ player: LocalPlayer, index: Int, session: LocalSession, revealRoles: Bool) -> some View {
        let isEliminated = eliminatedPlayerIndices.contains(index)
        let askerID = currentAsker(in: session)?.id
        let answererID = currentAnswerer(in: session)?.id
        let isAsker = !isEliminated && session.mode == .questions && player.id == askerID
        let isAnswerer = !isEliminated && session.mode == .questions && player.id == answererID
        let isSpeaker = !isEliminated && session.mode == .associations && player.id == askerID
        let isActive = isAsker || isAnswerer || isSpeaker

        return HStack(spacing: 10) {
            Text(player.avatar)
                .font(.system(size: 20))
                .frame(width: 34, height: 34)
                .background(isActive ? SpyTheme.red.opacity(0.06) : SpyTheme.dark)
                .clipShape(CutCornerShape(cut: 7))

            VStack(alignment: .leading, spacing: 4) {
                Text(player.name.uppercased())
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(scale: 0.54)

                Text(
                    revealRoles
                        ? (player.isSpy ? copy.spyLabel : copy.youAreDetective)
                        : localPlayerStatus(index: index, session: session)
                )
                    .font(.system(size: 9, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(revealRoles ? (player.isSpy ? SpyTheme.red : SpyTheme.green) : (isActive ? SpyTheme.red : SpyTheme.dim))
                    .spyFitted(scale: 0.56)
            }

            Spacer()

            if revealRoles {
                localBadge(player.isSpy ? copy.spyLabel : localized(en: "CLEAR", ru: "ЧИСТ", es: "LIMPIO", uk: "ЧИСТИЙ"), color: player.isSpy ? SpyTheme.red : SpyTheme.green)
            } else if isEliminated {
                localBadge(
                    player.isSpy
                        ? localized(en: "SPY OUT", ru: "ШПИОН ВЫБЫЛ", es: "ESPIA FUERA", uk: "ШПИГУН ВИБУВ")
                        : localized(en: "DETECTIVE OUT", ru: "ДЕТЕКТИВ ВЫБЫЛ", es: "DETECTIVE FUERA", uk: "ДЕТЕКТИВ ВИБУВ"),
                    color: player.isSpy ? SpyTheme.red : SpyTheme.green
                )
            } else if isAsker {
                localBadge(copy.asker, color: SpyTheme.red)
            } else if isAnswerer {
                localBadge(copy.answer, color: SpyTheme.green)
            } else if isSpeaker {
                localBadge(localized(en: "SPEAKER", ru: "ГОВОРИТ", es: "HABLA", uk: "ГОВОРИТЬ"), color: SpyTheme.red)
            }
        }
        .padding(10)
        .background(SpyTheme.panelDeep.opacity(isActive || revealRoles ? 1 : 0.72))
        .overlay(
            Rectangle()
                .stroke(isActive ? SpyTheme.red.opacity(0.45) : SpyTheme.stroke, lineWidth: 1)
        )
    }

    private func localPlayerStatus(index: Int, session: LocalSession) -> String {
        guard session.players.indices.contains(index) else { return copy.pending }
        if eliminatedPlayerIndices.contains(index) {
            return session.players[index].isSpy
                ? localized(en: "SPY — EXCLUDED", ru: "ШПИОН — ИСКЛЮЧЁН", es: "ESPIA — EXCLUIDO", uk: "ШПИГУН — ВИКЛЮЧЕНИЙ")
                : localized(en: "DETECTIVE — EXCLUDED", ru: "ДЕТЕКТИВ — ИСКЛЮЧЁН", es: "DETECTIVE — EXCLUIDO", uk: "ДЕТЕКТИВ — ВИКЛЮЧЕНИЙ")
        }
        let player = session.players[index]

        if session.mode == .associations {
            return player.id == currentAsker(in: session)?.id
                ? localized(en: "ASSOCIATION TURN", ru: "ХОД АССОЦИАЦИИ", es: "TURNO DE ASOCIACION", uk: "ХІД АСОЦІАЦІЇ")
                : copy.pending
        }

        if player.id == currentAsker(in: session)?.id { return copy.asker }
        if player.id == currentAnswerer(in: session)?.id { return copy.answer }
        return copy.pending
    }

    private func localBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .black, design: .default))
            .tracking(0.02)
            .foregroundStyle(color)
            .spyFitted(scale: 0.66, alignment: .center)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(color.opacity(0.1))
            .overlay(CutCornerShape(cut: 6).stroke(color.opacity(0.38), lineWidth: 1))
            .clipShape(CutCornerShape(cut: 6))
    }

    private func addPlayer() {
        guard players.count < 10 else { return }
        resetPlayerDragState()
        players.append("")
        avatars.append(localAvatars[players.count % localAvatars.count])
        playerIDs.append(UUID())
        HapticManager.shared.fire(.buttonPress)
    }

    private func dropPlayer() {
        guard players.count > 2 else { return }
        resetPlayerDragState()
        players.removeLast()
        avatars.removeLast()
        playerIDs.removeLast()
        HapticManager.shared.fire(.buttonPress)
    }

    private func removePlayer(at index: Int) {
        guard players.count > 2, players.indices.contains(index) else { return }
        resetPlayerDragState()
        players.remove(at: index)
        if avatars.indices.contains(index) {
            avatars.remove(at: index)
        } else {
            avatars = players.indices.map { localAvatars[$0 % localAvatars.count] }
        }
        if playerIDs.indices.contains(index) {
            playerIDs.remove(at: index)
        } else {
            syncPlayerIDsWithPlayers()
        }
        HapticManager.shared.fire(.buttonPress)
    }

    private func movePlayer(from source: Int, to destination: Int) {
        guard source != destination,
              players.indices.contains(source),
              players.indices.contains(destination)
        else { return }

        if avatars.count != players.count {
            avatars = players.indices.map { avatars[safe: $0] ?? localAvatars[$0 % localAvatars.count] }
        }
        syncPlayerIDsWithPlayers()

        let movedName = players.remove(at: source)
        let movedAvatar = avatars.remove(at: source)
        let movedID = playerIDs.remove(at: source)
        let insertIndex = min(destination, players.count)

        players.insert(movedName, at: insertIndex)
        avatars.insert(movedAvatar, at: insertIndex)
        playerIDs.insert(movedID, at: insertIndex)
    }

    private func cycleAvatar(_ index: Int) {
        guard avatars.indices.contains(index) else { return }
        let current = avatars[index]
        let next = ((localAvatars.firstIndex(of: current) ?? 0) + 1) % localAvatars.count
        avatars[index] = localAvatars[next]
        HapticManager.shared.fire(.buttonPress)
    }

    private func rerollBuiltinPreview() {
        let categories = localWordPools.keys.sorted()
        guard !categories.isEmpty else { return }
        let remaining = categories.filter { $0 != builtinPreviewCategory }
        let category = remaining.randomElement() ?? categories.randomElement() ?? "CLASSIC"
        builtinPreviewCategory = category
        generatedPack = GeneratedWordPack(
            name: category,
            category: category,
            words: localWordPools[category] ?? localWordPools["CLASSIC"] ?? []
        )
        wordCount = Double(max(generatedPack?.words.localCleanWords.count ?? 0, 2))
        selectedPackID = "builtin"
        localSourceBeforeCustomTheme = "builtin"
        localPoolExpanded = false
        disabledPoolWordKeys.removeAll()
        clearLocalPoolDraft()
        status = localized(en: "BUILT-IN INTEL REROLLED", ru: "ВСТРОЕННЫЙ INTEL ОБНОВЛЕН", es: "INTEL INTEGRADA CAMBIADA", uk: "ВБУДОВАНУ РОЗВІДКУ ОНОВЛЕНО")
        HapticManager.shared.fire(.tabSelection)
    }

    private func revealBuiltinPool() {
        let categories = localWordPools.keys.sorted()
        let category = categories.randomElement() ?? "CLASSIC"
        builtinPreviewCategory = category
        generatedPack = GeneratedWordPack(
            name: category,
            category: category,
            words: localWordPools[category] ?? localWordPools["CLASSIC"] ?? []
        )
        wordCount = Double(max(generatedPack?.words.localCleanWords.count ?? 0, 2))
        selectedPackID = "builtin"
        localSourceBeforeCustomTheme = "builtin"
        localPoolExpanded = false
        disabledPoolWordKeys.removeAll()
        clearLocalPoolDraft()
        status = ""
        HapticManager.shared.fire(.buttonPress)
    }

    private func generateLocalTheme() async {
        let theme = customTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !theme.isEmpty, !isGenerating else { return }

        let existingPoolCount = generatedPack?.words.localCleanWords.count ?? 0
        let initialTargetCount = localWordCountMode == .custom ? Int(localCustomWordCount) : 100
        let targetCount = min(
            localThemeGenerationLimit,
            max(existingPoolCount >= 2 ? existingPoolCount : initialTargetCount, 10)
        )
        let requestID = UUID()
        let themeKey = localWordKey(theme)

        localThemeRequestID = requestID
        isExpandingLocalThemePool = false
        isGenerating = true
        localThemeError = ""
        defer {
            if localThemeRequestID == requestID {
                isGenerating = false
                isExpandingLocalThemePool = false
            }
        }

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                generated = GeneratedWordPack(
                    name: "\(theme) Kit",
                    category: theme,
                    words: (1...targetCount).map { "\(theme) \($0)" },
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
            } else {
                generated = try await appState.client.generateWordPack(
                    theme: theme,
                    count: targetCount,
                    requestID: requestID,
                    preferFresh: existingPoolCount >= 2
                )
            }
            appState.recordAIUsage(
                used: generated.aiGenerationsToday,
                remaining: generated.aiRemaining
            )

            guard localThemeRequestID == requestID,
                  localWordKey(customTheme) == themeKey else { return }

            let words = generated.words.localCleanWords
            guard words.count >= 2 else {
                localThemeError = localized(
                    en: "Couldn't recognize this theme. Try another.",
                    ru: "Не удалось распознать тему. Попробуй другую.",
                    es: "No se pudo reconocer el tema. Prueba otro.",
                    uk: "Не вдалося розпізнати цю тему. Спробуй іншу."
                )
                HapticManager.shared.fire(.notification(.warning))
                return
            }

            generatedPack = GeneratedWordPack(
                name: generated.name,
                category: generated.category.nilIfBlank ?? theme,
                words: words,
                aiLimit: generated.aiLimit,
                aiGenerationsToday: generated.aiGenerationsToday,
                aiRemaining: generated.aiRemaining
            )
            selectedPackID = "generated"
            localPoolExpanded = false
            disabledPoolWordKeys.removeAll()
            clearLocalPoolDraft()
            wordCount = Double(min(words.count, targetCount))
            status = localized(en: "AI WORD POOL READY", ru: "AI-ПУЛ СЛОВ ГОТОВ", es: "BANCO IA LISTO", uk: "AI-ПУЛ СЛІВ ГОТОВИЙ")
            HapticManager.shared.fire(.milestone)
            persistLocalSettings()
        } catch {
            guard localThemeRequestID == requestID else { return }
            localThemeError = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func pushLocalThemeMax() async {
        let theme = customTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = localPoolSnapshot.words.localCleanWords
        let selectedWordCount = Int(wordCount)
        let wasUsingEntirePool = selectedWordCount >= current.count
        guard !theme.isEmpty,
              !isGenerating,
              localThemeMaxWords < localThemeGenerationLimit else { return }

        let additionalCount = min(50, localThemeGenerationLimit - current.count)
        let requestID = UUID()
        let themeKey = localWordKey(theme)

        localThemeRequestID = requestID
        isExpandingLocalThemePool = true
        isGenerating = true
        localThemeError = ""
        defer {
            if localThemeRequestID == requestID {
                isGenerating = false
                isExpandingLocalThemePool = false
            }
        }

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

            guard localThemeRequestID == requestID,
                  localWordKey(customTheme) == themeKey else { return }

            var seen = Set(current.map { localWordKey($0) })
            let additions = generated.words.localCleanWords.filter { seen.insert(localWordKey($0)).inserted }
            let merged = Array((current + additions).prefix(200))
            guard merged.count > current.count else {
                localThemeError = localized(
                    en: "Couldn't find more unique words.",
                    ru: "Больше уникальных слов найти не удалось.",
                    es: "No se encontraron mas palabras unicas.",
                    uk: "Не вдалося знайти більше унікальних слів."
                )
                HapticManager.shared.fire(.notification(.warning))
                return
            }

            generatedPack = GeneratedWordPack(
                name: generated.name ?? generatedPack?.name,
                category: generated.category.nilIfBlank ?? generatedPack?.category ?? theme,
                words: merged,
                aiLimit: generated.aiLimit,
                aiGenerationsToday: generated.aiGenerationsToday,
                aiRemaining: generated.aiRemaining
            )
            selectedPackID = "generated"
            clearLocalPoolDraft()
            disabledPoolWordKeys = disabledPoolWordKeys.filter { key in
                merged.contains { localWordKey($0) == key }
            }
            wordCount = Double(
                wasUsingEntirePool
                    ? merged.count
                    : min(merged.count, max(selectedWordCount, 2))
            )
            status = localized(en: "AI WORD POOL EXPANDED", ru: "AI-ПУЛ СЛОВ РАСШИРЕН", es: "BANCO IA AMPLIADO", uk: "AI-ПУЛ СЛІВ РОЗШИРЕНО")
            HapticManager.shared.fire(.milestone)
            persistLocalSettings()
        } catch {
            guard localThemeRequestID == requestID else { return }
            localThemeError = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func saveLocalThemePack() async {
        guard let email = appState.user?.email else { return }
        guard let generatedPack else { return }

        let words = activeLocalWords(localPoolSnapshot.words)
        guard words.count >= 2 else { return }

        isSavingGeneratedPack = true
        defer { isSavingGeneratedPack = false }

        do {
            let name = generatedPack.name?.nilIfBlank
                ?? generatedPack.category.nilIfBlank
                ?? customTheme.nilIfBlank
                ?? customNameFallback
            let saved = try await appState.client.createWordPack(
                name: name,
                category: generatedPack.category.nilIfBlank ?? name,
                words: words,
                ownerEmail: email
            )
            packs.append(saved)
            packs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            appState.markWordPacksChanged()
            status = localized(en: "WORDPACK SAVED", ru: "WORDPACK СОХРАНЕН", es: "WORDPACK GUARDADO", uk: "НАБІР СЛІВ ЗБЕРЕЖЕНО")
            HapticManager.shared.fire(.milestone)
            persistLocalSettings()
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func startLocalGame() {
        let names = players.enumerated().map { index, name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "\(copy.fallbackPlayer) \(index + 1)"
        }
        guard names.count >= 3 else {
            status = localized(
                en: "NEED AT LEAST 3 OPERATIVES",
                ru: "НУЖНО МИНИМУМ 3 ОПЕРАТИВНИКА",
                es: "NECESITAS AL MENOS 3 OPERATIVOS",
                uk: "ПОТРІБНО ЩОНАЙМЕНШЕ 3 ОПЕРАТИВНИКИ"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        if localNeedsGeneratedTheme {
            status = localPrimaryActionTitle
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        if !localHasCustomTheme && selectedPackID == "builtin" && generatedPack == nil {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                revealBuiltinPool()
            }
            return
        }

        guard localPlayablePool.count >= 2 else {
            status = localized(
                en: "KEEP AT LEAST TWO ACTIVE WORDS",
                ru: "ОСТАВЬ ХОТЯ БЫ ДВА АКТИВНЫХ СЛОВА",
                es: "DEJA AL MENOS DOS PALABRAS ACTIVAS",
                uk: "ЗАЛИШ ЩОНАЙМЕНШЕ ДВА АКТИВНІ СЛОВА"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        guard let word = pickLocalWord() else {
            status = localized(
                en: "WORD POOL IS UNAVAILABLE",
                ru: "ПУЛ СЛОВ НЕДОСТУПЕН",
                es: "EL BANCO DE PALABRAS NO ESTA DISPONIBLE",
                uk: "ПУЛ СЛІВ НЕДОСТУПНИЙ"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }
        let selectedSpyCount = min(
            max(Int(spyCount.rounded()), 1),
            GameRoom.maximumSpyCount(forPlayerCount: names.count)
        )
        let spyIndices = LocalSpyAssignmentPolicy.randomSpyIndices(
            playerCount: names.count,
            requestedSpyCount: selectedSpyCount
        )
        let spyIndexSet = Set(spyIndices)
        let localPlayers = names.enumerated().map { index, name in
            LocalPlayer(name: name, avatar: avatars[safe: index] ?? "🕵️", isSpy: spyIndexSet.contains(index))
        }

        timerTask?.cancel()
        session = LocalSession(
            word: word.word,
            category: word.category,
            spyIndices: spyIndices,
            pool: word.pool,
            players: localPlayers,
            mode: mode,
            spiesKnowEachOther: spiesKnowEachOther
        )
        eliminatedPlayerIndices = []
        resetAssociationFlow(playerIndices: Array(localPlayers.indices), mode: mode)
        revealIndex = 0
        cardRevealed = false
        guessSecondsRemaining = previewLocalGuessSeconds ?? 30
        showSpyGuessOptions = false
        pendingSpyGuess = nil
        questionIndex = 0
        accusedIndex = nil
        winner = nil
        spyGuess = nil
        status = ""
        phase = .cards
        HapticManager.shared.fire(.milestone)
    }

    private func revealCard() {
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.65)) {
            cardRevealed = true
        }
        HapticManager.shared.fire(.reveal)
    }

    private func nextCardTitle(_ session: LocalSession) -> String {
        revealIndex + 1 >= session.players.count ? copy.beginTimer : localized(en: "READ - NEXT", ru: "ПРОЧИТАЛ — ДАЛЬШЕ", es: "LEIDO - SIGUIENTE", uk: "ПРОЧИТАНО — ДАЛІ")
    }

    private func nextCardIcon(_ session: LocalSession) -> String {
        revealIndex + 1 >= session.players.count ? "timer" : "checkmark"
    }

    private func cardProgressDots(_ session: LocalSession) -> some View {
        HStack(spacing: 7) {
            ForEach(session.players.indices, id: \.self) { index in
                let isCurrent = index == revealIndex
                let isComplete = index < revealIndex

                Circle()
                    .fill(isComplete ? SpyTheme.green : (isCurrent ? SpyTheme.red : Color.white.opacity(0.15)))
                    .frame(width: isCurrent ? 9 : 7, height: isCurrent ? 9 : 7)
                    .overlay(
                        Circle()
                            .stroke(isCurrent ? SpyTheme.red.opacity(0.45) : SpyTheme.strokeDim, lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, -4)
    }

    private func nextCard() {
        guard let session else { return }
        if revealIndex + 1 >= session.players.count {
            beginPlaying()
        } else {
            withAnimation(.smooth(duration: 0.28)) {
                revealIndex += 1
                cardRevealed = false
            }
            HapticManager.shared.fire(.buttonPress)
        }
    }

    private func beginPlaying() {
        secondsRemaining = Int(duration * 60)
        if let session,
           session.mode == .associations,
           associationOrder.count != activeLocalPlayerIndices(in: session).count {
            resetAssociationFlow(playerIndices: activeLocalPlayerIndices(in: session), mode: session.mode)
        }
        isLocalGamePaused = false
        phase = .playing
        HapticManager.shared.fire(.milestone)
        startLocalTimerLoop()
    }

    private func startLocalTimerLoop() {
        timerTask?.cancel()
        timerTask = nil
        guard phase == .playing, !isLocalGamePaused, secondsRemaining > 0 else { return }

        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                guard phase == .playing, !isLocalGamePaused, secondsRemaining > 0 else {
                    if phase == .playing, !isLocalGamePaused, secondsRemaining <= 0 {
                        finishLocalGameAtDeadline()
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, phase == .playing, !isLocalGamePaused else { return }
                switch LocalGameDeadlinePolicy.outcome(afterTickFrom: secondsRemaining) {
                case let .continuePlaying(remainingSeconds):
                    secondsRemaining = remainingSeconds
                case .spyWins:
                    finishLocalGameAtDeadline()
                    return
                }
            }
        }
    }

    private func toggleLocalGamePause() {
        if isLocalGamePaused {
            resumeLocalGame()
        } else {
            pauseLocalGame()
        }
        HapticManager.shared.fire(.buttonPress)
    }

    private func pauseLocalGame() {
        guard phase == .playing, !isLocalGamePaused else { return }
        isLocalGamePaused = true
        timerTask?.cancel()
        timerTask = nil
    }

    private func resumeLocalGame() {
        guard phase == .playing, isLocalGamePaused, secondsRemaining > 0 else { return }
        isLocalGamePaused = false
        startLocalTimerLoop()
    }

    private func beginForgotCardReview() {
        guard phase == .playing, let session else { return }
        let activeIndices = activeLocalPlayerIndices(in: session)
        guard !activeIndices.isEmpty else { return }

        resumeTimerAfterCardReview = !isLocalGamePaused
        pauseLocalGame()
        forgotCardRequest = LocalForgotCardRequest(
            session: session,
            activePlayerIndices: activeIndices
        )
        HapticManager.shared.fire(.buttonPress)
    }

    private func finishForgotCardReview() {
        let shouldResume = LocalGameInterruptionPolicy.shouldResumeTimerAfterCardReview(
            wasRunning: resumeTimerAfterCardReview,
            phaseIsPlaying: phase == .playing,
            remainingSeconds: secondsRemaining
        )
        resumeTimerAfterCardReview = false
        if shouldResume {
            resumeLocalGame()
        }
    }

    private func finishLocalGameAtDeadline() {
        timerTask?.cancel()
        timerTask = nil
        isLocalGamePaused = false
        forgotCardRequest = nil
        resumeTimerAfterCardReview = false
        secondsRemaining = 0
        guessSecondsRemaining = 0
        showSpyGuessOptions = false
        pendingSpyGuess = nil
        accusedIndex = nil
        spyGuess = nil
        winner = .spy
        phase = .results
        HapticManager.shared.fire(.notification(.warning))
    }

    private func activeLocalPlayerIndices(in session: LocalSession) -> [Int] {
        session.players.indices.filter { !eliminatedPlayerIndices.contains($0) }
    }

    private func activeLocalSpyPlayers(in session: LocalSession) -> [LocalPlayer] {
        activeLocalPlayerIndices(in: session).compactMap { index in
            guard let player = session.players[safe: index], player.isSpy else { return nil }
            return player
        }
    }

    private func currentAsker(in session: LocalSession) -> LocalPlayer? {
        let activeIndices = activeLocalPlayerIndices(in: session)
        guard !activeIndices.isEmpty else { return nil }
        if session.mode == .associations {
            let fallbackIndex = activeIndices[questionIndex % activeIndices.count]
            let orderedIndex = associationOrder[safe: associationStep] ?? fallbackIndex
            return session.players[safe: orderedIndex]
        }

        return session.players[safe: activeIndices[questionIndex % activeIndices.count]]
    }

    private func currentAnswerer(in session: LocalSession) -> LocalPlayer? {
        let activeIndices = activeLocalPlayerIndices(in: session)
        guard !activeIndices.isEmpty else { return nil }
        return session.players[safe: activeIndices[(questionIndex + 1) % activeIndices.count]]
    }

    private func nextQuestion(in session: LocalSession) {
        let activeIndices = activeLocalPlayerIndices(in: session)
        guard !activeIndices.isEmpty else { return }
        if session.mode == .associations {
            advanceAssociationSpeaker(playerIndices: activeIndices)
            HapticManager.shared.fire(.tabSelection)
            return
        }

        questionIndex = (questionIndex + 1) % activeIndices.count
        HapticManager.shared.fire(.tabSelection)
    }

    private func resetAssociationFlow(playerIndices: [Int], mode: LocalMode) {
        guard mode == .associations, !playerIndices.isEmpty else {
            associationOrder = []
            associationStep = 0
            associationRouletteDone = true
            return
        }

        associationOrder = shuffledAssociationOrder(playerIndices: playerIndices, avoidingFirst: nil)
        associationStep = 0
        associationRouletteDone = false
    }

    private func advanceAssociationSpeaker(playerIndices: [Int]) {
        guard !playerIndices.isEmpty else { return }

        questionIndex += 1
        let nextStep = associationStep + 1
        if nextStep >= associationOrder.count {
            let last = associationOrder.last
            associationOrder = shuffledAssociationOrder(playerIndices: playerIndices, avoidingFirst: last)
            associationStep = 0
        } else {
            associationStep = nextStep
        }
        associationRouletteDone = false
    }

    private func shuffledAssociationOrder(playerIndices: [Int], avoidingFirst avoidedFirst: Int?) -> [Int] {
        guard !playerIndices.isEmpty else { return [] }
        var shuffled = playerIndices.shuffled()
        if let avoidedFirst, shuffled.count > 1, shuffled.first == avoidedFirst {
            shuffled.swapAt(0, 1)
        }
        return shuffled
    }

    private func resolveAccusation(_ index: Int, session: LocalSession) {
        accusedIndex = index
        spyGuess = nil
        let outcome = LocalGameAccusationPolicy.outcome(
            accusing: index,
            spyFlags: session.players.map(\.isSpy),
            eliminatedIndices: eliminatedPlayerIndices
        )

        guard outcome != .invalidAccusation else { return }
        eliminatedPlayerIndices.insert(index)

        switch outcome {
        case .continuePlaying:
            accusedIndex = nil
            questionIndex = 0
            resetAssociationFlow(
                playerIndices: activeLocalPlayerIndices(in: session),
                mode: session.mode
            )
            phase = .playing
            status = session.players[index].isSpy
                ? localized(
                    en: "SPY EXCLUDED — ROUND CONTINUES",
                    ru: "ШПИОН ИСКЛЮЧЁН — ИГРА ПРОДОЛЖАЕТСЯ",
                    es: "ESPIA EXCLUIDO — LA PARTIDA CONTINUA",
                    uk: "ШПИГУНА ВИКЛЮЧЕНО — ГРА ТРИВАЄ"
                )
                : localized(
                    en: "DETECTIVE EXCLUDED — ROUND CONTINUES",
                    ru: "ДЕТЕКТИВ ИСКЛЮЧЁН — ИГРА ПРОДОЛЖАЕТСЯ",
                    es: "DETECTIVE EXCLUIDO — LA PARTIDA CONTINUA",
                    uk: "ДЕТЕКТИВА ВИКЛЮЧЕНО — ГРА ТРИВАЄ"
                )
            HapticManager.shared.fire(.notification(.success))
        case .spyWins:
            timerTask?.cancel()
            winner = .spy
            phase = .results
            HapticManager.shared.fire(.notification(.warning))
        case .detectivesWin:
            timerTask?.cancel()
            winner = .detectives
            phase = .results
            HapticManager.shared.fire(.notification(.success))
        case .invalidAccusation:
            break
        }
    }

    private func resolveSpyGuess(_ word: String, session: LocalSession) {
        timerTask?.cancel()
        spyGuess = word
        pendingSpyGuess = nil
        showSpyGuessOptions = false
        winner = localWordKey(word) == localWordKey(session.word) ? .spy : .detectives
        phase = .results
        HapticManager.shared.fire(
            .notification(winner == .spy ? .warning : .success)
        )
    }

    private func reset() {
        timerTask?.cancel()
        session = nil
        phase = .setup
        revealIndex = 0
        cardRevealed = false
        secondsRemaining = 0
        guessSecondsRemaining = previewLocalGuessSeconds ?? 30
        questionIndex = 0
        status = ""
        winner = nil
        accusedIndex = nil
        spyGuess = nil
        pendingSpyGuess = nil
        showSpyGuessOptions = false
        eliminatedPlayerIndices = []
        resetAssociationFlow(playerIndices: [], mode: .questions)
        appState.isShellChromeSuppressed = false
    }

    private func consumeLocalSetupRequestIfNeeded() {
        guard appState.localSetupRequestID > handledLocalSetupRequestID else { return }
        handledLocalSetupRequestID = appState.localSetupRequestID
        reset()
    }

    private func loadPacks() async {
        if appState.shouldUsePreviewData {
            packs = WordPack.previewPacks
            reconcileLocalWordSources()
            return
        }

        guard let email = appState.user?.email else { return }
        do {
            packs = try await appState.client.wordPacks(ownerEmail: email)
            reconcileLocalWordSources()
        } catch {
            // Keep the restored source until a successful sync can confirm
            // whether the persisted pack still exists.
        }
    }

    private func reconcileLocalWordSources() {
        if localSourceBeforeCustomTheme != "builtin",
           !packs.contains(where: { $0.id == localSourceBeforeCustomTheme }) {
            localSourceBeforeCustomTheme = "builtin"
        }

        guard !localHasCustomTheme,
              selectedPackID != "builtin",
              selectedPackID != "generated",
              !packs.contains(where: { $0.id == selectedPackID }) else { return }

        selectedPackID = "builtin"
        generatedPack = nil
        localPoolExpanded = false
        disabledPoolWordKeys.removeAll()
        clearLocalPoolDraft()
    }

    private func pickLocalWord() -> (word: String, category: String, pool: [String])? {
        if let localPoolDraft {
            return localWordSelection(from: localPoolDraft.words, category: localPoolDraft.category)
        }

        if selectedPackID == "generated" {
            guard let generatedPack else { return nil }
            return localWordSelection(
                from: generatedPack.words,
                category: generatedPack.category.nilIfBlank ?? customTheme.nilIfBlank ?? customCategoryFallback
            )
        }

        if !customTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let generatedPack {
            return localWordSelection(
                from: generatedPack.words,
                category: generatedPack.category.nilIfBlank ?? customTheme
            )
        } else if !customTheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        if selectedPackID != "builtin",
           let pack = packs.first(where: { $0.id == selectedPackID }) {
            return localWordSelection(
                from: pack.words?.localCleanWords ?? [],
                category: pack.category?.nilIfBlank ?? pack.name
            )
        } else if selectedPackID != "builtin" {
            return nil
        }

        let category = localWordPools[builtinPreviewCategory] == nil ? (localWordPools.keys.randomElement() ?? "CLASSIC") : builtinPreviewCategory
        let words = localWordPools[category] ?? localWordPools["CLASSIC"] ?? ["Embassy"]
        return localWordSelection(from: words, category: category)
    }

    private func localWordSelection(
        from words: [String],
        category: String
    ) -> (word: String, category: String, pool: [String])? {
        let pool = playableLocalWords(words)
        guard pool.count >= 2, let word = pool.randomElement() else { return nil }
        return (word, category, pool)
    }

    private func timeString(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        let remainder = max(seconds, 0) % 60
        return "\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    private func localWinnerTitle(_ winner: LocalWinner, session: LocalSession) -> String {
        guard winner == .spy, session.spyPlayers.count > 1 else {
            return winner.title(copy)
        }
        return localized(
            en: "SPIES WIN",
            ru: "ШПИОНЫ ПОБЕДИЛИ",
            es: "GANAN LOS ESPIAS",
            uk: "ШПИГУНИ ПЕРЕМОГЛИ"
        )
    }

    private func localSpyGuessResultLabel(_ session: LocalSession) -> String {
        guard session.spyPlayers.count > 1 else {
            return localized(en: "SPY GUESSED", ru: "ШПИОН УГАДАЛ", es: "EL ESPIA DIJO", uk: "ШПИГУН ВГАДАВ")
        }
        return localized(
            en: "SPY TEAM GUESSED",
            ru: "КОМАНДА ШПИОНОВ ВЫБРАЛА",
            es: "EL EQUIPO DE ESPIAS DIJO",
            uk: "КОМАНДА ШПИГУНІВ ОБРАЛА"
        )
    }

    private func persistLocalSettings() {
        let settings = LocalGameSettings(
            players: players,
            avatars: avatars,
            duration: duration,
            spyCount: Int(spyCount.rounded()),
            spiesKnowEachOther: spiesKnowEachOther,
            wordCount: wordCount,
            mode: mode.rawValue,
            selectedPackID: selectedPackID,
            customTheme: customTheme,
            generatedPack: generatedPack,
            localWordCountMode: localWordCountMode.rawValue,
            localCustomWordCount: localCustomWordCount,
            sourceBeforeCustomTheme: localSourceBeforeCustomTheme
        )

        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: LocalGameSettings.storageKey)
    }

    private func restoreLocalSettings() {
        guard let data = UserDefaults.standard.data(forKey: LocalGameSettings.storageKey),
              let settings = try? JSONDecoder().decode(LocalGameSettings.self, from: data) else {
            return
        }

        players = settings.players.count >= 3 ? settings.players : players
        avatars = settings.avatars.count == players.count ? settings.avatars : players.indices.map { localAvatars[$0 % localAvatars.count] }
        playerIDs = players.map { _ in UUID() }
        duration = min(max(settings.duration, 1), 15)
        spyCount = Double(
            min(
                max(settings.spyCount ?? 1, 1),
                GameRoom.maximumSpyCount(forPlayerCount: players.count)
            )
        )
        spiesKnowEachOther = settings.spiesKnowEachOther ?? false
        wordCount = min(max(settings.wordCount, 2), Double(localThemeGenerationLimit))
        mode = settings.mode == "classic" ? .associations : (LocalMode(rawValue: settings.mode) ?? .questions)
        selectedPackID = settings.selectedPackID
        localSourceBeforeCustomTheme = settings.sourceBeforeCustomTheme
            ?? (settings.selectedPackID == "generated" ? "builtin" : settings.selectedPackID)
        customTheme = settings.customTheme
        generatedPack = settings.generatedPack
        clearLocalPoolDraft()
        localPoolExpanded = false
        localThemeError = ""
        localThemeRequestID = UUID()
        localWordCountMode = LocalWordCountMode(rawValue: settings.localWordCountMode ?? "") ?? .recommended
        localCustomWordCount = min(max(settings.localCustomWordCount ?? settings.wordCount, 10), 80)

        if localHasCustomTheme,
           let generatedPack,
           generatedPack.words.localCleanWords.count >= 2 {
            selectedPackID = "generated"
            wordCount = min(
                max(wordCount, 2),
                Double(min(generatedPack.words.localCleanWords.count, localThemeGenerationLimit))
            )
        } else if localHasCustomTheme {
            generatedPack = nil
            if selectedPackID == "generated" {
                selectedPackID = "builtin"
            }
        } else if selectedPackID == "generated" {
            selectedPackID = "builtin"
            generatedPack = nil
        } else if selectedPackID != "builtin" {
            generatedPack = nil
        }
    }

    private func applyPreviewLocalOverrides() {
#if DEBUG
        guard appState.shouldUsePreviewData else { return }

        if let previewLocalDurationSeconds {
            duration = max(Double(previewLocalDurationSeconds) / 60.0, 1.0 / 60.0)
        }

        guard let previewPhase = previewArgumentValue(prefix: "--spyclash-preview-local-phase=") else {
            return
        }

        applyPreviewLocalPhase(previewPhase)
#endif
    }

#if DEBUG
    private func applyPreviewLocalPhase(_ rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let basePreview = LocalSession.preview
        let preview = LocalSession(
            word: basePreview.word,
            category: basePreview.category,
            spyIndices: basePreview.spyIndices,
            pool: basePreview.pool,
            players: basePreview.players,
            mode: previewLocalMode ?? basePreview.mode,
            spiesKnowEachOther: basePreview.spiesKnowEachOther
        )

        players = preview.players.map(\.name)
        avatars = preview.players.map(\.avatar)
        playerIDs = players.map { _ in UUID() }
        mode = preview.mode
        selectedPackID = "builtin"
        builtinPreviewCategory = preview.category
        clearLocalPoolDraft()
        session = preview
        eliminatedPlayerIndices = []
        resetAssociationFlow(playerIndices: Array(preview.players.indices), mode: preview.mode)
        revealIndex = min(1, preview.players.count - 1)
        cardRevealed = false
        secondsRemaining = previewLocalDurationSeconds ?? 422
        guessSecondsRemaining = previewLocalGuessSeconds ?? 24
        showSpyGuessOptions = false
        pendingSpyGuess = nil
        accusedIndex = nil
        winner = nil
        spyGuess = nil
        status = ""

        switch normalized {
        case "cards", "role", "role-hidden", "card":
            phase = .cards
        case "cards-revealed", "role-revealed", "card-revealed":
            phase = .cards
            cardRevealed = true
        case "playing", "active", "game":
            phase = .playing
            questionIndex = preview.mode == .associations ? 0 : 1
        case "spyguess", "spy-guess", "guess":
            phase = .spyGuess
        case "voting", "vote":
            phase = .voting
        case "results", "result", "detectives":
            phase = .results
            winner = .detectives
            spyGuess = "STADIUM"
        case "spy-wins", "spywins":
            phase = .results
            winner = .spy
            spyGuess = preview.word
        default:
            phase = .setup
            session = nil
        }
    }
#endif

    private func previewArgumentValue(prefix: String) -> String? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    private var customCategoryFallback: String {
        localized(
            en: "CUSTOM",
            ru: "СВОЯ ТЕМА",
            es: "PERSONALIZADO",
            uk: "ВЛАСНА ТЕМА"
        )
    }

    private var customNameFallback: String {
        localized(
            en: "Custom",
            ru: "Своя тема",
            es: "Personalizado",
            uk: "Власна тема"
        )
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .ru:
            ru
        case .es:
            es
        case .uk:
            uk
        default:
            en
        }
    }
}

private struct LocalForgotCardRequest: Identifiable {
    let id = UUID()
    let session: LocalSession
    let activePlayerIndices: [Int]
}

private struct LocalForgotCardRecoveryView: View {
    @Environment(\.dismiss) private var dismiss

    let request: LocalForgotCardRequest
    let copy: LocalGameCopy
    let language: AppLanguage

    @State private var selectedPlayerIndex: Int?
    @State private var cardRevealed = false

    var body: some View {
        ZStack {
            SpyBackground()

            ScrollView {
                VStack(spacing: 22) {
                    header

                    if let selectedPlayerIndex,
                       let player = request.session.players[safe: selectedPlayerIndex] {
                        selectedPlayerFlow(player: player)
                    } else {
                        playerPicker
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("localGame.forgotCardRecovery")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized(en: "PRIVATE CARD REVIEW", ru: "ПОВТОРНЫЙ ПРОСМОТР", es: "REVISION PRIVADA", uk: "ПРИВАТНИЙ ПЕРЕГЛЯД КАРТКИ"))
                    .font(.system(size: 17, weight: .black, design: .default))
                    .tracking(0.08)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.64)
                Text(localized(en: "The game timer is paused", ru: "Игровой таймер остановлен", es: "El temporizador esta pausado", uk: "Ігровий таймер призупинено"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(SpyTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.dark)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle())
            .accessibilityLabel(localized(en: "Close", ru: "Закрыть", es: "Cerrar", uk: "Закрити"))
        }
    }

    private var playerPicker: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(SpyTheme.red)

                Text(localized(en: "WHO FORGOT THEIR CARD?", ru: "КТО ЗАБЫЛ КАРТУ?", es: "QUIEN OLVIDO SU CARTA?", uk: "ХТО ЗАБУВ СВОЮ КАРТКУ?"))
                    .font(.system(size: 20, weight: .black, design: .default))
                    .tracking(0.06)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)

                Text(localized(
                    en: "Choose a player, then pass them the phone. No role is shown on this screen.",
                    ru: "Выбери игрока и передай ему телефон. На этом экране роль не показывается.",
                    es: "Elige un jugador y pasale el telefono. Aqui no se muestra ningun rol.",
                    uk: "Обери гравця й передай йому телефон. На цьому екрані роль не показується."
                ))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                ForEach(request.activePlayerIndices, id: \.self) { index in
                    if let player = request.session.players[safe: index] {
                        Button {
                            selectedPlayerIndex = index
                            cardRevealed = false
                            HapticManager.shared.fire(.tabSelection)
                        } label: {
                            HStack(spacing: 9) {
                                Text(player.avatar)
                                    .font(.system(size: 24))
                                Text(player.name.uppercased())
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .tracking(0.04)
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.62)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .background(SpyTheme.dark)
                            .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .accessibilityIdentifier("localGame.forgotCard.player.\(index)")
                    }
                }
            }
        }
        .padding(18)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func selectedPlayerFlow(player: LocalPlayer) -> some View {
        VStack(spacing: 20) {
            if cardRevealed {
                RoleRevealCard(
                    player: player,
                    session: request.session,
                    revealed: true,
                    copy: copy,
                    language: language,
                    dontShow: localized(en: "DON'T SHOW OTHERS", ru: "НЕ ПОКАЗЫВАЙ ДРУГИМ", es: "NO MUESTRES A OTROS", uk: "НЕ ПОКАЗУЙ ІНШИМ")
                )
                .frame(maxWidth: 280)

                Button {
                    dismiss()
                } label: {
                    SpyActionLabel(
                        title: localized(en: "I REMEMBER — CONTINUE", ru: "ВСПОМНИЛ — ПРОДОЛЖИТЬ", es: "RECORDADO — CONTINUAR", uk: "ЗГАДАВ — ПРОДОВЖИТИ"),
                        systemImage: "checkmark",
                        tracking: 0.04,
                        lines: 2
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .frame(maxWidth: 300)
                .accessibilityIdentifier("localGame.forgotCard.done")
            } else {
                Spacer(minLength: 18)

                Text(player.avatar)
                    .font(.system(size: 58))

                Text(player.name.uppercased())
                    .font(.system(size: 26, weight: .black, design: .default))
                    .tracking(0.08)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.56, alignment: .center)

                Text(localized(
                    en: "PASS THE PHONE TO THIS PLAYER. They should continue alone.",
                    ru: "ПЕРЕДАЙ ТЕЛЕФОН ЭТОМУ ИГРОКУ. Дальше смотрит только он.",
                    es: "PASA EL TELEFONO A ESTE JUGADOR. Debe continuar a solas.",
                    uk: "ПЕРЕДАЙ ТЕЛЕФОН ЦЬОМУ ГРАВЦЕВІ. Далі дивиться лише він."
                ))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

                Button {
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.35)) {
                        cardRevealed = true
                    }
                    HapticManager.shared.fire(.reveal)
                } label: {
                    SpyActionLabel(
                        title: localized(en: "I'M READY — SHOW MY CARD", ru: "Я ГОТОВ — ПОКАЗАТЬ КАРТУ", es: "ESTOY LISTO — MOSTRAR CARTA", uk: "Я ГОТОВИЙ — ПОКАЗАТИ КАРТКУ"),
                        systemImage: "eye.fill",
                        tracking: 0.04,
                        lines: 2
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .frame(maxWidth: 320)
                .accessibilityIdentifier("localGame.forgotCard.reveal")

                Button {
                    selectedPlayerIndex = nil
                } label: {
                    Text(localized(en: "CHOOSE ANOTHER PLAYER", ru: "ВЫБРАТЬ ДРУГОГО", es: "ELEGIR OTRO JUGADOR", uk: "ОБРАТИ ІНШОГО ГРАВЦЯ"))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.06)
                        .foregroundStyle(SpyTheme.muted)
                        .frame(minHeight: 44)
                }
                .buttonStyle(SpyWebPressStyle())

                Spacer(minLength: 18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch language {
        case .ru: ru
        case .es: es
        case .uk: uk
        default: en
        }
    }
}

private struct RoleRevealCard: View {
    let player: LocalPlayer
    let session: LocalSession
    let revealed: Bool
    let copy: LocalGameCopy
    let language: AppLanguage
    let dontShow: String

    private var roleAccent: Color {
        player.isSpy ? SpyTheme.red : Color.white.opacity(0.42)
    }

    var body: some View {
        ZStack {
            cardBack
                .opacity(revealed ? 0 : 1)
                .rotation3DEffect(
                    .degrees(revealed ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.82
                )

            cardFace
                .opacity(revealed ? 1 : 0)
                .rotation3DEffect(
                    .degrees(revealed ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.82
                )
        }
        .frame(maxWidth: 300)
        .aspectRatio(0.75, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityRoleLabel)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.65), value: revealed)
    }

    private var cardBack: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.04)

            CardFrontPattern()
                .padding(10)

            cardCornerAccents(color: SpyTheme.red)

            cardPip(rotated: false)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            cardPip(rotated: true)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            VStack(spacing: 10) {
                Text("🂠")
                    .font(.system(size: 46))
                    .shadow(color: SpyTheme.red.opacity(0.58), radius: 10)
                Text("SPYCLASH")
                    .font(SpyTheme.brandFont(size: 13))
                    .tracking(1.5)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.70, alignment: .center)
                LinearGradient(
                    colors: [.clear, SpyTheme.red.opacity(0.8), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 44, height: 1)
                Text(copy.tapToReveal)
                    .font(.system(size: 14, weight: .black, design: .default))
                    .tracking(0.08)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.66, alignment: .center)
                Text(dontShow)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.14)
                    .foregroundStyle(Color.white.opacity(0.24))
                    .spyFitted(lines: 1, scale: 0.66, alignment: .center)
            }
            .padding(.horizontal, 24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.90), radius: 48, y: 12)
    }

    private var cardFace: some View {
        ZStack {
            (player.isSpy ? Color(red: 0.05, green: 0, blue: 0) : Color(red: 0.02, green: 0.02, blue: 0.03))

            cardCornerAccents(color: player.isSpy ? SpyTheme.red : Color.white.opacity(0.20))

            LinearGradient(
                colors: [.clear, roleAccent.opacity(player.isSpy ? 0.78 : 0.34), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 2)
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                Text(player.isSpy ? "🕵️" : "🔍")
                    .font(.system(size: 56))
                    .padding(.bottom, 10)

                Text(player.isSpy ? copy.youAreSpy : copy.youAreDetective)
                    .font(.system(size: 22, weight: .black, design: .default))
                    .tracking(0.12)
                    .foregroundStyle(player.isSpy ? SpyTheme.red : .white)
                    .spyFitted(lines: 2, scale: 0.56, alignment: .center)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(player.isSpy ? SpyTheme.red.opacity(0.40) : Color.white.opacity(0.12))
                    .frame(width: 132, height: 1)
                    .padding(.bottom, 14)

                if player.isSpy {
                    Text(copy.category(session.category))
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(lines: 2, scale: 0.62, alignment: .center)
                        .padding(.bottom, 14)
                    Text(copy.spyHint)
                        .font(SpyTheme.mono)
                        .foregroundStyle(.white.opacity(0.74))
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 3, scale: 0.70, alignment: .center)

                    if session.spiesKnowEachOther, !spyTeammates.isEmpty {
                        VStack(spacing: 4) {
                            Text(spyTeamTitle)
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(0.08)
                                .foregroundStyle(SpyTheme.red)
                            ForEach(spyTeammates) { teammate in
                                Text("\(teammate.avatar) \(teammate.name.uppercased())")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.56)
                            }
                        }
                        .padding(.top, 10)
                    }
                } else {
                    Text(copy.secretWord)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.66, alignment: .center)
                    Text(session.word.uppercased())
                        .font(.system(size: 32, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.48, alignment: .center)
                    Text(copy.category(session.category))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.12)
                        .foregroundStyle(Color.white.opacity(0.24))
                        .spyFitted(lines: 2, scale: 0.60, alignment: .center)
                        .padding(.top, 10)
                }
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(player.isSpy ? SpyTheme.red : Color.white.opacity(0.16), lineWidth: 2)
        )
        .shadow(color: player.isSpy ? SpyTheme.red.opacity(0.26) : .black.opacity(0.80), radius: 40)
    }

    private var spyTeammates: [LocalPlayer] {
        session.spyPlayers.filter { $0.id != player.id }
    }

    private var spyTeamTitle: String {
        switch language {
        case .en: "SPY TEAM"
        case .es: "EQUIPO DE ESPIAS"
        case .ru: "КОМАНДА ШПИОНОВ"
        case .uk: "КОМАНДА ШПИГУНІВ"
        }
    }

    private var accessibilityRoleLabel: String {
        guard revealed else { return copy.tapToReveal }
        guard player.isSpy else { return copy.youAreDetective }
        guard session.spiesKnowEachOther, !spyTeammates.isEmpty else { return copy.youAreSpy }

        let teammateNames = spyTeammates.map(\.name).joined(separator: ", ")
        return "\(copy.youAreSpy). \(spyTeamTitle): \(teammateNames)"
    }

    private func cardPip(rotated: Bool) -> some View {
        VStack(spacing: 0) {
            Text("S")
                .font(.system(size: 12, weight: .black, design: .monospaced))
            Text("♦")
                .font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundStyle(SpyTheme.red)
        .rotationEffect(.degrees(rotated ? 180 : 0))
    }

    private func cardCornerAccents(color: Color) -> some View {
        ZStack {
            cardCorner(color: color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            cardCorner(color: color)
                .rotationEffect(.degrees(90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            cardCorner(color: color)
                .rotationEffect(.degrees(-90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            cardCorner(color: color)
                .rotationEffect(.degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func cardCorner(color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 18))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 18, y: 0))
        }
        .stroke(color, lineWidth: 2)
        .frame(width: 18, height: 18)
    }
}

private struct CardFrontPattern: View {
    var body: some View {
        Canvas { context, size in
            var forward = Path()
            var x = -size.height
            while x <= size.width {
                forward.move(to: CGPoint(x: x, y: 0))
                forward.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += 10
            }

            var backward = Path()
            var y = CGFloat(0)
            while y <= size.width + size.height {
                backward.move(to: CGPoint(x: y, y: 0))
                backward.addLine(to: CGPoint(x: y - size.height, y: size.height))
                y += 10
            }

            context.stroke(forward, with: .color(.white.opacity(0.04)), lineWidth: 2)
            context.stroke(backward, with: .color(.white.opacity(0.04)), lineWidth: 2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct LocalGlitchText: View {
    let text: String
    var speedNanoseconds: UInt64 = 40_000_000

    @State private var displayed = ""

    private let glitchCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%")

    var body: some View {
        Text(displayed.isEmpty ? " " : displayed)
            .task(id: text) {
                await animate()
            }
    }

    @MainActor
    private func animate() async {
        displayed = ""
        let characters = Array(text)

        guard !characters.isEmpty else {
            displayed = text
            return
        }

        for tick in 0...(characters.count * 2) {
            if Task.isCancelled { return }

            let revealedCount = min(tick / 2, characters.count)
            let revealed = String(characters.prefix(revealedCount))
            let scrambled = characters
                .dropFirst(revealedCount)
                .map { character in
                    character == " " ? " " : (glitchCharacters.randomElement() ?? character)
                }

            displayed = revealed + String(scrambled)

            try? await Task.sleep(nanoseconds: speedNanoseconds)
        }

        displayed = text
    }
}

enum LocalLobbyPrimaryActionPolicy {
    enum Source: Equatable {
        case builtin
        case saved
        case generated
    }

    enum Action: Equatable {
        case generateRequired
        case revealRandom
        case dealCards
    }

    struct Resolution: Equatable {
        let action: Action
        let isEnabled: Bool
    }

    static func resolve(
        hasCustomTheme: Bool,
        hasGeneratedPack: Bool,
        source: Source
    ) -> Resolution {
        if hasCustomTheme, !hasGeneratedPack {
            return Resolution(action: .generateRequired, isEnabled: false)
        }

        if source == .builtin, !hasGeneratedPack {
            return Resolution(action: .revealRandom, isEnabled: true)
        }

        return Resolution(action: .dealCards, isEnabled: true)
    }
}

private enum LocalMode: String, CaseIterable, Identifiable {
    case questions
    case associations

    var id: String { rawValue }

    func title(_ copy: LocalGameCopy) -> String {
        switch self {
        case .questions: copy.questionsMode
        case .associations: copy.classicMode
        }
    }
}

private enum LocalPhase: Equatable {
    case setup
    case cards
    case playing
    case spyGuess
    case voting
    case results

    var isGameProcess: Bool {
        switch self {
        case .setup:
            false
        case .cards, .playing, .spyGuess, .voting, .results:
            true
        }
    }

    func status(_ copy: LocalGameCopy) -> String {
        switch self {
        case .setup: copy.setupStatus
        case .cards: copy.cardsStatus
        case .playing: copy.playingStatus
        case .spyGuess: copy.spyGuessStatus
        case .voting: copy.votingStatus
        case .results: copy.resultsStatus
        }
    }
}

private enum LocalWinner {
    case spy
    case detectives

    func title(_ copy: LocalGameCopy) -> String {
        switch self {
        case .spy: copy.spyWins
        case .detectives: copy.detectivesWin
        }
    }
}

private struct LocalPlayer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let avatar: String
    let isSpy: Bool
}

private struct LocalSession: Equatable {
    let word: String
    let category: String
    let spyIndices: [Int]
    let pool: [String]
    let players: [LocalPlayer]
    let mode: LocalMode
    let spiesKnowEachOther: Bool

    var spyPlayers: [LocalPlayer] {
        players.filter(\.isSpy)
    }
}

#if DEBUG
private extension LocalSession {
    static var preview: LocalSession {
        LocalSession(
            word: "Metro",
            category: "NIGHT CITY",
            spyIndices: [1],
            pool: ["Metro", "Rooftop", "Taxi", "Stadium", "Signal", "Market", "Tunnel", "Harbor"],
            players: [
                LocalPlayer(name: "Red Raven", avatar: "🕵️", isSpy: false),
                LocalPlayer(name: "Ghost", avatar: "👤", isSpy: true),
                LocalPlayer(name: "Signal", avatar: "🔥", isSpy: false)
            ],
            mode: .questions,
            spiesKnowEachOther: false
        )
    }
}
#endif

private struct LocalPoolSnapshot {
    let category: String
    let source: String
    let words: [String]
    let countLabel: String
    let emptyMessage: String
}

private struct LocalPoolDraft: Hashable {
    let category: String
    let source: String
    let words: [String]
}

private enum LocalSetupField: Hashable {
    case player(Int)
    case theme
    case poolWord
}

private enum LocalSetupPanel: Hashable {
    case mission
    case mode
    case roles
    case players
    case intel
    case timing
}

private enum LocalWordCountMode: String, CaseIterable, Identifiable {
    case recommended
    case custom

    var id: String { rawValue }
}

private struct LocalGameSettings: Codable {
    static let storageKey = "spyclash.local.settings.v2"

    let players: [String]
    let avatars: [String]
    let duration: Double
    let spyCount: Int?
    let spiesKnowEachOther: Bool?
    let wordCount: Double
    let mode: String
    let selectedPackID: String
    let customTheme: String
    let generatedPack: GeneratedWordPack?
    let localWordCountMode: String?
    let localCustomWordCount: Double?
    let sourceBeforeCustomTheme: String?
}

private let localAvatars = ["🕵️", "👤", "🤖", "🎭", "🧠", "💀", "🎯", "🔥", "👻", "🦅"]
private let localCollapsedPoolPreviewLimit = 8
private let localThemeGenerationLimit = 200

private let localWordPools: [String: [String]] = [
    "CLASSIC": [
        "Embassy", "Submarine", "Casino", "Airport", "Museum", "Hospital", "Bank Vault", "Opera House", "Train Station", "University",
        "Restaurant", "Cinema", "Library", "Space Station", "Police Station", "Hotel", "Zoo", "Laboratory", "Stadium", "Shopping Mall",
        "Cathedral", "Courtroom", "Factory", "Circus", "Theater", "School", "Post Office", "Harbor", "Metro", "Aquarium"
    ],
    "BLACK OPS": [
        "Safehouse", "Satellite", "Cipher", "Dead Drop", "Briefcase", "Laser Grid", "Rooftop", "Interrogation", "Vault", "Checkpoint",
        "Encrypted Drive", "Control Room", "Night Vision", "Drone", "Radio Tower", "Border Gate", "Decoy Van", "Hidden Tunnel", "Signal Jammer", "Microfilm",
        "Extraction Point", "Silent Alarm", "Disguise Kit", "Listening Post", "Fake Passport", "Underground Bunker", "Code Phrase", "Thermal Camera", "Blackout", "Courier"
    ],
    "TRAVEL": [
        "Hotel", "Beach", "Cruise Ship", "Ski Resort", "Desert Camp", "Night Market", "Theme Park", "Harbor", "Cathedral", "Metro",
        "Airport Lounge", "Mountain Cabin", "Train Platform", "Old Town", "Safari Lodge", "Island Ferry", "Street Market", "Museum Tour", "Vineyard", "Capsule Hotel",
        "Bus Terminal", "National Park", "River Boat", "Temple", "Boardwalk", "Hostel", "Observation Deck", "Cable Car", "Souvenir Shop", "Camping Site"
    ]
]

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array where Element == String {
    var localCleanWords: [String] {
        var seen = Set<String>()
        return compactMap { raw in
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            let key = word.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return word
        }
    }
}
