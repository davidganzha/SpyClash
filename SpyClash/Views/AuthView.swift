import AuthenticationServices
import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var otp = ""
    @State private var authTransitionDirection: CGFloat = 1
    @State private var displayedAppleAuthStage: AppleAuthStage?
    @State private var displayedStandardAuthStage: StandardAuthCinematicStage?

    private var copy: AuthCopy {
        appState.language.auth
    }

    var body: some View {
        ZStack {
            SpyBackground()
            VStack(spacing: 24) {
                header
                SpyPanel(motionDelay: 0.25) {
                    form
                }
                .padding(.horizontal, 20)
                footerSwitch
            }
            .padding(.vertical, 28)

            if let stage = displayedAppleAuthStage {
                AppleAuthCinematicOverlay(stage: stage)
                    .transition(.opacity)
                    .zIndex(10)
            } else if let stage = displayedStandardAuthStage {
                StandardAuthCinematicOverlay(stage: stage)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onAppear {
            displayedAppleAuthStage = appState.appleAuthStage
            displayedStandardAuthStage = appState.standardAuthCinematicStage
        }
        .onChange(of: appState.user) { _, user in
            if user != nil, !appState.hasActiveAuthCinematic {
                dismiss()
            }
        }
        .onChange(of: appState.appleAuthStage) { _, stage in
            if let stage {
                if displayedAppleAuthStage == nil {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        displayedAppleAuthStage = stage
                    }
                } else {
                    displayedAppleAuthStage = stage
                }
            } else if appState.user != nil,
                      appState.standardAuthCinematicStage == nil {
                // Keep the last black cinematic frame alive while the sheet
                // itself is dismissed. RootView has an identical black bridge
                // underneath, so Home can be revealed without a login flash.
                dismiss()
            } else {
                withAnimation(.easeOut(duration: 0.30)) {
                    displayedAppleAuthStage = nil
                }
            }
        }
        .onChange(of: appState.standardAuthCinematicStage) { _, stage in
            if let stage {
                if displayedStandardAuthStage == nil {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        displayedStandardAuthStage = stage
                    }
                } else {
                    displayedStandardAuthStage = stage
                }
            } else if appState.user != nil,
                      appState.appleAuthStage == nil {
                dismiss()
            } else {
                withAnimation(.easeOut(duration: 0.30)) {
                    displayedStandardAuthStage = nil
                }
            }
        }
        .interactiveDismissDisabled(appState.hasActiveAuthCinematic || appState.isBusy)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: headerIcon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(SpyTheme.red)
                .clipShape(CutCornerShape(cut: 11))
                .shadow(color: SpyTheme.red.opacity(0.5), radius: 20)
                .spyWebEntrance(delay: 0.10, duration: 0.50, y: 0, scale: 0.70)

            Text(eyebrow)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker(lines: 2, alignment: .center)
                .spyWebEntrance(delay: 0.05, duration: 0.45, y: 8)

            Text(title)
                .font(.system(size: 32, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(.white)
                .spyFitted(lines: 2, scale: 0.56, alignment: .center)
                .spyWebEntrance(delay: 0.15, duration: 0.45, y: 8)

            Text(subtitle)
                .font(SpyTheme.micro)
                .tracking(0.25)
                .foregroundStyle(SpyTheme.muted)
                .spyFitted(lines: 2, scale: 0.66, alignment: .center)
                .spyWebEntrance(delay: 0.20, duration: 0.45, y: 8)

            LanguageSwitcher()
                .padding(.top, 2)
                .spyWebEntrance(delay: 0.25, duration: 0.45, y: 8)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var form: some View {
        VStack(spacing: 16) {
            Group {
                switch appState.authPhase {
            case .email:
                appleButton
                googleButton
                divider
                emailField
                Button {
                    guard !email.trimmingCharacters(in: .whitespaces).isEmpty else {
                        HapticManager.shared.fire(.notification(.warning))
                        return
                    }
                    appState.authError = nil
                    appState.authNotice = nil
                    move(to: .password(email: email))
                } label: {
                    Label(copy.continueAction, systemImage: "arrow.right")
                }
                .buttonStyle(SpyButtonStyle(variant: .red))

            case .password(let lockedEmail):
                lockedEmailRow(lockedEmail)
                passwordField(title: copy.passphraseLabel, text: $password)
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    Task { await appState.login(email: lockedEmail, password: password) }
                } label: {
                    busyLabel(copy.authenticatingBusy, idle: copy.unlockAction)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(appState.isBusy || password.isEmpty)

                Button {
                    email = lockedEmail
                    appState.authError = nil
                    appState.authNotice = nil
                    move(to: .forgotPassword(email: lockedEmail))
                } label: {
                        Text(copy.forgotPassphrase)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.60, alignment: .center)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(SpyWebPressStyle())

            case .registerEmail:
                appleButton
                googleButton
                divider
                emailField
                Button {
                    guard !email.trimmingCharacters(in: .whitespaces).isEmpty else {
                        HapticManager.shared.fire(.notification(.warning))
                        return
                    }
                    appState.authError = nil
                    appState.authNotice = nil
                    move(to: .registerPassword(email: email))
                } label: {
                    Label(copy.joinNetworkAction, systemImage: "arrow.right")
                }
                .buttonStyle(SpyButtonStyle(variant: .red))

            case .registerPassword(let lockedEmail):
                lockedEmailRow(lockedEmail)
                passwordField(title: copy.passphraseLabel, text: $password, contentType: .newPassword)
                passwordField(title: copy.confirmPassphraseLabel, text: $confirmPassword, contentType: .newPassword)
                Button {
                    guard password == confirmPassword else {
                        appState.authError = copy.passphrasesMismatch
                        HapticManager.shared.fire(.notification(.warning))
                        return
                    }
                    HapticManager.shared.fire(.buttonPress)
                    Task { await appState.register(email: lockedEmail, password: password) }
                } label: {
                    busyLabel(copy.recruitingBusy, idle: copy.createCredentialsAction)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(appState.isBusy || password.isEmpty)

            case .otp(let lockedEmail):
                Text(copy.sixDigitKeyLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)
                TextField("000000", text: $otp)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(.white)
                    .padding(14)
                    .spyCutCard(cut: 9, fill: SpyTheme.panelDeep, stroke: SpyTheme.stroke)
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    Task { await appState.verify(email: lockedEmail, code: otp) }
                } label: {
                    busyLabel(copy.verifyingBusy, idle: copy.verifyEnterAction)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(appState.isBusy || otp.count < 6)

            case .forgotPassword(let lockedEmail):
                Text(copy.requestResetBody)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineSpacing(3)
                emailField
                    .onAppear {
                        if email.isEmpty {
                            email = lockedEmail
                        }
                    }
                Button {
                    let target = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty else { return }
                    HapticManager.shared.fire(.buttonPress)
                    Task { await appState.requestPasswordReset(email: target) }
                } label: {
                    busyLabel(copy.dispatchingBusy, idle: copy.dispatchResetLinkAction)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(appState.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            case .resetEmailSent(let lockedEmail):
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(SpyTheme.green)
                    Text(copy.resetInboxTitle)
                        .font(.system(size: 22, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                    Text(copy.resetInboxDetail(lockedEmail))
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity)
                Button {
                    appState.authError = nil
                    appState.authNotice = nil
                    move(to: .email)
                } label: {
                    Label(copy.backToLogin, systemImage: "arrow.left")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))

            case .resetPassword(let token):
                passwordField(title: copy.newPassphraseLabel, text: $password, contentType: .newPassword)
                passwordField(title: copy.confirmPassphraseLabel, text: $confirmPassword, contentType: .newPassword)
                Button {
                    guard password == confirmPassword else {
                        appState.authError = copy.passphrasesMismatch
                        HapticManager.shared.fire(.notification(.warning))
                        return
                    }
                    HapticManager.shared.fire(.buttonPress)
                    Task { await appState.resetPassword(token: token, newPassword: password) }
                } label: {
                    busyLabel(copy.resettingBusy, idle: copy.confirmNewKeyAction)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(appState.isBusy || password.isEmpty || confirmPassword.isEmpty)
                }
            }
            .id(appState.authPhase.motionKey)
            .transition(
                .asymmetric(
                    insertion: .offset(x: authTransitionDirection * 40).combined(with: .opacity),
                    removal: .offset(x: authTransitionDirection * -40).combined(with: .opacity)
                )
            )
            .animation(SpyMotion.authStep, value: appState.authPhase.motionKey)
        }
    }

    private var footerSwitch: some View {
        Button {
            appState.authError = nil
            appState.authNotice = nil
            switch appState.authPhase {
            case .email, .password:
                move(to: .registerEmail)
            case .forgotPassword, .resetEmailSent, .resetPassword:
                move(to: .email)
            default:
                move(to: .email)
            }
        } label: {
            Text(footerText)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.red)
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)
        }
    }

    private var emailField: some View {
        SpyInput(
            label: nil,
            placeholder: copy.emailPlaceholder,
            text: $email,
            icon: "envelope.fill",
            textContentType: .emailAddress,
            keyboardType: .emailAddress,
            autocapitalization: .never
        )
    }

    private func passwordField(
        title: String,
        text: Binding<String>,
        contentType: UITextContentType = .password
    ) -> some View {
        SpyInput(
            label: title,
            placeholder: "••••••••",
            text: text,
            icon: "lock.fill",
            kind: .secure,
            textContentType: contentType,
            autocapitalization: .never
        )
    }

    private var googleButton: some View {
        Button {
            HapticManager.shared.fire(.buttonPress)
            Task { await appState.loginWithGoogle() }
        } label: {
            HStack(spacing: 10) {
                if appState.isBusy {
                    SpySpinner(size: 18, accent: SpyTheme.red)
                } else {
                    Image(systemName: "g.circle.fill")
                }
                Text(copy.continueWithGoogle)
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .disabled(appState.isBusy)
        .opacity(appState.isBusy ? 0.62 : 1)
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            HapticManager.shared.fire(.buttonPress)
            appState.authError = nil
            appState.authNotice = nil
            appState.configureAppleSignInRequest(request)
        } onCompletion: { result in
            Task { @MainActor in
                await appState.completeAppleSignIn(result)
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(appState.isBusy)
        .opacity(appState.isBusy ? 0.62 : 1)
        .accessibilityLabel(copy.continueWithApple)
    }

    private var divider: some View {
        HStack {
            Rectangle().fill(SpyTheme.stroke).frame(height: 1)
            Text(copy.emailDivider)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.62, alignment: .center)
            Rectangle().fill(SpyTheme.stroke).frame(height: 1)
        }
    }

    private func lockedEmailRow(_ lockedEmail: String) -> some View {
        Button {
            move(to: appState.authPhase == .password(email: lockedEmail) ? .email : .registerEmail)
        } label: {
            HStack {
                Image(systemName: "arrow.left")
                    .foregroundStyle(SpyTheme.red)
                Text(lockedEmail)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(SpyTheme.dim)
            }
            .font(SpyTheme.mono)
            .foregroundStyle(.white.opacity(0.82))
            .padding(12)
            .spyCutCard(cut: 8, fill: SpyTheme.red.opacity(0.07), stroke: SpyTheme.red.opacity(0.25))
        }
    }

    private func busyLabel(_ busy: String, idle: String) -> some View {
        HStack(spacing: 8) {
            if appState.isBusy {
                SpyLoadingLabel(title: busy, accent: .white)
            } else {
                Text(idle)
            }
        }
    }

    private func move(to phase: AuthPhase) {
        HapticManager.shared.fire(.buttonPress)
        authTransitionDirection = phase.motionRank >= appState.authPhase.motionRank ? 1 : -1
        appState.authPhase = phase
    }

    private var headerIcon: String {
        switch appState.authPhase {
        case .email, .password: "rectangle.portrait.and.arrow.right"
        case .registerEmail, .registerPassword: "person.badge.plus"
        case .otp: "envelope.badge.shield.half.filled"
        case .forgotPassword, .resetEmailSent: "envelope.badge"
        case .resetPassword: "key.fill"
        }
    }

    private var eyebrow: String {
        copy.eyebrow(for: appState.authPhase)
    }

    private var title: String {
        copy.title(for: appState.authPhase)
    }

    private var subtitle: String {
        copy.subtitle(for: appState.authPhase)
    }

    private var footerText: String {
        switch appState.authPhase {
        case .email, .password:
            copy.requestAccessFooter
        case .forgotPassword, .resetEmailSent, .resetPassword:
            copy.backToLogin
        default:
            copy.loginFooter
        }
    }
}

struct AppleAuthCinematicOverlay: View {
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion

    let stage: AppleAuthStage

    @State private var completionScale: CGFloat = 1
    @State private var electricityActive = false
    @State private var markOpacity = 1.0

    var body: some View {
        GeometryReader { proxy in
            let markSize = min(proxy.size.width * 0.58, 270)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [SpyTheme.red.opacity(0.14), .clear],
                    center: .center,
                    startRadius: 4,
                    endRadius: markSize * 1.35
                )
                .ignoresSafeArea()

                ZStack {
                    ElectricResponse(active: electricityActive)
                        .frame(width: markSize * 1.38, height: markSize * 1.38)

                    SpyClashAssemblingMark(stage: stage)
                        .frame(width: markSize, height: markSize)
                }
                .scaleEffect(completionScale)
                .opacity(markOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .task(id: stage) {
            guard stage == .accessGranted else { return }

            if reduceMotion {
                electricityActive = true
                withAnimation(.easeOut(duration: 0.28)) {
                    completionScale = 1.06
                }
                withAnimation(.easeOut(duration: 0.48).delay(0.30)) {
                    markOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeOut(duration: 0.20)) {
                    electricityActive = false
                }
                return
            }

            electricityActive = true
            withAnimation(.smooth(duration: 0.42, extraBounce: 0.02)) {
                completionScale = 1.20
            }
            withAnimation(.easeOut(duration: 0.34).delay(0.50)) {
                markOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                electricityActive = false
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
    }

    private var accessibilityStatus: String {
        switch (appState.language, stage) {
        case (.uk, .accessGranted): "Вхід виконано. Готуємо SpyClash."
        case (.ru, .accessGranted): "Вход выполнен. Подготавливаем SpyClash."
        case (.es, .accessGranted): "Acceso concedido. Preparando SpyClash."
        case (_, .accessGranted): "Access granted. Preparing SpyClash."
        case (.uk, _): "Виконується вхід через Apple."
        case (.ru, _): "Выполняется вход через Apple."
        case (.es, _): "Iniciando sesión con Apple."
        case (_, _): "Signing in with Apple."
        }
    }
}

private struct StandardAuthCinematicOverlay: View {
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion

    let stage: StandardAuthCinematicStage

    @State private var completionScale: CGFloat = 1
    @State private var electricityActive = false
    @State private var markOpacity = 1.0

    var body: some View {
        GeometryReader { proxy in
            let markSize = min(proxy.size.width * 0.58, 270)

            ZStack {
                Color.black
                    .ignoresSafeArea()

                RadialGradient(
                    colors: [SpyTheme.red.opacity(0.14), .clear],
                    center: .center,
                    startRadius: 4,
                    endRadius: markSize * 1.35
                )
                .ignoresSafeArea()

                ZStack {
                    ElectricResponse(active: electricityActive)
                        .frame(width: markSize * 1.38, height: markSize * 1.38)

                    FourPartAssemblingMark(stage: stage)
                        .frame(width: markSize, height: markSize)
                }
                .scaleEffect(completionScale)
                .opacity(markOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .task(id: stage) {
            guard stage == .accessGranted else { return }

            electricityActive = true
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.28)) {
                    completionScale = 1.06
                }
                withAnimation(.easeInOut(duration: 0.48).delay(0.30)) {
                    markOpacity = 0
                }
            } else {
                withAnimation(.smooth(duration: 0.48, extraBounce: 0.015)) {
                    completionScale = 1.20
                }
                withAnimation(.easeInOut(duration: 0.48).delay(0.42)) {
                    markOpacity = 0
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                electricityActive = false
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
    }

    private var accessibilityStatus: String {
        switch (appState.language, stage) {
        case (.uk, .accessGranted): "Вхід виконано. Готуємо SpyClash."
        case (.ru, .accessGranted): "Вход выполнен. Подготавливаем SpyClash."
        case (.es, .accessGranted): "Acceso concedido. Preparando SpyClash."
        case (_, .accessGranted): "Access granted. Preparing SpyClash."
        case (.uk, _): "Збираємо логотип SpyClash."
        case (.ru, _): "Собираем логотип SpyClash."
        case (.es, _): "Montando el logotipo de SpyClash."
        case (_, _): "Assembling the SpyClash logo."
        }
    }
}

private struct FourPartAssemblingMark: View {
    @SpyReduceMotion private var reduceMotion

    let stage: StandardAuthCinematicStage

    @State private var placedCount = 0

    private let pieces = LogoMacroPiece.all

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)

            ZStack {
                ForEach(pieces) { piece in
                    let isPlaced = placedCount >= piece.id

                    Image("SpyClashLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .mask(
                            FragmentShape(points: piece.points)
                                .frame(width: side, height: side)
                        )
                        .rotationEffect(
                            .degrees(isPlaced || reduceMotion ? 0 : piece.rotation),
                            anchor: piece.anchor
                        )
                        .offset(
                            x: isPlaced || reduceMotion ? 0 : side * piece.offset[0],
                            y: isPlaced || reduceMotion ? 0 : side * piece.offset[1]
                        )
                        .scaleEffect(
                            isPlaced || reduceMotion ? 1 : 0.95,
                            anchor: piece.anchor
                        )
                        .opacity(isPlaced ? 1 : (reduceMotion ? 0 : 0.16))
                        .blur(radius: isPlaced || reduceMotion ? 0 : 2.2)
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .task {
            await Task.yield()
            placePieces(for: stage)
        }
        .onChange(of: stage) { _, newStage in
            placePieces(for: newStage)
        }
        .accessibilityHidden(true)
    }

    private func placePieces(for stage: StandardAuthCinematicStage) {
        let target = stage.placedCount
        guard target > placedCount else { return }

        withAnimation(
            reduceMotion
                ? .easeOut(duration: 0.18)
                : .timingCurve(0.18, 0.78, 0.18, 1, duration: 1.0)
        ) {
            placedCount = target
        }
    }
}

private struct SpyClashAssemblingMark: View {
    @SpyReduceMotion private var reduceMotion

    let stage: AppleAuthStage

    @State private var appeared = false
    @State private var revealedFragments = 0
    @State private var completionFlash = false

    private let assemblyOrder = [5, 6, 2, 9, 0, 8, 3, 10, 1, 7, 4, 11]

    private let fragments: [LogoFragment] = [
        .init(points: [[0, 0], [0.36, 0], [0.34, 0.27], [0, 0.30]], offset: [-72, -64], rotation: -20),
        .init(points: [[0.34, 0], [0.70, 0], [0.68, 0.27], [0.34, 0.27]], offset: [10, -90], rotation: 12),
        .init(points: [[0.70, 0], [1, 0], [1, 0.31], [0.68, 0.27]], offset: [78, -54], rotation: 22),
        .init(points: [[0, 0.30], [0.35, 0.27], [0.38, 0.51], [0, 0.48]], offset: [-92, -4], rotation: 18),
        .init(points: [[0.35, 0.27], [0.68, 0.27], [0.70, 0.52], [0.38, 0.51]], offset: [-34, 42], rotation: -16),
        .init(points: [[0.68, 0.27], [1, 0.31], [1, 0.53], [0.70, 0.52]], offset: [98, 8], rotation: -24),
        .init(points: [[0, 0.48], [0.38, 0.51], [0.35, 0.76], [0, 0.73]], offset: [-78, 58], rotation: -18),
        .init(points: [[0.38, 0.51], [0.70, 0.52], [0.67, 0.77], [0.35, 0.76]], offset: [24, -58], rotation: 20),
        .init(points: [[0.70, 0.52], [1, 0.53], [1, 0.76], [0.67, 0.77]], offset: [82, 58], rotation: 15),
        .init(points: [[0, 0.73], [0.35, 0.76], [0.36, 1], [0, 1]], offset: [-62, 92], rotation: 24),
        .init(points: [[0.35, 0.76], [0.67, 0.77], [0.68, 1], [0.36, 1]], offset: [0, 104], rotation: -14),
        .init(points: [[0.67, 0.77], [1, 0.76], [1, 1], [0.68, 1]], offset: [72, 86], rotation: -22)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(fragments.enumerated()), id: \.offset) { index, fragment in
                Image("SpyClashLogo")
                    .resizable()
                    .scaledToFit()
                    .mask(FragmentShape(points: fragment.points))
                    .offset(fragmentOffset(fragment, index: index))
                    .rotationEffect(.degrees(fragmentRotation(fragment, index: index)))
                    .opacity(fragmentOpacity(index))
                    .blur(radius: isAssembled(index) ? 0 : 2.2)
            }

            Image("SpyClashLogo")
                .resizable()
                .scaledToFit()
                .opacity(revealedFragments == fragments.count ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: revealedFragments)

            Image("SpyClashLogo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .opacity(completionFlash ? 0.52 : 0)
                .blendMode(.screen)
                .blur(radius: completionFlash ? 8 : 1)
        }
        .task {
            appeared = true

            try? await Task.sleep(for: .milliseconds(220))
            for count in 1...fragments.count {
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.20, bounce: 0.16)) {
                    revealedFragments = count
                }

                let placementDuration = reduceMotion ? 120 : 200
                try? await Task.sleep(for: .milliseconds(placementDuration))
                guard !Task.isCancelled else { return }

                if count < fragments.count {
                    try? await Task.sleep(for: .milliseconds(220 - placementDuration))
                }
            }
        }
        .onChange(of: stage) { _, newStage in
            guard newStage == .accessGranted, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.16)) { completionFlash = true }
            withAnimation(.easeIn(duration: 0.42).delay(0.16)) { completionFlash = false }
        }
        .accessibilityHidden(true)
    }

    private var assembledCount: Int {
        appeared ? revealedFragments : 0
    }

    private func isAssembled(_ index: Int) -> Bool {
        assemblyOrder.prefix(assembledCount).contains(index)
    }

    private func fragmentOffset(_ fragment: LogoFragment, index: Int) -> CGSize {
        guard !reduceMotion, !isAssembled(index) else { return .zero }
        return CGSize(width: fragment.offset[0], height: fragment.offset[1])
    }

    private func fragmentRotation(_ fragment: LogoFragment, index: Int) -> Double {
        reduceMotion || isAssembled(index) ? 0 : fragment.rotation
    }

    private func fragmentOpacity(_ index: Int) -> Double {
        if isAssembled(index) { return 1 }
        return reduceMotion ? 0 : 0.08
    }

}

private struct ElectricResponse: View {
    let active: Bool

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                ElectricBoltShape(index: index)
                    .trim(from: 0, to: active ? 1 : 0)
                    .stroke(
                        Color.cyan.opacity(0.82),
                        style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .miter)
                    )
                    .blur(radius: 4)

                ElectricBoltShape(index: index)
                    .trim(from: 0, to: active ? 1 : 0)
                    .stroke(
                        Color.white.opacity(0.96),
                        style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .miter)
                    )
            }
        }
        .scaleEffect(active ? 1.04 : 0.90)
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.13), value: active)
        .accessibilityHidden(true)
    }
}

private struct ElectricBoltShape: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.5
        let angle = (Double(index) / 8 * Double.pi * 2) - Double.pi / 2
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let tangent = CGVector(dx: -direction.dy, dy: direction.dx)
        let polarity: CGFloat = index.isMultiple(of: 2) ? 1 : -1

        func point(_ radial: CGFloat, _ lateral: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + direction.dx * radial + tangent.dx * lateral,
                y: center.y + direction.dy * radial + tangent.dy * lateral
            )
        }

        var path = Path()
        path.move(to: point(radius * 0.58, 0))
        path.addLine(to: point(radius * 0.68, polarity * radius * 0.040))
        path.addLine(to: point(radius * 0.76, -polarity * radius * 0.025))
        path.addLine(to: point(radius * 0.84, polarity * radius * 0.052))
        path.addLine(to: point(radius * 0.93, 0))
        return path
    }
}

private struct LogoMacroPiece: Identifiable {
    let id: Int
    let points: [[CGFloat]]
    let offset: [CGFloat]
    let rotation: Double
    let anchor: UnitPoint

    // These four masks follow the four disconnected alpha components in the
    // original 1024×1024 logo. Together they cover every visible logo pixel
    // exactly once, so the assembled result remains pixel-identical.
    static let all: [LogoMacroPiece] = [
        .init(
            id: 1,
            points: [[0.515, 0.36], [0.75, 0.36], [0.75, 0.65], [0.515, 0.65]],
            offset: [0.48, -0.28],
            rotation: -7,
            anchor: UnitPoint(x: 0.633, y: 0.500)
        ),
        .init(
            id: 2,
            points: [[0.25, 0.46], [0.39, 0.46], [0.39, 0.53], [0.47, 0.53], [0.47, 0.74], [0.25, 0.74]],
            offset: [-0.48, -0.12],
            rotation: -8,
            anchor: UnitPoint(x: 0.355, y: 0.598)
        ),
        .init(
            id: 3,
            points: [[0.34, 0.75], [0.75, 0.75], [0.75, 0.95], [0.34, 0.95]],
            offset: [-0.36, 0.44],
            rotation: 6,
            anchor: UnitPoint(x: 0.546, y: 0.851)
        ),
        .init(
            id: 4,
            points: [[0.25, 0.05], [0.70, 0.05], [0.70, 0.24], [0.50, 0.24], [0.50, 0.50], [0.39, 0.50], [0.39, 0.45], [0.25, 0.45]],
            offset: [0.40, -0.40],
            rotation: 7,
            anchor: UnitPoint(x: 0.475, y: 0.268)
        )
    ]
}

private struct LogoFragment {
    let points: [[CGFloat]]
    let offset: [CGFloat]
    let rotation: Double
}

private struct FragmentShape: Shape {
    let points: [[CGFloat]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: rect.width * first[0], y: rect.height * first[1]))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.width * point[0], y: rect.height * point[1]))
        }
        path.closeSubpath()
        return path
    }
}

private extension AuthPhase {
    var motionKey: String {
        switch self {
        case .email: "email"
        case .password: "password"
        case .registerEmail: "register-email"
        case .registerPassword: "register-password"
        case .otp: "otp"
        case .forgotPassword: "forgot-password"
        case .resetEmailSent: "reset-email-sent"
        case .resetPassword: "reset-password"
        }
    }

    var motionRank: Int {
        switch self {
        case .email, .registerEmail: 0
        case .password, .registerPassword, .forgotPassword: 1
        case .otp, .resetEmailSent: 2
        case .resetPassword: 3
        }
    }
}
