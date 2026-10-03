import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var stepTitleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var greetingSize: CGFloat = 24

    private var permissions: OnboardingPermissionCoordinator {
        appState.radarNearby.localNetworkPermissions
    }
    @State private var permissionFlow = OnboardingPermissionFlow()
    @State private var permissionRequestTask: Task<Void, Never>?
    @State private var step = Step.language
    @State private var selectedLanguage: AppLanguage?
    @State private var introSymbol = IntroSymbol.hand
    @State private var introMarkIsVisible = false
    @State private var revealedLanguageCount = 0
    @State private var isFinishing = false
    @State private var isAwaitingLocalNetworkSettingsReturn = false

    private let languageOrder: [AppLanguage] = [.uk, .en, .es, .ru]

    init(
        startsAtLocalNetworkPermission: Bool = false,
        preservedSource _: OnboardingAcquisitionSource? = nil
    ) {
        if startsAtLocalNetworkPermission {
            _permissionFlow = State(
                initialValue: OnboardingPermissionFlow(startingAt: .nearby)
            )
            _step = State(initialValue: .permissions)
        }
    }

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
                            case .game:
                                gameStep
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
                .background {
                    SpyTheme.black.ignoresSafeArea(edges: .bottom)
                }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            permissions.setApplicationActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, newPhase in
            permissions.setApplicationActive(newPhase == .active)
            guard newPhase == .active,
                  isAwaitingLocalNetworkSettingsReturn else { return }
            isAwaitingLocalNetworkSettingsReturn = false
            recheckLocalNetworkAfterSettings()
        }
        .onDisappear {
            permissionRequestTask?.cancel()
            permissionRequestTask = nil
        }
    }

    private var copy: OnboardingCopy {
        OnboardingCopy(language: selectedLanguage ?? appState.language)
    }

    private var stepTitleFont: Font {
        // ScaledMetric applies Dynamic Type once. A scalable custom font here
        // would apply it again and split words at accessibility sizes.
        .custom("Rajdhani-Bold", fixedSize: min(stepTitleSize, 48))
    }

    private var languageStep: some View {
        VStack(spacing: 34) {
            introMark

            VStack(spacing: 0) {
                ForEach(languageOrder.indices, id: \.self) { index in
                    languageButton(languageOrder[index], index: index)

                    if index < languageOrder.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: 310)

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
                            .font(.custom("Rajdhani-Bold", fixedSize: 68))
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
        .frame(minHeight: 78)
        .accessibilityHidden(true)
        .animation(pageAnimation, value: selectedLanguage)
    }

    private func languageButton(_ language: AppLanguage, index: Int) -> some View {
        let isSelected = selectedLanguage == language
        let isRevealed = index < revealedLanguageCount

        return Button {
            selectLanguage(language)
        } label: {
            HStack(spacing: 16) {
                Text(language.title)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isSelected ? 1 : 0.68))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(SpyTheme.red)
                        .shadow(color: SpyTheme.red.opacity(0.55), radius: 8)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 17 : 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.985))
        .disabled(!isRevealed)
        .opacity(isRevealed ? 1 : 0)
        .offset(y: reduceMotion || isRevealed ? 0 : 18)
        .accessibilityIdentifier("spyclash.onboarding.language.\(language.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var gameStep: some View {
        VStack(spacing: 26) {
            OnboardingRolesIllustration()
                .frame(maxWidth: 320)
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                Text(copy.gameTitle)
                    .font(stepTitleFont)
                    .foregroundStyle(.white)

                Text(copy.gameRoles)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                Text(copy.gameBody)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(SpyTheme.bodyText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spyclash.onboarding.game")
    }

    private var permissionsStep: some View {
        VStack(spacing: 26) {
            OnboardingRadarIllustration(reduceMotion: reduceMotion)
                .frame(width: 254, height: 254)
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                Text(copy.radarTitle)
                    .font(stepTitleFont)
                    .foregroundStyle(.white)

                Text(copy.radarBody)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(SpyTheme.bodyText)

                Text(copy.localNetworkExplanation)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(SpyTheme.bodyText.opacity(0.8))
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if let statusText = localNetworkStatusText {
                HStack(alignment: .top, spacing: 8) {
                    if isPermissionFlowBusy {
                        ProgressView()
                            .tint(SpyTheme.red)
                    }
                    Text(statusText)
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(SpyTheme.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spyclash.onboarding.permission.screen.nearby")
        .task {
            await preparePermissionFlow()
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if showsBottomAction {
            Button {
                performBottomAction()
            } label: {
                Group {
                    if let bottomActionTitle, !isFinishing {
                        HStack(spacing: 10) {
                            Text(bottomActionTitle)
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.72)

                            Image(systemName: bottomActionSystemImage)
                                .font(.system(size: 17, weight: .black))
                                .contentTransition(.opacity)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    } else if isFinishing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: bottomActionSystemImage)
                            .font(.system(size: 21, weight: .black))
                            .foregroundStyle(.white)
                            .contentTransition(.opacity)
                    }
                }
                .frame(
                    minWidth: bottomActionTitle == nil ? 66 : 148,
                    minHeight: 54
                )
                .background(SpyTheme.red, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: SpyTheme.red.opacity(0.38), radius: 18, y: 7)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .id(bottomActionIdentifier)
            .buttonStyle(SpyWebPressStyle(pressedScale: 0.93))
            .disabled(isBottomActionDisabled)
            .accessibilityIdentifier(bottomActionIdentifier)
            .accessibilityLabel(bottomActionAccessibilityLabel)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.82).combined(with: .opacity))
        }
    }

    private var showsBottomAction: Bool {
        switch step {
        case .language:
            selectedLanguage != nil
        case .game:
            true
        case .permissions:
            switch permissionFlow.phase {
            case .ready:
                canPerformCurrentPermissionAction
            case .complete:
                true
            case .loading, .requesting, .resolved:
                false
            }
        }
    }

    private var bottomActionSystemImage: String {
        guard step == .permissions else { return "arrow.right" }
        guard let permission = permissionFlow.currentPermission else {
            return "checkmark"
        }
        guard permission == .nearby else { return "arrow.right" }

        switch permissions.status(for: permission) {
        case .denied:
            return "gearshape"
        case .unavailable:
            return "arrow.clockwise"
        case .notDetermined, .requesting, .granted, .unsupported:
            return "arrow.right"
        }
    }

    private var bottomActionTitle: String? {
        guard step == .permissions else {
            return step == .game ? copy.nextAction : nil
        }
        guard let permission = permissionFlow.currentPermission else {
            return copy.startPlayingAction
        }

        switch permissions.status(for: permission) {
        case .notDetermined:
            return copy.radarEnableAction
        case .denied where permission == .nearby:
            return copy.permissionSettingsAction
        case .unavailable where permission == .nearby:
            return copy.permissionRetryAction
        case .granted, .denied, .unavailable, .unsupported:
            return copy.startPlayingAction
        case .requesting:
            return copy.permissionRequesting
        }
    }

    private var bottomActionIdentifier: String {
        guard step == .permissions else {
            return "spyclash.onboarding.next"
        }
        guard let permission = permissionFlow.currentPermission else {
            return "spyclash.onboarding.finish"
        }
        return "spyclash.onboarding.permission.\(permission.rawValue)"
    }

    private var bottomActionAccessibilityLabel: String {
        bottomActionTitle ?? copy.nextAction
    }

    private var isBottomActionDisabled: Bool {
        isFinishing
            || isPermissionFlowBusy
            || !canPerformCurrentPermissionAction
    }

    private var canPerformCurrentPermissionAction: Bool {
        guard step == .permissions,
              let permission = permissionFlow.currentPermission else {
            return true
        }
        guard case .ready = permissionFlow.phase else { return false }

        switch permissions.status(for: permission) {
        case .notDetermined, .granted, .denied, .unavailable, .unsupported:
            return true
        case .requesting:
            return false
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
                step = .game
            }

        case .game:
            HapticManager.shared.fire(.navigation)
            withAnimation(pageAnimation) {
                step = .permissions
            }

        case .permissions:
            guard !isFinishing, !isPermissionFlowBusy else { return }
            guard permissionFlow.isComplete else {
                performCurrentPermissionAction()
                return
            }
            permissionRequestTask?.cancel()
            permissionRequestTask = Task { @MainActor in
                await finishOnboarding()
            }
        }
    }

    @MainActor
    private func finishOnboarding() async {
        guard !Task.isCancelled, !isFinishing, permissionFlow.isComplete else { return }
        // The account-gate transition removes this view before its reveal
        // animation ends. From here the completion must outlive onDisappear.
        permissionRequestTask = nil
        isFinishing = true
        defer { isFinishing = false }
        HapticManager.shared.fire(.milestone)
        await appState.finishOnboarding()
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

    private func preparePermissionFlow() async {
        guard permissionFlow.phase == .loading,
              let permission = permissionFlow.currentPermission else { return }
        await permissions.refresh()
        guard !Task.isCancelled,
              permissionFlow.currentPermission == permission else { return }
        withAnimation(pageAnimation) {
            _ = permissionFlow.markReady(for: permission)
        }
    }

    private var isPermissionFlowBusy: Bool {
        guard step == .permissions else { return false }
        switch permissionFlow.phase {
        case .loading, .requesting, .resolved:
            return true
        case .ready, .complete:
            return false
        }
    }

    private func performCurrentPermissionAction() {
        guard case .ready = permissionFlow.phase,
              let permission = permissionFlow.currentPermission else { return }
        let status = permissions.status(for: permission)
        HapticManager.shared.fire(.buttonPress)

        switch status {
        case .notDetermined:
            beginPermissionRequest(permission)
        case .denied:
            if permission == .nearby {
                openLocalNetworkSettings()
            } else {
                showExistingPermissionResolution(status, for: permission)
            }
        case .unavailable:
            if permission == .nearby {
                beginPermissionRequest(permission)
            } else {
                showExistingPermissionResolution(status, for: permission)
            }
        case .granted, .unsupported:
            showExistingPermissionResolution(status, for: permission)
        case .requesting:
            return
        }
    }

    private func beginPermissionRequest(_ permission: OnboardingPermissionKind) {
        let requestID = UUID()
        var didBeginRequest = false
        withAnimation(pageAnimation) {
            didBeginRequest = permissionFlow.beginRequest(
                for: permission,
                requestID: requestID
            )
        }
        guard didBeginRequest else { return }

        permissionRequestTask?.cancel()
        permissionRequestTask = Task { @MainActor in
            let didStartRequest = await permissions.request(permission)
            guard !Task.isCancelled else { return }
            guard didStartRequest else {
                withAnimation(pageAnimation) {
                    _ = permissionFlow.cancelRequest(
                        for: permission,
                        requestID: requestID
                    )
                }
                permissionRequestTask = nil
                return
            }
            await applyPermissionRequestResult(
                permission,
                requestID: requestID
            )
        }
    }

    private func openLocalNetworkSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        isAwaitingLocalNetworkSettingsReturn = true
        openURL(settingsURL)
    }

    private func recheckLocalNetworkAfterSettings() {
        guard step == .permissions,
              permissionFlow.currentPermission == .nearby,
              case .ready = permissionFlow.phase else { return }
        beginPermissionRequest(.nearby)
    }

    private func showExistingPermissionResolution(
        _ status: OnboardingPermissionStatus,
        for permission: OnboardingPermissionKind
    ) {
        var didResolve = false
        withAnimation(pageAnimation) {
            didResolve = permissionFlow.resolveWithoutRequest(
                status,
                for: permission
            )
        }
        guard didResolve else { return }

        permissionRequestTask?.cancel()
        permissionRequestTask = Task { @MainActor in
            await showPermissionResolutionThenAdvance(permission)
        }
    }

    private func applyPermissionRequestResult(
        _ permission: OnboardingPermissionKind,
        requestID: UUID
    ) async {
        guard !Task.isCancelled else { return }
        let resolvedStatus = permissions.status(for: permission)
        var didResolveRequest = false
        withAnimation(pageAnimation) {
            didResolveRequest = permissionFlow.resolveRequest(
                for: permission,
                requestID: requestID,
                status: resolvedStatus
            )
        }
        guard didResolveRequest else {
            permissionRequestTask = nil
            return
        }

        if resolvedStatus == .granted {
            HapticManager.shared.fire(.notification(.success))
        }
        await showPermissionResolutionThenAdvance(permission)
    }

    private func showPermissionResolutionThenAdvance(
        _ permission: OnboardingPermissionKind
    ) async {
        do {
            try await Task.sleep(for: .milliseconds(620))
        } catch {
            return
        }
        guard !Task.isCancelled,
              permissionFlow.currentPermission == permission,
              case .resolved(let status) = permissionFlow.phase,
              OnboardingPermissionFlow.statusCompletesStep(
                  status,
                  for: permission
              ) else { return }
        var didAdvance = false
        withAnimation(pageAnimation) {
            didAdvance = permissionFlow.advance(after: permission)
        }
        guard didAdvance else { return }
        if permissionFlow.isComplete {
            await finishOnboarding()
        }
        permissionRequestTask = nil
    }

    private func permissionDisplayStatus(
        _ permission: OnboardingPermissionKind
    ) -> OnboardingPermissionStatus {
        guard permissionFlow.currentPermission == permission else {
            return permissions.status(for: permission)
        }
        switch permissionFlow.phase {
        case .loading, .requesting:
            return .requesting
        case .resolved(let status):
            return status
        case .ready, .complete:
            return permissions.status(for: permission)
        }
    }

    private var localNetworkStatusText: String? {
        guard permissionFlow.currentPermission == .nearby else { return nil }
        if permissionFlow.phase == .loading {
            return nil
        }
        switch permissionDisplayStatus(.nearby) {
        case .notDetermined:
            return nil
        case .requesting:
            return copy.permissionRequesting
        case .granted:
            return nil
        case .denied:
            return copy.localNetworkDenied
        case .unavailable:
            return copy.localNetworkUnavailable
        case .unsupported:
            return copy.localNetworkUnsupported
        }
    }
}

private struct OnboardingRolesIllustration: View {
    var body: some View {
        HStack(spacing: 18) {
            roleCard(isSpy: false)
                .rotationEffect(.degrees(-7))
                .offset(y: 8)

            roleCard(isSpy: true)
                .rotationEffect(.degrees(7))
                .offset(y: -8)
        }
        .padding(.horizontal, 14)
        .frame(height: 212)
    }

    private func roleCard(isSpy: Bool) -> some View {
        VStack(spacing: 20) {
            Image(systemName: isSpy ? "person.fill" : "person.2.fill")
                .font(.system(size: 37, weight: .medium))
                .foregroundStyle(isSpy ? SpyTheme.red : .white.opacity(0.9))

            Group {
                if isSpy {
                    Text("?")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(SpyTheme.red)
                } else {
                    HStack(spacing: 5) {
                        ForEach(0..<4) { _ in
                            Circle()
                                .fill(.white.opacity(0.9))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                isSpy ? SpyTheme.red.opacity(0.10) : .white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .frame(height: 174)
        .background(SpyTheme.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    isSpy ? SpyTheme.red.opacity(0.65) : .white.opacity(0.16),
                    lineWidth: 1
                )
        }
        .shadow(color: isSpy ? SpyTheme.red.opacity(0.15) : .black, radius: 22, y: 8)
    }
}

private struct OnboardingRadarIllustration: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 30 : elapsed.truncatingRemainder(dividingBy: 14) / 14 * 360

            ZStack {
                Circle()
                    .fill(SpyTheme.red.opacity(0.035))

                Circle()
                    .fill(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.72),
                                .init(color: SpyTheme.red.opacity(0.20), location: 1)
                            ],
                            center: .center
                        )
                    )
                    .rotationEffect(.degrees(angle))

                ForEach(1...3, id: \.self) { ring in
                    Circle()
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                        .padding(CGFloat(3 - ring) * 42)
                }

                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(width: 1)
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 1)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(SpyTheme.red, in: Circle())
                    .shadow(color: SpyTheme.red.opacity(0.28), radius: 22)

                playerMark(size: 40)
                    .offset(x: -69, y: -67)
                playerMark(size: 34)
                    .offset(x: 86, y: -28)
                playerMark(size: 36)
                    .offset(x: 22, y: 87)
            }
        }
    }

    private func playerMark(size: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(SpyTheme.card, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(SpyTheme.red.opacity(0.65), lineWidth: 1)
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
        case game
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

    var gameTitle: String {
        localized(
            en: "SpyClash is…",
            es: "SpyClash es…",
            ru: "SpyClash — это…",
            uk: "SpyClash — це…"
        )
    }

    var gameRoles: String {
        localized(
            en: "Detectives know the secret word. The spy doesn't.",
            es: "Los detectives conocen la palabra secreta. El espía no.",
            ru: "Детективы знают секретное слово. Шпион — нет.",
            uk: "Детективи знають секретне слово. Шпигун — ні."
        )
    }

    var gameBody: String {
        localized(
            en: "Listen closely and find the spy. If you're the spy, blend in.",
            es: "Escucha a los demás y descubre al espía. Si eres tú, disimula.",
            ru: "Слушайте друг друга и вычислите шпиона. Если шпион — вы, не выдавайте себя.",
            uk: "Слухайте одне одного та знайдіть шпигуна. Якщо шпигун — ви, не видавайте себе."
        )
    }

    var radarTitle: String {
        localized(
            en: "Your next game is nearby",
            es: "Tu próxima partida está cerca",
            ru: "Ваша следующая игра — рядом",
            uk: "Ваша наступна гра — поруч"
        )
    }

    var radarBody: String {
        localized(
            en: "Radar helps you find nearby SpyClash players. Invite them and play together.",
            es: "El radar te ayuda a encontrar jugadores de SpyClash cerca. Invítalos y jugad juntos.",
            ru: "Радар помогает найти игроков SpyClash поблизости. Приглашайте их и играйте вместе.",
            uk: "Радар допомагає знайти гравців SpyClash поблизу. Запрошуйте їх і грайте разом."
        )
    }

    var localNetworkExplanation: String {
        localized(
            en: "Allow Local Network access so Radar can discover players around you.",
            es: "Permite el acceso a la red local para que el radar encuentre jugadores cerca.",
            ru: "Разрешите доступ к локальной сети, чтобы радар мог находить игроков рядом.",
            uk: "Дозвольте доступ до локальної мережі, щоб радар міг знаходити гравців поруч."
        )
    }

    var nextAction: String {
        localized(en: "Next", es: "Siguiente", ru: "Дальше", uk: "Далі")
    }

    var startPlayingAction: String {
        localized(en: "Let's play", es: "A jugar", ru: "Играть", uk: "Грати")
    }

    var radarEnableAction: String {
        localized(en: "Enable Radar", es: "Activar radar", ru: "Включить радар", uk: "Увімкнути радар")
    }

    var permissionSettingsAction: String {
        localized(en: "Open Settings", es: "Abrir ajustes", ru: "Открыть настройки", uk: "Відкрити налаштування")
    }

    var permissionRetryAction: String {
        localized(en: "Try again", es: "Reintentar", ru: "Попробовать снова", uk: "Спробувати ще раз")
    }

    var permissionRequesting: String {
        localized(
            en: "Waiting for Local Network access…",
            es: "Esperando acceso a la red local…",
            ru: "Ожидаем доступ к локальной сети…",
            uk: "Очікуємо доступ до локальної мережі…"
        )
    }

    var localNetworkDenied: String {
        localized(
            en: "Turn on Local Network for SpyClash in Settings to continue.",
            es: "Activa la red local para SpyClash en Ajustes para continuar.",
            ru: "Чтобы продолжить, включите «Локальную сеть» для SpyClash в настройках.",
            uk: "Щоб продовжити, увімкніть «Локальну мережу» для SpyClash у налаштуваннях."
        )
    }

    var localNetworkUnavailable: String {
        localized(
            en: "We couldn't check Local Network access. Please try again.",
            es: "No pudimos comprobar el acceso a la red local. Inténtalo de nuevo.",
            ru: "Не удалось проверить доступ к локальной сети. Попробуйте ещё раз.",
            uk: "Не вдалося перевірити доступ до локальної мережі. Спробуйте ще раз."
        )
    }

    var localNetworkUnsupported: String {
        localized(
            en: "Radar isn't available on this device. You can continue.",
            es: "El radar no está disponible en este dispositivo. Puedes continuar.",
            ru: "На этом устройстве радар недоступен. Можно продолжить.",
            uk: "На цьому пристрої радар недоступний. Можна продовжити."
        )
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
