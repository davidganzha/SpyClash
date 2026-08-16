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
        case .uk: "ЛІЦЕНЗІЇ"
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

    func eyebrow(for language: AppLanguage) -> String {
        localized(
            language,
            en: "// LEGAL",
            es: "// LEGAL",
            ru: "// ПРАВОВАЯ ИНФОРМАЦИЯ",
            uk: "// ПРАВОВА ІНФОРМАЦІЯ"
        )
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .privacy:
            localized(language, en: "PRIVACY POLICY", es: "POLÍTICA DE PRIVACIDAD", ru: "ПОЛИТИКА КОНФИДЕНЦИАЛЬНОСТИ", uk: "ПОЛІТИКА КОНФІДЕНЦІЙНОСТІ")
        case .terms:
            localized(language, en: "TERMS OF SERVICE", es: "TÉRMINOS DEL SERVICIO", ru: "УСЛОВИЯ ИСПОЛЬЗОВАНИЯ", uk: "УМОВИ ВИКОРИСТАННЯ")
        case .acknowledgements:
            localized(language, en: "THIRD-PARTY ACKNOWLEDGEMENTS", es: "AVISOS DE TERCEROS", ru: "УВЕДОМЛЕНИЯ О СТОРОННИХ КОМПОНЕНТАХ", uk: "ВІДОМОСТІ ПРО СТОРОННІ КОМПОНЕНТИ")
        }
    }

    func lastUpdated(for language: AppLanguage) -> String {
        switch self {
        case .privacy:
            localized(language, en: "Last updated: August 2026", es: "Última actualización: agosto de 2026", ru: "Последнее обновление: август 2026 г.", uk: "Останнє оновлення: серпень 2026 р.")
        case .terms:
            localized(language, en: "Last updated: July 2026", es: "Última actualización: julio de 2026", ru: "Последнее обновление: июль 2026 г.", uk: "Останнє оновлення: липень 2026 р.")
        case .acknowledgements:
            localized(language, en: "Open-source software and font license notices", es: "Avisos de licencias de software de código abierto y fuentes", ru: "Уведомления о лицензиях открытого ПО и шрифтов", uk: "Відомості про ліцензії відкритого ПЗ і шрифтів")
        }
    }

    func sections(for language: AppLanguage) -> [LegalSection] {
        let sections = switch language {
        case .en: englishSections
        case .es: spanishSections
        case .ru: russianSections
        case .uk: ukrainianSections
        }
        guard self == .privacy, sections.indices.contains(2) else {
            return sections
        }

        var privacySections = sections
        let dataSharing = privacySections[2]
        let equivalentProtection = localized(
            language,
            en: "We require every service provider that receives user data to provide the same or equivalent protection described in this policy and required by the App Review Guidelines.",
            es: "Exigimos que todo proveedor de servicios que reciba datos de usuarios proporcione la misma protección o una equivalente a la descrita en esta política y exigida por las Directrices de revisión de App Store.",
            ru: "Мы требуем, чтобы каждый поставщик услуг, получающий данные пользователей, обеспечивал такую же или равнозначную защиту, как описано в этой политике и требуется Правилами проверки App Store.",
            uk: "Ми вимагаємо, щоб кожен постачальник послуг, який отримує дані користувачів, забезпечував такий самий або рівнозначний захист, як описано в цій політиці та вимагається Правилами перевірки App Store."
        )
        privacySections[2] = LegalSection(
            title: dataSharing.title,
            text: "\(dataSharing.text) \(equivalentProtection)",
            usesMonospacedBody: dataSharing.usesMonospacedBody
        )
        return privacySections
    }

    private var englishSections: [LegalSection] {
        switch self {
        case .privacy:
            [
                LegalSection(
                    title: "1. INFORMATION WE COLLECT",
                    text: "We collect information you provide directly, including your email address, display name, avatar, profile comments, and custom word packs. We store friend requests, accepted friendships, and blocked-player relationships, including the account identifiers and relationship status needed to operate this in-service social graph. Accepted friends may be visible on player profiles. SpyClash does not access or upload your device address book. When you submit a Community report, we store the selected reason, the reporter and reported account identifiers, and a private snapshot of the reported comment when applicable. We store account identifiers, private room and game state, match history, scores, and gameplay statistics needed to operate the service. We process AI-generation requests and retain generated results and limited account-linked metadata. When you use optional AI word-pack generation, the theme, requested count, and any exclusion words are sent to the SpyClash backend. When no suitable cached result is available, the backend processes those inputs through Base44 InvokeLLM as described below. Our cache does not retain the raw theme or exclusion words. Account-linked cache and replay records contain generated categories and words, request or replay identifiers, one-way theme and exclusion keys, a language code, result counts, and expiry timestamps. Separate function logs record allow-listed operational fields such as the one-way theme key, language code, requested and returned counts, cache or replay outcomes, and provider-attempt counts; they omit the raw theme and exclusion words. These fields are used to operate the generator and evaluate its reliability. To deliver notifications and Live Activities, we collect a randomly generated installation identifier, APNs and ActivityKit push tokens, notification authorization status and preferences, app version, and selected language or locale. We retain delivery states, attempt counts, and error codes needed to retry delivery, revoke invalid tokens, and diagnose notification failures. The Base44 backend links notification registrations to your account, stores one-way installation and token hashes, and stores raw push tokens in encrypted form. For accounts with a legacy provider agreement, we may retain transaction or subscription identifiers, lifecycle status, and dates; we do not receive full payment-card details. QR camera frames and ARKit Camera Assistance data used to stabilize local Nearby Interaction/Radar ranging are processed on device and are not uploaded or retained."
                ),
                LegalSection(
                    title: "2. HOW WE USE YOUR INFORMATION",
                    text: "We use the information we collect to authenticate accounts; operate rooms, matches, friendships, blocks, word packs, leaderboards, and player statistics; host and moderate user content; investigate Community reports; enforce the Community Standards; provide customer support; generate AI word packs; and send game-related notifications and Live Activity updates. We use the allow-listed AI interaction fields described above to evaluate the reliability of the existing generator. Notification language, authorization and preference settings, and app version are used to localize and operate notification delivery, not to evaluate user behavior. We do not use this information for advertising or cross-company tracking."
                ),
                LegalSection(
                    title: "3. DATA SHARING",
                    text: "We do not sell your personal information. Base44 provides authentication, application data storage, server functions, access-controlled records, and operational metrics limited to the fields described above. For optional AI word-pack generation, when no suitable cached result is available, the SpyClash backend sends the theme, requested count, and any exclusion words through Base44 InvokeLLM. Base44 handles the request through the AI model provider configured for that integration. Processing and retention by Base44 and any model provider are subject to the applicable service configuration, terms, and data-protection obligations. AI processing is used only to generate word packs requested by the user; Community-content moderation uses non-AI safety rules. Apple processes data for Sign in with Apple, legacy transaction reconciliation, APNs notifications, and ActivityKit delivery. To deliver notifications and Live Activities, the Base44 backend sends Apple the token and corresponding alert or public match-state payload. These payloads may include display names, avatar symbols, participant status, round, public category, timer, and navigation identifiers, but not email, room join code, role, or secret word. Google processes Google sign-in, and Stripe processes retained legacy web-billing records. We limit disclosures to the service functions described above. We use service providers to deliver the functions described here and require them to handle data under their applicable terms and data-protection obligations. Your display name, avatar, profile comments, competitive statistics, accepted friends, and content you choose to share may be visible to other SpyClash players. A custom word pack may be shown to participants when you select it for a game. Community reports and their snapshots are not public and are available only to authorized administrators and necessary service providers."
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
                    text: Self.bundledLicense(named: "Rajdhani-OFL-1.1", language: .en),
                    usesMonospacedBody: true
                ),
                LegalSection(
                    title: "SOCKET.IO CLIENT SWIFT 16.1.1 · MIT LICENSE",
                    text: Self.bundledLicense(named: "SocketIO-MIT", language: .en),
                    usesMonospacedBody: true
                ),
                LegalSection(
                    title: "STARSCREAM 4.0.8 · APACHE LICENSE 2.0",
                    text: Self.bundledLicense(named: "Starscream-Apache-2.0", language: .en),
                    usesMonospacedBody: true
                )
            ]
        }
    }

    private static func bundledLicense(named name: String, language: AppLanguage) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return localized(
                language,
                en: "The bundled license text could not be loaded. Please contact https://spyclash.com/support.",
                es: "No se pudo cargar el texto de la licencia incluida. Ponte en contacto mediante https://spyclash.com/support.",
                ru: "Не удалось загрузить текст лицензии из комплекта приложения. Обратитесь через https://spyclash.com/support.",
                uk: "Не вдалося завантажити текст ліцензії з комплекту застосунку. Зверніться через https://spyclash.com/support."
            )
        }
        return text
    }

    private static func localized(
        _ language: AppLanguage,
        en: String,
        es: String,
        ru: String,
        uk: String
    ) -> String {
        switch language {
        case .en: en
        case .es: es
        case .ru: ru
        case .uk: uk
        }
    }

    private func localized(
        _ language: AppLanguage,
        en: String,
        es: String,
        ru: String,
        uk: String
    ) -> String {
        Self.localized(language, en: en, es: es, ru: ru, uk: uk)
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

private extension LegalSheetKind {
    var spanishSections: [LegalSection] {
        switch self {
        case .privacy:
            [
                LegalSection(
                    title: "1. INFORMACIÓN QUE RECOPILAMOS",
                    text: "Recopilamos la información que proporcionas directamente, incluida tu dirección de correo electrónico, nombre para mostrar, avatar, comentarios de perfil y paquetes de palabras personalizados. Almacenamos solicitudes de amistad, amistades aceptadas y relaciones con jugadores bloqueados, incluidos los identificadores de cuenta y el estado de la relación necesarios para operar este grafo social dentro del servicio. Los amigos aceptados pueden ser visibles en los perfiles de los jugadores. SpyClash no accede a la libreta de direcciones de tu dispositivo ni la carga. Cuando envías un reporte de Comunidad, almacenamos el motivo seleccionado, los identificadores de las cuentas denunciante y denunciada, y una instantánea privada del comentario denunciado cuando corresponda. Almacenamos los identificadores de cuenta, el estado privado de las salas y partidas, el historial de partidas, las puntuaciones y las estadísticas de juego necesarios para operar el servicio. Procesamos solicitudes de generación mediante IA y conservamos los resultados generados y metadatos limitados vinculados a la cuenta. Cuando utilizas la generación opcional de paquetes de palabras mediante IA, el tema, la cantidad solicitada y cualquier palabra excluida se envían al backend de SpyClash. Cuando no hay un resultado adecuado en caché, el backend procesa esos datos mediante Base44 InvokeLLM como se describe a continuación. Nuestra caché no conserva el tema ni las palabras excluidas en su forma original. Los registros de caché y repetición vinculados a la cuenta contienen las categorías y palabras generadas, identificadores de solicitud o repetición, claves unidireccionales del tema y de exclusión, un código de idioma, cantidades de resultados y marcas de tiempo de expiración. Los registros separados de funciones guardan campos operativos incluidos en una lista permitida, como la clave unidireccional del tema, el código de idioma, las cantidades solicitadas y devueltas, los resultados de caché o repetición y el número de intentos de proveedor; omiten el tema y las palabras excluidas en su forma original. Estos campos se utilizan para operar el generador y evaluar su fiabilidad. Para entregar notificaciones y Live Activities, recopilamos un identificador de instalación generado aleatoriamente, tokens push de APNs y ActivityKit, el estado de autorización y las preferencias de notificaciones, la versión de la aplicación y el idioma o la configuración regional seleccionados. Conservamos los estados de entrega, el número de intentos y los códigos de error necesarios para reintentar la entrega, revocar tokens no válidos y diagnosticar fallos de notificaciones. El backend de Base44 vincula los registros de notificaciones con tu cuenta, almacena hashes unidireccionales de la instalación y de los tokens, y guarda los tokens push originales de forma cifrada. Para las cuentas con un acuerdo heredado con un proveedor, podemos conservar identificadores de transacción o suscripción, estados del ciclo de vida y fechas; no recibimos los datos completos de la tarjeta de pago. Los fotogramas de la cámara para códigos QR y los datos de Asistencia de Cámara de ARKit utilizados para estabilizar las mediciones locales de distancia de Nearby Interaction/Radar se procesan en el dispositivo y no se cargan ni se conservan."
                ),
                LegalSection(
                    title: "2. CÓMO UTILIZAMOS TU INFORMACIÓN",
                    text: "Utilizamos la información que recopilamos para autenticar cuentas; operar salas, partidas, amistades, bloqueos, paquetes de palabras, clasificaciones y estadísticas de jugadores; alojar y moderar contenido de usuarios; investigar reportes de Comunidad; aplicar las Normas de la Comunidad; prestar asistencia al cliente; generar paquetes de palabras mediante IA; y enviar notificaciones relacionadas con el juego y actualizaciones de Live Activity. Utilizamos los campos permitidos de interacción con IA descritos anteriormente para evaluar la fiabilidad del generador existente. El idioma de las notificaciones, los ajustes de autorización y preferencias, y la versión de la aplicación se utilizan para localizar y operar la entrega de notificaciones, no para evaluar el comportamiento de los usuarios. No utilizamos esta información para publicidad ni para seguimiento entre empresas."
                ),
                LegalSection(
                    title: "3. DIVULGACIÓN DE DATOS",
                    text: "No vendemos tu información personal. Base44 proporciona autenticación, almacenamiento de datos de la aplicación, funciones de servidor, registros con acceso controlado y métricas operativas limitadas a los campos descritos anteriormente. Para la generación opcional de paquetes de palabras mediante IA, cuando no hay un resultado adecuado en caché, el backend de SpyClash envía el tema, la cantidad solicitada y cualquier palabra excluida mediante Base44 InvokeLLM. Base44 procesa la solicitud a través del proveedor de modelos de IA configurado para esa integración. El procesamiento y la conservación por parte de Base44 y de cualquier proveedor de modelos están sujetos a la configuración, los términos y las obligaciones de protección de datos aplicables. El procesamiento de IA se utiliza únicamente para generar los paquetes de palabras solicitados por el usuario; la moderación del contenido de Comunidad utiliza reglas de seguridad sin IA. Apple procesa datos para Sign in with Apple, la conciliación de transacciones heredadas, las notificaciones APNs y la entrega mediante ActivityKit. Para entregar notificaciones y Live Activities, el backend de Base44 envía a Apple el token y la alerta correspondiente o la carga útil del estado público de la partida. Estas cargas útiles pueden incluir nombres para mostrar, símbolos de avatar, estado de participantes, ronda, categoría pública, temporizador e identificadores de navegación, pero no correo electrónico, código para entrar en la sala, rol ni palabra secreta. Google procesa el inicio de sesión con Google y Stripe procesa los registros conservados de facturación web heredada. Limitamos las divulgaciones a las funciones del servicio descritas anteriormente. Utilizamos proveedores de servicios para prestar las funciones descritas aquí y les exigimos que traten los datos conforme a sus términos y obligaciones de protección de datos aplicables. Tu nombre para mostrar, avatar, comentarios de perfil, estadísticas competitivas, amigos aceptados y el contenido que decidas compartir pueden ser visibles para otros jugadores de SpyClash. Un paquete de palabras personalizado puede mostrarse a los participantes cuando lo seleccionas para una partida. Los reportes de Comunidad y sus instantáneas no son públicos y solo están disponibles para administradores autorizados y proveedores de servicios necesarios."
                ),
                LegalSection(
                    title: "4. CONSERVACIÓN DE DATOS",
                    text: "Los datos de la cuenta se conservan mientras tu cuenta esté activa o durante los periodos operativos más breves que se describen aquí. Las variantes de caché de IA caducan después de siete días y los registros de repetición correctos caducan después de 24 horas; las filas caducadas pueden permanecer hasta que se ejecute la limpieza periódica, pero dejan de utilizarse. Puedes eliminar la cuenta en la aplicación de iOS, en Perfil > Zona de peligro. La eliminación borra los datos del perfil, los paquetes de palabras personalizados, las solicitudes de amistad, las amistades aceptadas, los bloqueos, los comentarios del perfil, las invitaciones a salas, las referencias a salas activas, los registros del historial de partidas, el uso de IA asociado a la cuenta, los registros de caché y repetición, los registros de dispositivos para push y los registros de Live Activity. Durante la eliminación intentamos revocar la credencial de actualización almacenada de Sign in with Apple y eliminar nuestra copia almacenada. Si no puede confirmarse la revocación de Apple, la aplicación te informa de que puede ser necesaria una revocación manual. En los reportes de Comunidad relacionados con la cuenta eliminada, los identificadores de cuenta originales se sustituyen por marcadores estables de eliminación. El reporte privado y su instantánea de contenido solo pueden conservarse durante el tiempo razonablemente necesario para investigaciones de seguridad, medidas de cumplimiento y registros legales; el acceso permanece limitado a administradores autorizados y proveedores de servicios necesarios. Pueden conservarse registros limitados de transacciones heredadas para cancelaciones, reembolsos, disputas, prevención del fraude, contabilidad y obligaciones legales. Si todavía tienes un acuerdo de facturación heredado independiente gestionado por un proveedor, eliminar la cuenta no lo cancela; debes gestionarlo directamente con ese proveedor."
                ),
                LegalSection(
                    title: "5. MÉTRICAS DE LA APLICACIÓN NATIVA Y ALCANCE DEL SITIO WEB",
                    text: "Esta política dentro de la aplicación describe la aplicación nativa para iOS. La aplicación nativa no incorpora Google Analytics, un SDK de publicidad ni un SDK de seguimiento entre aplicaciones. Sus análisis y diagnósticos se limitan a los campos de interacción con IA vinculados a la cuenta y a los campos operativos de entrega push descritos anteriormente. El sitio web público puede utilizar almacenamiento local y telemetría de la plataforma de alojamiento o de la aplicación; los datos recopilados en el sitio web se rigen por la política de privacidad disponible allí."
                ),
                LegalSection(
                    title: "6. PRIVACIDAD DE LOS MENORES",
                    text: "Nuestro servicio no está dirigido a menores de 13 años. Si descubrimos que hemos recopilado información personal de un menor de 13 años sin una autorización válida, tomaremos medidas razonables para eliminarla."
                ),
                LegalSection(
                    title: "7. CAMBIOS EN ESTA POLÍTICA",
                    text: "Podemos actualizar esta Política de privacidad periódicamente. Te notificaremos cualquier cambio publicando la nueva política en esta página con una fecha actualizada."
                ),
                LegalSection(
                    title: "8. CONTACTO",
                    text: "Para consultas sobre privacidad o ayuda para eliminar datos, visita https://spyclash.com/support."
                )
            ]
        case .terms:
            [
                LegalSection(
                    title: "1. ACEPTACIÓN DE LOS TÉRMINOS",
                    text: "Al acceder a SpyClash o utilizarlo, aceptas quedar vinculado por estos Términos del servicio. Si no aceptas estos términos, no utilices nuestro servicio."
                ),
                LegalSection(
                    title: "2. USO DEL SERVICIO",
                    text: "SpyClash es un juego multijugador de deducción social destinado al entretenimiento. Debes tener al menos 13 años para utilizar este servicio. Aceptas utilizar el servicio únicamente con fines lícitos y de una forma que no vulnere los derechos de otras personas."
                ),
                LegalSection(
                    title: "3. RESPONSABILIDAD SOBRE LA CUENTA",
                    text: "Eres responsable de mantener la confidencialidad de las credenciales de tu cuenta y de todas las actividades que se realicen con ella. Aceptas notificarnos inmediatamente cualquier uso no autorizado de tu cuenta."
                ),
                LegalSection(
                    title: "4. JUEGO LIMPIO",
                    text: "Aceptas jugar de forma justa y no utilizar trucos, exploits, software de automatización, bots, hacks ni software de terceros no autorizado que pueda afectar al juego. Las infracciones pueden dar lugar a la suspensión o cancelación de la cuenta."
                ),
                LegalSection(
                    title: "5. CONTENIDO",
                    text: "Aceptas no utilizar el juego para transmitir contenido ilegal, perjudicial, amenazante, abusivo, acosador, difamatorio o de cualquier otro modo objetable. Nos reservamos el derecho de retirar cualquier contenido que infrinja estos términos."
                ),
                LegalSection(
                    title: "6. CONTENIDO DEL USUARIO Y LICENCIA",
                    text: "Conservas la propiedad del contenido que creas o envías, incluidos nombres para mostrar, avatares, comentarios y paquetes de palabras personalizados. Declaras y garantizas que eres propietario de ese contenido o que dispones de todos los derechos necesarios para enviarlo, y que no vulnera los derechos de terceros. Al enviar contenido de usuario, otorgas a SpyClash una licencia mundial, no exclusiva, libre de regalías, sublicenciable y transferible para alojar, almacenar, reproducir, dar formato, adaptar a requisitos técnicos, mostrar públicamente, comunicar, distribuir, moderar y utilizar de cualquier otro modo dicho contenido según sea necesario para operar, prestar, proteger, mejorar y promocionar el servicio. Esta licencia dura únicamente el tiempo razonablemente necesario para esos fines, sin perjuicio del contenido ya compartido con otros usuarios, las copias de seguridad, la conservación legal y los registros de cumplimiento. Puedes eliminar contenido cuando se proporcionen controles para ello, y nosotros podemos retirar contenido que infrinja estos Términos."
                ),
                LegalSection(
                    title: "7. NORMAS DE LA COMUNIDAD Y SEGURIDAD",
                    text: "No publiques acoso, intimidación, discurso de odio, amenazas, incitación a autolesionarse, contenido sexual o de explotación, contenido ilegal, spam, suplantación, información privada ni otro material abusivo. Los filtros automatizados del servidor pueden rechazar envíos objetables, pero ningún filtro es perfecto. Utiliza Reportar en un perfil o comentario para enviar un reporte privado a moderación. Utiliza Bloquear para impedir que ambas cuentas encuentren o abran el perfil de la otra, comenten o envíen invitaciones a salas; los comentarios y las invitaciones existentes entre ambas cuentas se eliminan. Tras una revisión, podemos retirar contenido, limitar funciones, suspender o cancelar cuentas. Los reportes deliberadamente falsos o abusivos también infringen estas Normas. Para solicitar una revisión o apelar, visita https://spyclash.com/support."
                ),
                LegalSection(
                    title: "8. PROPIEDAD INTELECTUAL",
                    text: "Salvo el contenido de los usuarios, el software, la marca, el arte original, las funciones y la funcionalidad de SpyClash son de nuestra propiedad o se utilizan bajo licencia y están protegidos por las leyes internacionales de derechos de autor, marcas y demás propiedad intelectual."
                ),
                LegalSection(
                    title: "9. EXCLUSIÓN DE GARANTÍAS",
                    text: "SpyClash se proporciona «tal cual», sin garantías de ningún tipo, expresas ni implícitas. No garantizamos que el servicio sea ininterrumpido, esté libre de errores o carezca de virus u otros componentes dañinos."
                ),
                LegalSection(
                    title: "10. LIMITACIÓN DE RESPONSABILIDAD",
                    text: "En la máxima medida permitida por la ley, no seremos responsables de ningún daño indirecto, incidental, especial, consecuente o punitivo que surja de tu uso del servicio o esté relacionado con él."
                ),
                LegalSection(
                    title: "11. ACUERDOS HEREDADOS CON PROVEEDORES",
                    text: "Los acuerdos con Apple o Stripe creados en versiones anteriores siguen siendo gestionados por el proveedor correspondiente. Eliminar una cuenta de SpyClash no cancela dicho acuerdo."
                ),
                LegalSection(
                    title: "12. CAMBIOS EN LOS TÉRMINOS",
                    text: "Nos reservamos el derecho de modificar estos Términos del servicio en cualquier momento. Informaremos a los usuarios de los cambios importantes publicando una versión actualizada en esta página. El uso continuado del servicio después de los cambios constituye la aceptación de los nuevos términos."
                ),
                LegalSection(
                    title: "13. CONTACTO",
                    text: "Para obtener asistencia o realizar consultas sobre estos Términos, visita https://spyclash.com/support."
                )
            ]
        case .acknowledgements:
            acknowledgementSections(for: .es)
        }
    }

    var russianSections: [LegalSection] {
        switch self {
        case .privacy:
            [
                LegalSection(
                    title: "1. КАКУЮ ИНФОРМАЦИЮ МЫ СОБИРАЕМ",
                    text: "Мы собираем информацию, которую вы предоставляете напрямую, включая адрес электронной почты, отображаемое имя, аватар, комментарии в профиле и пользовательские наборы слов. Мы храним запросы на добавление в друзья, принятые дружеские связи и связи с заблокированными игроками, включая идентификаторы учетных записей и статус связи, необходимые для работы этого социального графа внутри сервиса. Принятые друзья могут отображаться в профилях игроков. SpyClash не получает доступ к адресной книге вашего устройства и не загружает ее. Когда вы отправляете жалобу в Сообществе, мы сохраняем выбранную причину, идентификаторы учетных записей отправителя жалобы и лица, на которое подана жалоба, а также закрытый снимок содержимого комментария, на который подана жалоба, когда это применимо. Мы храним идентификаторы учетных записей, закрытое состояние комнат и игр, историю матчей, результаты и игровую статистику, необходимые для работы сервиса. Мы обрабатываем запросы на генерацию с помощью ИИ и сохраняем созданные результаты и ограниченные метаданные, связанные с учетной записью. Когда вы используете необязательную генерацию наборов слов с помощью ИИ, тема, запрошенное количество и любые исключаемые слова отправляются в серверную часть SpyClash. Если подходящего результата в кэше нет, серверная часть обрабатывает эти входные данные через Base44 InvokeLLM, как описано ниже. Наш кэш не сохраняет исходный текст темы или исключаемых слов. Связанные с учетной записью записи кэша и повторного воспроизведения содержат созданные категории и слова, идентификаторы запроса или повторного воспроизведения, односторонние ключи темы и исключений, код языка, количество результатов и отметки времени истечения срока действия. Отдельные журналы функций записывают разрешенные операционные поля, такие как односторонний ключ темы, код языка, запрошенное и возвращенное количество, результат кэширования или повторного воспроизведения и число попыток обращения к поставщикам; исходный текст темы и исключаемых слов в них не записывается. Эти поля используются для работы генератора и оценки его надежности. Для доставки уведомлений и Live Activities мы собираем случайно созданный идентификатор установки, push-токены APNs и ActivityKit, статус разрешения и настройки уведомлений, версию приложения и выбранный язык или локаль. Мы сохраняем статусы доставки, количество попыток и коды ошибок, необходимые для повторной доставки, отзыва недействительных токенов и диагностики сбоев уведомлений. Серверная часть Base44 связывает регистрации уведомлений с вашей учетной записью, хранит односторонние хэши установки и токенов, а исходные push-токены хранит в зашифрованном виде. Для учетных записей с ранее заключенным соглашением с поставщиком мы можем сохранять идентификаторы транзакций или подписок, статус жизненного цикла и даты; полные данные платежной карты мы не получаем. Кадры камеры для QR-кодов и данные Camera Assistance ARKit, используемые для стабилизации локального измерения расстояния Nearby Interaction/Radar, обрабатываются на устройстве, не загружаются и не сохраняются."
                ),
                LegalSection(
                    title: "2. КАК МЫ ИСПОЛЬЗУЕМ ВАШУ ИНФОРМАЦИЮ",
                    text: "Мы используем собранную информацию для аутентификации учетных записей; работы комнат, матчей, дружеских связей, блокировок, наборов слов, таблиц лидеров и статистики игроков; размещения и модерации пользовательского содержимого; рассмотрения жалоб Сообщества; применения Стандартов сообщества; оказания поддержки пользователям; создания наборов слов с помощью ИИ; а также отправки игровых уведомлений и обновлений Live Activity. Мы используем описанные выше разрешенные поля взаимодействия с ИИ для оценки надежности существующего генератора. Язык уведомлений, параметры разрешений и предпочтений, а также версия приложения используются для локализации и обеспечения доставки уведомлений, а не для оценки поведения пользователей. Мы не используем эту информацию для рекламы или отслеживания между компаниями."
                ),
                LegalSection(
                    title: "3. ПЕРЕДАЧА ДАННЫХ",
                    text: "Мы не продаем вашу личную информацию. Base44 обеспечивает аутентификацию, хранение данных приложения, серверные функции, записи с контролируемым доступом и операционные метрики, ограниченные описанными выше полями. Для необязательной генерации наборов слов с помощью ИИ, если подходящего результата в кэше нет, серверная часть SpyClash передает тему, запрошенное количество и любые исключаемые слова через Base44 InvokeLLM. Base44 обрабатывает запрос с помощью поставщика модели ИИ, настроенного для этой интеграции. Обработка и хранение данных в Base44 и у любого поставщика модели регулируются применимой конфигурацией сервиса, условиями и обязательствами по защите данных. Обработка ИИ используется только для создания наборов слов по запросу пользователя; модерация содержимого Сообщества использует правила безопасности без ИИ. Apple обрабатывает данные для Sign in with Apple, сверки ранее совершенных транзакций, уведомлений APNs и доставки ActivityKit. Для доставки уведомлений и Live Activities серверная часть Base44 передает Apple токен и соответствующее уведомление или полезную нагрузку публичного состояния матча. Такая полезная нагрузка может включать отображаемые имена, символы аватаров, статус участников, раунд, публичную категорию, таймер и идентификаторы навигации, но не адрес электронной почты, код входа в комнату, роль или секретное слово. Google обрабатывает вход через Google, а Stripe — сохраненные записи ранее действовавшего веб-биллинга. Мы ограничиваем передачу данных описанными выше функциями сервиса. Мы используем поставщиков услуг для выполнения описанных здесь функций и требуем от них обрабатывать данные согласно применимым к ним условиям и обязательствам по защите данных. Ваше отображаемое имя, аватар, комментарии в профиле, соревновательная статистика, принятые друзья и содержимое, которым вы решили поделиться, могут быть видны другим игрокам SpyClash. Пользовательский набор слов может быть показан участникам, когда вы выбираете его для игры. Жалобы Сообщества и их снимки не являются публичными и доступны только уполномоченным администраторам и необходимым поставщикам услуг."
                ),
                LegalSection(
                    title: "4. ХРАНЕНИЕ ДАННЫХ",
                    text: "Данные учетной записи хранятся, пока ваша учетная запись активна, либо в течение более коротких операционных сроков, описанных здесь. Варианты кэша ИИ перестают действовать через семь дней, а успешные записи повторного воспроизведения — через 24 часа; строки с истекшим сроком могут оставаться до очередной периодической очистки, но больше не используются. Учетную запись можно удалить в приложении iOS в разделе Профиль > Опасная зона. При удалении стираются данные профиля, пользовательские наборы слов, запросы на добавление в друзья, принятые дружеские связи, блокировки, комментарии в профиле, приглашения в комнаты, ссылки на активные комнаты, записи истории матчей, сведения об использовании ИИ в рамках учетной записи, записи кэша и повторного воспроизведения, регистрации push-устройств и регистрации Live Activity. Во время удаления мы пытаемся отозвать сохраненные учетные данные обновления Sign in with Apple и удалить хранящуюся у нас копию. Если отзыв у Apple не удается подтвердить, приложение сообщает, что может потребоваться ручной отзыв. В жалобах Сообщества, связанных с удаленной учетной записью, исходные идентификаторы учетной записи заменяются стабильными маркерами удаления. Закрытая жалоба и снимок ее содержимого могут сохраняться только в течение срока, разумно необходимого для расследования вопросов безопасности, применения правил и ведения юридических записей; доступ остается ограниченным уполномоченными администраторами и необходимыми поставщиками услуг. Ограниченные записи ранее совершенных транзакций могут сохраняться для отмены, возврата средств, разрешения споров, предотвращения мошенничества, бухгалтерского учета и исполнения юридических обязательств. Если у вас остается отдельное ранее заключенное соглашение о выставлении счетов, которым управляет поставщик, удаление учетной записи его не отменяет; управляйте им непосредственно через этого поставщика."
                ),
                LegalSection(
                    title: "5. МЕТРИКИ НАТИВНОГО ПРИЛОЖЕНИЯ И ОБЛАСТЬ ДЕЙСТВИЯ ВЕБ-САЙТА",
                    text: "Эта политика внутри приложения описывает нативное приложение для iOS. Нативное приложение не содержит Google Analytics, рекламный SDK или SDK для межприложенческого отслеживания. Его аналитика и диагностика ограничены описанными выше полями взаимодействия с ИИ, связанными с учетной записью, и операционными полями доставки push-уведомлений. Публичный веб-сайт может использовать локальное хранилище и телеметрию хостинга или платформы приложения; данные, собираемые на веб-сайте, регулируются опубликованной там политикой конфиденциальности."
                ),
                LegalSection(
                    title: "6. КОНФИДЕНЦИАЛЬНОСТЬ ДЕТЕЙ",
                    text: "Наш сервис не предназначен для детей младше 13 лет. Если нам станет известно, что мы собрали личную информацию ребенка младше 13 лет без действительного разрешения, мы предпримем разумные меры для ее удаления."
                ),
                LegalSection(
                    title: "7. ИЗМЕНЕНИЯ ЭТОЙ ПОЛИТИКИ",
                    text: "Мы можем время от времени обновлять эту Политику конфиденциальности. Мы сообщим вам об изменениях, опубликовав новую политику на этой странице с обновленной датой."
                ),
                LegalSection(
                    title: "8. КОНТАКТЫ",
                    text: "По вопросам конфиденциальности или для получения помощи с удалением данных посетите https://spyclash.com/support."
                )
            ]
        case .terms:
            [
                LegalSection(
                    title: "1. ПРИНЯТИЕ УСЛОВИЙ",
                    text: "Получая доступ к SpyClash или используя его, вы соглашаетесь соблюдать настоящие Условия использования. Если вы не согласны с этими условиями, не используйте наш сервис."
                ),
                LegalSection(
                    title: "2. ИСПОЛЬЗОВАНИЕ СЕРВИСА",
                    text: "SpyClash — многопользовательская игра на социальную дедукцию, предназначенная для развлечения. Для использования этого сервиса вам должно быть не менее 13 лет. Вы соглашаетесь использовать сервис только в законных целях и таким образом, чтобы не нарушать права других лиц."
                ),
                LegalSection(
                    title: "3. ОТВЕТСТВЕННОСТЬ ЗА УЧЕТНУЮ ЗАПИСЬ",
                    text: "Вы несете ответственность за сохранение конфиденциальности учетных данных своей учетной записи и за все действия, совершенные с ее использованием. Вы соглашаетесь незамедлительно сообщать нам о любом несанкционированном использовании вашей учетной записи."
                ),
                LegalSection(
                    title: "4. ЧЕСТНАЯ ИГРА",
                    text: "Вы соглашаетесь играть честно и не использовать читы, эксплойты, средства автоматизации, ботов, взломы или любое несанкционированное стороннее программное обеспечение, способное повлиять на игровой процесс. Нарушения могут привести к приостановке или прекращению действия учетной записи."
                ),
                LegalSection(
                    title: "5. СОДЕРЖИМОЕ",
                    text: "Вы соглашаетесь не использовать игру для передачи незаконного, вредоносного, угрожающего, оскорбительного, преследующего, клеветнического или иным образом неприемлемого содержимого. Мы оставляем за собой право удалять любое содержимое, нарушающее эти условия."
                ),
                LegalSection(
                    title: "6. ПОЛЬЗОВАТЕЛЬСКОЕ СОДЕРЖИМОЕ И ЛИЦЕНЗИЯ",
                    text: "Вы сохраняете права собственности на содержимое, которое создаете или отправляете, включая отображаемые имена, аватары, комментарии и пользовательские наборы слов. Вы заявляете и гарантируете, что владеете этим содержимым либо обладаете всеми правами, необходимыми для его отправки, и что оно не нарушает права третьих лиц. Отправляя пользовательское содержимое, вы предоставляете SpyClash всемирную, неисключительную, безвозмездную, допускающую сублицензирование и передачу лицензию на размещение, хранение, воспроизведение, форматирование, адаптацию к техническим требованиям, публичный показ, сообщение, распространение, модерацию и иное использование этого содержимого в объеме, необходимом для работы, предоставления, защиты, улучшения и продвижения сервиса. Эта лицензия действует только в течение срока, разумно необходимого для таких целей, с учетом содержимого, уже переданного другим пользователям, резервных копий, юридического хранения и записей о применении правил. Вы можете удалять содержимое там, где предусмотрены соответствующие элементы управления, а мы можем удалять содержимое, нарушающее настоящие Условия."
                ),
                LegalSection(
                    title: "7. СТАНДАРТЫ СООБЩЕСТВА И БЕЗОПАСНОСТЬ",
                    text: "Не публикуйте материалы, содержащие преследование, травлю, язык ненависти, угрозы, поощрение самоповреждения, сексуальное или эксплуатирующее содержимое, незаконное содержимое, спам, выдачу себя за другое лицо, личную информацию или иные оскорбительные материалы. Автоматические серверные фильтры могут отклонять неприемлемые публикации, но ни один фильтр не совершенен. Используйте действие «Пожаловаться» в профиле или комментарии, чтобы отправить закрытую жалобу на рассмотрение модерации. Используйте действие «Заблокировать», чтобы обе учетные записи больше не могли находить или открывать профили друг друга, оставлять комментарии или отправлять приглашения в комнаты; существующие комментарии и приглашения между этими учетными записями удаляются. После рассмотрения мы можем удалить содержимое, ограничить функции, приостановить или прекратить действие учетных записей. Заведомо ложные или неправомерные жалобы также нарушают настоящие Стандарты. Чтобы запросить пересмотр или подать апелляцию, посетите https://spyclash.com/support."
                ),
                LegalSection(
                    title: "8. ИНТЕЛЛЕКТУАЛЬНАЯ СОБСТВЕННОСТЬ",
                    text: "За исключением пользовательского содержимого, программное обеспечение, бренд, оригинальные графические материалы, функции и функциональность SpyClash принадлежат нам либо используются по лицензии и защищены международными законами об авторском праве, товарных знаках и иной интеллектуальной собственности."
                ),
                LegalSection(
                    title: "9. ОТКАЗ ОТ ГАРАНТИЙ",
                    text: "SpyClash предоставляется «как есть» без каких-либо явно выраженных или подразумеваемых гарантий. Мы не гарантируем, что сервис будет работать непрерывно, без ошибок, вирусов или иных вредоносных компонентов."
                ),
                LegalSection(
                    title: "10. ОГРАНИЧЕНИЕ ОТВЕТСТВЕННОСТИ",
                    text: "В максимальной степени, разрешенной законом, мы не несем ответственности за любой косвенный, случайный, специальный, последующий или штрафной ущерб, возникший в результате использования вами сервиса или связанный с ним."
                ),
                LegalSection(
                    title: "11. РАНЕЕ ЗАКЛЮЧЕННЫЕ СОГЛАШЕНИЯ С ПОСТАВЩИКАМИ",
                    text: "Соглашения с Apple или Stripe, заключенные в предыдущих версиях, продолжают управляться соответствующим поставщиком. Удаление учетной записи SpyClash не отменяет такое соглашение."
                ),
                LegalSection(
                    title: "12. ИЗМЕНЕНИЯ УСЛОВИЙ",
                    text: "Мы оставляем за собой право изменить настоящие Условия использования в любое время. Мы уведомим пользователей о существенных изменениях, опубликовав обновленную версию на этой странице. Продолжение использования сервиса после внесения изменений означает принятие новых условий."
                ),
                LegalSection(
                    title: "13. КОНТАКТЫ",
                    text: "Для получения поддержки или по вопросам настоящих Условий посетите https://spyclash.com/support."
                )
            ]
        case .acknowledgements:
            acknowledgementSections(for: .ru)
        }
    }

    var ukrainianSections: [LegalSection] {
        switch self {
        case .privacy:
            [
                LegalSection(
                    title: "1. ЯКУ ІНФОРМАЦІЮ МИ ЗБИРАЄМО",
                    text: "Ми збираємо інформацію, яку ви надаєте безпосередньо, зокрема адресу електронної пошти, ім’я для відображення, аватар, коментарі у профілі та власні набори слів. Ми зберігаємо запити на додавання в друзі, прийняті дружні зв’язки та зв’язки із заблокованими гравцями, зокрема ідентифікатори облікових записів і статус зв’язку, необхідні для роботи цього соціального графа всередині сервісу. Прийняті друзі можуть відображатися у профілях гравців. SpyClash не отримує доступу до адресної книги вашого пристрою та не завантажує її. Коли ви надсилаєте скаргу у Спільноті, ми зберігаємо вибрану причину, ідентифікатори облікових записів особи, яка подала скаргу, та особи, на яку подано скаргу, а також закритий знімок вмісту коментаря, на який подано скаргу, коли це застосовно. Ми зберігаємо ідентифікатори облікових записів, закритий стан кімнат та ігор, історію матчів, результати й ігрову статистику, необхідні для роботи сервісу. Ми обробляємо запити на генерацію за допомогою ШІ та зберігаємо створені результати й обмежені метадані, пов’язані з обліковим записом. Коли ви використовуєте необов’язкову генерацію наборів слів за допомогою ШІ, тема, запитана кількість і слова-винятки надсилаються на серверну частину SpyClash. Коли немає придатного кешованого результату, серверна частина обробляє ці вхідні дані через Base44 InvokeLLM, як описано нижче. Наш кеш не зберігає початковий текст теми або слів-винятків. Пов’язані з обліковим записом записи кешу та повторного відтворення містять створені категорії й слова, ідентифікатори запиту або повторного відтворення, односторонні ключі теми та винятків, код мови, кількість результатів і позначки часу завершення строку дії. Окремі журнали функцій записують дозволені операційні поля, як-от односторонній ключ теми, код мови, запитану й повернуту кількість, результати кешування або повторного відтворення та кількість спроб звернення до постачальників; початковий текст теми й слів-винятків до них не потрапляє. Ці поля використовуються для роботи генератора та оцінювання його надійності. Для доставлення сповіщень і Live Activities ми збираємо випадково створений ідентифікатор установлення, push-токени APNs і ActivityKit, статус дозволу та налаштування сповіщень, версію застосунку й вибрану мову або локаль. Ми зберігаємо статуси доставлення, кількість спроб і коди помилок, необхідні для повторного доставлення, відкликання недійсних токенів і діагностики збоїв сповіщень. Серверна частина Base44 пов’язує реєстрації сповіщень із вашим обліковим записом, зберігає односторонні хеші установлення й токенів, а початкові push-токени зберігає в зашифрованому вигляді. Для облікових записів із раніше укладеною угодою з постачальником ми можемо зберігати ідентифікатори транзакцій або підписок, статус життєвого циклу й дати; повні реквізити платіжної картки ми не отримуємо. Кадри камери для QR-кодів і дані Camera Assistance ARKit, що використовуються для стабілізації локального вимірювання відстані Nearby Interaction/Radar, обробляються на пристрої, не завантажуються й не зберігаються."
                ),
                LegalSection(
                    title: "2. ЯК МИ ВИКОРИСТОВУЄМО ВАШУ ІНФОРМАЦІЮ",
                    text: "Ми використовуємо зібрану інформацію для автентифікації облікових записів; роботи кімнат, матчів, дружніх зв’язків, блокувань, наборів слів, таблиць лідерів і статистики гравців; розміщення та модерації користувацького вмісту; розгляду скарг Спільноти; застосування Стандартів спільноти; надання підтримки користувачам; створення наборів слів за допомогою ШІ; а також надсилання ігрових сповіщень і оновлень Live Activity. Ми використовуємо описані вище дозволені поля взаємодії із ШІ для оцінювання надійності наявного генератора. Мова сповіщень, параметри дозволів і вподобань, а також версія застосунку використовуються для локалізації та забезпечення доставлення сповіщень, а не для оцінювання поведінки користувачів. Ми не використовуємо цю інформацію для реклами або відстеження між компаніями."
                ),
                LegalSection(
                    title: "3. ПЕРЕДАВАННЯ ДАНИХ",
                    text: "Ми не продаємо вашу особисту інформацію. Base44 забезпечує автентифікацію, зберігання даних застосунку, серверні функції, записи з контрольованим доступом та операційні метрики, обмежені описаними вище полями. Для необов’язкової генерації наборів слів за допомогою ШІ, коли немає придатного кешованого результату, серверна частина SpyClash передає тему, запитану кількість і слова-винятки через Base44 InvokeLLM. Base44 обробляє запит за допомогою постачальника моделі ШІ, налаштованого для цієї інтеграції. Обробка та зберігання даних у Base44 і будь-якого постачальника моделі регулюються застосовною конфігурацією служби, умовами та зобов’язаннями щодо захисту даних. Обробка ШІ використовується лише для створення наборів слів на запит користувача; модерація вмісту Спільноти використовує правила безпеки без ШІ. Apple обробляє дані для Sign in with Apple, звіряння раніше здійснених транзакцій, сповіщень APNs і доставлення ActivityKit. Для доставлення сповіщень і Live Activities серверна частина Base44 передає Apple токен і відповідне сповіщення або корисне навантаження публічного стану матчу. Таке корисне навантаження може містити імена для відображення, символи аватарів, статус учасників, раунд, публічну категорію, таймер та ідентифікатори навігації, але не адресу електронної пошти, код входу до кімнати, роль або секретне слово. Google обробляє вхід через Google, а Stripe — збережені записи раніше чинного веббілінгу. Ми обмежуємо передавання даних описаними вище функціями сервісу. Ми використовуємо постачальників послуг для виконання описаних тут функцій і вимагаємо від них обробляти дані відповідно до застосовних до них умов і зобов’язань щодо захисту даних. Ваше ім’я для відображення, аватар, коментарі у профілі, змагальна статистика, прийняті друзі та вміст, яким ви вирішили поділитися, можуть бути видимими іншим гравцям SpyClash. Власний набір слів може бути показаний учасникам, коли ви вибираєте його для гри. Скарги Спільноти та їхні знімки не є публічними й доступні лише уповноваженим адміністраторам і необхідним постачальникам послуг."
                ),
                LegalSection(
                    title: "4. ЗБЕРІГАННЯ ДАНИХ",
                    text: "Дані облікового запису зберігаються, доки ваш обліковий запис активний, або протягом коротших операційних строків, описаних тут. Варіанти кешу ШІ втрачають чинність через сім днів, а успішні записи повторного відтворення — через 24 години; рядки зі строком дії, що минув, можуть залишатися до чергового періодичного очищення, але більше не використовуються. Обліковий запис можна видалити в застосунку iOS у розділі Профіль > Небезпечна зона. Під час видалення стираються дані профілю, власні набори слів, запити на додавання в друзі, прийняті дружні зв’язки, блокування, коментарі у профілі, запрошення до кімнат, посилання на активні кімнати, записи історії матчів, відомості про використання ШІ в межах облікового запису, записи кешу й повторного відтворення, реєстрації push-пристроїв і реєстрації Live Activity. Під час видалення ми намагаємося відкликати збережені облікові дані оновлення Sign in with Apple і видалити копію, що зберігається в нас. Якщо відкликання в Apple не вдається підтвердити, застосунок повідомляє, що може знадобитися ручне відкликання. У скаргах Спільноти, пов’язаних із видаленим обліковим записом, початкові ідентифікатори облікового запису замінюються стабільними маркерами видалення. Закрита скарга та знімок її вмісту можуть зберігатися лише протягом строку, обґрунтовано необхідного для розслідування питань безпеки, застосування правил і ведення юридичних записів; доступ залишається обмеженим уповноваженими адміністраторами й необхідними постачальниками послуг. Обмежені записи раніше здійснених транзакцій можуть зберігатися для скасування, повернення коштів, вирішення спорів, запобігання шахрайству, бухгалтерського обліку та виконання юридичних обов’язків. Якщо у вас залишається окрема раніше укладена угода про виставлення рахунків, якою керує постачальник, видалення облікового запису її не скасовує; керуйте нею безпосередньо через цього постачальника."
                ),
                LegalSection(
                    title: "5. МЕТРИКИ НАТИВНОГО ЗАСТОСУНКУ ТА СФЕРА ДІЇ ВЕБСАЙТУ",
                    text: "Ця політика всередині застосунку описує нативний застосунок для iOS. Нативний застосунок не містить Google Analytics, рекламного SDK або SDK для міжзастосункового відстеження. Його аналітика й діагностика обмежені описаними вище полями взаємодії із ШІ, пов’язаними з обліковим записом, та операційними полями доставлення push-сповіщень. Публічний вебсайт може використовувати локальне сховище й телеметрію хостингу або платформи застосунку; дані, зібрані на вебсайті, регулюються опублікованою там політикою конфіденційності."
                ),
                LegalSection(
                    title: "6. КОНФІДЕНЦІЙНІСТЬ ДІТЕЙ",
                    text: "Наш сервіс не призначений для дітей віком до 13 років. Якщо нам стане відомо, що ми зібрали особисту інформацію дитини віком до 13 років без дійсного дозволу, ми вживемо обґрунтованих заходів для її видалення."
                ),
                LegalSection(
                    title: "7. ЗМІНИ ЦІЄЇ ПОЛІТИКИ",
                    text: "Ми можемо час від часу оновлювати цю Політику конфіденційності. Ми повідомимо вам про зміни, опублікувавши нову політику на цій сторінці з оновленою датою."
                ),
                LegalSection(
                    title: "8. КОНТАКТИ",
                    text: "З питань конфіденційності або для отримання допомоги з видаленням даних відвідайте https://spyclash.com/support."
                )
            ]
        case .terms:
            [
                LegalSection(
                    title: "1. ПРИЙНЯТТЯ УМОВ",
                    text: "Отримуючи доступ до SpyClash або використовуючи його, ви погоджуєтеся дотримуватися цих Умов використання. Якщо ви не погоджуєтеся з цими умовами, не використовуйте наш сервіс."
                ),
                LegalSection(
                    title: "2. ВИКОРИСТАННЯ СЕРВІСУ",
                    text: "SpyClash — це багатокористувацька гра на соціальну дедукцію, призначена для розваг. Для використання цього сервісу вам має бути щонайменше 13 років. Ви погоджуєтеся використовувати сервіс лише із законною метою й у спосіб, що не порушує прав інших осіб."
                ),
                LegalSection(
                    title: "3. ВІДПОВІДАЛЬНІСТЬ ЗА ОБЛІКОВИЙ ЗАПИС",
                    text: "Ви відповідаєте за збереження конфіденційності облікових даних свого облікового запису та за всі дії, здійснені з його використанням. Ви погоджуєтеся негайно повідомляти нам про будь-яке несанкціоноване використання вашого облікового запису."
                ),
                LegalSection(
                    title: "4. ЧЕСНА ГРА",
                    text: "Ви погоджуєтеся грати чесно й не використовувати чити, експлойти, засоби автоматизації, ботів, злами або будь-яке несанкціоноване стороннє програмне забезпечення, здатне вплинути на ігровий процес. Порушення можуть призвести до призупинення або припинення дії облікового запису."
                ),
                LegalSection(
                    title: "5. ВМІСТ",
                    text: "Ви погоджуєтеся не використовувати гру для передавання незаконного, шкідливого, загрозливого, образливого, переслідувального, наклепницького або іншого неприйнятного вмісту. Ми залишаємо за собою право видаляти будь-який вміст, що порушує ці умови."
                ),
                LegalSection(
                    title: "6. КОРИСТУВАЦЬКИЙ ВМІСТ І ЛІЦЕНЗІЯ",
                    text: "Ви зберігаєте право власності на вміст, який створюєте або надсилаєте, зокрема імена для відображення, аватари, коментарі та власні набори слів. Ви заявляєте й гарантуєте, що володієте цим вмістом або маєте всі права, необхідні для його надсилання, і що він не порушує прав третіх осіб. Надсилаючи користувацький вміст, ви надаєте SpyClash всесвітню, невиключну, безоплатну ліцензію з правом субліцензування та передавання на розміщення, зберігання, відтворення, форматування, адаптацію до технічних вимог, публічний показ, повідомлення, розповсюдження, модерацію та інше використання цього вмісту в обсязі, необхідному для роботи, надання, захисту, поліпшення й просування сервісу. Ця ліцензія діє лише протягом строку, обґрунтовано необхідного для таких цілей, з урахуванням вмісту, уже переданого іншим користувачам, резервних копій, юридичного зберігання та записів про застосування правил. Ви можете видаляти вміст там, де передбачені відповідні засоби керування, а ми можемо видаляти вміст, що порушує ці Умови."
                ),
                LegalSection(
                    title: "7. СТАНДАРТИ СПІЛЬНОТИ ТА БЕЗПЕКА",
                    text: "Не публікуйте матеріали, що містять переслідування, цькування, мову ворожнечі, погрози, заохочення до самоушкодження, сексуальний або експлуатаційний вміст, незаконний вміст, спам, видавання себе за іншу особу, приватну інформацію чи інші образливі матеріали. Автоматичні серверні фільтри можуть відхиляти неприйнятні публікації, але жоден фільтр не є досконалим. Використовуйте дію «Поскаржитися» у профілі або коментарі, щоб надіслати закриту скаргу на розгляд модерації. Використовуйте дію «Заблокувати», щоб обидва облікові записи більше не могли знаходити або відкривати профілі один одного, залишати коментарі чи надсилати запрошення до кімнат; наявні коментарі та запрошення між цими обліковими записами видаляються. Після розгляду ми можемо видалити вміст, обмежити функції, призупинити або припинити дію облікових записів. Завідомо неправдиві або неправомірні скарги також порушують ці Стандарти. Щоб подати запит на перегляд або апеляцію, відвідайте https://spyclash.com/support."
                ),
                LegalSection(
                    title: "8. ІНТЕЛЕКТУАЛЬНА ВЛАСНІСТЬ",
                    text: "За винятком користувацького вмісту, програмне забезпечення, бренд, оригінальні графічні матеріали, функції та функціональність SpyClash належать нам або використовуються за ліцензією й захищені міжнародними законами про авторське право, торговельні марки та іншу інтелектуальну власність."
                ),
                LegalSection(
                    title: "9. ВІДМОВА ВІД ГАРАНТІЙ",
                    text: "SpyClash надається «як є» без будь-яких прямо виражених або непрямих гарантій. Ми не гарантуємо, що сервіс працюватиме безперервно, без помилок, вірусів чи інших шкідливих компонентів."
                ),
                LegalSection(
                    title: "10. ОБМЕЖЕННЯ ВІДПОВІДАЛЬНОСТІ",
                    text: "У максимальному обсязі, дозволеному законом, ми не несемо відповідальності за будь-які непрямі, випадкові, спеціальні, наслідкові або штрафні збитки, що виникли внаслідок використання вами сервісу або пов’язані з ним."
                ),
                LegalSection(
                    title: "11. РАНІШЕ УКЛАДЕНІ УГОДИ З ПОСТАЧАЛЬНИКАМИ",
                    text: "Угоди з Apple або Stripe, укладені в попередніх версіях, і надалі керуються відповідним постачальником. Видалення облікового запису SpyClash не скасовує таку угоду."
                ),
                LegalSection(
                    title: "12. ЗМІНИ УМОВ",
                    text: "Ми залишаємо за собою право змінити ці Умови використання в будь-який час. Ми повідомимо користувачів про суттєві зміни, опублікувавши оновлену версію на цій сторінці. Подальше використання сервісу після внесення змін означає прийняття нових умов."
                ),
                LegalSection(
                    title: "13. КОНТАКТИ",
                    text: "Для отримання підтримки або з питань цих Умов відвідайте https://spyclash.com/support."
                )
            ]
        case .acknowledgements:
            acknowledgementSections(for: .uk)
        }
    }

    private func acknowledgementSections(for language: AppLanguage) -> [LegalSection] {
        [
            LegalSection(
                title: "RAJDHANI BOLD · SIL OPEN FONT LICENSE 1.1",
                text: Self.bundledLicense(named: "Rajdhani-OFL-1.1", language: language),
                usesMonospacedBody: true
            ),
            LegalSection(
                title: "SOCKET.IO CLIENT SWIFT 16.1.1 · MIT LICENSE",
                text: Self.bundledLicense(named: "SocketIO-MIT", language: language),
                usesMonospacedBody: true
            ),
            LegalSection(
                title: "STARSCREAM 4.0.8 · APACHE LICENSE 2.0",
                text: Self.bundledLicense(named: "Starscream-Apache-2.0", language: language),
                usesMonospacedBody: true
            )
        ]
    }
}

struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
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
            Text(kind.eyebrow(for: appState.language))
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
            .accessibilityLabel(closeAccessibilityLabel)
        }
        .padding(.bottom, 12)
        .opacity(reveal ? 1 : 0)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.title(for: appState.language))
                .font(.system(size: 36, weight: .black, design: .default))
                .tracking(0.10)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.72)
                .lineLimit(2)

            Text(kind.lastUpdated(for: appState.language))
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
            ForEach(Array(kind.sections(for: appState.language).enumerated()), id: \.element.id) { index, section in
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
            Label(backHomeTitle, systemImage: "chevron.left")
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

    private var closeAccessibilityLabel: String {
        switch appState.language {
        case .en: "Close legal document"
        case .es: "Cerrar documento legal"
        case .ru: "Закрыть юридический документ"
        case .uk: "Закрити правовий документ"
        }
    }

    private var backHomeTitle: String {
        switch appState.language {
        case .en: "BACK TO HOME"
        case .es: "VOLVER AL INICIO"
        case .ru: "НАЗАД НА ГЛАВНУЮ"
        case .uk: "НАЗАД НА ГОЛОВНУ"
        }
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
                .accessibilityLabel(accessibilityLabel(for: language))
            }
        }
    }

    private func accessibilityLabel(for language: AppLanguage) -> String {
        switch appState.language {
        case .en: "Set language \(language.title)"
        case .es: "Cambiar idioma a \(language.title)"
        case .ru: "Выбрать язык: \(language.title)"
        case .uk: "Обрати мову: \(language.title)"
        }
    }
}
