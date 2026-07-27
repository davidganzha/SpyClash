import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var appState

    @State private var displayName = ""
    @State private var avatar = "🕵️"
    @State private var selectedLanguage: AppLanguage = .en
    @State private var selectedCardTheme: SpyCardThemeID = .field
    @State private var selectedCardAccent: SpyCardAccentID = .signalRed
    @State private var selectedCardBadge: SpyCardBadgeID = .operative
    @State private var history: [GameHistory] = []
    @State private var isSaving = false
    @State private var isSavingLanguage = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var legalSheet: LegalSheetKind?
    @State private var status = ""
    @State private var statusKind: ProfileStatusKind?

    private let availableAvatars = ["🕵️", "🥷", "🧠", "🎭", "🃏", "👁️", "🔥", "⚡️", "🎯", "🛡️"]

    private var copy: ProfileCopy {
        appState.language.profile
    }

    private var deleteDialogMessage: String {
        guard appState.isCasadaProtocolActive else { return copy.deleteDialogMessage }
        return localized(
            en: "This permanently deletes your profile, game history, custom packs, and social data. Limited security, moderation, and legacy billing records may be retained where legally required. Deleting your account does not cancel an existing Apple or Stripe subscription; manage it with that provider.",
            ru: "Это навсегда удалит профиль, историю игр, пользовательские паки и социальные данные. Ограниченные записи безопасности, модерации и прежних платежей могут храниться по закону. Удаление аккаунта не отменяет действующую подписку Apple или Stripe — управляйте ею у провайдера.",
            es: "Esto elimina permanentemente tu perfil, historial, paquetes personalizados y datos sociales. Algunos registros de seguridad, moderacion y facturacion anterior pueden conservarse por ley. Eliminar la cuenta no cancela una suscripcion existente de Apple o Stripe; gestionela con el proveedor."
        )
    }

    private var manualAppleRevocationMessage: String {
        localized(
            en: "Your SpyClash account was deleted. If you previously used Sign in with Apple, also open your Apple Account settings and remove SpyClash from Sign in with Apple.",
            ru: "Аккаунт SpyClash удалён. Если вы раньше входили через Apple, откройте настройки Аккаунта Apple и удалите SpyClash из раздела «Вход с Apple».",
            es: "Tu cuenta de SpyClash se eliminó. Si antes usaste Iniciar sesión con Apple, abre los ajustes de tu Cuenta de Apple y elimina SpyClash de Iniciar sesión con Apple."
        )
    }

    var body: some View {
        PageChrome(eyebrow: copy.eyebrow, status: "") {
            VStack(alignment: .leading, spacing: 16) {
                spyCard
                profileCard
                statsCard
                legalCard
                dangerZoneCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
        }
        .accessibilityHidden(showDeleteConfirmation)
        .task {
            displayName = appState.user?.callSign ?? ""
            avatar = appState.user?.avatar ?? "🕵️"
            selectedLanguage = appState.language
            selectedCardTheme = SpyCardThemeID(rawValue: appState.user?.spyCardTheme ?? "") ?? .field
            selectedCardAccent = SpyCardAccentID(rawValue: appState.user?.spyCardAccent ?? "") ?? .signalRed
            selectedCardBadge = SpyCardBadgeID(rawValue: appState.user?.spyCardBadge ?? "") ?? .operative
            if !appState.shouldUsePreviewData {
                await appState.refreshSubscription()
            }
            await loadHistory()
        }
        .overlay {
            if showDeleteConfirmation {
                SpyConfirmDialog(
                    title: copy.deleteDialogTitle,
                    message: deleteDialogMessage,
                    confirmTitle: isDeleting ? copy.deletingAccount : copy.deleteDialogAction,
                    cancelTitle: copy.cancel,
                    isBusy: isDeleting
                ) {
                    Task { await deleteAccount() }
                } onCancel: {
                    showDeleteConfirmation = false
                }
                .zIndex(10)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.smooth(duration: 0.22), value: showDeleteConfirmation)
        .sheet(item: $legalSheet) { sheet in
            LegalDocumentSheet(kind: sheet)
                .spyGlobalToastLayer()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
        }
        .onChange(of: showDeleteConfirmation, initial: true) { _, isPresented in
            appState.isShellChromeSuppressed = isPresented
        }
        .onDisappear {
            if showDeleteConfirmation {
                appState.isShellChromeSuppressed = false
            }
        }
        .onChange(of: status) { _, message in
            publishProfileToast(message)
        }
    }

    private var spyCard: some View {
        GeometryReader { proxy in
            let cardHeight = proxy.size.width / 1.50
            let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    SpyBrandMark()
                        .frame(width: 28, height: 36)
                        .offset(x: -2)

                    HStack(spacing: 6) {
                        Text(cardBadgeGlyph(selectedCardBadge))
                            .foregroundStyle(spyCardAccentColor)
                        Text(cardBadgeTitle(selectedCardBadge).uppercased())
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.6)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(spyCardAccentColor.opacity(0.075), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(spyCardAccentColor.opacity(0.30), lineWidth: 0.75)
                    )

                    Spacer(minLength: 12)
                }
                .padding(.leading, 13)
                .padding(.trailing, 17)
                .frame(height: 50)

                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 13) {
                        Text(avatar)
                            .font(.system(size: 29))
                            .frame(width: 52, height: 52)
                            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(spyCardAccentColor.opacity(0.38), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profileCallSign.uppercased())
                                .font(SpyTheme.brandFont(size: 24))
                                .tracking(0.9)
                                .foregroundStyle(.white)
                                .spyFitted(lines: 1, scale: 0.62)

                            Text("SPYID • \(appState.user?.spyID ?? "UNASSIGNED")")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .tracking(0.08)
                                .foregroundStyle(Color.white.opacity(0.38))
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 9) {
                        spyCardMetric(
                            copy.rating,
                            value: "\(rating >= 0 ? "+" : "")\(rating)",
                            accent: SpyTheme.red
                        )
                        spyCardMetric(copy.games, value: "\(gamesCount)", accent: SpyTheme.amber)
                        spyCardMetric(
                            copy.rate,
                            value: "\(winRate)%",
                            accent: SpyTheme.green
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 17)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .frame(width: proxy.size.width, height: cardHeight)
            .background {
                ZStack {
                    cardShape
                        .fill(.ultraThinMaterial)
                        .opacity(selectedCardTheme == .field ? 1 : 0.46)

                    cardShape
                        .fill(Color.black.opacity(selectedCardTheme == .blacksite ? 0.78 : 0.34))

                    cardShape
                        .fill(
                            LinearGradient(
                                colors: spyCardThemeColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    cardShape
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.10), .clear],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.58
                            )
                        )

                    cardShape
                        .fill(
                            RadialGradient(
                                colors: [spyCardAccentColor.opacity(0.11), .clear],
                                center: .bottomTrailing,
                                startRadius: 0,
                                endRadius: proxy.size.width * 0.66
                            )
                        )

                    SpyCardSurfacePattern(
                        theme: selectedCardTheme,
                        accent: spyCardAccentColor
                    )
                    .clipShape(cardShape)
                }
            }
            .clipShape(cardShape)
            .overlay {
                cardShape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.white.opacity(0.07),
                                spyCardAccentColor.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                cardShape
                    .inset(by: 1.5)
                    .stroke(Color.white.opacity(0.035), lineWidth: 0.75)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.20), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 30)
            }
            .overlay(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [
                        .clear,
                        spyCardAccentColor.opacity(appState.hasFullAccess ? 0.88 : 0.42),
                        Color.white.opacity(0.16),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                    .frame(width: 76, height: 1.5)
                    .padding(.trailing, 22)
                    .padding(.bottom, 1)
                    .shadow(color: spyCardAccentColor.opacity(appState.hasFullAccess ? 0.28 : 0.10), radius: 5)
            }
            .background {
                ZStack {
                    cardShape
                        .stroke(Color.black.opacity(0.90), lineWidth: 1)
                        .shadow(color: .black.opacity(0.38), radius: 14)

                    cardShape
                        .stroke(spyCardAccentColor.opacity(0.18), lineWidth: 1)
                        .shadow(color: spyCardAccentColor.opacity(0.11), radius: 10)
                }
            }
            .animation(.smooth(duration: 0.28), value: selectedCardTheme)
            .animation(.smooth(duration: 0.22), value: selectedCardAccent)
            .animation(.smooth(duration: 0.22), value: selectedCardBadge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spyCardAccessibilityLabel)
        }
        .aspectRatio(1.50, contentMode: .fit)
        .spyWebEntrance(delay: 0, duration: 0.50, y: 18, scale: 0.98)
    }

    private var profileCallSign: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? appState.user?.callSign.nilIfBlank
            ?? "OPERATIVE"
    }

    private var spyCardAccessibilityLabel: String {
        "SPYCARD, \(profileCallSign), SPYID \(appState.user?.spyID ?? "unassigned"), \(copy.games) \(gamesCount), \(copy.rating) \(rating), \(copy.rate) \(winRate) percent"
    }

    private var spyCardAccentColor: Color {
        cardAccentColor(selectedCardAccent)
    }

    private var spyCardThemeColors: [Color] {
        switch selectedCardTheme {
        case .field:
            [Color.white.opacity(0.085), Color.white.opacity(0.018), Color.black.opacity(0.24)]
        case .blacksite:
            [Color.white.opacity(0.035), Color.black.opacity(0.42), Color.black.opacity(0.82)]
        case .dossier:
            [SpyTheme.red.opacity(0.14), Color.white.opacity(0.025), Color.black.opacity(0.46)]
        }
    }

    private func spyCardMetric(_ title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SpyTheme.brandFont(size: 20))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(0.20), radius: 6)
            Text(title.uppercased())
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(accent.opacity(0.58))
                .spyFitted(scale: 0.60)
        }
        .frame(width: 58, alignment: .leading)
    }

    private var profileCard: some View {
        SpyPanel(motionDelay: 0.25) {
            VStack(alignment: .leading, spacing: 14) {
                SpySceneKicker(
                    title: localized(en: "IDENTITY SETTINGS", ru: "НАСТРОЙКИ ЛИЧНОСТИ", es: "AJUSTES DE IDENTIDAD"),
                    status: nil,
                    accent: SpyTheme.muted
                )

                Text(copy.selectAvatar)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)

                avatarCategory(
                    title: localized(en: "OPERATIVE IDENTITIES", ru: "ОБРАЗЫ ОПЕРАТИВНИКА", es: "IDENTIDADES OPERATIVAS"),
                    avatars: availableAvatars
                )

                spyCardCustomization

                SpyInput(
                    label: copy.displayName,
                    placeholder: copy.callSignPlaceholder,
                    text: $displayName,
                    icon: "person.crop.circle.fill",
                    autocapitalization: .words,
                    height: 50,
                    maxLength: 48
                )

                languageSelector

                RadarPolicySettingsView()

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        SpyPrimaryCommandLabel(
                            title: copy.savingProfile,
                            detail: nil,
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                    } else {
                        SpyPrimaryCommandLabel(
                            title: copy.saveProfile,
                            detail: nil,
                            systemImage: "checkmark.seal.fill"
                        )
                    }
                }
                .buttonStyle(SpyPrimaryCommandStyle())

            }
        }
    }

    private func publishProfileToast(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard status == message else { return }
            appState.showToast(
                message,
                kind: statusKind == .success ? .success : .error
            )
            status = ""
            statusKind = nil
        }
    }

    private var statsCard: some View {
        SpyPanel(accent: SpyTheme.green, motionDelay: 0.40) {
            VStack(alignment: .leading, spacing: 14) {
                Text(copy.archive)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                HStack(spacing: 12) {
                    stat(copy.rating, "\(rating >= 0 ? "+" : "")\(rating)")
                    stat(copy.games, "\(gamesCount)")
                    stat(copy.rate, "\(winRate)%")
                }
                HStack(spacing: 8) {
                    statPill(copy.wins, "\(winCount)", color: SpyTheme.green)
                    statPill(copy.spy, "\(spyGames)", color: SpyTheme.red)
                    statPill(copy.detective, "\(detectiveGames)", color: .white.opacity(0.74))
                }
            }
        }
    }

    private var legalCard: some View {
        SpyPanel(motionDelay: 0.48) {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy.legal)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)

                Text(copy.legalHint)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                legalButton(copy.privacy, kind: .privacy, icon: "hand.raised.fill")
                legalButton(copy.terms, kind: .terms, icon: "doc.text.fill")
                legalButton(
                    localized(en: "THIRD-PARTY LICENSES", ru: "СТОРОННИЕ ЛИЦЕНЗИИ", es: "LICENCIAS DE TERCEROS"),
                    kind: .acknowledgements,
                    icon: "checkmark.seal.fill"
                )
            }
        }
    }

    private var dangerZoneCard: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0.56) {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy.dangerZone)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)
                    .spyKicker(lines: 2)

                Text(copy.dangerBody)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    HapticManager.shared.fire(.buttonPress)
                    status = ""
                    statusKind = nil
                    showDeleteConfirmation = true
                } label: {
                    SpyActionLabel(
                        title: copy.deleteAccount,
                        systemImage: "trash.fill",
                        tracking: 0.02,
                        lines: 2
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isDeleting)
                .accessibilityIdentifier("profile.deleteAccount")
                .accessibilityHint(deleteDialogMessage)
            }
        }
    }

    private func legalButton(_ title: String, kind: LegalSheetKind, icon: String) -> some View {
        Button {
            HapticManager.shared.fire(.buttonPress)
            legalSheet = kind
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.06)
                    .foregroundStyle(.white)
                    .spyFitted(scale: 0.62)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(SpyTheme.dim)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(SpyTheme.black)
            .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func avatarCategory(
        title: String,
        avatars: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.09)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.64)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(Array(avatars.enumerated()), id: \.element) { index, item in
                    avatarButton(item, index: index)
                }
            }
        }
    }

    private func avatarButton(_ item: String, index: Int) -> some View {
        let isSelected = avatar == item

        return Button {
            avatar = item
            HapticManager.shared.fire(.tabSelection)
        } label: {
            Text(item)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(isSelected ? SpyTheme.red.opacity(0.12) : SpyTheme.panelDeep)
                .overlay(Rectangle().stroke(isSelected ? SpyTheme.red : SpyTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.90))
        .accessibilityLabel(localized(en: "Avatar \(item)", ru: "Аватар \(item)", es: "Avatar \(item)"))
        .spyWebEntrance(delay: Double(index) * 0.04, duration: 0.35, y: 0, scale: 0.8)
    }

    private var spyCardCustomization: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(en: "// SPYCARD STUDIO", ru: "// SPYCARD СТУДИЯ", es: "// ESTUDIO SPYCARD"))
                .font(SpyTheme.micro)
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker(lines: 2)

            VStack(spacing: 7) {
                customizationRow(label: localized(en: "SKIN", ru: "ОБШИВКА", es: "ESTILO")) {
                    HStack(spacing: 6) {
                        ForEach(SpyCardThemeID.allCases) { item in
                            themeSwatch(item)
                        }
                    }
                }

                customizationRow(label: localized(en: "SIGNAL", ru: "СВЕТ", es: "SENAL")) {
                    HStack(spacing: 6) {
                        ForEach(SpyCardAccentID.allCases) { item in
                            accentSwatch(item)
                        }
                    }
                }

                customizationRow(label: localized(en: "CLEARANCE", ru: "ДОПУСК", es: "ACCESO")) {
                    HStack(spacing: 6) {
                        ForEach(SpyCardBadgeID.allCases) { item in
                            badgeSwatch(item)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(8)
            .background(SpyTheme.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SpyTheme.stroke, lineWidth: 1)
            )

        }
        .padding(.top, 4)
    }

    private func customizationRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(0.55)
                .foregroundStyle(SpyTheme.faint)
                .frame(width: 48, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func themeSwatch(_ item: SpyCardThemeID) -> some View {
        let isSelected = selectedCardTheme == item

        return Button {
            selectCardTheme(item)
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(themeSwatchGradient(item))
                    .overlay(SpyCardSurfacePattern(theme: item, accent: spyCardAccentColor).opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    Text(cardThemeTitle(item))
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .padding(6)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(spyCardAccentColor, in: Circle())
                        .padding(4)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? spyCardAccentColor : SpyTheme.strokeStrong, lineWidth: isSelected ? 1.25 : 0.75)
            )
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .accessibilityLabel(cardThemeTitle(item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accentSwatch(_ item: SpyCardAccentID) -> some View {
        let isSelected = selectedCardAccent == item
        let color = cardAccentColor(item)

        return Button {
            selectedCardAccent = item
            HapticManager.shared.fire(.tabSelection)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(isSelected ? 0.75 : 0.15), radius: 4)

                Text(cardAccentTitle(item))
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.15)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

            }
            .foregroundStyle(isSelected ? color : SpyTheme.muted)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? color.opacity(0.11) : SpyTheme.control, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? color.opacity(0.85) : SpyTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .accessibilityLabel(cardAccentTitle(item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badgeSwatch(_ item: SpyCardBadgeID) -> some View {
        let isSelected = selectedCardBadge == item

        return Button {
            selectCardBadge(item)
        } label: {
            HStack(spacing: 5) {
                Text(cardBadgeGlyph(item))
                    .foregroundStyle(isSelected ? spyCardAccentColor : SpyTheme.dim)

                Text(cardBadgeTitle(item))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

            }
            .font(.system(size: 6.5, weight: .black, design: .monospaced))
            .tracking(0.2)
            .foregroundStyle(isSelected ? .white : SpyTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 34)
            .background(isSelected ? spyCardAccentColor.opacity(0.10) : SpyTheme.control, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? spyCardAccentColor.opacity(0.85) : SpyTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .accessibilityLabel(cardBadgeTitle(item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func themeSwatchGradient(_ item: SpyCardThemeID) -> LinearGradient {
        let colors: [Color]
        switch item {
        case .field:
            colors = [Color(red: 0.10, green: 0.12, blue: 0.13), Color.black]
        case .blacksite:
            colors = [Color(red: 0.055, green: 0.055, blue: 0.065), Color.black]
        case .dossier:
            colors = [SpyTheme.red.opacity(0.26), Color(red: 0.10, green: 0.055, blue: 0.055), Color.black]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func selectCardTheme(_ item: SpyCardThemeID) {
        selectedCardTheme = item
        HapticManager.shared.fire(.tabSelection)
    }

    private func selectCardBadge(_ item: SpyCardBadgeID) {
        selectedCardBadge = item
        HapticManager.shared.fire(.tabSelection)
    }

    private func cardThemeTitle(_ item: SpyCardThemeID) -> String {
        switch item {
        case .field: localized(en: "FIELD", ru: "ПОЛЕ", es: "CAMPO")
        case .blacksite: localized(en: "BLACKSITE", ru: "БЛЭКСАЙТ", es: "BLACKSITE")
        case .dossier: localized(en: "DOSSIER", ru: "ДОСЬЕ", es: "DOSSIER")
        }
    }

    private func cardAccentTitle(_ item: SpyCardAccentID) -> String {
        switch item {
        case .signalRed: localized(en: "RED", ru: "КРАСНЫЙ", es: "ROJO")
        case .clearanceAmber: localized(en: "AMBER", ru: "ЯНТАРЬ", es: "AMBAR")
        case .verifiedGreen: localized(en: "GREEN", ru: "ЗЕЛЕНЫЙ", es: "VERDE")
        }
    }

    private func cardBadgeTitle(_ item: SpyCardBadgeID) -> String {
        switch item {
        case .operative: localized(en: "OPERATIVE", ru: "ОПЕРАТИВ", es: "OPERATIVO")
        case .ghost: localized(en: "GHOST", ru: "ПРИЗРАК", es: "FANTASMA")
        case .analyst: localized(en: "ANALYST", ru: "АНАЛИТИК", es: "ANALISTA")
        case .handler: localized(en: "HANDLER", ru: "КУРАТОР", es: "CONTROL")
        }
    }

    private func cardBadgeGlyph(_ item: SpyCardBadgeID) -> String {
        switch item {
        case .operative: "◆"
        case .ghost: "◌"
        case .analyst: "⌁"
        case .handler: "▲"
        }
    }

    private func cardAccentColor(_ item: SpyCardAccentID) -> Color {
        switch item {
        case .signalRed: SpyTheme.red
        case .clearanceAmber: SpyTheme.amber
        case .verifiedGreen: SpyTheme.green
        }
    }

    private var languageSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(copy.languageLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)

                if isSavingLanguage {
                    SpySpinner(size: 16, accent: SpyTheme.red)
                }
            }

            HStack(spacing: 8) {
                ForEach(AppLanguage.allCases) { language in
                    languageChip(language)
                }
            }
        }
    }

    private func languageChip(_ language: AppLanguage) -> some View {
        let isSelected = selectedLanguage == language

        return Button {
            selectLanguage(language)
        } label: {
            VStack(spacing: 4) {
                Text(language.shortCode)
                    .font(.system(size: 13, weight: .black, design: .default))
                    .tracking(0.04)

                Text(language.title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .default))
                    .tracking(0.02)
                    .spyFitted(lines: 2, scale: 0.66, alignment: .center)
            }
            .foregroundStyle(isSelected ? .white : SpyTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(isSelected ? SpyTheme.red : SpyTheme.dark)
            .overlay(Rectangle().stroke(isSelected ? Color.clear : SpyTheme.strokeStrong))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(isSavingLanguage)
        .animation(.smooth(duration: 0.24), value: isSelected)
    }

    private var winCount: Int {
        history.filter { $0.won == true }.count
    }

    private var gamesCount: Int {
        history.count
    }

    private var winRate: Int {
        guard gamesCount > 0 else { return 0 }
        return Int((Double(winCount) / Double(gamesCount) * 100).rounded())
    }

    private var rating: Int {
        history.reduce(0) { partial, item in
            if item.won == true {
                partial + (item.role == "detective" ? 30 : 60)
            } else {
                partial + (item.role == "detective" ? -20 : -40)
            }
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }

    private var spyGames: Int {
        history.filter { $0.role == "spy" }.count
    }

    private var detectiveGames: Int {
        history.filter { $0.role == "detective" }.count
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()
            Text(value)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statPill(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.66)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(SpyTheme.dark)
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func loadHistory() async {
        guard let user = appState.user else { return }

        if appState.shouldUsePreviewData {
            history = GameHistory.previewArchive
            return
        }

        history = (try? await appState.client.gameHistory(
            userID: user.id,
            email: user.email,
            limit: nil
        )) ?? []
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            appState.user = try await appState.client.updateProfile(
                displayName: displayName,
                avatar: avatar,
                language: selectedLanguage,
                spyCardTheme: selectedCardTheme,
                spyCardAccent: selectedCardAccent,
                spyCardBadge: selectedCardBadge
            )
            try await appState.setLanguage(selectedLanguage, syncRemote: false)
            status = appState.language.profile.saved
            statusKind = .success
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func selectLanguage(_ language: AppLanguage) {
        guard selectedLanguage != language else { return }

        selectedLanguage = language
        status = ""
        statusKind = nil
        HapticManager.shared.fire(.tabSelection)

        Task {
            isSavingLanguage = true
            defer { isSavingLanguage = false }

            do {
                try await appState.setLanguage(language)
                status = language.languageSavedMessage
                statusKind = .success
            } catch {
                status = language.languageFailedMessage
                statusKind = .error
                HapticManager.shared.fire(.notification(.warning))
            }
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            let result = try await appState.client.deleteAccount()
            showDeleteConfirmation = false
            let manualNotice = result.manualAppleRevocationRequired
                ? manualAppleRevocationMessage
                : nil
            // Clear the deleted account's bearer material immediately. The
            // root-level notice survives the Profile view disappearing.
            appState.logout()
            appState.accountDeletionManualRevocationNotice = manualNotice
        } catch {
            status = error.localizedDescription.uppercased()
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }
}

struct SpyCardSurfacePattern: View {
    let theme: SpyCardThemeID
    let accent: Color

    var body: some View {
        Canvas { context, size in
            switch theme {
            case .field:
                drawFieldGrid(in: &context, size: size)
            case .blacksite:
                drawBlacksitePanels(in: &context, size: size)
            case .dossier:
                drawDossierMarks(in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawFieldGrid(in context: inout GraphicsContext, size: CGSize) {
        let spacing = max(18, size.width / 13)
        var grid = Path()

        stride(from: spacing, through: size.width, by: spacing).forEach { x in
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: spacing, through: size.height, by: spacing).forEach { y in
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(Color.white.opacity(0.026)), lineWidth: 0.5)

        let center = CGPoint(x: size.width * 0.83, y: size.height * 0.69)
        var reticle = Path()
        reticle.addEllipse(in: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
        reticle.move(to: CGPoint(x: center.x - 24, y: center.y))
        reticle.addLine(to: CGPoint(x: center.x - 9, y: center.y))
        reticle.move(to: CGPoint(x: center.x + 9, y: center.y))
        reticle.addLine(to: CGPoint(x: center.x + 24, y: center.y))
        reticle.move(to: CGPoint(x: center.x, y: center.y - 24))
        reticle.addLine(to: CGPoint(x: center.x, y: center.y - 9))
        reticle.move(to: CGPoint(x: center.x, y: center.y + 9))
        reticle.addLine(to: CGPoint(x: center.x, y: center.y + 24))
        context.stroke(reticle, with: .color(accent.opacity(0.16)), lineWidth: 0.7)
    }

    private func drawBlacksitePanels(in context: inout GraphicsContext, size: CGSize) {
        let panels: [(CGFloat, CGFloat)] = [(0.76, 0.055), (0.84, 0.035), (0.91, 0.02)]
        for (position, opacity) in panels {
            var panel = Path()
            panel.move(to: CGPoint(x: size.width * position, y: 0))
            panel.addLine(to: CGPoint(x: size.width * min(position + 0.08, 1.04), y: 0))
            panel.addLine(to: CGPoint(x: size.width * max(position - 0.08, 0), y: size.height))
            panel.addLine(to: CGPoint(x: size.width * max(position - 0.16, -0.04), y: size.height))
            panel.closeSubpath()
            context.fill(panel, with: .color(Color.white.opacity(opacity)))
        }

        var accessRail = Path()
        accessRail.move(to: CGPoint(x: size.width * 0.925, y: size.height * 0.18))
        accessRail.addLine(to: CGPoint(x: size.width * 0.925, y: size.height * 0.82))
        context.stroke(accessRail, with: .color(accent.opacity(0.32)), lineWidth: 1)
    }

    private func drawDossierMarks(in context: inout GraphicsContext, size: CGSize) {
        let left = size.width * 0.68
        let right = size.width * 0.92
        let lineColor = Color.white.opacity(0.06)

        for index in 0..<5 {
            let y = size.height * (0.18 + CGFloat(index) * 0.095)
            var line = Path()
            line.move(to: CGPoint(x: left, y: y))
            line.addLine(to: CGPoint(x: right - CGFloat(index % 2) * size.width * 0.07, y: y))
            context.stroke(line, with: .color(lineColor), lineWidth: 1)
        }

        var stamp = Path()
        stamp.addEllipse(in: CGRect(
            x: size.width * 0.73,
            y: size.height * 0.59,
            width: size.width * 0.16,
            height: size.width * 0.16
        ))
        context.stroke(stamp, with: .color(accent.opacity(0.18)), lineWidth: 1.2)

        var registration = Path()
        let inset = size.width * 0.055
        let length = size.width * 0.045
        registration.move(to: CGPoint(x: inset, y: inset + length))
        registration.addLine(to: CGPoint(x: inset, y: inset))
        registration.addLine(to: CGPoint(x: inset + length, y: inset))
        registration.move(to: CGPoint(x: size.width - inset - length, y: size.height - inset))
        registration.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
        registration.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset - length))
        context.stroke(registration, with: .color(accent.opacity(0.24)), lineWidth: 0.8)
    }
}

private enum ProfileStatusKind {
    case success
    case error
}
