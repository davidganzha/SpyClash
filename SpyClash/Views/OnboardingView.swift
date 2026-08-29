import SwiftUI
import UIKit

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var stepTitleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var greetingSize: CGFloat = 24
    @Namespace private var languageSelectionNamespace

    @State private var permissions = OnboardingPermissionCoordinator()
    @State private var step = Step.language
    @State private var selectedLanguage: AppLanguage?
    @State private var selectedSource: OnboardingAcquisitionSource?
    @State private var introSymbol = IntroSymbol.hand
    @State private var introMarkIsVisible = false
    @State private var revealedLanguageCount = 0
    @State private var isFinishing = false
    @State private var activePermissionRequest: OnboardingPermissionKind?
    @State private var permissionOpenedInSettings: OnboardingPermissionKind?

    private let languageOrder: [AppLanguage] = [.uk, .en, .es, .ru]
    private let sourceOrder: [OnboardingAcquisitionSource] = [
        .chatGPT,
        .appStoreSearch,
        .webSearch,
        .socialMedia,
        .friendsOrFamily,
        .other
    ]
    private let permissionOrder: [OnboardingPermissionKind] = [
        .notifications,
        .camera,
        .nearby
    ]

    var body: some View {
        ZStack {
            SpyTheme.black
                .ignoresSafeArea()

            SpyLaserScanLayer(style: .onboarding, reduceMotion: reduceMotion)

            LinearGradient(
                colors: [
                    SpyTheme.black.opacity(0.66),
                    SpyTheme.black.opacity(0.20),
                    SpyTheme.black.opacity(0.66)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 28)

                        Group {
                            switch step {
                            case .language:
                                languageStep
                            case .source:
                                sourceStep
                            case .permissions:
                                permissionsStep
                            }
                        }
                        .id(step)
                        .transition(pageTransition)

                        Spacer(minLength: 34)
                    }
                    .frame(maxWidth: 520)
                    .frame(minHeight: max(0, proxy.size.height - 12))
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomAction
        }
        .preferredColorScheme(.dark)
        .task {
            await permissions.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let settingsPermission = permissionOpenedInSettings
            permissionOpenedInSettings = nil
            if settingsPermission == .nearby {
                activePermissionRequest = .nearby
            }
            Task {
                await permissions.refresh()
                guard settingsPermission == .nearby else { return }
                await permissions.request(.nearby)
                activePermissionRequest = nil
            }
        }
    }

    private var copy: OnboardingCopy {
        OnboardingCopy(language: selectedLanguage ?? appState.language)
    }

    private var languageStep: some View {
        VStack(spacing: 34) {
            introMark

            LazyVGrid(
                columns: optionColumns,
                spacing: 12
            ) {
                ForEach(languageOrder.indices, id: \.self) { index in
                    languageButton(languageOrder[index], index: index)
                }
            }

        }
        .task {
            await playLanguageIntro()
        }
    }

    private var introMark: some View {
        ZStack {
            if selectedLanguage != nil {
                Text(copy.languageGreeting)
                    .id(selectedLanguage)
                    .font(.system(size: greetingSize, weight: .semibold, design: .rounded))
                    .tracking(0.2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(languageLeadTransition)
            } else {
                Group {
                    switch introSymbol {
                    case .hand:
                        OnboardingWavingHand(reduceMotion: reduceMotion)
                    case .question:
                        Text("?")
                            .font(SpyTheme.brandFont(size: 68))
                            .foregroundStyle(.white)
                            .shadow(color: SpyTheme.red.opacity(0.72), radius: 18)
                    }
                }
                .id(introSymbol)
                .transition(languageLeadTransition)
            }
        }
        .opacity(introMarkIsVisible ? 1 : 0)
        .blur(radius: reduceMotion || introMarkIsVisible ? 0 : 16)
        .scaleEffect(reduceMotion || introMarkIsVisible ? 1 : 0.96)
        .frame(height: 78)
        .accessibilityHidden(true)
        .animation(pageAnimation, value: selectedLanguage)
    }

    private func languageButton(_ language: AppLanguage, index: Int) -> some View {
        let isSelected = selectedLanguage == language
        let isRevealed = index < revealedLanguageCount

        return Button {
            selectLanguage(language)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.085),
                                Color.white.opacity(0.035)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SpyTheme.red, SpyTheme.red.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .matchedGeometryEffect(
                            id: "onboarding-language-selection",
                            in: languageSelectionNamespace
                        )
                }

                Text(language.title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.075),
                        lineWidth: 1
                    )
            }
            .shadow(color: isSelected ? SpyTheme.red.opacity(0.34) : .clear, radius: 18, y: 7)
            .scaleEffect(isSelected ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.965))
        .disabled(!isRevealed)
        .opacity(isRevealed ? 1 : 0)
        .offset(y: reduceMotion || isRevealed ? 0 : 18)
        .accessibilityIdentifier("spyclash.onboarding.language.\(language.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sourceStep: some View {
        VStack(spacing: 30) {
            Text(copy.sourceTitle)
                .font(SpyTheme.brandFont(size: stepTitleSize))
                .tracking(1.1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.68)

            LazyVGrid(
                columns: optionColumns,
                spacing: 10
            ) {
                ForEach(sourceOrder, id: \.rawValue) { source in
                    sourceButton(source)
                }
            }
        }
    }

    private func sourceButton(_ source: OnboardingAcquisitionSource) -> some View {
        let isSelected = selectedSource == source

        return Button {
            withAnimation(reduceMotion ? nil : SpyMotion.press) {
                selectedSource = source
            }
            HapticManager.shared.fire(.tabSelection)
        } label: {
            Text(copy.sourceLabel(source))
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .frame(maxWidth: .infinity, minHeight: 58)
                .padding(.horizontal, 10)
                .background(
                    isSelected ? SpyTheme.red : Color.white.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(color: isSelected ? SpyTheme.red.opacity(0.28) : .clear, radius: 16, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier("spyclash.onboarding.source.\(source.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var permissionsStep: some View {
        VStack(spacing: 28) {
            Text(copy.permissionsTitle)
                .font(SpyTheme.brandFont(size: stepTitleSize))
                .tracking(1.1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.68)

            VStack(spacing: 12) {
                ForEach(permissionOrder, id: \.self) { permission in
                    permissionButton(permission)
                }
            }

        }
        .task {
            await permissions.refresh()
        }
    }

    private func permissionButton(_ permission: OnboardingPermissionKind) -> some View {
        Button {
            performPermissionAction(permission)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: permissionIcon(permission))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(permissionAccent(permission))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.permissionTitle(permission))
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)

                    Text(copy.permissionBody(permission))
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(SpyTheme.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                permissionStatusIcon(permission)
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                permissions.status(for: permission) == .granted
                    ? SpyTheme.green.opacity(0.075)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(!canActivate(permission) || isPermissionRequestInFlight)
        .accessibilityIdentifier("spyclash.onboarding.permission.\(permissionID(permission))")
        .accessibilityHint(permissionAccessibilityHint(permission))
    }

    @ViewBuilder
    private func permissionStatusIcon(_ permission: OnboardingPermissionKind) -> some View {
        switch permissions.status(for: permission) {
        case .notDetermined:
            Image(systemName: "arrow.up.right")
                .foregroundStyle(SpyTheme.red)
        case .requesting:
            ProgressView()
                .tint(SpyTheme.red)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SpyTheme.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(SpyTheme.red)
        case .unavailable:
            Image(systemName: canActivate(permission) ? "arrow.clockwise" : "minus.circle.fill")
                .foregroundStyle(canActivate(permission) ? SpyTheme.red : SpyTheme.dim)
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if showsBottomAction {
            Button {
                performBottomAction()
            } label: {
                ZStack {
                    if isFinishing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: step == .permissions ? "checkmark" : "arrow.right")
                            .font(.system(size: 21, weight: .black))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 66, height: 54)
                .background(SpyTheme.red, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: SpyTheme.red.opacity(0.38), radius: 18, y: 7)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(SpyWebPressStyle(pressedScale: 0.93))
            .disabled(isFinishing || isPermissionRequestInFlight)
            .accessibilityIdentifier(step == .permissions ? "spyclash.onboarding.finish" : "spyclash.onboarding.next")
            .accessibilityLabel(step == .permissions ? copy.finishAction : copy.nextAction)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .transition(.scale(scale: 0.82).combined(with: .opacity))
        }
    }

    private var showsBottomAction: Bool {
        switch step {
        case .language:
            selectedLanguage != nil
        case .source:
            selectedSource != nil
        case .permissions:
            selectedSource != nil
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }

        return .asymmetric(
            insertion: .modifier(
                active: OnboardingStepTransitionModifier(
                    opacity: 0,
                    blur: 12,
                    scale: 0.975,
                    y: 10
                ),
                identity: OnboardingStepTransitionModifier()
            ),
            removal: .modifier(
                active: OnboardingStepTransitionModifier(
                    opacity: 0,
                    blur: 10,
                    scale: 1.02,
                    y: -8
                ),
                identity: OnboardingStepTransitionModifier()
            )
        )
    }

    private var languageLeadTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }

        return .modifier(
            active: OnboardingStepTransitionModifier(
                opacity: 0,
                blur: 9,
                scale: 0.975,
                y: 4
            ),
            identity: OnboardingStepTransitionModifier()
        )
    }

    private var optionColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 10)]
        }
        return [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var pageAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .easeInOut(duration: 0.38)
    }

    private func selectLanguage(_ language: AppLanguage) {
        appState.setOnboardingLanguage(language)
        withAnimation(reduceMotion ? nil : SpyMotion.press) {
            selectedLanguage = language
        }
        HapticManager.shared.fire(.tabSelection)
    }

    private func performBottomAction() {
        switch step {
        case .language:
            guard selectedLanguage != nil else { return }
            HapticManager.shared.fire(.navigation)
            withAnimation(pageAnimation) {
                step = .source
            }

        case .source:
            guard selectedSource != nil else { return }
            HapticManager.shared.fire(.navigation)
            withAnimation(pageAnimation) {
                step = .permissions
            }

        case .permissions:
            guard let selectedSource,
                  !isFinishing,
                  !isPermissionRequestInFlight else { return }
            isFinishing = true
            HapticManager.shared.fire(.milestone)
            Task {
                await appState.finishOnboarding(
                    source: selectedSource,
                    enableNearbyTransport: permissions.status(for: .nearby) == .granted
                )
                isFinishing = false
            }
        }
    }

    private func playLanguageIntro() async {
        guard revealedLanguageCount == 0 else { return }

        if reduceMotion {
            introSymbol = .question
            introMarkIsVisible = true
            revealedLanguageCount = languageOrder.count
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            return
        }

        withAnimation(.easeInOut(duration: 1.35)) {
            introMarkIsVisible = true
        }

        do {
            // 1.35 s fade-in + 1.00 s calm hold.
            try await Task.sleep(for: .milliseconds(2_350))
        } catch {
            return
        }

        withAnimation(.easeInOut(duration: 1.65)) {
            introMarkIsVisible = false
        }

        do {
            // Together with the entrance and hold, the hand's full visible
            // arc is four seconds and never snaps away.
            try await Task.sleep(for: .milliseconds(1_650))
        } catch {
            return
        }

        introSymbol = .question
        withAnimation(.easeInOut(duration: 0.95)) {
            introMarkIsVisible = true
        }

        do {
            try await Task.sleep(for: .milliseconds(260))
        } catch {
            return
        }

        for index in languageOrder.indices {
            guard !Task.isCancelled else { return }
            withAnimation(SpyMotion.entrance(duration: 0.48)) {
                revealedLanguageCount = index + 1
            }
            do {
                try await Task.sleep(for: .milliseconds(64))
            } catch {
                return
            }
        }
    }

    private func permissionIcon(_ permission: OnboardingPermissionKind) -> String {
        switch permission {
        case .notifications:
            "bell.badge.fill"
        case .camera:
            "qrcode.viewfinder"
        case .nearby:
            "dot.radiowaves.left.and.right"
        }
    }

    private func permissionID(_ permission: OnboardingPermissionKind) -> String {
        switch permission {
        case .notifications:
            "notifications"
        case .camera:
            "camera"
        case .nearby:
            "nearby"
        }
    }

    private var isPermissionRequestInFlight: Bool {
        activePermissionRequest != nil
            || permissionOrder.contains {
                permissions.status(for: $0) == .requesting
            }
    }

    private func canActivate(_ permission: OnboardingPermissionKind) -> Bool {
        switch permissions.status(for: permission) {
        case .notDetermined:
            true
        case .denied:
            true
        case .unavailable:
            permission == .nearby
                && OnboardingPermissionCoordinator.canEvaluateNearbyPrivacy
        case .requesting, .granted:
            false
        }
    }

    private func performPermissionAction(_ permission: OnboardingPermissionKind) {
        guard activePermissionRequest == nil else { return }

        switch permissions.status(for: permission) {
        case .denied:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            permissionOpenedInSettings = permission
            HapticManager.shared.fire(.buttonPress)
            openURL(settingsURL)
        case .notDetermined, .unavailable:
            guard canActivate(permission) else { return }
            activePermissionRequest = permission
            HapticManager.shared.fire(.buttonPress)
            Task {
                await permissions.request(permission)
                activePermissionRequest = nil
            }
        case .requesting, .granted:
            return
        }
    }

    private func permissionAccent(_ permission: OnboardingPermissionKind) -> Color {
        switch permissions.status(for: permission) {
        case .granted:
            SpyTheme.green
        case .unavailable:
            SpyTheme.dim
        case .notDetermined, .requesting, .denied:
            SpyTheme.red
        }
    }

    private func permissionAccessibilityHint(_ permission: OnboardingPermissionKind) -> String {
        switch permissions.status(for: permission) {
        case .notDetermined:
            copy.permissionRequestHint
        case .requesting:
            copy.permissionRequesting
        case .granted:
            copy.permissionGranted
        case .denied:
            copy.permissionDeniedHint
        case .unavailable:
            canActivate(permission)
                ? copy.permissionRequestHint
                : copy.permissionUnavailable
        }
    }
}

private struct OnboardingWavingHand: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let normalizedPhase = elapsed.truncatingRemainder(dividingBy: 1.8) / 1.8
            let angle = reduceMotion ? 0 : sin(normalizedPhase * 2 * .pi) * 7

            Image(systemName: "hand.wave.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: SpyTheme.red.opacity(0.72), radius: 18)
                .rotationEffect(.degrees(angle), anchor: .bottomTrailing)
        }
    }
}

private extension OnboardingView {
    enum Step: Int, CaseIterable, Hashable, Identifiable {
        case language
        case source
        case permissions

        var id: Int { rawValue }
    }

    enum IntroSymbol: Hashable {
        case hand
        case question
    }
}

private struct OnboardingStepTransitionModifier: ViewModifier {
    var opacity: Double = 1
    var blur: CGFloat = 0
    var scale: CGFloat = 1
    var y: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale)
            .offset(y: y)
    }
}

private struct OnboardingCopy {
    let language: AppLanguage

    var languageGreeting: String {
        localized(
            en: "Hello! We'll use English.",
            es: "¡Hola! Hablaremos en español.",
            ru: "Здравствуйте! Будем говорить по-русски.",
            uk: "Вітаємо! Говоритимемо українською."
        )
    }

    var sourceTitle: String {
        localized(
            en: "HOW DID YOU FIND US?",
            es: "¿CÓMO NOS ENCONTRASTE?",
            ru: "КАК ВЫ УЗНАЛИ О НАС?",
            uk: "ЯК ВИ ДІЗНАЛИСЯ ПРО НАС?"
        )
    }

    var permissionsTitle: String {
        localized(
            en: "PERMISSIONS",
            es: "PERMISOS",
            ru: "РАЗРЕШЕНИЯ",
            uk: "ДОЗВОЛИ"
        )
    }

    var nextAction: String {
        localized(en: "Next", es: "Siguiente", ru: "Дальше", uk: "Далі")
    }

    var finishAction: String {
        localized(en: "Finish", es: "Finalizar", ru: "Завершить", uk: "Завершити")
    }

    var permissionRequesting: String {
        localized(en: "WAITING FOR IOS", es: "ESPERANDO A IOS", ru: "ОЖИДАНИЕ IOS", uk: "ОЧІКУВАННЯ IOS")
    }

    var permissionGranted: String {
        localized(en: "ENABLED", es: "ACTIVADO", ru: "ВКЛЮЧЕНО", uk: "УВІМКНЕНО")
    }

    var permissionUnavailable: String {
        localized(en: "NOT AVAILABLE", es: "NO DISPONIBLE", ru: "НЕДОСТУПНО", uk: "НЕДОСТУПНО")
    }

    var permissionRequestHint: String {
        localized(
            en: "Opens the iOS permission request.",
            es: "Abre la solicitud de permiso de iOS.",
            ru: "Откроет системный запрос разрешения iOS.",
            uk: "Відкриє системний запит дозволу iOS."
        )
    }

    var permissionDeniedHint: String {
        localized(
            en: "Permission was not granted. You can change it in iOS Settings.",
            es: "No se concedió el permiso. Puedes cambiarlo en los ajustes de iOS.",
            ru: "Разрешение не предоставлено. Его можно изменить в настройках iOS.",
            uk: "Дозвіл не надано. Його можна змінити в налаштуваннях iOS."
        )
    }

    func sourceLabel(_ source: OnboardingAcquisitionSource) -> String {
        switch source {
        case .chatGPT:
            "ChatGPT"
        case .appStoreSearch:
            localized(en: "App Store search", es: "Búsqueda en App Store", ru: "Поиск в App Store", uk: "Пошук в App Store")
        case .webSearch:
            localized(en: "Web search", es: "Búsqueda web", ru: "Поиск в интернете", uk: "Пошук в інтернеті")
        case .socialMedia:
            localized(en: "Social media", es: "Redes sociales", ru: "Социальные сети", uk: "Соціальні мережі")
        case .friendsOrFamily:
            localized(en: "Friends or family", es: "Amigos o familia", ru: "Друзья или семья", uk: "Друзі або родина")
        case .other:
            localized(en: "Other", es: "Otro", ru: "Другое", uk: "Інше")
        }
    }

    func permissionTitle(_ permission: OnboardingPermissionKind) -> String {
        switch permission {
        case .notifications:
            localized(en: "Notifications", es: "Notificaciones", ru: "Уведомления", uk: "Сповіщення")
        case .camera:
            localized(en: "Camera", es: "Cámara", ru: "Камера", uk: "Камера")
        case .nearby:
            localized(en: "Nearby players", es: "Jugadores cercanos", ru: "Игроки рядом", uk: "Гравці поруч")
        }
    }

    func permissionBody(_ permission: OnboardingPermissionKind) -> String {
        switch permission {
        case .notifications:
            localized(
                en: "Room invites and important game events.",
                es: "Invitaciones y eventos importantes de la partida.",
                ru: "Приглашения и важные события игры.",
                uk: "Запрошення та важливі події гри."
            )
        case .camera:
            localized(
                en: "Scan a room QR code to join.",
                es: "Escanea el QR de una sala para entrar.",
                ru: "Сканируйте QR-код для входа в комнату.",
                uk: "Скануйте QR-код для входу до кімнати."
            )
        case .nearby:
            localized(
                en: "Find nearby players with Radar.",
                es: "Encuentra jugadores cercanos con el radar.",
                ru: "Находите игроков рядом через радар.",
                uk: "Знаходьте гравців поруч через радар."
            )
        }
    }

    private func localized(en: String, es: String, ru: String, uk: String) -> String {
        switch language {
        case .en:
            en
        case .es:
            es
        case .ru:
            ru
        case .uk:
            uk
        }
    }
}
