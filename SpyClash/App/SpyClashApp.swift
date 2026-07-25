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
                    appState.setRadarApplicationActive(isActive)
                    if isActive {
                        PushNotificationCoordinator.shared.applicationDidBecomeActive()
                        appState.synchronizeAccessOnActivation()
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
        Group {
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
        .overlay {
            Color.black
                .opacity(appState.authHomeRevealPhase == .covered ? 1 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .allowsHitTesting(appState.authHomeRevealPhase != .idle)
                .accessibilityHidden(true)
                .animation(
                    appState.authHomeRevealPhase == .revealing
                        ? .easeInOut(duration: 0.82)
                        : nil,
                    value: appState.authHomeRevealPhase
                )
        }
        .overlay {
            if let presentationID = appState.fullAccessUnlockPresentationID {
                FullAccessUnlockOverlay(presentationID: presentationID)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let invitation = appState.radarNearby.incomingInvitation {
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
        } else {
            AppShellView()
        }
#else
        if appState.user == nil || appState.hasActiveAuthCinematic {
            WelcomeView()
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
        default: "APPLE ACCESS"
        }
    }

    private var manualAppleRevocationDoneTitle: String {
        switch appState.language {
        case .ru: "ГОТОВО"
        case .es: "LISTO"
        default: "DONE"
        }
    }
}

private struct FullAccessUnlockOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentationID: UUID

    @State private var isVisible = false
    @State private var ringScale = 0.72
    @State private var scanOffset: CGFloat = -120
    @State private var contentOpacity = 0.0

    var body: some View {
        ZStack {
            Color.black.opacity(isVisible ? 0.78 : 0)
                .ignoresSafeArea()

            Circle()
                .stroke(SpyTheme.red.opacity(0.15), lineWidth: 1)
                .frame(width: 250, height: 250)
                .scaleEffect(ringScale)

            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(
                    AngularGradient(
                        colors: [.clear, SpyTheme.red, .white, SpyTheme.red, .clear],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .square)
                )
                .frame(width: 198, height: 198)
                .rotationEffect(.degrees(isVisible ? 218 : -24))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, SpyTheme.red.opacity(0.75), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 260, height: 1)
                .offset(y: scanOffset)

            VStack(spacing: 8) {
                Image(systemName: "infinity")
                    .font(.system(size: 48, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: SpyTheme.red.opacity(0.9), radius: 14)

                Text(statusText)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.16)
                    .foregroundStyle(SpyTheme.red)
            }
            .opacity(contentOpacity)
            .scaleEffect(isVisible ? 1 : 0.88)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
        .task(id: presentationID) {
            HapticManager.shared.prepareFullAccessPresentation()
            if reduceMotion {
                isVisible = true
                ringScale = 1
                scanOffset = 120
                contentOpacity = 1
            } else {
                withAnimation(.easeOut(duration: 0.24)) {
                    isVisible = true
                    contentOpacity = 1
                }
                withAnimation(.timingCurve(0.12, 0.86, 0.22, 1, duration: 0.72)) {
                    ringScale = 1
                    scanOffset = 120
                }
            }
            HapticManager.shared.playFullAccessCharge()
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            HapticManager.shared.playFullAccessCompletion()
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 900 : 1_280))
            guard !Task.isCancelled else { return }
            if !reduceMotion {
                withAnimation(.easeIn(duration: 0.28)) {
                    isVisible = false
                    contentOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            appState.dismissFullAccessUnlock(presentationID)
        }
    }

    private var statusText: String {
        switch appState.language {
        case .en: "ACCESS SYNCHRONIZED"
        case .ru: "ДОСТУП СИНХРОНИЗИРОВАН"
        case .es: "ACCESO SINCRONIZADO"
        }
    }
}

private struct BootView: View {
    @Environment(AppState.self) private var appState
    @State private var pulse = false

    var body: some View {
        ZStack {
            SpyBackground()
            VStack(spacing: 20) {
                SpyLoader(isAnimating: pulse)

                Text(appState.language.bootSyncingFieldKit)
                    .font(SpyTheme.micro)
                    .tracking(0.18)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
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
            // the assembled Home screen back to RootView so later actions,
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
