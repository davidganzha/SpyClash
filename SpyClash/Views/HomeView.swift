import SwiftUI

enum HomeRootPrimaryAction: Equatable {
    case chooseMode
    case returnToActiveRoom
}

struct HomeRootPresentationPolicy {
    static func showsLandingActions(
        hasActiveRoom: Bool,
        explicitlyRequested _: Bool
    ) -> Bool {
        !hasActiveRoom
    }

    static func primaryAction(hasActiveRoom: Bool) -> HomeRootPrimaryAction {
        hasActiveRoom ? .returnToActiveRoom : .chooseMode
    }
}

struct HomeHeroTypographyPolicy {
    static func fontSize(
        baseFontSize: CGFloat,
        language: AppLanguage,
        isModeHero: Bool
    ) -> CGFloat {
        guard !isModeHero else { return baseFontSize }

        return switch language {
        case .ru, .uk:
            baseFontSize * 0.86
        case .en, .es:
            baseFontSize
        }
    }
}

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spyEntranceMotionEnabled) private var entranceMotionEnabled
    @Environment(\.spyEntrancePresentationActive) private var entrancePresentationActive

    @State private var joinCode = ""
    @State private var stage: HomeStage = .main
    @State private var statusText = ""
    @State private var statusKind: HomeStatusKind?
    @State private var isLoading = false
    @State private var tutorialMode: TutorialMode?
    @State private var isQRScannerPresented = false
    @State private var idlePulse = false
    @State private var visualDrift = false
    @State private var revealHero = false

    var body: some View {
        ZStack {
            SpyBackground()
            SpyLaserScanLayer(reduceMotion: reduceMotion)

            VStack(spacing: 0) {
                homeTopBarReserve

                VStack(spacing: 0) {
                    SpyPageStatusLine(
                        eyebrow: localized(en: "STATUS:", ru: "СТАТУС:", es: "ESTADO:", uk: "СТАТУС:"),
                        status: homeShellStatus
                    )

                    GeometryReader { proxy in
                        homeScene(height: proxy.size.height)
                    }
                }
                .overlay(alignment: .top) {
                    SpyPageTopEdge()
                }
            }
        }
        .sheet(item: $tutorialMode) { mode in
            HowToPlaySheet(initialMode: mode, language: appState.language)
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
        }
        .sheet(isPresented: $isQRScannerPresented) {
            QRScannerSheet()
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
        }
        .onAppear {
            startHeroEntranceIfNeeded()
            startAmbientMotionIfNeeded()
#if DEBUG
            configureStatusPreviewIfNeeded()
#endif
        }
        .onChange(of: entranceMotionEnabled) { _, isEnabled in
            guard isEnabled, entrancePresentationActive else { return }
            startHeroEntranceIfNeeded()
        }
        .onChange(of: entrancePresentationActive) { _, isActive in
            if isActive {
                startHeroEntranceIfNeeded()
            } else {
                resetHeroEntrance()
            }
        }
        .onChange(of: appState.homeRootRequestID) { _, _ in
            resetToHomeRoot()
        }
        .onChange(of: statusText) { _, message in
            publishHomeToast(message)
        }
    }

    private func startHeroEntranceIfNeeded() {
        guard entranceMotionEnabled, entrancePresentationActive, !revealHero else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.72, dampingFraction: 0.86).delay(0.08)) {
            revealHero = true
        }
    }

    private func resetHeroEntrance() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revealHero = false
        }
    }

    private func startAmbientMotionIfNeeded() {
        guard !reduceMotion else { return }
        if !idlePulse {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                idlePulse = true
            }
        }
        if !visualDrift {
            withAnimation(.easeInOut(duration: 7.2).repeatForever(autoreverses: true)) {
                visualDrift = true
            }
        }
    }

    private func resetToHomeRoot() {
        joinCode = ""
        statusText = ""
        statusKind = nil

        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : SpyMotion.page) {
            stage = .main
        }
    }

#if DEBUG
    private func configureStatusPreviewIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--spyclash-preview-home-room-closed"),
              statusText.isEmpty
        else { return }

        statusText = localized(en: "ROOM CLOSED", ru: "КОМНАТА ЗАКРЫТА", es: "SALA CERRADA", uk: "КІМНАТУ ЗАКРИТО")
        statusKind = .success
    }
#endif

    private var copy: HomeCopy {
        appState.language.home
    }

    private var joinCodeBinding: Binding<String> {
        Binding(
            get: { joinCode },
            set: { joinCode = String($0.uppercased().prefix(6)) }
        )
    }

    private func homeScene(height: CGFloat) -> some View {
        let roomActive = appState.activeRoom != nil
        let showsLandingActions = HomeRootPresentationPolicy.showsLandingActions(
            hasActiveRoom: roomActive,
            explicitlyRequested: appState.isHomeLandingPresentationRequested
        )
        let showsActiveRoomPanel = roomActive && !showsLandingActions
        let compact = height < 760 || (showsLandingActions && stage != .main)
        let isActionStage = showsLandingActions && stage != .main
        let usesShortActionLayout = isActionStage && height < 620
        let sceneSpacing: CGFloat = isActionStage ? 6 : (compact ? 12 : 18)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: sceneSpacing) {
                Color.clear
                    .frame(height: isActionStage ? 4 : (compact ? 8 : 18))

                hero(
                    compact: compact || showsActiveRoomPanel,
                    usesShortActionLayout: usesShortActionLayout
                )
                    .layoutPriority(1)

                if showsActiveRoomPanel {
                    activeRoomPanel
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                }

                Color.clear
                    .frame(height: isActionStage ? 0 : (compact ? 6 : 12))

                if showsLandingActions {
                    VStack(spacing: compact ? 10 : 12) {
                        mainActions
                            .frame(maxWidth: stage == .main ? 350 : 382)
                            .id(stage)
                            .animation(SpyMotion.page, value: stage)
                    }
                }

                Spacer(minLength: 20)
            }
            .frame(maxWidth: 414)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height, alignment: .top)
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
    }

    private var homeTopBarReserve: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 80)
    }

    private var homeShellStatus: String {
        guard let room = appState.activeRoom else {
            return localized(en: "ONLINE", ru: "В СЕТИ", es: "EN LÍNEA", uk: "У МЕРЕЖІ")
        }
        return copy.statusLabel(room.status).uppercased()
    }

    private func hero(compact: Bool, usesShortActionLayout: Bool) -> some View {
        let isModeHero = appState.activeRoom == nil && (stage == .playMode || stage == .onlineMode)
        let showMainCopy = stage == .main || appState.activeRoom != nil
        let usesCondensedActionLayout = compact && appState.activeRoom == nil && stage != .main
        let baseHeroFontSize: CGFloat = usesShortActionLayout ? 36 : (usesCondensedActionLayout ? 42 : (compact ? 48 : 58))
        let heroFontSize = HomeHeroTypographyPolicy.fontSize(
            baseFontSize: baseHeroFontSize,
            language: appState.language,
            isModeHero: isModeHero
        )
        let heroHeight: CGFloat = usesShortActionLayout ? 96 : (usesCondensedActionLayout ? 168 : (compact ? 200 : 252))

        return VStack(spacing: compact ? 14 : 22) {
            if showMainCopy {
                Text(localized(en: "// PLAY SOCIAL DEDUCTION", ru: "// ИГРА НА СОЦИАЛЬНУЮ ДЕДУКЦИЮ", es: "// DEDUCCION SOCIAL", uk: "// ГРА В СОЦІАЛЬНУ ДЕДУКЦІЮ"))
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                HomeHeroTitle(
                    isModeHero: isModeHero,
                    fontSize: heroFontSize,
                    usesCondensedLines: usesShortActionLayout,
                    language: appState.language
                )
                .shadow(color: .black.opacity(0.62), radius: 18, y: 8)
                .shadow(color: SpyTheme.red.opacity(idlePulse ? 0.16 : 0.06), radius: idlePulse ? 28 : 14)
                .scaleEffect(visualDrift ? 1.006 : 0.997)
            }
            .frame(height: heroHeight)

            if showMainCopy && !compact {
                Text(localized(
                    en: "Detectives know the word. The spy does not. Find the spy before the spy guesses the word.",
                    ru: "Детективы знают слово. Шпион - нет. Угадайте шпиона раньше, чем шпион угадает слово.",
                    es: "Los detectives conocen la palabra. El espia no. Encuentra al espia antes de que adivine la palabra.",
                    uk: "Детективи знають слово. Шпигун — ні. Знайдіть шпигуна раніше, ніж він вгадає слово."
                ))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(0.04)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(SpyTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(revealHero ? 1 : 0)
        .offset(y: revealHero ? 0 : 28)
    }

    @ViewBuilder
    private var mainActions: some View {
        switch stage {
        case .main:
            mainStageActions
        case .playMode:
            playModeActions
        case .onlineMode:
            onlineModeActions
        case .join:
            joinRoomActions
        }
    }

    private var mainStageActions: some View {
        VStack(spacing: 10) {
            Button {
                HapticManager.shared.fire(.buttonPress)
                switch HomeRootPresentationPolicy.primaryAction(
                    hasActiveRoom: appState.activeRoom != nil
                ) {
                case .chooseMode:
                    withAnimation(SpyMotion.page) {
                        stage = .playMode
                    }
                case .returnToActiveRoom:
                    appState.dismissHomeLandingPresentation()
                    withAnimation(.smooth(duration: 0.28)) {
                        appState.selectedTab = .game
                    }
                }
            } label: {
                heroButtonLabel(
                    title: localized(en: "PLAY", ru: "ИГРАТЬ", es: "JUGAR", uk: "ГРАТИ"),
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(SpyWebPressStyle())
            .spyWebEntrance(delay: 0.55, duration: 0.50, y: 18)

            webGhostButton(title: appState.language.howToPlayTitle, systemImage: "questionmark.circle.fill") {
                tutorialMode = .questions
            }
            .spyWebEntrance(delay: 0.70, duration: 0.50, y: 18)
        }
        .transition(.opacity)
    }

    private var playModeActions: some View {
        VStack(spacing: 10) {
            webChoiceCard(
                title: localized(en: "ONLINE", ru: "ОНЛАЙН", es: "ONLINE", uk: "ОНЛАЙН"),
                subtitle: localized(en: "Each player on their own device", ru: "Каждый на своём телефоне", es: "Cada jugador en su telefono", uk: "Кожен гравець на своєму пристрої"),
                icon: .emoji("📡"),
                badge: localized(en: "RECOMMENDED", ru: "РЕКОМЕНДОВАНО", es: "RECOMENDADO", uk: "РЕКОМЕНДОВАНО"),
                highlighted: true,
                compact: true
            ) {
                HapticManager.shared.fire(.buttonPress)
                withAnimation(SpyMotion.page) {
                    stage = .onlineMode
                }
            }

            webChoiceCard(
                title: localized(en: "LOCAL", ru: "ЛОКАЛЬНО", es: "LOCAL", uk: "ЛОКАЛЬНО"),
                subtitle: localized(en: "One device · pass & play", ru: "Один телефон, передаёте по кругу", es: "Un telefono · pasar y jugar", uk: "Один пристрій · передавайте по колу"),
                icon: .systemImage("iphone"),
                prominence: .secondary,
                compact: true
            ) {
                HapticManager.shared.fire(.tabSelection)
                appState.openLocalSetup()
            }

            webGhostButton(title: localized(en: "Cancel", ru: "Отмена", es: "Cancelar", uk: "Скасувати"), systemImage: "chevron.left") {
                HapticManager.shared.fire(.buttonPress)
                withAnimation(SpyMotion.page) {
                    stage = .main
                }
            }
        }
        .transition(.opacity)
    }

    private var onlineModeActions: some View {
        VStack(spacing: 10) {
                Text(localized(en: "ONLINE MODE", ru: "РАЗНЫЕ УСТРОЙСТВА", es: "MODO ONLINE", uk: "РІЗНІ ПРИСТРОЇ"))
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .frame(maxWidth: .infinity)
                .spyKicker(lines: 2, alignment: .center)

            webChoiceCard(
                title: localized(en: isLoading ? "CREATING ROOM" : "CREATE ROOM", ru: isLoading ? "СОЗДАЕМ КОМНАТУ" : "СОЗДАТЬ КОМНАТУ", es: isLoading ? "CREANDO SALA" : "CREAR SALA", uk: isLoading ? "СТВОРЮЄМО КІМНАТУ" : "СТВОРИТИ КІМНАТУ"),
                subtitle: localized(en: "Start a new game session", ru: "Новая игровая сессия", es: "Iniciar una nueva sesion", uk: "Почати нову ігрову сесію"),
                icon: .emoji(isLoading ? "⏳" : "➕"),
                highlighted: true,
                compact: true
            ) {
                Task { await createRoom() }
            }
            .disabled(isLoading)

            webChoiceCard(
                title: localized(en: "ENTER ROOM", ru: "ВОЙТИ В КОМНАТУ", es: "ENTRAR A SALA", uk: "УВІЙТИ ДО КІМНАТИ"),
                subtitle: localized(en: "Enter code or scan QR", ru: "Ввести код или сканировать QR", es: "Codigo o escanear QR", uk: "Введіть код або відскануйте QR"),
                icon: .emoji("🚪"),
                compact: true
            ) {
                HapticManager.shared.fire(.buttonPress)
                withAnimation(SpyMotion.page) {
                    stage = .join
                }
            }

            webGhostButton(title: localized(en: "Cancel", ru: "Отмена", es: "Cancelar", uk: "Скасувати"), systemImage: "chevron.left") {
                HapticManager.shared.fire(.buttonPress)
                withAnimation(SpyMotion.page) {
                    stage = .playMode
                }
            }
        }
        .transition(.opacity)
    }

    private var joinRoomActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localized(en: "// ENTER ROOM", ru: "// ВОЙТИ В КОМНАТУ", es: "// ENTRAR A SALA", uk: "// УВІЙТИ ДО КІМНАТИ"))
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker(lines: 2)
                .padding(.bottom, 16)

            Text(localized(en: "ROOM CODE", ru: "КОД КОМНАТЫ", es: "CODIGO", uk: "КОД КІМНАТИ"))
                .font(.system(size: 22, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(.white)
                .spyFitted(scale: 0.62)
                .padding(.bottom, 24)

            TextField("ABC123", text: joinCodeBinding)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    Task { await joinRoom() }
                }
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(4)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 10))
                .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.inputBorder, lineWidth: 1))
                .padding(.bottom, 12)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    webSmallActionButton(title: localized(en: isLoading ? "Joining..." : "Join", ru: isLoading ? "Входим..." : "Войти", es: isLoading ? "Entrando..." : "Entrar", uk: isLoading ? "Входимо..." : "Увійти"), variant: .red) {
                        Task { await joinRoom() }
                    }
                    .disabled(isLoading || joinCode.isEmpty)

                    webSmallActionButton(title: localized(en: "SCAN", ru: "СКАН", es: "SCAN", uk: "СКАНУВАТИ"), systemImage: "qrcode.viewfinder", variant: .outline) {
                        isQRScannerPresented = true
                    }
                }

                webGhostButton(title: localized(en: "Cancel", ru: "Отмена", es: "Cancelar", uk: "Скасувати"), systemImage: "chevron.left") {
                    HapticManager.shared.fire(.buttonPress)
                    withAnimation(SpyMotion.page) {
                        stage = .onlineMode
                        joinCode = ""
                        statusText = ""
                        statusKind = nil
                    }
                }
            }
        }
        .padding(28)
        .background(SpyTheme.dark, in: CutCornerShape(cut: 14))
        .overlay(CutCornerShape(cut: 14).stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.red)
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: SpyTheme.red)
                .rotationEffect(.degrees(180))
        }
        .transition(.opacity)
    }

    private func heroButtonLabel(title: String, systemImage: String, loading: Bool = false) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .black))
                .symbolEffect(.pulse, options: loading ? .repeating : .default, value: loading)
                Text(title)
                    .font(.system(size: 13, weight: .black, design: .default))
                    .tracking(title.count > 12 ? 0.02 : 0.14)
                    .spyFitted(lines: 2, scale: 0.70, alignment: .center)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background(
            SpyTheme.red,
            in: CutCornerShape(cut: 12)
        )
        .shadow(color: SpyTheme.red.opacity(0.22), radius: 16, y: 7)
    }

    private func webChoiceCard(
        title: String,
        subtitle: String,
        icon: HomeChoiceIcon,
        badge: String? = nil,
        prominence: HomeChoiceProminence = .standard,
        highlighted: Bool = false,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isSecondary = prominence == .secondary
        let iconSize: CGFloat = compact ? (isSecondary ? 27 : 40) : 44
        let iconWidth: CGFloat = compact ? (isSecondary ? 34 : 46) : 48
        let titleSize: CGFloat = compact ? (isSecondary ? 17 : 21) : 22
        let subtitleSize: CGFloat = isSecondary ? 11 : 13
        let verticalPadding: CGFloat = compact ? (isSecondary ? 13 : 14) : 24
        let minimumHeight: CGFloat = compact ? (isSecondary ? 72 : 88) : 102
        let cardBackground = highlighted
            ? SpyTheme.control
            : (isSecondary ? Color.white.opacity(0.015) : SpyTheme.control)
        let cardStroke = highlighted
            ? SpyTheme.red.opacity(0.56)
            : (isSecondary ? SpyTheme.strokeDim.opacity(0.72) : SpyTheme.strokeStrong)
        let cornerColor = highlighted
            ? SpyTheme.red
            : (isSecondary ? SpyTheme.strokeDim : Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))

        return Button(action: action) {
            HStack(spacing: isSecondary ? 14 : 18) {
                Group {
                    switch icon {
                    case let .emoji(value):
                        Text(value)
                            .font(.system(size: iconSize))
                            .saturation(isSecondary ? 0 : 1)
                            .opacity(isSecondary ? 0.48 : 1)
                    case let .systemImage(name):
                        Image(systemName: name)
                            .font(.system(size: iconSize, weight: .medium))
                            .foregroundStyle(isSecondary ? SpyTheme.dim : Color.white)
                    }
                }
                .frame(width: iconWidth)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: isSecondary ? 3 : (compact ? 5 : 6)) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(0.06)
                            .foregroundStyle(SpyTheme.red)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SpyTheme.red.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(SpyTheme.red.opacity(0.42), lineWidth: 1))
                    }

                    Text(title)
                        .font(.system(size: titleSize, weight: isSecondary ? .bold : .black, design: .default))
                        .tracking(title.count > 10 ? 0.04 : 0.16)
                        .foregroundStyle(isSecondary ? Color.white.opacity(0.70) : Color.white)
                        .spyFitted(lines: 2, scale: 0.66)
                        .allowsTightening(true)
                        .layoutPriority(2)

                    Text(subtitle)
                        .font(.system(size: subtitleSize, weight: .semibold, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(isSecondary ? Color.white.opacity(0.52) : SpyTheme.dim)
                        .spyFitted(lines: 2, scale: 0.72)
                }

                Spacer(minLength: 8)

                Text("›")
                    .font(.system(size: isSecondary ? 20 : 24, weight: .bold, design: .default))
                    .foregroundStyle(highlighted ? SpyTheme.red : SpyTheme.dim)
                    .opacity(isSecondary ? 0.60 : 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, compact ? 20 : 24)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .background {
                ZStack {
                    CutCornerShape(cut: 14)
                        .fill(cardBackground)

                    if highlighted {
                        CutCornerShape(cut: 14)
                            .fill(SpyTheme.red.opacity(0.07))
                    }
                }
            }
            .overlay(CutCornerShape(cut: 14).stroke(cardStroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                cornerMark(color: cornerColor)
            }
            .overlay(alignment: .bottomTrailing) {
                cornerMark(color: cornerColor)
                    .rotationEffect(.degrees(180))
            }
            .contentShape(CutCornerShape(cut: 14))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func webGhostButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .black))
                Text(title)
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(title.count > 12 ? 0.02 : 0.12)
                    .spyFitted(lines: 2, scale: 0.70, alignment: .center)
            }
            .foregroundStyle(SpyTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.clear, in: CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.strokeDim, lineWidth: 1))
            .contentShape(CutCornerShape(cut: 12))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func webSmallActionButton(
        title: String,
        systemImage: String? = nil,
        variant: HomeSmallActionVariant,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .black))
                }
                Text(title)
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(title.count > 10 ? 0.0 : 0.06)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)
            }
            .foregroundStyle(variant == .red ? .white : SpyTheme.red)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background {
                CutCornerShape(cut: 10)
                    .fill(variant == .red ? SpyTheme.red : Color.clear)

            }
            .overlay(CutCornerShape(cut: 10).stroke(variant == .red ? Color.clear : SpyTheme.red, lineWidth: 1))
            .shadow(color: variant == .red ? SpyTheme.red.opacity(0.18) : .clear, radius: 12, y: 5)
            .contentShape(CutCornerShape(cut: 10))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func cornerMark(color: Color) -> some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 14, y: 0))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 14))
        }
        .stroke(color, lineWidth: 1)
        .frame(width: 14, height: 14)
    }

    private func webCommandRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        SpyCommandCard(
            title: title,
            systemImage: systemImage,
            minHeight: 68,
            action: action
        )
    }

    private func webCommandButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        SpyCommandCard(
            title: title,
            systemImage: systemImage,
            accessory: nil,
            minHeight: 60,
            action: action
        )
    }

    @ViewBuilder
    private var activeRoomPanel: some View {
        if let room = appState.activeRoom {
            let isPlaying = (room.status ?? "waiting").lowercased() == "playing"

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(localized(en: "// ACTIVE SESSION", ru: "// АКТИВНАЯ СЕССИЯ", es: "// SESION ACTIVA", uk: "// АКТИВНА СЕСІЯ"))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.68)

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(isPlaying ? SpyTheme.green : SpyTheme.red)
                            .frame(width: 6, height: 6)
                            .shadow(color: isPlaying ? SpyTheme.green : SpyTheme.red, radius: 5)

                        Text(isPlaying
                            ? localized(en: "IN PROGRESS", ru: "ИГРА ИДЁТ", es: "EN CURSO", uk: "ГРА ТРИВАЄ")
                            : localized(en: "LOBBY", ru: "ЛОББИ", es: "LOBBY", uk: "ЛОБІ"))
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.08)
                            .foregroundStyle(isPlaying ? SpyTheme.green : SpyTheme.red)
                            .spyFitted(scale: 0.68)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(SpyTheme.red.opacity(0.035))

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localized(en: "ROOM KEY", ru: "КЛЮЧ КОМНАТЫ", es: "CLAVE DE SALA", uk: "КЛЮЧ КІМНАТИ"))
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.faint)

                        Text(room.code.uppercased())
                            .font(.system(size: 27, weight: .black, design: .monospaced))
                            .tracking(3.2)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Image(systemName: isHost(room) ? "crown.fill" : "person.fill")
                            .font(.system(size: 9, weight: .black))
                        Text(isHost(room)
                            ? localized(en: "HOST", ru: "ХОСТ", es: "HOST", uk: "ХОСТ")
                            : localized(en: "AGENT", ru: "АГЕНТ", es: "AGENTE", uk: "АГЕНТ"))
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.08)
                    }
                    .foregroundStyle(isHost(room) ? SpyTheme.amber : SpyTheme.muted)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background((isHost(room) ? SpyTheme.amber : SpyTheme.muted).opacity(0.06), in: CutCornerShape(cut: 6))
                    .overlay(CutCornerShape(cut: 6).stroke((isHost(room) ? SpyTheme.amber : SpyTheme.muted).opacity(0.30), lineWidth: 1))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 64)

                Rectangle()
                    .fill(SpyTheme.stroke)
                    .frame(height: 1)

                HStack(spacing: 10) {
                    activeRoomReturnButton(room: room)
                    activeRoomLeaveButton(room: room)
                }
                .padding(12)
                .background(SpyTheme.black.opacity(0.28))
            }
            .frame(maxWidth: 340)
            .background {
                LinearGradient(
                    colors: [SpyTheme.red.opacity(0.075), SpyTheme.card, SpyTheme.dark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(CutCornerShape(cut: 12))
            }
            .clipShape(CutCornerShape(cut: 12))
            .overlay(CutCornerShape(cut: 12).stroke(SpyTheme.strokeStrong, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(SpyTheme.red)
                    .frame(width: 58, height: 2)
                    .padding(.leading, 16)
            }
            .shadow(color: SpyTheme.red.opacity(0.10), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.34), radius: 18, y: 10)
        }
    }

    private func activeRoomReturnButton(room: GameRoom) -> some View {
        Button {
            HapticManager.shared.fire(.buttonPress)
            withAnimation(.smooth(duration: 0.28)) {
                appState.selectedTab = .game
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .black))

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(en: "RETURN TO ROOM", ru: "ВЕРНУТЬСЯ В КОМНАТУ", es: "VOLVER A LA SALA", uk: "ПОВЕРНУТИСЯ ДО КІМНАТИ"))
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(0.04)
                        .spyFitted(lines: 2, scale: 0.60)

                    Text(room.code.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.10)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(SpyTheme.red, in: CutCornerShape(cut: 10))
            .contentShape(CutCornerShape(cut: 10))
            .shadow(color: SpyTheme.red.opacity(0.20), radius: 12, y: 5)
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func activeRoomLeaveButton(room: GameRoom) -> some View {
        Button {
            Task { await closeActiveRoom(room) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 15, weight: .black))

                Text(localized(en: "LEAVE", ru: "ВЫЙТИ", es: "SALIR", uk: "ВИЙТИ"))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.06)
                    .spyFitted(scale: 0.65, alignment: .center)
            }
            .foregroundStyle(SpyTheme.red)
            .frame(width: 84)
            .frame(minHeight: 58)
            .background(SpyTheme.red.opacity(0.045), in: CutCornerShape(cut: 10))
            .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.red.opacity(0.58), lineWidth: 1))
            .contentShape(CutCornerShape(cut: 10))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func publishHomeToast(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard statusText == message else { return }
            appState.showToast(
                message,
                kind: statusKind == .success ? .success : .error
            )
            statusText = ""
            statusKind = nil
        }
    }

    private func createRoom() async {
        guard let user = appState.user else { return }
        let operation = RoomSyncOperation.creatingRoom
        guard appState.beginRoomSync(operation) else { return }
        isLoading = true
        defer {
            isLoading = false
            appState.endRoomSync(operation)
        }
        await Task.yield()
        do {
            let room = try await appState.client.createRoom(for: user)
            try Task.checkCancellation()
            guard appState.user?.id == user.id else { return }
            try appState.confirmExplicitRoomActivation(room)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                appState.activeRoom = room
                appState.selectedTab = .game
            }
            statusText = copy.roomReady(room.code)
            statusKind = .success
            HapticManager.shared.fire(.milestone)
        } catch is CancellationError {
            return
        } catch {
            guard appState.user?.id == user.id else { return }
            statusText = roomErrorMessage(error)
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func joinRoom() async {
        guard let user = appState.user else { return }
        let operation = RoomSyncOperation.joiningRoom
        guard appState.beginRoomSync(operation) else { return }
        isLoading = true
        defer {
            isLoading = false
            appState.endRoomSync(operation)
        }
        await Task.yield()
        do {
            let code = joinCode
            let room = try await appState.joinRoomSnapshotForExplicitActivation(
                code: code,
                user: user
            )
            try Task.checkCancellation()
            guard appState.user?.id == user.id else { return }
            try appState.confirmExplicitRoomActivation(room)
            appState.activeRoom = room
            appState.selectedTab = .game
            statusText = copy.roomReady(room.code)
            statusKind = .success
            HapticManager.shared.fire(.milestone)
        } catch is CancellationError {
            return
        } catch {
            guard appState.user?.id == user.id else { return }
            statusText = roomErrorMessage(error)
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func roomErrorMessage(_ error: Error) -> String {
        if let base44Error = error as? Base44Error, base44Error.isClientUpdateRequired {
            return localized(
                en: "UPDATE SPYCLASH TO JOIN THIS MULTI-SPY ROOM",
                ru: "ОБНОВИ SPYCLASH, ЧТОБЫ ВОЙТИ В КОМНАТУ С НЕСКОЛЬКИМИ ШПИОНАМИ",
                es: "ACTUALIZA SPYCLASH PARA ENTRAR EN ESTA SALA MULTIESPIA",
                uk: "ОНОВИ SPYCLASH, ЩОБ УВІЙТИ ДО КІМНАТИ З КІЛЬКОМА ШПИГУНАМИ"
            )
        }
        return error.localizedDescription.uppercased()
    }

    private func closeActiveRoom(_ room: GameRoom) async {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            appState.leaveRoomImmediately(room)
            stage = .main
        }
        statusText = isHost(room) ? localized(en: "ROOM CLOSED", ru: "КОМНАТА ЗАКРЫТА", es: "SALA CERRADA", uk: "КІМНАТУ ЗАКРИТО") : localized(en: "LEFT ROOM", ru: "ВЫШЕЛ ИЗ КОМНАТЫ", es: "SALA ABANDONADA", uk: "ВИ ВИЙШЛИ З КІМНАТИ")
        statusKind = .success
        HapticManager.shared.fire(.notification(.success))
    }

    private func closeRoomMenuTitle(_ room: GameRoom) -> String {
        isHost(room)
            ? localized(en: "Close room", ru: "Закрыть комнату", es: "Cerrar sala", uk: "Закрити кімнату")
            : localized(en: "Leave room", ru: "Выйти из комнаты", es: "Salir de sala", uk: "Вийти з кімнати")
    }

    private func isHost(_ room: GameRoom) -> Bool {
        appState.user?.email == room.hostEmail
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

private struct HomeHeroTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spyEntranceMotionEnabled) private var entranceMotionEnabled
    @Environment(\.spyEntrancePresentationActive) private var entrancePresentationActive
    @State private var isVisible = false

    let isModeHero: Bool
    let fontSize: CGFloat
    let usesCondensedLines: Bool
    let language: AppLanguage

    private var lineWords: [[String]] {
        switch (language, isModeHero, usesCondensedLines) {
        case (.en, true, true): [["SELECT", "YOUR"], ["MODE"]]
        case (.en, true, false): [["SELECT"], ["YOUR"], ["MODE"]]
        case (.en, false, true): [["CAN", "YOU"], ["FIND", "THE", "SPY?"]]
        case (.en, false, false): [["CAN", "YOU"], ["FIND", "THE"], ["SPY?"]]
        case (.es, true, true): [["ELIGE", "TU"], ["MODO"]]
        case (.es, true, false): [["ELIGE"], ["TU"], ["MODO"]]
        case (.es, false, true): [["¿PUEDES"], ["HALLAR", "AL", "ESPÍA?"]]
        case (.es, false, false): [["¿PUEDES"], ["HALLAR", "AL"], ["ESPÍA?"]]
        case (.ru, true, _): [["ВЫБЕРИ"], ["РЕЖИМ"]]
        case (.ru, false, true): [["НАЙДЁШЬ"], ["ШПИОНА?"]]
        case (.ru, false, false): [["СМОЖЕШЬ"], ["НАЙТИ"], ["ШПИОНА?"]]
        case (.uk, true, _): [["ОБЕРИ"], ["РЕЖИМ"]]
        case (.uk, false, true): [["ЗНАЙДЕШ"], ["ШПИГУНА?"]]
        case (.uk, false, false): [["ЗМОЖЕШ"], ["ЗНАЙТИ"], ["ШПИГУНА?"]]
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(lineWords.enumerated()), id: \.offset) { lineIndex, words in
                HStack(spacing: 14) {
                    ForEach(Array(words.enumerated()), id: \.offset) { wordIndex, word in
                        HStack(spacing: 4) {
                            ForEach(Array(word.enumerated()), id: \.offset) { characterIndex, character in
                                HomeHeroGlyph(
                                    character: character,
                                    index: glyphOffset(for: lineIndex, wordIndex: wordIndex) + characterIndex,
                                    isVisible: isVisible,
                                    reduceMotion: reduceMotion,
                                    faceColor: lineIndex == lineWords.count - 1 ? SpyTheme.red : .white
                                )
                            }
                        }
                    }
                }
                .lineLimit(1)
            }
        }
        .font(SpyTheme.brandFont(size: fontSize))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lineWords.flatMap { $0 }.joined(separator: " "))
        .task(id: entranceMotionEnabled && entrancePresentationActive) {
            guard entranceMotionEnabled, entrancePresentationActive else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isVisible = false
                }
                return
            }
            guard !isVisible else { return }
            await Task.yield()
            isVisible = true
        }
    }

    private func glyphOffset(for lineIndex: Int, wordIndex: Int) -> Int {
        let previousLines = lineWords.prefix(lineIndex).flatMap { $0 }.reduce(0) { $0 + $1.count }
        let previousWords = lineWords[lineIndex].prefix(wordIndex).reduce(0) { $0 + $1.count }
        return previousLines + previousWords
    }

}

private struct HomeHeroGlyph: View {
    let character: Character
    let index: Int
    let isVisible: Bool
    let reduceMotion: Bool
    let faceColor: Color

    var body: some View {
        Text(String(character))
            .foregroundStyle(faceColor)
            .opacity(isVisible ? 1 : 0)
            .blur(radius: reduceMotion || isVisible ? 0 : 18)
            .offset(y: reduceMotion || isVisible ? 0 : -16)
            .animation(reduceMotion ? nil : SpyMotion.heroGlyph(index: index), value: isVisible)
    }
}

private enum HomeStatusKind {
    case success
    case error
}

private enum HomeStage {
    case main
    case playMode
    case onlineMode
    case join
}

private enum HomeChoiceIcon {
    case emoji(String)
    case systemImage(String)
}

private enum HomeChoiceProminence: Equatable {
    case standard
    case secondary
}

private enum HomeSmallActionVariant {
    case red
    case outline
}

private struct HowToPlaySheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var mode: TutorialMode
    @State private var stepIndex = 0
    @State private var reveal = false

    let language: AppLanguage

    init(initialMode: TutorialMode, language: AppLanguage) {
        self.language = language
        _mode = State(initialValue: initialMode)
    }

    private var steps: [TutorialStep] {
        language.tutorialSteps(for: mode)
    }

    private var currentStep: TutorialStep {
        steps[min(stepIndex, max(steps.count - 1, 0))]
    }

    private var isFirstStep: Bool {
        stepIndex == 0
    }

    private var isLastStep: Bool {
        stepIndex >= steps.count - 1
    }

    var body: some View {
        ZStack {
            SpyBackground()

            VStack(alignment: .leading, spacing: 20) {
                closeRow
                header
                modePicker
                tutorialCard
                progressRow
                navigationRow
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .onAppear {
            withAnimation(.spring(response: 0.56, dampingFraction: 0.82).delay(0.06)) {
                reveal = true
            }
        }
        .animation(.smooth(duration: 0.32), value: stepIndex)
        .animation(.smooth(duration: 0.32), value: mode)
    }

    private var closeRow: some View {
        HStack {
            Spacer()
            Button {
                HapticManager.shared.fire(.buttonPress)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .accessibilityLabel(closeTutorialAccessibilityLabel)
        }
        .opacity(reveal ? 1 : 0)
        .offset(y: reveal ? 0 : -10)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.tutorialHeader)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()

            Text(language.howToPlayTitle)
                .font(.system(size: 36, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.72)
                .lineLimit(2)
        }
        .opacity(reveal ? 1 : 0)
        .offset(y: reveal ? 0 : 18)
    }

    private var closeTutorialAccessibilityLabel: String {
        switch language {
        case .en: "Close tutorial"
        case .es: "Cerrar tutorial"
        case .ru: "Закрыть обучение"
        case .uk: "Закрити навчання"
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(TutorialMode.allCases) { item in
                Button {
                    guard mode != item else { return }
                    HapticManager.shared.fire(.tabSelection)
                    mode = item
                    stepIndex = 0
                } label: {
                    Text(language.tutorialModeTitle(item))
                        .font(.system(size: 11, weight: .bold, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(mode == item ? .white : SpyTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(mode == item ? SpyTheme.red : SpyTheme.dark)
                        .overlay(Rectangle().stroke(mode == item ? SpyTheme.red : SpyTheme.strokeStrong))
                        .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
            }
        }
        .opacity(reveal ? 1 : 0)
    }

    private var tutorialCard: some View {
        SpyPanel(accent: SpyTheme.red) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(currentStep.icon)
                        .font(.system(size: 52))
                        .frame(width: 68, height: 68)
                        .background(SpyTheme.panelDeep)
                        .overlay(Rectangle().stroke(SpyTheme.stroke))

                    Spacer()

                    Text(String(format: "%02d", stepIndex + 1))
                        .font(.system(size: 34, weight: .black, design: .monospaced))
                        .tracking(0.18)
                        .foregroundStyle(SpyTheme.red.opacity(0.82))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(currentStep.title.uppercased())
                        .font(.system(size: 24, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.58)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(currentStep.text)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineSpacing(7)
                        .foregroundStyle(SpyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id("\(mode.id)-\(stepIndex)")
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
        .opacity(reveal ? 1 : 0)
        .offset(y: reveal ? 0 : 22)
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index == stepIndex ? SpyTheme.red : SpyTheme.stroke)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(reveal ? 1 : 0)
    }

    private var navigationRow: some View {
        HStack(spacing: 10) {
            Button {
                HapticManager.shared.fire(.buttonPress)
                stepIndex = max(0, stepIndex - 1)
            } label: {
                Label(language.tutorialBack, systemImage: "chevron.left")
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .disabled(isFirstStep)
            .opacity(isFirstStep ? 0.45 : 1)

            Button {
                HapticManager.shared.fire(.buttonPress)
                if isLastStep {
                    dismiss()
                } else {
                    stepIndex = min(steps.count - 1, stepIndex + 1)
                }
            } label: {
                Label(isLastStep ? language.tutorialDone : language.tutorialNext, systemImage: isLastStep ? "checkmark.seal.fill" : "chevron.right")
            }
            .buttonStyle(SpyButtonStyle(variant: isLastStep ? .red : .outline))
        }
        .opacity(reveal ? 1 : 0)
    }
}
