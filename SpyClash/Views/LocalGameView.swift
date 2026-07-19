import SwiftUI

struct LocalGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var players = ["", ""]
    @State private var avatars = ["🕵️", "👤"]
    @State private var duration = 10.0
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
    @State private var isChoosingLocalPoolExpansion = false
    @State private var localPoolExpansionCount = 50.0
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
    @State private var playerIDs = [UUID(), UUID()]
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
    @State private var winner: LocalWinner?
    @State private var timerTask: Task<Void, Never>?
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
        localBody
            .task {
                restoreLocalSettings()
                applyPreviewLocalOverrides()
                consumeLocalSetupRequestIfNeeded()
                await loadPacks()
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    localPreviewPulse = true
                }
                updateLocalShellChromeSuppression()
            }
            .onChange(of: players) { _, _ in persistLocalSettings() }
            .onChange(of: avatars) { _, _ in persistLocalSettings() }
            .onChange(of: duration) { _, _ in persistLocalSettings() }
            .onChange(of: wordCount) { _, _ in persistLocalSettings() }
            .onChange(of: mode) { _, _ in persistLocalSettings() }
            .onChange(of: selectedPackID) { _, _ in persistLocalSettings() }
            .onChange(of: customTheme) { _, _ in persistLocalSettings() }
            .onChange(of: localWordCountMode) { _, _ in persistLocalSettings() }
            .onChange(of: localCustomWordCount) { _, _ in persistLocalSettings() }
            .onChange(of: phase) { _, _ in updateLocalShellChromeSuppression() }
            .onChange(of: appState.localSetupRequestID) { _, _ in consumeLocalSetupRequestIfNeeded() }
            .onDisappear {
                timerTask?.cancel()
                appState.isShellChromeSuppressed = false
            }
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
        PageChrome(eyebrow: copy.eyebrow, status: phase.status(copy)) {
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
            .animation(.smooth(duration: 0.38), value: phase)
        }
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

            VStack(alignment: .leading, spacing: 14) {
                localSetupSlot(.mission) {
                    localMissionPanel
                }
                localSetupSlot(.mode) {
                    localModePanel
                }
                localSetupSlot(.players) {
                    localPlayersPanel
                }
                localSetupSlot(.intel) {
                    localIntelPanel
                }
                localSetupSlot(.controls) {
                    localControls
                }
                localSetupSlot(.timing) {
                    localTimingPanel
                }
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .animation(localSetupFocusAnimation, value: animatedLocalSetupPanel)
        .onAppear {
            animatedLocalSetupPanel = focusedLocalSetupPanel
        }
        .onChange(of: focusedLocalSetupPanel) { _, newPanel in
            withAnimation(localSetupFocusAnimation) {
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
                .modifier(LocalSetupFocusEffect(dimmed: dimmed))

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
        withAnimation(localSetupFocusAnimation) {
            animatedLocalSetupPanel = nil
            focusedLocalSetupField = nil
        }
        resetPlayerDragState()
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
        SpySceneStage(accent: mode == .questions ? SpyTheme.red : SpyTheme.amber, motionDelay: 0, minHeight: 150, isSubtle: true) {
            VStack(alignment: .leading, spacing: 11) {
                SpySceneKicker(
                    title: localized(en: "PASS & PLAY", ru: "ПЕРЕДАВАЙ И ИГРАЙ", es: "PASA Y JUEGA"),
                    status: nil,
                    accent: mode == .questions ? SpyTheme.red : SpyTheme.amber
                )

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(localized(en: "LOCAL MISSION", ru: "ЛОКАЛЬНАЯ МИССИЯ", es: "MISION LOCAL"))
                            .font(SpyTheme.brandFont(size: 29))
                            .tracking(1.2)
                            .foregroundStyle(.white)
                            .spyFitted(lines: 2, scale: 0.62)

                        Text(localized(
                            en: "One device. Secret roles. No network required.",
                            ru: "Один телефон. Тайные роли. Сеть не нужна.",
                            es: "Un dispositivo. Roles secretos. Sin red."
                        ))
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .lineSpacing(3)
                        .foregroundStyle(SpyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%02d", players.count))
                            .font(SpyTheme.brandFont(size: 30))
                            .foregroundStyle(.white)
                        Text(localized(en: "OPERATIVES", ru: "ОПЕРАТИВНИКИ", es: "AGENTES"))
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.08)
                            .foregroundStyle(SpyTheme.dim)
                    }
                }

                HStack(spacing: 8) {
                    localMissionBadge(mode == .questions ? localized(en: "QUESTIONS", ru: "ВОПРОСЫ", es: "PREGUNTAS") : localized(en: "ASSOCIATIONS", ru: "АССОЦИАЦИИ", es: "ASOCIACIONES"), color: mode == .questions ? SpyTheme.red : SpyTheme.amber)
                    localMissionBadge(localDurationLabel, color: SpyTheme.muted)
                }
            }
        }
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
                sectionHeader(systemImage: "gearshape.fill", title: localized(en: "GAME MODE", ru: "РЕЖИМ ИГРЫ", es: "MODO DE JUEGO"))

                HStack(spacing: 10) {
                    localModeOption(.questions, symbol: "?")
                    localModeOption(.associations, symbol: "💭")
                }
            }
        }
    }

    private var localPlayersPanel: some View {
        localSetupPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(systemImage: "person.2.fill", title: "\(localized(en: "PLAYERS", ru: "ИГРОКИ", es: "JUGADORES")) (\(players.count))")

                VStack(spacing: 8) {
                    ForEach(localPlayerRows, id: \.id) { row in
                        localPlayerEditorRow(index: row.index, id: row.id)
                    }
                }

                if players.count < 10 {
                    Button {
                        addPlayer()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .black))
                            Text(localized(en: "ADD PLAYER", ru: "ДОБАВИТЬ ИГРОКА", es: "ANADIR JUGADOR"))
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
                }
            }
            .animation(.smooth(duration: 0.18), value: playerIDs)
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

            localPlayerNameField(index: index, id: id)

            if players.count > 2 {
                localRemovePlayerButton(index: index)
            }
        }
        .opacity(isDragging ? 0.72 : 1)
        .offset(y: isDragging ? playerDragResidualY : 0)
        .scaleEffect(isDragging ? 1.015 : (isArmed ? 0.985 : 1))
        .zIndex(isDragging ? 10 : 0)
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.16), value: armedPlayerID)
        .animation(.smooth(duration: 0.16), value: draggingPlayerIndex)
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
        .accessibilityLabel(localized(en: "Reorder player", ru: "Переставить игрока", es: "Reordenar jugador"))
        .accessibilityHint(localized(en: "Hold and drag to reorder", ru: "Зажми и перетащи, чтобы изменить порядок", es: "Mantén y arrastra para reordenar"))
    }

    private func localPlayerNameField(index: Int, id: UUID) -> some View {
        TextField(
            localized(en: "Player \(index + 1)", ru: "Игрок \(index + 1)", es: "Jugador \(index + 1)"),
            text: localPlayerNameBinding(id: id)
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
    }

    private func localPlayerNameBinding(id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let index = playerIDs.firstIndex(of: id),
                      players.indices.contains(index) else { return "" }
                return players[index]
            },
            set: { value in
                guard let index = playerIDs.firstIndex(of: id),
                      players.indices.contains(index) else { return }
                players[index] = value
            }
        )
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
            withAnimation(.smooth(duration: 0.14)) {
                movePlayer(from: currentIndex, to: currentIndex + 1)
            }
            currentIndex += 1
            draggingPlayerIndex = currentIndex
            playerDragResidualY -= rowStride
            HapticManager.shared.fire(.tabSelection)
        }

        while playerDragResidualY < -rowStride / 2, currentIndex > 0 {
            withAnimation(.smooth(duration: 0.14)) {
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
                withAnimation(.smooth(duration: 0.18)) {
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
        .accessibilityLabel(localized(en: "Remove player", ru: "Удалить игрока", es: "Eliminar jugador"))
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
        .animation(.smooth(duration: 0.28), value: localHasCustomTheme)
        .animation(.smooth(duration: 0.28), value: localThemeAnalyzed)
        .animation(.smooth(duration: 0.28), value: generatedPack)
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
        if !localThemeError.isEmpty {
            Text(localThemeError)
                .font(.system(size: 12, weight: .semibold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.red)
                .spyFitted(lines: 2, scale: 0.62)
        }

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
            localGeneratedPoolControls
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(SpyTheme.panel, in: CutCornerShape(cut: 12))
            .overlay(
                CutCornerShape(cut: 12)
                    .stroke(SpyTheme.stroke, lineWidth: 1)
            )
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

    private func localPackChip(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .black, design: .default))
                    .tracking(0.02)
                    .spyFitted(scale: 0.56, alignment: .center)

                if let subtitle {
                    Text("(\(subtitle))")
                        .font(.system(size: 9, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? SpyTheme.red : SpyTheme.muted)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(isSelected ? SpyTheme.red.opacity(0.06) : SpyTheme.dark)
            .overlay(Rectangle().stroke(isSelected ? SpyTheme.red.opacity(0.50) : SpyTheme.strokeStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
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
                    withAnimation(.smooth(duration: 0.20)) {
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
                .accessibilityLabel(localized(en: "Clear theme", ru: "Очистить тему", es: "Limpiar tema"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
        .overlay(
            CutCornerShape(cut: 9)
                .stroke(focusedLocalSetupField == .theme ? SpyTheme.red.opacity(0.86) : SpyTheme.inputBorder, lineWidth: 1)
        )
        .shadow(color: focusedLocalSetupField == .theme ? SpyTheme.red.opacity(0.12) : .clear, radius: 8)
        .animation(.smooth(duration: 0.18), value: focusedLocalSetupField == .theme)
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
        isChoosingLocalPoolExpansion = false
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

                    SpyWebSlider(value: $localCustomWordCount, range: 10...80, step: 1)
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
            withAnimation(.smooth(duration: 0.18)) {
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
    }

    private var localGenerateButton: some View {
        Button {
            Task { await generateLocalTheme() }
        } label: {
            if isGenerating && !isExpandingLocalThemePool {
                SpyLoadingLabel(
                    title: localized(en: "GENERATING INTEL", ru: "ГЕНЕРАЦИЯ INTEL", es: "GENERANDO INTEL"),
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
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localized(en: "You don't have any word packs yet.", ru: "У тебя пока нет word packs.", es: "Aun no tienes word packs."))
                                .font(.system(size: 11, weight: .bold, design: .default))
                                .tracking(0.02)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 2, scale: 0.62)
                            Text(localized(en: "+ Create first pack →", ru: "+ Создать первый пак →", es: "+ Crear primer pack →"))
                                .font(.system(size: 11, weight: .black, design: .monospaced))
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
                Text("\(localized(en: "WORD PACKS", ru: "WORD PACKS", es: "WORD PACKS")) \(packs.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                    localPackChip(
                        title: localized(en: "RANDOM", ru: "СЛУЧАЙНО", es: "AZAR"),
                        subtitle: nil,
                        isSelected: selectedPackID == "builtin"
                    ) {
                        selectLocalWordSource("builtin")
                    }

                    ForEach(packs) { pack in
                        localPackChip(
                            title: pack.name,
                            subtitle: "\(pack.words?.localCleanWords.count ?? 0)",
                        isSelected: selectedPackID == pack.id
                    ) {
                        selectLocalWordSource(pack.id)
                    }
                }
                }

                if selectedPackID != "builtin",
                   let selected = packs.first(where: { $0.id == selectedPackID }) {
                    Text("\(localized(en: "Selected", ru: "Выбрано", es: "Seleccionado")) \(selected.name) · \(selected.words?.localCleanWords.count ?? 0) \(copy.wordsSuffix)")
                        .font(.system(size: 10, weight: .bold, design: .default))
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
                    step: 1,
                    accent: SpyTheme.red
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

    private var localGeneratedPoolControls: some View {
        Group {
            if isChoosingLocalPoolExpansion, localPoolExpansionMaximum > 0 {
                localPoolExpansionPicker
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    localWordsSlider

                    if localThemeMaxWords < localThemeGenerationLimit {
                        localAddMoreWordsButton
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: isChoosingLocalPoolExpansion
        )
    }

    private var localPoolExpansionPicker: some View {
        SpyPoolExpansionPicker(
            additionalWords: $localPoolExpansionCount,
            range: Double(localPoolExpansionMinimum)...Double(localPoolExpansionMaximum),
            currentPoolCount: localThemeMaxWords,
            poolLimit: localThemeGenerationLimit,
            title: localized(en: "EXPAND POOL", ru: "РАСШИРИТЬ ПУЛ", es: "AMPLIAR BANCO"),
            poolProgressTitle: localized(
                en: "PROJECTED POOL",
                ru: "ПРОГНОЗ ПУЛА",
                es: "BANCO ESTIMADO"
            ),
            confirmTitle: { count in
                localized(
                    en: "ADD UP TO +\(count) WORDS",
                    ru: "ДОБАВИТЬ ДО +\(count) СЛОВ",
                    es: "ANADIR HASTA +\(count) PALABRAS"
                )
            },
            loadingTitle: { count in
                localized(
                    en: "ADDING UP TO +\(count) WORDS",
                    ru: "ДОБАВЛЯЕМ ДО +\(count) СЛОВ",
                    es: "ANADIENDO HASTA +\(count) PALABRAS"
                )
            },
            closeAccessibilityLabel: localized(
                en: "Close pool expansion",
                ru: "Закрыть расширение пула",
                es: "Cerrar ampliacion del banco"
            ),
            accessibilityPrefix: "localGame.poolExpansion",
            isLoading: isExpandingLocalThemePool,
            onClose: closeLocalPoolExpansion,
            onConfirm: beginLocalPoolExpansion
        )
    }

    private var localPoolExpansionMaximum: Int {
        min(100, max(localThemeGenerationLimit - localThemeMaxWords, 0))
    }

    private var localPoolExpansionMinimum: Int {
        min(5, localPoolExpansionMaximum)
    }

    private var localAddMoreWordsButton: some View {
        Button {
            openLocalPoolExpansion()
        } label: {
            SpyActionLabel(
                title: localAddMoreWordsLabel,
                systemImage: "plus.circle.fill",
                fontSize: 10.5,
                iconSize: 13,
                tracking: 0.02,
                lines: 2
            )
        }
        .buttonStyle(SpyButtonStyle(variant: .outline))
        .disabled(isGenerating || localThemeMaxWords >= localThemeGenerationLimit)
        .accessibilityIdentifier("localGame.addMoreThemeWords")
    }

    private func openLocalPoolExpansion() {
        guard localPoolExpansionMaximum > 0, !isGenerating else { return }
        localPoolExpansionCount = Double(min(50, localPoolExpansionMaximum))
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            isChoosingLocalPoolExpansion = true
        }
        HapticManager.shared.fire(.buttonPress)
    }

    private func closeLocalPoolExpansion() {
        guard !isExpandingLocalThemePool else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            isChoosingLocalPoolExpansion = false
        }
        HapticManager.shared.fire(.buttonPress)
    }

    private func beginLocalPoolExpansion(_ count: Int) {
        guard !isGenerating, localPoolExpansionMaximum > 0 else { return }
        isExpandingLocalThemePool = true
        isGenerating = true
        Task { await pushLocalThemeMax(additionalCount: count) }
    }

    private var localSaveAsWordPackButton: some View {
        Button {
            Task { await saveLocalThemePack() }
        } label: {
            if isSavingGeneratedPack {
                SpyLoadingLabel(
                    title: localized(en: "SAVING PACK", ru: "СОХРАНЕНИЕ ПАКА", es: "GUARDANDO PACK"),
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

                SpyWebSlider(value: $duration, range: 1...15, step: 1)
            }
        }
    }

    private var localControls: some View {
        VStack(spacing: 10) {
            Button {
                startLocalGame()
            } label: {
                SpyPrimaryCommandLabel(
                    title: localPrimaryActionTitle,
                    detail: localPrimaryActionDetail,
                    systemImage: localNeedsGeneratedTheme ? "sparkles" : "rectangle.portrait.on.rectangle.portrait.angled.fill"
                )
            }
            .buttonStyle(SpyPrimaryCommandStyle())
            .disabled(localNeedsGeneratedTheme)
            .opacity(localNeedsGeneratedTheme ? 0.48 : 1)

            Button {
                appState.selectedTab = .home
            } label: {
                SpyActionLabel(title: localized(en: "BACK", ru: "НАЗАД", es: "ATRAS"), systemImage: "chevron.left", tracking: 0.02)
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))

            if !status.isEmpty {
                Text(status)
                    .font(SpyTheme.micro)
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(lines: 3, scale: 0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var localPrimaryActionTitle: String {
        if localNeedsGeneratedTheme {
            return localized(en: "GENERATE THEME FIRST", ru: "СНАЧАЛА СГЕНЕРИРУЙ ТЕМУ", es: "GENERA EL TEMA PRIMERO")
        }

        if !localHasCustomTheme && selectedPackID == "builtin" && generatedPack == nil {
            return localized(en: "RANDOM THEME", ru: "СЛУЧАЙНАЯ ТЕМА", es: "TEMA ALEATORIO")
        }

        return localized(en: "DEAL CARDS", ru: "РАЗДАТЬ КАРТОЧКИ", es: "REPARTIR CARTAS")
    }

    private var localPrimaryActionDetail: String {
        if localNeedsGeneratedTheme {
            return localized(en: "COMPLETE INTEL ABOVE", ru: "ЗАВЕРШИ ПОДГОТОВКУ INTEL", es: "COMPLETA INTEL ARRIBA")
        }

        if !localHasCustomTheme && selectedPackID == "builtin" && generatedPack == nil {
            return localized(en: "REVEAL A RANDOM FIELD POOL", ru: "ОТКРЫТЬ СЛУЧАЙНЫЙ НАБОР", es: "REVELAR UN GRUPO ALEATORIO")
        }

        return localized(en: "PASS THE DEVICE TO REVEAL ROLES", ru: "ПЕРЕДАВАЙ ТЕЛЕФОН ДЛЯ РАСКРЫТИЯ РОЛЕЙ", es: "PASA EL DISPOSITIVO PARA VER ROLES")
    }

    private var localDurationLabel: String {
        let seconds = max(Int((duration * 60).rounded()), 1)
        if seconds < 60 {
            return localized(en: "\(seconds) SEC", ru: "\(seconds) СЕК", es: "\(seconds) SEG")
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
        localized(en: "THEME", ru: "ТЕМА", es: "TEMA")
    }

    private var localUnlimitedLabel: String {
        localized(en: "AI INTEL", ru: "AI INTEL", es: "IA INTEL")
    }

    private var localThemePlaceholder: String {
        localized(en: "Marvel, European countries...", ru: "Marvel, страны Европы...", es: "Marvel, paises...")
    }

    private var localCountLabel: String {
        localized(en: "// WORDS TO CREATE", ru: "// СОЗДАТЬ СЛОВ", es: "// PALABRAS A CREAR")
    }

    private var localWordsLabel: String {
        localized(en: "WORDS IN GAME", ru: "СЛОВ В ИГРЕ", es: "PALABRAS EN JUEGO")
    }

    private var localAddMoreWordsLabel: String {
        if localThemeMaxWords >= localThemeGenerationLimit {
            return localized(en: "WORD POOL MAXED", ru: "ДОСТИГНУТ МАКСИМУМ", es: "BANCO AL MAXIMO")
        }
        return localized(en: "EXPAND POOL", ru: "РАСШИРИТЬ ПУЛ", es: "AMPLIAR BANCO")
    }

    private var localAIWarning: String {
        localized(
            en: "AI may make mistakes. Double-check words before playing.",
            ru: "AI может ошибаться. Проверь слова перед игрой.",
            es: "IA puede fallar. Revisa las palabras antes de jugar."
        )
    }

    private var localAddWordPlaceholder: String {
        localized(en: "Add word...", ru: "Добавить слово...", es: "Agregar palabra...")
    }

    private var localRandomThemeHint: String {
        localized(
            en: "Leave the field empty to play from a random or saved word pack.",
            ru: "Оставь поле пустым, чтобы играть со случайной темой или сохраненным паком.",
            es: "Deja el campo vacio para jugar con un tema aleatorio o pack guardado."
        )
    }

    private var localSaveAsWordPackLabel: String {
        localized(en: "SAVE AS WORDPACK", ru: "СОХРАНИТЬ КАК WORDPACK", es: "GUARDAR WORDPACK")
    }

    private var localPoolIcon: String {
        if localHasCustomTheme { return "✨" }
        if selectedPackID != "builtin" { return "📦" }
        return "🎲"
    }

    private var localPoolLabel: String {
        if localHasCustomTheme {
            return localized(en: "GENERATED", ru: "СГЕНЕРИРОВАНО", es: "GENERADO")
        }
        if selectedPackID != "builtin" {
            return localized(en: "WORDPACK", ru: "WORDPACK", es: "WORDPACK")
        }
        return localized(en: "RANDOM THEME", ru: "СЛУЧАЙНАЯ ТЕМА", es: "TEMA ALEATORIO")
    }

    private var localThemeActionTitle: String {
        if generatedPack?.words.localCleanWords.count ?? 0 >= 2 {
            return localized(en: "REGENERATE", ru: "СГЕНЕРИРОВАТЬ ЗАНОВО", es: "REGENERAR")
        }
        return localized(en: "GENERATE WORDS", ru: "СГЕНЕРИРОВАТЬ СЛОВА", es: "GENERAR PALABRAS")
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
            localized(en: "RECOMMENDED", ru: "РЕКОМЕНДОВАНО", es: "RECOMENDADO")
        case .custom:
            localized(en: "CUSTOM", ru: "СВОЙ ВЫБОР", es: "CUSTOM")
        }
    }

    private func localWordCountModeHint(_ mode: LocalWordCountMode) -> String {
        switch mode {
        case .recommended:
            localized(en: "100 words", ru: "100 слов", es: "100 palabras")
        case .custom:
            localized(
                en: "\(Int(localCustomWordCount)) words",
                ru: "\(Int(localCustomWordCount)) слов",
                es: "\(Int(localCustomWordCount)) palabras"
            )
        }
    }

    private func localThemeMetaLabel(maxWords: Int) -> String {
        return localized(
            en: "AI POOL · \(maxWords) AVAILABLE",
            ru: "AI-ПУЛ · \(maxWords) ДОСТУПНО",
            es: "BANCO IA · \(maxWords) DISPONIBLES"
        )
    }

    private func localPoolStats(inGame: Int, active: Int, total: Int) -> String {
        localized(
            en: "\(inGame) in game · \(active)/\(total) active · tap to cross out",
            ru: "\(inGame) в игре · \(active)/\(total) активных · нажми, чтобы вычеркнуть",
            es: "\(inGame) en juego · \(active)/\(total) activas · toca para tachar"
        )
    }

    private func localPoolExpansionLabel(total: Int) -> String {
        if localPoolExpanded {
            return localized(en: "SHOW LESS", ru: "ПОКАЗАТЬ МЕНЬШЕ", es: "MOSTRAR MENOS")
        }

        return localized(
            en: "SHOW ALL \(total) WORDS",
            ru: "ПОКАЗАТЬ ВСЕ СЛОВА · \(total)",
            es: "MOSTRAR \(total) PALABRAS"
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
        withAnimation(.smooth(duration: 0.22)) {
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

    private func localModeOption(_ candidate: LocalMode, symbol: String) -> some View {
        let isSelected = mode == candidate

        return Button {
            HapticManager.shared.fire(.tabSelection)
            withAnimation(.smooth(duration: 0.24)) {
                mode = candidate
            }
        } label: {
            VStack(spacing: 7) {
                Text(symbol)
                    .font(.system(size: candidate == .questions ? 22 : 20, weight: .black, design: .default))
                    .foregroundStyle(isSelected ? .white.opacity(0.82) : SpyTheme.dim)

                Text(candidate.title(copy))
                    .font(.system(size: 11, weight: .black, design: .default))
                    .tracking(candidate.title(copy).count > 10 ? 0.0 : 0.08)
                    .foregroundStyle(isSelected ? .white : SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 82)
            .background(isSelected ? SpyTheme.red : Color.clear, in: CutCornerShape(cut: 9))
            .overlay(
                CutCornerShape(cut: 9)
                    .stroke(isSelected ? SpyTheme.red : SpyTheme.stroke, lineWidth: 1)
            )
            .contentShape(CutCornerShape(cut: 9))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func localModeSubtitle(_ mode: LocalMode) -> String {
        switch mode {
        case .questions:
            localized(
                en: "Ask direct questions in a rotating pair. Best when players want a sharper interrogation rhythm.",
                ru: "Игроки задают вопросы по очереди. Лучше для жесткого ритма допроса.",
                es: "Haz preguntas directas por turnos. Ideal para un ritmo mas tactico."
            )
        case .associations:
            localized(
                en: "Each player says one association. Best when the table wants a fast, web-style clue chain.",
                ru: "Каждый говорит одну ассоциацию. Ближе к web-ритму с быстрой цепочкой подсказок.",
                es: "Cada jugador dice una asociacion. Ideal para una cadena rapida de pistas."
            )
        }
    }

    private func localModeMicrocopy(_ mode: LocalMode) -> String {
        switch mode {
        case .questions:
            localized(en: "ASK / ANSWER", ru: "ВОПРОС / ОТВЕТ", es: "PREGUNTA / RESPONDE")
        case .associations:
            localized(en: "ONE CLUE EACH", ru: "ПО ОДНОЙ ПОДСКАЗКЕ", es: "UNA PISTA")
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
                            title: localized(en: "REROLL", ru: "ДРУГОЙ", es: "OTRO"),
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
                        withAnimation(.smooth(duration: 0.30)) {
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
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: localPreviewPulse)
        }
        .animation(.smooth(duration: 0.30), value: localPoolExpanded)
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
                    .accessibilityLabel(localized(en: "Remove \(word)", ru: "Удалить \(word)", es: "Eliminar \(word)"))
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
                    dontShow: localized(en: "DON'T SHOW OTHERS", ru: "НЕ ПОКАЗЫВАЙ ДРУГИМ", es: "NO MUESTRES A OTROS")
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
                localTimerStrip
                localAgentStrip(session)

                if session.mode == .questions {
                    localActivePairCard(session)
                } else {
                    localAssociationCard(session)
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
                Text(localized(en: "// ASSOCIATION DRUM", ru: "// БАРАБАН АССОЦИАЦИЙ", es: "// TAMBOR DE ASOCIACIONES"))
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)

                HStack(spacing: 10) {
                    localConfigTile(title: localized(en: "SPEAKER", ru: "ГОВОРИТ", es: "HABLA"), value: currentAsker(in: session)?.name.uppercased() ?? copy.pending)
                    localConfigTile(title: localized(en: "ROUND", ru: "РАУНД", es: "RONDA"), value: "\(questionIndex + 1)")
                }

                Text(localized(
                    en: "Say one association for the hidden word. Keep the tempo moving, listen for weak links, then call the final vote.",
                    ru: "Назови одну ассоциацию к скрытому слову. Держи темп, слушай слабые связи и затем запускай финальный голос.",
                    es: "Di una asociacion para la palabra oculta. Mantén el ritmo, detecta enlaces debiles y llama el voto final."
                ))
                .font(SpyTheme.mono)
                .foregroundStyle(SpyTheme.muted)
                .lineSpacing(3)
            }
        }
    }

    private var localPlayingHeader: some View {
        HStack {
            Text(localized(en: "// PLAYING", ru: "// ИГРА", es: "// JUGANDO"))
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
                    Text(localized(en: "STOP", ru: "СТОП", es: "STOP"))
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
            Text(localized(en: "TIME LEFT", ru: "ОСТАЛОСЬ", es: "QUEDA"))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
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

    private func localAgentStrip(_ session: LocalSession) -> some View {
        localCompactPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(localized(en: "AGENTS", ru: "АГЕНТЫ", es: "AGENTES")) (\(session.players.count))")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.66)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(session.players.indices, id: \.self) { index in
                        localAgentChip(session.players[index])
                    }
                }
            }
        }
    }

    private func localActivePairCard(_ session: LocalSession) -> some View {
        localCompactPanel(accent: SpyTheme.red, fillHeight: true) {
            VStack(spacing: 14) {
                Text(localized(en: "ACTIVE PAIR", ru: "АКТИВНАЯ ПАРА", es: "PAREJA ACTIVA"))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62, alignment: .center)

                HStack(alignment: .center, spacing: 12) {
                    localPairAgentCell(
                        title: localized(en: "ASKS", ru: "СПРАШИВАЕТ", es: "PREGUNTA"),
                        player: currentAsker(in: session),
                        color: SpyTheme.red
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(SpyTheme.red)
                        .symbolEffect(.pulse, value: questionIndex)

                    localPairAgentCell(
                        title: localized(en: "ANSWERS", ru: "ОТВЕЧАЕТ", es: "RESPONDE"),
                        player: currentAnswerer(in: session),
                        color: .white
                    )
                }

                localCompactActionButton(
                    title: localized(en: "NEXT PAIR", ru: "СЛЕДУЮЩАЯ ПАРА", es: "SIGUIENTE PAREJA"),
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
                    Text(localized(en: "SAYS ASSOCIATION", ru: "ГОВОРИТ АССОЦИАЦИЮ", es: "DICE ASOCIACION"))
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
                            ? localized(en: "NEW ROUND", ru: "НОВЫЙ РАУНД", es: "NUEVA RONDA")
                            : localized(en: "NEXT PLAYER", ru: "СЛЕДУЮЩИЙ ИГРОК", es: "SIGUIENTE JUGADOR"),
                        prefix: isRoundEnd ? "🎲" : "↻",
                        primary: false
                    ) {
                        nextQuestion(in: session)
                    }

                    HStack(spacing: 4) {
                        ForEach(session.players.indices, id: \.self) { index in
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
            let count = max(session.players.count, 1)
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate * 12) % count
            let previewPlayer = session.players[safe: tick] ?? currentAsker(in: session)

            VStack(spacing: 12) {
                Text(localized(en: "ASSOCIATION ROULETTE", ru: "РУЛЕТКА АССОЦИАЦИЙ", es: "RULETA DE ASOCIACIONES"))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62, alignment: .center)

                Text(previewPlayer?.avatar ?? "🕵️")
                    .font(.system(size: 58))
                    .frame(height: 64)
                    .shadow(color: SpyTheme.red.opacity(0.35), radius: 18)

                Text(localized(en: "SELECTING OPERATIVE", ru: "ВЫБОР ОПЕРАТИВНИКА", es: "ELIGIENDO OPERATIVO"))
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
            let spyPlayer = session.players[safe: session.spyIndex]
            ZStack {
                VStack(spacing: 20) {
                    Text("⏰")
                        .font(.system(size: 60))
                        .scaleEffect(guessSecondsRemaining <= 10 ? 1.05 : 1)
                        .animation(.smooth(duration: 0.2), value: guessSecondsRemaining)

                    Text(localized(en: "TIME'S UP!", ru: "ВРЕМЯ ВЫШЛО!", es: "TIEMPO TERMINADO"))
                        .font(.system(size: 36, weight: .black, design: .default))
                        .tracking(0.06)
                        .foregroundStyle(SpyTheme.red)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.56, alignment: .center)

                    localGuessCountdown

                    if let spyPlayer {
                        VStack(spacing: 8) {
                            Text(localized(en: "Pass phone to the spy:", ru: "Передай телефон шпиону:", es: "Pasa el telefono al espia:"))
                                .font(.system(size: 13, weight: .semibold, design: .default))
                                .foregroundStyle(SpyTheme.dim)
                                .multilineTextAlignment(.center)
                                .spyFitted(lines: 2, scale: 0.66, alignment: .center)

                            Text(spyPlayer.avatar)
                                .font(.system(size: 32))

                            Text(spyPlayer.name.uppercased())
                                .font(.system(size: 18, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .spyFitted(lines: 2, scale: 0.58, alignment: .center)
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
                            title: localized(en: "GUESS THE WORD", ru: "УГАДАТЬ СЛОВО", es: "ADIVINAR PALABRA"),
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
        VStack(spacing: 4) {
            Text(localized(en: "SPY HAS", ru: "У ШПИОНА", es: "EL ESPIA TIENE"))
                .font(SpyTheme.micro)
                .tracking(0.08)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.66, alignment: .center)

            Text("\(guessSecondsRemaining)s")
                .font(.system(size: 42, weight: .black, design: .monospaced))
                .tracking(0.04)
                .foregroundStyle(guessSecondsRemaining <= 10 ? SpyTheme.red : .white)
                .contentTransition(.numericText())

            Text(localized(en: "TO GUESS", ru: "ЧТОБЫ УГАДАТЬ", es: "PARA ADIVINAR"))
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
                    Text(localized(en: "SPY GUESS", ru: "ДОГАДКА ШПИОНА", es: "INTENTO DEL ESPIA"))
                        .font(SpyTheme.micro)
                        .tracking(0.18)
                        .foregroundStyle(SpyTheme.red)
                        .spyKicker(lines: 2)

                    Text(localized(en: "CHOOSE THE SECRET WORD", ru: "ВЫБЕРИ СЕКРЕТНОЕ СЛОВО", es: "ELIGE LA PALABRA SECRETA"))
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
                            Text(localized(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR"))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SpyButtonStyle(variant: .ghost))

                        Button {
                            guard let pendingSpyGuess else { return }
                            resolveSpyGuess(pendingSpyGuess, session: session)
                        } label: {
                            Text(pendingSpyGuess.map { "▶ \($0.uppercased())" } ?? localized(en: "CHOOSE", ru: "ВЫБРАТЬ", es: "ELEGIR"))
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
                        ForEach(session.players.indices, id: \.self) { index in
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

                Text(winner.title(copy))
                    .font(.system(size: 44, weight: .black, design: .default))
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.red)
                    .multilineTextAlignment(.center)
                    .spyFitted(lines: 2, scale: 0.52, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                localResultWordPanel(session)

                if let spy = session.players[safe: session.spyIndex] {
                    Text("\(localized(en: "SPY WAS", ru: "ШПИОНОМ БЫЛ", es: "EL ESPIA ERA")) \(spy.avatar) \(spy.name.uppercased())")
                        .font(.system(size: 12, weight: .bold, design: .default))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.dim)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                }

                VStack(spacing: 10) {
                    Button {
                        startLocalGame()
                    } label: {
                        SpyActionLabel(
                            title: localized(en: "PLAY AGAIN", ru: "СЫГРАТЬ ЕЩЁ", es: "JUGAR OTRA VEZ"),
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
                            title: localized(en: "HOME", ru: "НА ГЛАВНУЮ", es: "INICIO"),
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
                Text(localized(en: "SECRET WORD", ru: "СЕКРЕТНОЕ СЛОВО", es: "PALABRA SECRETA"))
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
                    Text("\(localized(en: "SPY GUESSED", ru: "ШПИОН УГАДАЛ", es: "EL ESPIA DIJO")) \(spyGuess.uppercased())")
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
        localized(en: "NEXT ASSOCIATION", ru: "СЛЕДУЮЩАЯ АССОЦИАЦИЯ", es: "SIGUIENTE ASOCIACION")
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
            SpyWebSlider(value: value, range: range, step: 1)
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
                emptyMessage: localized(en: "Add at least one active word before dealing cards.", ru: "Добавь хотя бы одно активное слово перед раздачей.", es: "Agrega al menos una palabra activa antes de repartir.")
            )
        }

        if selectedPackID == "generated", let generatedPack {
            let words = generatedPack.words.localCleanWords
            return LocalPoolSnapshot(
                category: generatedPack.category.nilIfBlank ?? customTheme.nilIfBlank ?? "CUSTOM",
                source: localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO"),
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Generate a theme before dealing cards.", ru: "Сгенерируй тему перед раздачей карт.", es: "Genera un tema antes de repartir.")
            )
        }

        if !localHasCustomTheme,
           selectedPackID == "builtin",
           let generatedPack {
            let words = generatedPack.words.localCleanWords
            return LocalPoolSnapshot(
                category: generatedPack.category.nilIfBlank ?? builtinPreviewCategory,
                source: localized(en: "BUILT-IN INTEL", ru: "ВСТРОЕННЫЙ INTEL", es: "INTEL INTEGRADA"),
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Built-in pool is unavailable.", ru: "Встроенный пул недоступен.", es: "Banco integrado no disponible.")
            )
        }

        if localHasCustomTheme {
            return LocalPoolSnapshot(
                category: customTheme.nilIfBlank ?? "CUSTOM",
                source: localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO"),
                words: [],
                countLabel: "0 \(copy.wordsSuffix)",
                emptyMessage: localized(en: "Generate a theme before dealing cards.", ru: "Сгенерируй тему перед раздачей карт.", es: "Genera un tema antes de repartir.")
            )
        }

        if selectedPackID != "builtin",
           let pack = packs.first(where: { $0.id == selectedPackID }) {
            let words = pack.words?.localCleanWords ?? []
            return LocalPoolSnapshot(
                category: pack.category?.nilIfBlank ?? pack.name,
                source: localized(en: "WORD PACK", ru: "WORDPACK", es: "WORDPACK"),
                words: words,
                countLabel: "\(words.count) \(copy.wordsSuffix)",
                emptyMessage: localized(en: "This pack is empty. Choose another source.", ru: "Этот пак пуст. Выбери другой источник.", es: "Este pack esta vacio. Elige otra fuente.")
            )
        }

        let category = localWordPools[builtinPreviewCategory] == nil ? "CLASSIC" : builtinPreviewCategory
        let words = (localWordPools[category] ?? localWordPools["CLASSIC"] ?? []).localCleanWords
        return LocalPoolSnapshot(
            category: category,
            source: localized(en: "BUILT-IN INTEL", ru: "ВСТРОЕННЫЙ INTEL", es: "INTEL INTEGRADA"),
            words: words,
            countLabel: "\(words.count) \(copy.wordsSuffix)",
            emptyMessage: localized(en: "Built-in pool is unavailable.", ru: "Встроенный пул недоступен.", es: "Banco integrado no disponible.")
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
                        Text(localized(en: "// SESSION ROSTER", ru: "// СОСТАВ СЕССИИ", es: "// LISTA DE SESION"))
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
                    localConfigTile(title: localized(en: "OPERATIVES", ru: "ИГРОКИ", es: "AGENTES"), value: "\(session.players.count)")
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
        let activeIndex = questionIndex % max(session.players.count, 1)
        let answerIndex = (questionIndex + 1) % max(session.players.count, 1)
        let isAsker = session.mode == .questions && index == activeIndex
        let isAnswerer = session.mode == .questions && index == answerIndex
        let isSpeaker = session.mode == .associations && index == activeIndex
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

                Text(revealRoles ? (player.isSpy ? copy.spyLabel : copy.youAreDetective) : localPlayerStatus(index: index, session: session))
                    .font(.system(size: 9, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(revealRoles ? (player.isSpy ? SpyTheme.red : SpyTheme.green) : (isActive ? SpyTheme.red : SpyTheme.dim))
                    .spyFitted(scale: 0.56)
            }

            Spacer()

            if revealRoles {
                localBadge(player.isSpy ? copy.spyLabel : localized(en: "CLEAR", ru: "ЧИСТ", es: "LIMPIO"), color: player.isSpy ? SpyTheme.red : SpyTheme.green)
            } else if isAsker {
                localBadge(copy.asker, color: SpyTheme.red)
            } else if isAnswerer {
                localBadge(copy.answer, color: SpyTheme.green)
            } else if isSpeaker {
                localBadge(localized(en: "SPEAKER", ru: "ГОВОРИТ", es: "HABLA"), color: SpyTheme.red)
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
        guard !session.players.isEmpty else { return copy.pending }
        let activeIndex = questionIndex % session.players.count
        let answerIndex = (questionIndex + 1) % session.players.count

        if session.mode == .associations {
            return index == activeIndex
                ? localized(en: "ASSOCIATION TURN", ru: "ХОД АССОЦИАЦИИ", es: "TURNO DE ASOCIACION")
                : copy.pending
        }

        if index == activeIndex { return copy.asker }
        if index == answerIndex { return copy.answer }
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
        status = localized(en: "BUILT-IN INTEL REROLLED", ru: "ВСТРОЕННЫЙ INTEL ОБНОВЛЕН", es: "INTEL INTEGRADA CAMBIADA")
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

        isChoosingLocalPoolExpansion = false

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
                generated = try await appState.client.generateWordPack(theme: theme, count: targetCount)
            }
            try Task.checkCancellation()
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
                    es: "No se pudo reconocer el tema. Prueba otro."
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
            status = localized(en: "AI WORD POOL READY", ru: "AI-ПУЛ СЛОВ ГОТОВ", es: "BANCO IA LISTO")
            HapticManager.shared.fire(.milestone)
            persistLocalSettings()
        } catch is CancellationError {
            return
        } catch {
            guard localThemeRequestID == requestID else { return }
            localThemeError = error.localizedDescription.uppercased()
            status = localThemeError
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func pushLocalThemeMax(additionalCount requestedAdditionalCount: Int) async {
        guard isExpandingLocalThemePool, isGenerating else { return }

        let requestID = UUID()
        localThemeRequestID = requestID
        defer {
            if localThemeRequestID == requestID {
                isGenerating = false
                isExpandingLocalThemePool = false
            }
        }

        let theme = customTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = localPoolSnapshot.words.localCleanWords
        let selectedWordCount = Int(wordCount)
        guard !theme.isEmpty,
              localThemeMaxWords < localThemeGenerationLimit else { return }

        let additionLimit = min(
            max(requestedAdditionalCount, 1),
            min(100, localThemeGenerationLimit - current.count)
        )
        guard additionLimit > 0 else { return }
        // The service accepts at least five requested words. Near the 200-word
        // cap we still expose the true remaining capacity and trim to that cap.
        let generationRequestCount = max(5, additionLimit)
        let themeKey = localWordKey(theme)

        localThemeError = ""

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                generated = GeneratedWordPack(
                    name: "\(theme) Kit",
                    category: theme,
                    words: (1...generationRequestCount).map { "\(theme) \(current.count + $0)" },
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
            } else {
                generated = try await appState.client.generateWordPack(
                    theme: theme,
                    count: generationRequestCount,
                    excluding: current
                )
            }
            try Task.checkCancellation()
            appState.recordAIUsage(
                used: generated.aiGenerationsToday,
                remaining: generated.aiRemaining
            )

            guard localThemeRequestID == requestID,
                  localWordKey(customTheme) == themeKey else { return }

            var seen = Set(current.map { localWordKey($0) })
            let additions = Array(
                generated.words.localCleanWords
                    .filter { seen.insert(localWordKey($0)).inserted }
                    .prefix(additionLimit)
            )
            let merged = Array((current + additions).prefix(200))
            guard merged.count > current.count else {
                localThemeError = localized(
                    en: "Couldn't find more unique words.",
                    ru: "Больше уникальных слов найти не удалось.",
                    es: "No se encontraron mas palabras unicas."
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
            let addedCount = merged.count - current.count
            let minimumGameWords = min(10, merged.count)
            wordCount = Double(min(merged.count, max(selectedWordCount, minimumGameWords)))
            status = localized(
                en: "AI WORD POOL EXPANDED · +\(addedCount)",
                ru: "AI-ПУЛ СЛОВ РАСШИРЕН · +\(addedCount)",
                es: "BANCO IA AMPLIADO · +\(addedCount)"
            )
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                isChoosingLocalPoolExpansion = false
            }
            HapticManager.shared.fire(.milestone)
            persistLocalSettings()
        } catch is CancellationError {
            return
        } catch {
            guard localThemeRequestID == requestID else { return }
            localThemeError = error.localizedDescription.uppercased()
            status = localThemeError
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func saveLocalThemePack() async {
        guard !isSavingGeneratedPack else { return }
        guard let email = appState.user?.email else { return }
        guard let generatedPack else { return }

        let words = activeLocalWords(localPoolSnapshot.words)
        guard words.count >= 2 else { return }

        isSavingGeneratedPack = true
        defer { isSavingGeneratedPack = false }

        do {
            let name = generatedPack.name?.nilIfBlank ?? generatedPack.category.nilIfBlank ?? customTheme.nilIfBlank ?? "Custom"
            let saved = try await appState.client.createWordPack(
                name: name,
                category: generatedPack.category.nilIfBlank ?? name,
                words: words,
                ownerEmail: email
            )
            try Task.checkCancellation()
            packs.append(saved)
            packs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            status = localized(en: "WORDPACK SAVED", ru: "WORDPACK СОХРАНЕН", es: "WORDPACK GUARDADO")
            HapticManager.shared.fire(.milestone)
            persistLocalSettings()
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func startLocalGame() {
        let names = players.enumerated().map { index, name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "\(copy.fallbackPlayer) \(index + 1)"
        }
        guard names.count >= 2 else {
            status = copy.needTwoOperatives
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        if localNeedsGeneratedTheme {
            status = localPrimaryActionTitle
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        if !localHasCustomTheme && selectedPackID == "builtin" && generatedPack == nil {
            withAnimation(.smooth(duration: 0.28)) {
                revealBuiltinPool()
            }
            return
        }

        guard localPlayablePool.count >= 2 else {
            status = localized(
                en: "KEEP AT LEAST TWO ACTIVE WORDS",
                ru: "ОСТАВЬ ХОТЯ БЫ ДВА АКТИВНЫХ СЛОВА",
                es: "DEJA AL MENOS DOS PALABRAS ACTIVAS"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }

        guard let word = pickLocalWord() else {
            status = localized(
                en: "WORD POOL IS UNAVAILABLE",
                ru: "ПУЛ СЛОВ НЕДОСТУПЕН",
                es: "EL BANCO DE PALABRAS NO ESTA DISPONIBLE"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }
        let spyIndex = Int.random(in: names.indices)
        let localPlayers = names.enumerated().map { index, name in
            LocalPlayer(name: name, avatar: avatars[safe: index] ?? "🕵️", isSpy: index == spyIndex)
        }

        timerTask?.cancel()
        session = LocalSession(
            word: word.word,
            category: word.category,
            spyIndex: spyIndex,
            pool: word.pool,
            players: localPlayers,
            mode: mode
        )
        resetAssociationFlow(playerCount: localPlayers.count, mode: mode)
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
        revealIndex + 1 >= session.players.count ? copy.beginTimer : localized(en: "READ - NEXT", ru: "ПРОЧИТАЛ — ДАЛЬШЕ", es: "LEIDO - SIGUIENTE")
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
        if let session, session.mode == .associations, associationOrder.count != session.players.count {
            resetAssociationFlow(playerCount: session.players.count, mode: session.mode)
        }
        phase = .playing
        HapticManager.shared.fire(.milestone)
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled && secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                secondsRemaining -= 1
                if (1...3).contains(secondsRemaining) {
                }
            }
            if !Task.isCancelled {
                beginSpyGuess()
                HapticManager.shared.fire(.notification(.warning))
            }
        }
    }

    private func beginSpyGuess() {
        guessSecondsRemaining = previewLocalGuessSeconds ?? 30
        showSpyGuessOptions = false
        pendingSpyGuess = nil
        phase = .spyGuess
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled && guessSecondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guessSecondsRemaining -= 1
                if (1...3).contains(guessSecondsRemaining) {
                }
            }
            if !Task.isCancelled {
                spyGuess = nil
                pendingSpyGuess = nil
                winner = .detectives
                phase = .results
                HapticManager.shared.fire(.milestone)
            }
        }
    }

    private func currentAsker(in session: LocalSession) -> LocalPlayer? {
        guard !session.players.isEmpty else { return nil }
        if session.mode == .associations {
            let fallbackIndex = questionIndex % max(session.players.count, 1)
            let orderedIndex = associationOrder[safe: associationStep] ?? fallbackIndex
            return session.players[safe: orderedIndex]
        }

        return session.players[safe: questionIndex % session.players.count]
    }

    private func currentAnswerer(in session: LocalSession) -> LocalPlayer? {
        guard !session.players.isEmpty else { return nil }
        return session.players[safe: (questionIndex + 1) % session.players.count]
    }

    private func nextQuestion(in session: LocalSession) {
        if session.mode == .associations {
            advanceAssociationSpeaker(playerCount: session.players.count)
            HapticManager.shared.fire(.tabSelection)
            return
        }

        questionIndex = (questionIndex + 1) % max(session.players.count, 1)
        HapticManager.shared.fire(.tabSelection)
    }

    private func resetAssociationFlow(playerCount: Int, mode: LocalMode) {
        guard mode == .associations, playerCount > 0 else {
            associationOrder = []
            associationStep = 0
            associationRouletteDone = true
            return
        }

        associationOrder = shuffledAssociationOrder(playerCount: playerCount, avoidingFirst: nil)
        associationStep = 0
        associationRouletteDone = false
    }

    private func advanceAssociationSpeaker(playerCount: Int) {
        guard playerCount > 0 else { return }

        questionIndex += 1
        let nextStep = associationStep + 1
        if nextStep >= associationOrder.count {
            let last = associationOrder.last
            associationOrder = shuffledAssociationOrder(playerCount: playerCount, avoidingFirst: last)
            associationStep = 0
        } else {
            associationStep = nextStep
        }
        associationRouletteDone = false
    }

    private func shuffledAssociationOrder(playerCount: Int, avoidingFirst avoidedFirst: Int?) -> [Int] {
        guard playerCount > 0 else { return [] }
        var shuffled = Array(0..<playerCount).shuffled()
        if let avoidedFirst, shuffled.count > 1, shuffled.first == avoidedFirst {
            shuffled.swapAt(0, 1)
        }
        return shuffled
    }

    private func resolveAccusation(_ index: Int, session: LocalSession) {
        accusedIndex = index
        spyGuess = nil
        winner = index == session.spyIndex ? .detectives : .spy
        phase = .results
        HapticManager.shared.fire(.notification(index == session.spyIndex ? .success : .warning))
    }

    private func resolveSpyGuess(_ word: String, session: LocalSession) {
        timerTask?.cancel()
        spyGuess = word
        pendingSpyGuess = nil
        showSpyGuessOptions = false
        winner = localWordKey(word) == localWordKey(session.word) ? .spy : .detectives
        phase = .results
        HapticManager.shared.fire(.notification(winner == .spy ? .warning : .success))
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
        resetAssociationFlow(playerCount: 0, mode: .questions)
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
            let loadedPacks = try await appState.client.wordPacks(ownerEmail: email)
            try Task.checkCancellation()
            guard appState.user?.email == email else { return }
            packs = loadedPacks
            reconcileLocalWordSources()
        } catch is CancellationError {
            return
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
                category: generatedPack.category.nilIfBlank ?? customTheme.nilIfBlank ?? "CUSTOM"
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

    private func persistLocalSettings() {
        let settings = LocalGameSettings(
            players: players,
            avatars: avatars,
            duration: duration,
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

        players = settings.players.count >= 2 ? settings.players : players
        avatars = settings.avatars.count == players.count ? settings.avatars : players.indices.map { localAvatars[$0 % localAvatars.count] }
        playerIDs = players.map { _ in UUID() }
        duration = min(max(settings.duration, 1), 15)
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
            spyIndex: basePreview.spyIndex,
            pool: basePreview.pool,
            players: basePreview.players,
            mode: previewLocalMode ?? basePreview.mode
        )

        players = preview.players.map(\.name)
        avatars = preview.players.map(\.avatar)
        playerIDs = players.map { _ in UUID() }
        mode = preview.mode
        selectedPackID = "builtin"
        builtinPreviewCategory = preview.category
        clearLocalPoolDraft()
        session = preview
        resetAssociationFlow(playerCount: preview.players.count, mode: preview.mode)
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
}

private struct RoleRevealCard: View {
    let player: LocalPlayer
    let session: LocalSession
    let revealed: Bool
    let copy: LocalGameCopy
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
        .accessibilityLabel(revealed ? (player.isSpy ? copy.youAreSpy : copy.youAreDetective) : copy.tapToReveal)
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
    let spyIndex: Int
    let pool: [String]
    let players: [LocalPlayer]
    let mode: LocalMode
}

#if DEBUG
private extension LocalSession {
    static var preview: LocalSession {
        LocalSession(
            word: "Metro",
            category: "NIGHT CITY",
            spyIndex: 1,
            pool: ["Metro", "Rooftop", "Taxi", "Stadium", "Signal", "Market", "Tunnel", "Harbor"],
            players: [
                LocalPlayer(name: "Red Raven", avatar: "🕵️", isSpy: false),
                LocalPlayer(name: "Ghost", avatar: "👤", isSpy: true),
                LocalPlayer(name: "Signal", avatar: "🔥", isSpy: false)
            ],
            mode: .questions
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
    case players
    case intel
    case timing
    case controls
}

private struct LocalSetupFocusEffect: ViewModifier {
    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.20 : 1)
            .scaleEffect(dimmed ? 0.94 : 1)
            .blur(radius: dimmed ? 2 : 0)
            .allowsHitTesting(!dimmed)
            .animation(.smooth(duration: 0.34), value: dimmed)
    }
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
