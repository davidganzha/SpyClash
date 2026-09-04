import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var stepTitleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var greetingSize: CGFloat = 24

    @State private var permissions = OnboardingPermissionCoordinator()
    @State private var permissionFlow = OnboardingPermissionFlow()
    @State private var permissionRequestTask: Task<Void, Never>?
    @State private var step = Step.language
    @State private var selectedLanguage: AppLanguage?
    @State private var selectedSource: OnboardingAcquisitionSource?
    @State private var introSymbol = IntroSymbol.hand
    @State private var introMarkIsVisible = false
    @State private var revealedLanguageCount = 0
    @State private var isFinishing = false
    @State private var isAwaitingLocalNetworkSettingsReturn = false

    private let languageOrder: [AppLanguage] = [.uk, .en, .es, .ru]
    private let sourceOrder: [OnboardingAcquisitionSource] = [
        .chatGPT,
        .appStoreSearch,
        .webSearch,
        .socialMedia,
        .friendsOrFamily,
        .other
    ]

    init(
        startsAtLocalNetworkPermission: Bool = false,
        preservedSource: OnboardingAcquisitionSource? = nil
    ) {
        if startsAtLocalNetworkPermission {
            _permissionFlow = State(
                initialValue: OnboardingPermissionFlow(startingAt: .nearby)
            )
            _step = State(initialValue: .permissions)
            _selectedSource = State(initialValue: preservedSource ?? .other)
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
        Group {
            if let permission = permissionFlow.currentPermission {
                permissionPrompt(permission)
                    .id(permission)
                    .transition(pageTransition)
            } else {
                permissionCompletion
                    .transition(pageTransition)
            }
        }
        .task {
            await preparePermissionFlow()
        }
    }

    private func permissionPrompt(_ permission: OnboardingPermissionKind) -> some View {
        VStack(spacing: 22) {
            permissionHero(permission)

            Text(copy.permissionTitle(permission))
                .font(SpyTheme.brandFont(size: stepTitleSize))
                .tracking(1.0)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.72)

            Text(copy.permissionBody(permission))
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            if let statusText = permissionStatusText(permission) {
                Text(statusText)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(permissionDisplayColor(permission))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 350)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spyclash.onboarding.permission.screen.\(permissionID(permission))")
    }

    @ViewBuilder
    private func permissionHero(_ permission: OnboardingPermissionKind) -> some View {
        switch permissionDisplayStatus(permission) {
        case .notDetermined:
            Image(systemName: permissionIcon(permission))
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(SpyTheme.red)
                .shadow(color: SpyTheme.red.opacity(0.58), radius: 18)
        case .requesting:
            ProgressView()
                .controlSize(.large)
                .tint(SpyTheme.red)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(SpyTheme.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(SpyTheme.red)
        case .unavailable:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(SpyTheme.dim)
        case .unsupported:
            Image(systemName: "iphone")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(SpyTheme.dim)
        }
    }

    private var permissionCompletion: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark")
                .font(.system(size: 54, weight: .black))
                .foregroundStyle(SpyTheme.red)
                .shadow(color: SpyTheme.red.opacity(0.58), radius: 18)

            Text(copy.permissionsCompleteTitle)
                .font(SpyTheme.brandFont(size: stepTitleSize))
                .tracking(1.0)
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spyclash.onboarding.permission.complete")
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
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Image(systemName: bottomActionSystemImage)
                                .font(.system(size: 17, weight: .black))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                    } else if isFinishing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: bottomActionSystemImage)
                            .font(.system(size: 21, weight: .black))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
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
        guard step == .permissions else { return nil }
        guard let permission = permissionFlow.currentPermission else {
            return copy.finishAction
        }

        switch permissions.status(for: permission) {
        case .notDetermined:
            return copy.permissionAllowAction
        case .denied where permission == .nearby:
            return copy.permissionSettingsAction
        case .unavailable where permission == .nearby:
            return copy.permissionRetryAction
        case .granted, .denied, .unavailable, .unsupported:
            return copy.permissionContinueAction
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
        return "spyclash.onboarding.permission.\(permissionID(permission))"
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
            guard !isFinishing, !isPermissionFlowBusy else { return }
            guard permissionFlow.isComplete else {
                performCurrentPermissionAction()
                return
            }
            guard let selectedSource else { return }
            isFinishing = true
            HapticManager.shared.fire(.milestone)
            Task {
                await appState.finishOnboarding(
                    source: selectedSource
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
        HapticManager.shared.fire(.navigation)
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

    private func permissionStatusText(
        _ permission: OnboardingPermissionKind
    ) -> String? {
        guard permissionFlow.currentPermission == permission else { return nil }
        if permissionFlow.phase == .loading {
            return copy.permissionChecking
        }
        switch permissionDisplayStatus(permission) {
        case .notDetermined:
            return nil
        case .requesting:
            return copy.permissionRequesting
        case .granted:
            return copy.permissionGranted
        case .denied:
            return permission == .nearby
                ? copy.localNetworkDenied
                : copy.permissionDenied
        case .unavailable:
            return permission == .nearby
                ? copy.localNetworkUnavailable
                : copy.permissionUnavailable
        case .unsupported:
            return copy.localNetworkUnsupported
        }
    }

    private func permissionDisplayColor(
        _ permission: OnboardingPermissionKind
    ) -> Color {
        switch permissionDisplayStatus(permission) {
        case .granted:
            SpyTheme.green
        case .unavailable, .unsupported:
            SpyTheme.dim
        case .notDetermined, .requesting, .denied:
            SpyTheme.red
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

    var nextAction: String {
        localized(en: "Next", es: "Siguiente", ru: "Дальше", uk: "Далі")
    }

    var finishAction: String {
        localized(en: "Finish", es: "Finalizar", ru: "Завершить", uk: "Завершити")
    }

    var permissionAllowAction: String {
        localized(en: "Allow", es: "Permitir", ru: "Разрешить", uk: "Дозволити")
    }

    var permissionContinueAction: String {
        localized(en: "Continue", es: "Continuar", ru: "Продолжить", uk: "Продовжити")
    }

    var permissionSettingsAction: String {
        localized(en: "Open Settings", es: "Abrir ajustes", ru: "Открыть настройки", uk: "Відкрити налаштування")
    }

    var permissionRetryAction: String {
        localized(en: "Retry", es: "Reintentar", ru: "Повторить", uk: "Повторити")
    }

    var permissionRequesting: String {
        localized(en: "WAITING FOR IOS", es: "ESPERANDO A IOS", ru: "ОЖИДАНИЕ IOS", uk: "ОЧІКУВАННЯ IOS")
    }

    var permissionChecking: String {
        localized(en: "CHECKING", es: "COMPROBANDO", ru: "ПРОВЕРКА", uk: "ПЕРЕВІРКА")
    }

    var permissionGranted: String {
        localized(en: "ENABLED", es: "ACTIVADO", ru: "ВКЛЮЧЕНО", uk: "УВІМКНЕНО")
    }

    var permissionDenied: String {
        localized(
            en: "NOT ENABLED",
            es: "NO ACTIVADO",
            ru: "НЕ ВКЛЮЧЕНО",
            uk: "НЕ УВІМКНЕНО"
        )
    }

    var permissionUnavailable: String {
        localized(
            en: "NOT AVAILABLE",
            es: "NO DISPONIBLE",
            ru: "НЕДОСТУПНО",
            uk: "НЕДОСТУПНО"
        )
    }

    var localNetworkDenied: String {
        localized(
            en: "LOCAL NETWORK IS OFF · OPEN SETTINGS",
            es: "RED LOCAL DESACTIVADA · ABRE AJUSTES",
            ru: "ЛОКАЛЬНАЯ СЕТЬ ВЫКЛЮЧЕНА · ОТКРОЙТЕ НАСТРОЙКИ",
            uk: "ЛОКАЛЬНУ МЕРЕЖУ ВИМКНЕНО · ВІДКРИЙТЕ НАЛАШТУВАННЯ"
        )
    }

    var localNetworkUnavailable: String {
        localized(
            en: "CHECK FAILED · RETRY",
            es: "FALLO EN LA COMPROBACIÓN · REINTENTA",
            ru: "ПРОВЕРКА НЕ УДАЛАСЬ · ПОВТОРИТЕ",
            uk: "ПЕРЕВІРКА НЕ ВДАЛАСЯ · ПОВТОРІТЬ"
        )
    }

    var localNetworkUnsupported: String {
        localized(
            en: "SIMULATOR · CHECK ON A PHYSICAL IPHONE",
            es: "SIMULADOR · COMPRUEBA EN UN IPHONE FÍSICO",
            ru: "СИМУЛЯТОР · ПРОВЕРЬТЕ НА ФИЗИЧЕСКОМ IPHONE",
            uk: "СИМУЛЯТОР · ПЕРЕВІРТЕ НА ФІЗИЧНОМУ IPHONE"
        )
    }

    var permissionsCompleteTitle: String {
        localized(
            en: "SETUP COMPLETE",
            es: "CONFIGURACIÓN COMPLETA",
            ru: "НАСТРОЙКА ЗАВЕРШЕНА",
            uk: "НАЛАШТУВАННЯ ЗАВЕРШЕНО"
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
            localized(en: "Local Network", es: "Red local", ru: "Локальная сеть", uk: "Локальна мережа")
        }
    }

    func permissionBody(_ permission: OnboardingPermissionKind) -> String {
        switch permission {
        case .notifications:
            localized(
                en: "Optional. Get room invites and important game events.",
                es: "Opcional. Recibe invitaciones y eventos importantes de la partida.",
                ru: "Необязательно. Получайте приглашения и важные события игры.",
                uk: "Необов'язково. Отримуйте запрошення та важливі події гри."
            )
        case .camera:
            localized(
                en: "Optional. Scan a room QR code to join.",
                es: "Opcional. Escanea el QR de una sala para entrar.",
                ru: "Необязательно. Сканируйте QR-код для входа в комнату.",
                uk: "Необов'язково. Скануйте QR-код для входу до кімнати."
            )
        case .nearby:
            localized(
                en: "Required for Radar: allow Local Network to find nearby iPhones. iOS will request precise Rangefinder access automatically after a peer connects.",
                es: "Obligatorio para Radar: permite la red local para encontrar iPhone cercanos. iOS pedirá acceso al telémetro preciso automáticamente al conectar un dispositivo.",
                ru: "Обязательно для Радара: разрешите локальную сеть для поиска iPhone рядом. Доступ к точному дальномеру iOS запросит автоматически после подключения.",
                uk: "Обов'язково для Радара: дозвольте локальну мережу для пошуку iPhone поруч. Доступ до точного далекоміра iOS запросить автоматично після підключення."
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
