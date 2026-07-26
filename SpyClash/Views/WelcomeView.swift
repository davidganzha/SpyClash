import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAuth = false
    @State private var legalSheet: LegalSheetKind?
    @State private var isWordmarkVisible = false

    private var copy: WelcomeCopy {
        appState.language.welcome
    }

    var body: some View {
        ZStack {
            SpyBackground()
            cornerMarks

            VStack(spacing: 0) {
                statusLine
                Spacer(minLength: 28)
                hero
                Spacer(minLength: 26)
                footer
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .sheet(isPresented: $showAuth) {
            AuthView()
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
                .presentationBackground(Color.black)
        }
        .sheet(item: $legalSheet) { sheet in
            LegalDocumentSheet(kind: sheet)
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
        }
        .onAppear {
            isWordmarkVisible = true
            presentAuthForPendingInviteIfNeeded()
            presentAuthForRecoveryIfNeeded()
        }
        .onChange(of: appState.pendingJoinCode) { _, _ in
            presentAuthForPendingInviteIfNeeded()
        }
        .onChange(of: appState.authPhase) { _, phase in
            if phase.isRecoveryPresentation {
                showAuth = true
            }
        }
    }

    private var statusLine: some View {
        HStack(alignment: .center, spacing: 14) {
            statusPill
            Spacer(minLength: 12)
            languageSelector
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Text(copy.statusPrefix)
                .foregroundStyle(SpyTheme.dim)
            Circle()
                .fill(SpyTheme.red)
                .frame(width: 7, height: 7)
                .shadow(color: SpyTheme.red, radius: 10)
            Text(copy.locked)
                .foregroundStyle(SpyTheme.red)
        }
        .font(SpyTheme.micro)
        .tracking(0.12)
        .spyFitted(scale: 0.62, alignment: .trailing)
    }

    private var languageSelector: some View {
        LanguageSwitcher()
    }

    private var hero: some View {
        VStack(spacing: 34) {
            VStack(spacing: 14) {
                VStack(spacing: 18) {
                    SpyBrandMark()
                        .frame(width: 126, height: 126)
                        .scaleEffect(isWordmarkVisible ? 1 : 0.93)
                        .blur(radius: isWordmarkVisible ? 0 : 5)
                        .opacity(isWordmarkVisible ? 1 : 0)
                        .shadow(color: SpyTheme.red.opacity(0.22), radius: 24)
                        .animation(
                            reduceMotion ? nil : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.72),
                            value: isWordmarkVisible
                        )

                    HStack(spacing: 0) {
                        Text("SPY")
                            .foregroundStyle(SpyTheme.red)
                        Text("CLASH")
                            .foregroundStyle(.white)
                    }
                    .font(SpyTheme.brandFont(size: 44))
                    .tracking(4)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(y: isWordmarkVisible ? 0 : 8)
                    .opacity(isWordmarkVisible ? 1 : 0)
                    .shadow(color: SpyTheme.red.opacity(0.12), radius: 10)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.52).delay(0.20),
                        value: isWordmarkVisible
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(height: 194)

                Text(copy.tagline)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)

                if let pendingCode = appState.pendingJoinCode {
                    Text(copy.inviteArmed(pendingCode))
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(SpyTheme.green.opacity(0.08))
                        .overlay(Rectangle().stroke(SpyTheme.green.opacity(0.24)))
                }
            }

            VStack(spacing: 12) {
                Button {
                    appState.authError = nil
                    appState.authNotice = nil
                    appState.authPhase = .email
                    showAuth = true
                } label: {
                    Label(copy.enterGame, systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(SpyButtonStyle(variant: .red))

                Button {
                    appState.authError = nil
                    appState.authNotice = nil
                    appState.authPhase = .registerEmail
                    showAuth = true
                } label: {
                    Label(copy.createAccount, systemImage: "person.badge.plus")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerButton(copy.privacy, sheet: .privacy)
            Text("//")
                .foregroundStyle(Color.white.opacity(0.1))
            footerButton(copy.terms, sheet: .terms)
            Text("//")
                .foregroundStyle(Color.white.opacity(0.1))
            footerButton(acknowledgementsTitle, sheet: .acknowledgements)
        }
        .font(SpyTheme.micro)
        .tracking(0.12)
        .foregroundStyle(SpyTheme.dim)
    }

    private var acknowledgementsTitle: String {
        switch appState.language {
        case .en: "LICENSES"
        case .es: "LICENCIAS"
        case .ru: "ЛИЦЕНЗИИ"
        }
    }

    private func footerButton(_ title: String, sheet: LegalSheetKind) -> some View {
        Button {
            legalSheet = sheet
        } label: {
            Text(title)
                .foregroundStyle(legalSheet == sheet ? SpyTheme.red : SpyTheme.dim)
                .contentTransition(.opacity)
        }
        .buttonStyle(SpyWebPressStyle())
        .spyHitTarget()
        .contentShape(Rectangle())
    }

    private var cornerMarks: some View {
        VStack {
            HStack {
                corner
                Spacer()
                corner.rotationEffect(.degrees(90))
            }
            Spacer()
            HStack {
                corner.rotationEffect(.degrees(270))
                Spacer()
                corner.rotationEffect(.degrees(180))
            }
        }
        .padding(18)
    }

    private var corner: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 22, y: 0))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 22))
        }
        .stroke(SpyTheme.red, lineWidth: 1)
        .frame(width: 22, height: 22)
    }

    private func presentAuthForPendingInviteIfNeeded() {
        guard appState.user == nil, appState.pendingJoinCode != nil else {
            return
        }

        appState.authPhase = .email
        showAuth = true
    }

    private func presentAuthForRecoveryIfNeeded() {
        guard appState.user == nil, appState.authPhase.isRecoveryPresentation else {
            return
        }

        showAuth = true
    }
}

enum LegalSheetKind: String, Identifiable, Hashable {
    case privacy
    case terms
    case acknowledgements

    var id: String { rawValue }

    var eyebrow: String { "// LEGAL" }

    var title: String {
        switch self {
        case .privacy: "PRIVACY POLICY"
        case .terms: "TERMS OF SERVICE"
        case .acknowledgements: "THIRD-PARTY ACKNOWLEDGEMENTS"
        }
    }

    var lastUpdated: String {
        switch self {
        case .privacy, .terms:
            "Last updated: July 2026"
        case .acknowledgements:
            "Open-source software and font license notices"
        }
    }

    var sections: [LegalSection] {
        switch self {
        case .privacy:
            [
                LegalSection(
                    title: "1. INFORMATION WE COLLECT",
                    text: "We collect information you provide directly, including your email address, display name, avatar, profile comments, and custom word packs. We store friend requests, accepted friendships, and blocked-player relationships, including the account identifiers and relationship status needed to operate this in-service social graph. Accepted friends may be visible on player profiles. SpyClash does not access or upload your device address book. When you submit a Community report, we store the selected reason, the reporter and reported account identifiers, and a private snapshot of the reported comment when applicable. We store account identifiers, private room and game state, match history, scores, and gameplay statistics needed to operate the service. We process AI-generation requests and retain generated results and limited account-linked metadata. When you use AI word-pack generation, the theme, requested count, and exclusion words are sent to the server and then to the configured AI-provider chain described below. Our cache does not retain the raw theme or exclusion words. Account-linked cache and replay records contain generated categories and words, request or replay identifiers, one-way theme and exclusion keys, a language code, result counts, and expiry timestamps. Separate function logs record allow-listed operational fields such as the one-way theme key, language code, requested and returned counts, cache or replay outcomes, and provider-attempt counts; they omit the raw theme and exclusion words. These fields are used to operate the generator and evaluate its reliability. To deliver notifications and Live Activities, we collect a randomly generated installation identifier, APNs and ActivityKit push tokens, notification authorization status and preferences, app version, and selected language or locale. We retain delivery states, attempt counts, and error codes needed to retry delivery, revoke invalid tokens, and diagnose notification failures. The Base44 backend links notification registrations to your account, stores one-way installation and token hashes, and stores raw push tokens in encrypted form. For accounts with a legacy provider agreement, we may retain transaction or subscription identifiers, lifecycle status, and dates; we do not receive full payment-card details. QR camera frames and ARKit Camera Assistance data used to stabilize local Nearby Interaction/Radar ranging are processed on device and are not uploaded or retained."
                ),
                LegalSection(
                    title: "2. HOW WE USE YOUR INFORMATION",
                    text: "We use the information we collect to authenticate accounts; operate rooms, matches, friendships, blocks, word packs, leaderboards, and player statistics; host and moderate user content; investigate Community reports; enforce the Community Standards; provide customer support; generate AI word packs; and send game-related notifications and Live Activity updates. We use the allow-listed AI interaction fields described above to evaluate the reliability of the existing generator. Notification language, authorization and preference settings, and app version are used to localize and operate notification delivery, not to evaluate user behavior. We do not use this information for advertising or cross-company tracking."
                ),
                LegalSection(
                    title: "3. DATA SHARING",
                    text: "We do not sell your personal information. Base44 provides authentication, application data storage, server functions, access-controlled records, and operational metrics limited to the fields described above. For AI word-pack generation, the configured direct AI endpoint, which defaults to OpenAI's Responses API, is tried first with the request's store option set to false. On specified operational or configuration failures, the same input may also be processed through Base44 InvokeLLM; Base44 may process that request through its configured AI model provider. Provider-side processing and retention are governed by the applicable provider terms and configuration. Apple processes data for Sign in with Apple, legacy transaction reconciliation, APNs notifications, and ActivityKit delivery. To deliver notifications and Live Activities, the Base44 backend sends Apple the token and corresponding alert or public match-state payload. These payloads may include display names, avatar symbols, participant status, round, public category, timer, and navigation identifiers, but not email, room join code, role, or secret word. Google processes Google sign-in, and Stripe processes retained legacy web-billing records. We limit disclosures to the service functions described above and configure and oversee our service providers to protect personal data consistently with this policy and applicable law. Your display name, avatar, profile comments, competitive statistics, accepted friends, and content you choose to share may be visible to other SpyClash players. A custom word pack may be shown to participants when you select it for a game. Community reports and their snapshots are not public and are available only to authorized administrators and necessary service providers."
                ),
                LegalSection(
                    title: "4. DATA STORAGE",
                    text: "Account data is retained while your account is active or for the shorter operational periods described here. AI cache variants expire after seven days, and successful replay records expire after 24 hours; expired rows may remain until periodic cleanup runs but are no longer used. You can delete the account in the iOS app under Profile > Danger Zone. Deletion removes profile data, custom word packs, friend requests, accepted friendships, blocks, profile comments, room invitations, active room references, match-history records, account-scoped AI usage, cache and replay records, push-device registrations, and Live Activity registrations. During deletion, we attempt to revoke the stored Sign in with Apple refresh credential and scrub our stored copy. If Apple revocation cannot be confirmed, the app informs you that manual revocation may be required. For a Community report involving the deleted account, raw account identifiers are replaced with stable deletion tombstones. The private report and its content snapshot may be retained only as reasonably necessary for safety investigation, enforcement, and legal records; access remains limited to authorized administrators and necessary service providers. Limited legacy transaction records may be retained for cancellation, refund, dispute, fraud-prevention, accounting, and legal obligations. If you still have a separate provider-managed legacy billing agreement, account deletion does not cancel it; manage it directly with that provider."
                ),
                LegalSection(
                    title: "5. NATIVE APP METRICS AND WEBSITE SCOPE",
                    text: "This in-app policy describes the native iOS app. The native app does not embed Google Analytics, an advertising SDK, or a cross-app tracking SDK. Its analytics and diagnostics are limited to the account-linked AI interaction fields and operational push-delivery fields described above. The public website may use local storage and hosting or application-platform telemetry; data collected on the website is governed by the privacy policy made available there."
                ),
                LegalSection(
                    title: "6. CHILDREN'S PRIVACY",
                    text: "Our service is not directed to children under the age of 13. If we learn that we collected personal information from a child under 13 without valid authorization, we will take reasonable steps to delete it."
                ),
                LegalSection(
                    title: "7. CHANGES TO THIS POLICY",
                    text: "We may update this Privacy Policy from time to time. We will notify you of any changes by posting the new policy on this page with an updated date."
                ),
                LegalSection(
                    title: "8. CONTACT US",
                    text: "For privacy questions or data-deletion assistance, visit https://spyclash.com/support."
                )
            ]
        case .terms:
            [
                LegalSection(
                    title: "1. ACCEPTANCE OF TERMS",
                    text: "By accessing or using SpyClash, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use our service."
                ),
                LegalSection(
                    title: "2. USE OF THE SERVICE",
                    text: "SpyClash is a multiplayer social deduction game intended for entertainment purposes. You must be at least 13 years old to use this service. You agree to use the service only for lawful purposes and in a manner that does not infringe the rights of others."
                ),
                LegalSection(
                    title: "3. ACCOUNT RESPONSIBILITY",
                    text: "You are responsible for maintaining the confidentiality of your account credentials and for all activities that occur under your account. You agree to notify us immediately of any unauthorized use of your account."
                ),
                LegalSection(
                    title: "4. FAIR PLAY",
                    text: "You agree to play fairly and not to use any cheats, exploits, automation software, bots, hacks, or any unauthorized third-party software that may affect the gameplay. Violations may result in account suspension or termination."
                ),
                LegalSection(
                    title: "5. CONTENT",
                    text: "You agree not to use the game to transmit any content that is unlawful, harmful, threatening, abusive, harassing, defamatory, or otherwise objectionable. We reserve the right to remove any content that violates these terms."
                ),
                LegalSection(
                    title: "6. USER CONTENT AND LICENSE",
                    text: "You retain ownership of content you create or submit, including display names, avatars, comments, and custom word packs. You represent and warrant that you own that content or have every right needed to submit it and that it does not infringe any third party's rights. By submitting user content, you grant SpyClash a worldwide, non-exclusive, royalty-free, sublicensable, and transferable license to host, store, reproduce, format, adapt for technical requirements, publicly display, communicate, distribute, moderate, and otherwise use that content as necessary to operate, provide, secure, improve, and promote the service. This license lasts only as long as reasonably necessary for those purposes, subject to content already shared with other users, backups, legal retention, and enforcement records. You may delete content where controls are provided, and we may remove content that violates these Terms."
                ),
                LegalSection(
                    title: "7. COMMUNITY STANDARDS AND SAFETY",
                    text: "Do not post harassment, bullying, hate speech, threats, encouragement of self-harm, sexual or exploitative content, illegal content, spam, impersonation, private information, or other abusive material. Automated server filters may reject objectionable submissions, but no filter is perfect. Use Report on a profile or comment to send a private report for moderation review. Use Block to stop both accounts from discovering or opening each other's profiles, commenting, or sending room invitations; existing comments and invitations between the accounts are removed. We may remove content, restrict features, suspend, or terminate accounts after review. Knowingly false or abusive reports also violate these Standards. For a review or appeal request, visit https://spyclash.com/support."
                ),
                LegalSection(
                    title: "8. INTELLECTUAL PROPERTY",
                    text: "Except for user content, the SpyClash software, brand, original artwork, features, and functionality are owned by us or used under license and are protected by international copyright, trademark, and other intellectual property laws."
                ),
                LegalSection(
                    title: "9. DISCLAIMER OF WARRANTIES",
                    text: "SpyClash is provided 'as is' without any warranties of any kind, either express or implied. We do not warrant that the service will be uninterrupted, error-free, or free of viruses or other harmful components."
                ),
                LegalSection(
                    title: "10. LIMITATION OF LIABILITY",
                    text: "To the maximum extent permitted by law, we shall not be liable for any indirect, incidental, special, consequential, or punitive damages arising out of or related to your use of the service."
                ),
                LegalSection(
                    title: "11. LEGACY PROVIDER AGREEMENTS",
                    text: "Apple or Stripe agreements created in earlier versions remain managed by the applicable provider. Deleting a SpyClash account does not cancel such an agreement."
                ),
                LegalSection(
                    title: "12. CHANGES TO TERMS",
                    text: "We reserve the right to modify these Terms of Service at any time. We will notify users of significant changes by posting an updated version on this page. Continued use of the service after changes constitutes acceptance of the new terms."
                ),
                LegalSection(
                    title: "13. CONTACT",
                    text: "For support or questions about these Terms, visit https://spyclash.com/support."
                )
            ]
        case .acknowledgements:
            [
                LegalSection(
                    title: "RAJDHANI BOLD · SIL OPEN FONT LICENSE 1.1",
                    text: Self.bundledLicense(named: "Rajdhani-OFL-1.1"),
                    usesMonospacedBody: true
                ),
                LegalSection(
                    title: "SOCKET.IO CLIENT SWIFT 16.1.1 · MIT LICENSE",
                    text: Self.bundledLicense(named: "SocketIO-MIT"),
                    usesMonospacedBody: true
                ),
                LegalSection(
                    title: "STARSCREAM 4.0.8 · APACHE LICENSE 2.0",
                    text: Self.bundledLicense(named: "Starscream-Apache-2.0"),
                    usesMonospacedBody: true
                )
            ]
        }
    }

    private static func bundledLicense(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled license text could not be loaded. Please contact https://spyclash.com/support."
        }
        return text
    }
}

struct LegalSection: Identifiable {
    let title: String
    let text: String
    let usesMonospacedBody: Bool

    init(title: String, text: String, usesMonospacedBody: Bool = false) {
        self.title = title
        self.text = text
        self.usesMonospacedBody = usesMonospacedBody
    }

    var id: String { title }
}

struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reveal = false

    let kind: LegalSheetKind

    var body: some View {
        ZStack {
            SpyBackground()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("legal-top")
                        legalChrome
                        header
                        sections
                        backButton
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 56)
                    .padding(.bottom, 64)
                }
                .id(kind.id)
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("legal-top", anchor: .top)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.28).delay(0.04)) {
                reveal = true
            }
        }
    }

    private var legalChrome: some View {
        HStack {
            Text("LEGAL")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.22)
                .foregroundStyle(SpyTheme.dim)

            Spacer()

            Button {
                HapticManager.shared.fire(.buttonPress)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(SpyTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(Color.clear, in: CutCornerShape(cut: 8))
                    .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(SpyWebPressStyle())
            .spyHitTarget()
            .accessibilityLabel("Close legal document")
        }
        .padding(.bottom, 12)
        .opacity(reveal ? 1 : 0)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title)
                .font(.system(size: 36, weight: .black, design: .default))
                .tracking(0.10)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.72)
                .lineLimit(2)

            Text(kind.lastUpdated)
                .font(SpyTheme.micro)
                .tracking(0.18)
                .foregroundStyle(SpyTheme.faint)
                .spyKicker()
        }
        .padding(.bottom, 48)
        .opacity(reveal ? 1 : 0)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 36) {
            ForEach(Array(kind.sections.enumerated()), id: \.element.id) { index, section in
                LegalSectionRow(section: section)
                    .opacity(reveal ? 1 : 0)
                    .animation(.easeOut(duration: 0.24).delay(Double(index) * 0.03), value: reveal)
            }
        }
    }

    private var backButton: some View {
        Button {
            HapticManager.shared.fire(.buttonPress)
            dismiss()
        } label: {
            Label("BACK TO HOME", systemImage: "chevron.left")
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .padding(.top, 24)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SpyTheme.strokeDim)
                .frame(height: 1)
        }
        .padding(.top, 36)
        .opacity(reveal ? 1 : 0)
    }
}

struct LegalSectionRow: View {
    let section: LegalSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 14, weight: .black, design: .default))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.red)
                .spyKicker(lines: 2)
                .fixedSize(horizontal: false, vertical: true)

            Text(section.text)
                .font(.system(
                    size: 13,
                    weight: .medium,
                    design: section.usesMonospacedBody ? .monospaced : .default
                ))
                .tracking(0.02)
                .lineSpacing(9)
                .foregroundStyle(SpyTheme.muted.opacity(0.98))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LanguageSwitcher: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 5) {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    guard appState.language != language else { return }
                    HapticManager.shared.fire(.tabSelection)
                    Task {
                        try? await appState.setLanguage(language, syncRemote: appState.user != nil)
                    }
                } label: {
                    Text(language.shortCode)
                        .font(SpyTheme.micro)
                        .tracking(0.08)
                        .foregroundStyle(appState.language == language ? .white : SpyTheme.dim)
                        .frame(width: 34, height: 28)
                        .background(appState.language == language ? SpyTheme.red.opacity(0.9) : SpyTheme.panelDeep)
                        .overlay(Rectangle().stroke(appState.language == language ? SpyTheme.red : SpyTheme.stroke))
                }
                .buttonStyle(SpyWebPressStyle())
                .spyHitTarget()
                .accessibilityLabel("Set language \(language.title)")
            }
        }
    }
}
