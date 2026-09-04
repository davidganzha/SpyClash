import SwiftUI

@main
struct SpyClashApp: App {
    @UIApplicationDelegateAdaptor(SpyClashAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .tint(SpyTheme.red)
                .task {
                    await appState.restoreSession()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    let isActive = phase == .active
                    appState.setRadarApplicationActive(
                        isActive,
                        stopTransportWhenInactive: phase == .background
                    )
                    if isActive {
                        PushNotificationCoordinator.shared.applicationDidBecomeActive()
                        appState.resumeAfterActivation()
                        appState.refreshActiveRoomOnActivation()
                    } else {
                        PushNotificationCoordinator.shared.applicationDidEnterBackground()
                    }
                }
        }
    }
}

private struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            if appState.isRestoring {
                BootView()
            } else {
                restoredContent
            }
        }
        .background(SpyBackground())
        .buttonStyle(SpyWebPressStyle())
        .environment(
            \.spyEntranceMotionEnabled,
            appState.authHomeRevealPhase != .covered
        )
        .accessibilityHidden(appState.authHomeRevealPhase != .idle)
        .overlay {
            if appState.authHomeRevealPhase != .idle {
                ZStack {
                    Color.black

                    if let message = appState.onboardingLaunchMessage {
                        OnboardingLaunchMessageView(message: message)
                    }
                }
                .opacity(appState.authHomeRevealPhase == .covered ? 1 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .allowsHitTesting(true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appState.onboardingLaunchMessage ?? "SpyClash")
                .accessibilityAddTraits(.isModal)
                .animation(
                    appState.authHomeRevealPhase == .revealing
                        ? .easeInOut(duration: 0.82)
                        : nil,
                    value: appState.authHomeRevealPhase
                )
            }
        }
        .overlay {
            if appState.authHomeRevealPhase == .idle,
               !appState.requiresOnboarding,
               let invitation = appState.radarNearby.incomingInvitation {
                RadarIncomingInvitationOverlay(invitation: invitation)
            }
        }
        .spyGlobalToastLayer()
        .alert(
            manualAppleRevocationTitle,
            isPresented: manualAppleRevocationBinding
        ) {
            Button(manualAppleRevocationDoneTitle) {
                appState.accountDeletionManualRevocationNotice = nil
            }
        } message: {
            Text(appState.accountDeletionManualRevocationNotice ?? "")
        }
        .sheet(isPresented: recoverySheetBinding) {
            AuthView()
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
                .presentationBackground(Color.black)
        }
        .onOpenURL { url in
            appState.handleIncomingURL(url)
        }
        .task(id: "\(appState.user?.id ?? "signed-out")|\(appState.isAuthTransitionActive)") {
            guard !appState.isAuthTransitionActive else { return }
            await appState.consumePendingRoutesIfPossible()
        }
        .task(id: appState.activeRoom?.id) {
            guard let roomID = appState.activeRoom?.id else { return }
            await appState.monitorActiveRoom(roomID)
        }
        .animation(.smooth(duration: 0.45), value: appState.isRestoring)
        .animation(.smooth(duration: 0.45), value: appState.user?.id)
    }

    @ViewBuilder
    private var restoredContent: some View {
#if DEBUG
        if appState.shouldUsePreviewData,
           let directPreview = DebugPreviewDestination.current {
            directPreview.makeView()
        } else if appState.user == nil || appState.hasActiveAuthCinematic {
            WelcomeView()
        } else if appState.requiresOnboarding {
            OnboardingView(
                startsAtLocalNetworkPermission: appState
                    .requiresLocalNetworkOnboardingUpgrade,
                preservedSource: appState.preservedOnboardingAcquisitionSource
            )
        } else {
            AppShellView()
        }
#else
        if appState.user == nil || appState.hasActiveAuthCinematic {
            WelcomeView()
        } else if appState.requiresOnboarding {
            OnboardingView(
                startsAtLocalNetworkPermission: appState
                    .requiresLocalNetworkOnboardingUpgrade,
                preservedSource: appState.preservedOnboardingAcquisitionSource
            )
        } else {
            AppShellView()
        }
#endif
    }

    private var recoverySheetBinding: Binding<Bool> {
        Binding {
            appState.user != nil && appState.authPhase.isRecoveryPresentation
        } set: { isPresented in
            if !isPresented, appState.authPhase.isRecoveryPresentation {
                appState.authPhase = .email
            }
        }
    }

    private var manualAppleRevocationBinding: Binding<Bool> {
        Binding {
            appState.accountDeletionManualRevocationNotice != nil
        } set: { isPresented in
            if !isPresented {
                appState.accountDeletionManualRevocationNotice = nil
            }
        }
    }

    private var manualAppleRevocationTitle: String {
        switch appState.language {
        case .ru: "ДОСТУП APPLE"
        case .es: "ACCESO DE APPLE"
        case .uk: "ДОСТУП APPLE"
        default: "APPLE ACCESS"
        }
    }

    private var manualAppleRevocationDoneTitle: String {
        switch appState.language {
        case .ru: "ГОТОВО"
        case .es: "LISTO"
        case .uk: "ГОТОВО"
        default: "DONE"
        }
    }
}

private struct OnboardingLaunchMessageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.hidden

    let message: String

    var body: some View {
        Text(message)
            .font(SpyTheme.brandFont(size: 36))
            .tracking(0.16)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .opacity(phase == .visible ? 1 : 0)
            .blur(radius: reduceMotion ? 0 : phase.blurRadius)
            .scaleEffect(reduceMotion ? 1 : phase.scale)
            .task(id: message) {
                phase = .hidden
                await Task.yield()

                if reduceMotion {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        phase = .visible
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(560))
                    } catch {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        phase = .fadingOut
                    }
                    return
                }

                withAnimation(.easeInOut(duration: 1.35)) {
                    phase = .visible
                }
                do {
                    // 1.35 s fade-in + 1.00 s stillness.
                    try await Task.sleep(for: .milliseconds(2_350))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 1.65)) {
                    phase = .fadingOut
                }
            }
            .accessibilityLabel(message)
    }

    private enum Phase: Equatable {
        case hidden
        case visible
        case fadingOut

        var blurRadius: CGFloat {
            switch self {
            case .hidden: 16
            case .visible: 0
            case .fadingOut: 12
            }
        }

        var scale: CGFloat {
            switch self {
            case .hidden: 0.96
            case .visible: 1
            case .fadingOut: 1.015
            }
        }
    }
}

private struct BootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            SpyBackground()
            VStack(spacing: 20) {
                SpyLoader()

                Text(appState.language.bootSyncingFieldKit)
                    .font(SpyTheme.micro)
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)
            }
        }
    }
}

#if DEBUG
private enum DebugPreviewDestination {
    case boot
    case home
    case welcome
    case auth
    case onboarding
    case appleAuthTerminal
    case standardAuthTerminal
    case scanner
    case roomQR
    case radar
    case privacy
    case terms
    case acknowledgements

    static var current: DebugPreviewDestination? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--spyclash-ui-preview") else {
            return nil
        }

        let value = arguments
            .first { $0.hasPrefix("--spyclash-preview-direct=") }
            .map { String($0.dropFirst("--spyclash-preview-direct=".count)) }

        switch value {
        case "boot", "loader":
            return .boot
        case "home":
            return .home
        case "welcome":
            return .welcome
        case "auth", "login":
            return .auth
        case "onboarding", "on-board", "setup":
            return .onboarding
        case "apple-auth", "apple-terminal", "auth-terminal":
            return .appleAuthTerminal
        case "standard-auth", "google-auth", "email-auth", "four-part-auth":
            return .standardAuthTerminal
        case "scanner", "qrScanner", "qr-scanner":
            return .scanner
        case "roomQR", "room-qr", "qr":
            return .roomQR
        case "radar", "nearby":
            return .radar
        case "privacy":
            return .privacy
        case "terms":
            return .terms
        case "acknowledgements", "licenses", "third-party-licenses":
            return .acknowledgements
        default:
            return nil
        }
    }

    @MainActor
    @ViewBuilder
    func makeView() -> some View {
        switch self {
        case .boot:
            BootView()
        case .home:
            HomeView()
        case .welcome:
            WelcomeView()
        case .auth:
            AuthView()
        case .onboarding:
            OnboardingView()
        case .appleAuthTerminal:
            DebugAppleAuthAssemblyPreview()
        case .standardAuthTerminal:
            DebugStandardAuthAssemblyPreview()
        case .scanner:
            QRScannerSheet()
        case .roomQR:
            RoomQRSheet(room: GameRoom.previewRoom(status: "waiting"))
        case .radar:
            RadarInviteView(room: GameRoom.previewRoom(status: "waiting"))
        case .privacy:
            LegalDocumentSheet(kind: .privacy)
        case .terms:
            LegalDocumentSheet(kind: .terms)
        case .acknowledgements:
            LegalDocumentSheet(kind: .acknowledgements)
        }
    }
}

private struct DebugAppleAuthAssemblyPreview: View {
    @Environment(AppState.self) private var appState
    @State private var showAuth = false

    var body: some View {
        Group {
            if appState.user == nil || appState.appleAuthStage != nil {
                DebugAuthSheetPresenter(showAuth: $showAuth)
            } else if appState.requiresOnboarding {
                OnboardingView()
            } else {
                AppShellView()
            }
        }
        .task {
            guard let previewUser = appState.user else { return }

            appState.authPhase = .email
            appState.appleAuthStage = nil
            appState.authHomeRevealPhase = .idle
            appState.user = nil
            showAuth = true

            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            appState.appleAuthStage = .verifyingIdentity

            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            appState.appleAuthStage = .establishingSession

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            appState.appleAuthStage = .synchronizingProfile
            appState.user = previewUser

            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            appState.appleAuthStage = .accessGranted

            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            appState.authHomeRevealPhase = .covered

            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            appState.appleAuthStage = nil

            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            appState.authHomeRevealPhase = .revealing

            try? await Task.sleep(for: .milliseconds(860))
            guard !Task.isCancelled else { return }
            appState.authHomeRevealPhase = .idle

            // The preview owns the route only for the cinematic itself. Hand
            // the assembled destination back to RootView so later actions,
            // especially logout, follow the same lifecycle as production.
            appState.isUIPreviewMode = false
        }
    }
}

private struct DebugStandardAuthAssemblyPreview: View {
    @Environment(AppState.self) private var appState
    @State private var showAuth = false

    var body: some View {
        Group {
            if appState.user == nil || appState.standardAuthCinematicStage != nil {
                DebugAuthSheetPresenter(showAuth: $showAuth)
            } else if appState.requiresOnboarding {
                OnboardingView()
            } else {
                AppShellView()
            }
        }
        .task {
            guard let previewUser = appState.user else { return }

            appState.authPhase = .email
            appState.appleAuthStage = nil
            appState.standardAuthCinematicStage = nil
            appState.authHomeRevealPhase = .idle
            appState.user = nil
            showAuth = true

            // Let the full-screen auth sheet finish presenting before the
            // cinematic starts; otherwise the first piece inherits the
            // system sheet transition and the login form can flash through.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await appState.runStandardAuthPreview(with: previewUser)
        }
    }
}

private struct DebugAuthSheetPresenter: View {
    @Binding var showAuth: Bool

    var body: some View {
        SpyBackground()
            .ignoresSafeArea()
            .sheet(isPresented: $showAuth) {
                AuthView()
                    .spyGlobalToastLayer()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(0)
                    .presentationBackground(Color.black)
            }
    }
}
#endif
