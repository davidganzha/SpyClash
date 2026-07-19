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

    private let basicAvatars = ["🕵️", "🥷", "🧠", "🎭"]
    private let premiumAvatars = ["🃏", "👁️", "🔥", "⚡️", "🎯", "🛡️"]

    private var copy: ProfileCopy {
        appState.language.profile
    }

    var body: some View {
        PageChrome(eyebrow: copy.eyebrow, status: copy.lockedStatus) {
            VStack(alignment: .leading, spacing: 16) {
                spyCard
                profileCard
                statsCard
                legalCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
        }
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
                    message: copy.deleteDialogMessage,
                    confirmTitle: copy.deleteDialogAction,
                    cancelTitle: copy.cancel,
                    isBusy: isDeleting
                ) {
                    Task { await deleteAccount() }
                } onCancel: {
                    showDeleteConfirmation = false
                }
                .zIndex(10)
            }
        }
        .animation(.smooth(duration: 0.22), value: showDeleteConfirmation)
        .sheet(item: $legalSheet) { sheet in
            LegalDocumentSheet(kind: sheet)
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

                    HStack(spacing: 5) {
                        Text(cardBadgeGlyph(selectedCardBadge))
                            .foregroundStyle(spyCardAccentColor)
                        Text(cardBadgeTitle(selectedCardBadge).uppercased())
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.6)

                    Spacer(minLength: 12)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(membershipAccent)
                            .frame(width: 5, height: 5)

                        Text(membershipTitle)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.12)
                            .foregroundStyle(membershipAccent)
                    }
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
                            value: hasAdvancedStatistics ? "\(rating >= 0 ? "+" : "")\(rating)" : "—",
                            accent: hasAdvancedStatistics ? SpyTheme.red : SpyTheme.muted
                        )
                        spyCardMetric(copy.games, value: "\(gamesCount)", accent: SpyTheme.amber)
                        spyCardMetric(
                            copy.rate,
                            value: hasAdvancedStatistics ? "\(winRate)%" : "—",
                            accent: hasAdvancedStatistics ? SpyTheme.green : SpyTheme.muted
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

                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.055),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .rotationEffect(.degrees(-18))
                    .offset(x: -proxy.size.width * 0.24)
                    .mask(cardShape)
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
                        spyCardAccentColor.opacity(appState.hasLimitlessAccess ? 0.88 : 0.42),
                        Color.white.opacity(0.16),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                    .frame(width: 76, height: 1.5)
                    .padding(.trailing, 22)
                    .padding(.bottom, 1)
                    .shadow(color: spyCardAccentColor.opacity(appState.hasLimitlessAccess ? 0.28 : 0.10), radius: 5)
            }
            .shadow(color: spyCardAccentColor.opacity(0.09), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.42), radius: 24, y: 14)
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
        let identity = "SPYCARD, \(profileCallSign), SPYID \(appState.user?.spyID ?? "unassigned"), \(membershipTitle), \(copy.games) \(gamesCount)"
        guard hasAdvancedStatistics else {
            return "\(identity), \(localized(en: "advanced statistics locked", ru: "расширенная статистика закрыта", es: "estadisticas avanzadas bloqueadas"))"
        }
        return "\(identity), \(copy.rating) \(rating), \(copy.rate) \(winRate) percent"
    }

    private var membershipTitle: String {
        switch appState.membershipTier {
        case .limitless:
            "LIMITLESS"
        case .free:
            "FREE"
        case nil:
            if case .unavailable = appState.membershipSyncState {
                localized(en: "UNAVAILABLE", ru: "НЕДОСТУПЕН", es: "NO DISPONIBLE")
            } else {
                localized(en: "SYNCING", ru: "СИНХРОНИЗАЦИЯ", es: "SINCRONIZANDO")
            }
        }
    }

    private var membershipAccent: Color {
        switch appState.membershipTier {
        case .limitless:
            SpyTheme.red
        case .free:
            Color(red: 142 / 255, green: 142 / 255, blue: 146 / 255)
        case nil:
            SpyTheme.amber
        }
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
                    title: localized(en: "BASIC SET", ru: "БАЗОВЫЙ НАБОР", es: "SET BASICO"),
                    badge: "FREE",
                    avatars: basicAvatars,
                    isPremium: false
                )

                avatarCategory(
                    title: localized(en: "PREMIUM IDENTITIES", ru: "ПРЕМИУМ ОБРАЗЫ", es: "IDENTIDADES PREMIUM"),
                    badge: "LIMITLESS",
                    avatars: premiumAvatars,
                    isPremium: true
                )

                spyCardCustomization

                SpyInput(
                    label: copy.displayName,
                    placeholder: copy.callSignPlaceholder,
                    text: $displayName,
                    icon: "person.crop.circle.fill",
                    autocapitalization: .words,
                    height: 50
                )

                languageSelector

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
                .disabled(isSaving || isSavingLanguage || isDeleting || appState.isSynchronizingLanguage)

                if !status.isEmpty {
                    SpyToast(
                        text: status,
                        kind: statusKind == .success ? .success : .error
                    )
                }
            }
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
                if hasAdvancedStatistics {
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
                } else {
                    HStack(spacing: 12) {
                        stat(copy.games, "\(gamesCount)")

                        Button {
                            appState.presentedSheet = .pricing
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 15, weight: .black))
                                Text(localized(
                                    en: "ADVANCED STATISTICS // LIMITLESS",
                                    ru: "РАСШИРЕННАЯ СТАТИСТИКА // LIMITLESS",
                                    es: "ESTADISTICAS AVANZADAS // LIMITLESS"
                                ))
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(0.06)
                                .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                            }
                            .foregroundStyle(SpyTheme.red)
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .background(SpyTheme.red.opacity(0.05))
                            .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.28)))
                        }
                        .buttonStyle(SpyWebPressStyle())
                    }
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
        badge: String,
        avatars: [String],
        isPremium: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.09)
                    .foregroundStyle(isPremium ? SpyTheme.red : SpyTheme.dim)
                    .spyFitted(scale: 0.64)

                Text(badge)
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(isPremium ? SpyTheme.red : SpyTheme.muted)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background((isPremium ? SpyTheme.red : SpyTheme.muted).opacity(0.08))
                    .overlay(
                        Rectangle()
                            .stroke((isPremium ? SpyTheme.red : SpyTheme.muted).opacity(0.34), lineWidth: 1)
                    )

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(Array(avatars.enumerated()), id: \.element) { index, item in
                    avatarButton(item, index: index, isPremium: isPremium)
                }
            }

            if isPremium && !hasPremiumAvatarAccess {
                Text(premiumAvatarLockMessage)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.06)
                .foregroundStyle(SpyTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func avatarButton(_ item: String, index: Int, isPremium: Bool) -> some View {
        let isSelected = avatar == item
        let isPreserved = isPremium && item == appState.user?.avatar && !hasPremiumAvatarAccess
        let isLocked = isPremium && !hasPremiumAvatarAccess && !isPreserved
        let border = isSelected
            ? SpyTheme.red
            : (isLocked ? SpyTheme.red.opacity(0.28) : SpyTheme.stroke)

        return Button {
            if isLocked {
                appState.presentedSheet = .pricing
            } else {
                avatar = item
                HapticManager.shared.fire(.tabSelection)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(item)
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
                    .opacity(isLocked ? 0.34 : 1)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(SpyTheme.red, in: Circle())
                        .offset(x: 4, y: -4)
                } else if isPreserved {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(SpyTheme.amber)
                        .offset(x: 4, y: -4)
                }
            }
            .frame(width: 44, height: 44)
            .background(isSelected ? SpyTheme.red.opacity(0.12) : SpyTheme.panelDeep)
            .overlay(Rectangle().stroke(border, lineWidth: 1))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.90))
        .accessibilityLabel(
            isLocked
                ? localized(en: "Premium avatar, locked", ru: "Премиум аватар, закрыт", es: "Avatar premium bloqueado")
                : localized(en: "Avatar \(item)", ru: "Аватар \(item)", es: "Avatar \(item)")
        )
        .spyWebEntrance(delay: Double(index) * 0.04, duration: 0.35, y: 0, scale: 0.8)
    }

    private var spyCardCustomization: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(localized(en: "// SPYCARD CONFIG", ru: "// НАСТРОЙКА SPYCARD", es: "// CONFIGURAR SPYCARD"))
                    .font(SpyTheme.micro)
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker(lines: 2)

                Text("LIMITLESS")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(SpyTheme.red.opacity(0.08))
                    .overlay(Rectangle().stroke(SpyTheme.red.opacity(0.34), lineWidth: 1))
            }

            customizationLabel(localized(en: "FIELD SKIN", ru: "ОБШИВКА", es: "ESTILO"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(SpyCardThemeID.allCases) { item in
                    customizationButton(
                        title: cardThemeTitle(item),
                        icon: cardThemeIcon(item),
                        isSelected: selectedCardTheme == item,
                        isLocked: item.requiresLimitless && !hasSpyCardCustomizationAccess && selectedCardTheme != item
                    ) {
                        selectCardTheme(item)
                    }
                }
            }

            customizationLabel(localized(en: "SIGNAL ACCENT", ru: "СИГНАЛЬНЫЙ ЦВЕТ", es: "ACENTO"))
            HStack(spacing: 8) {
                ForEach(SpyCardAccentID.allCases) { item in
                    accentButton(item)
                }
            }

            customizationLabel(localized(en: "CLEARANCE BADGE", ru: "ЗНАК ДОПУСКА", es: "INSIGNIA"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(SpyCardBadgeID.allCases) { item in
                    customizationButton(
                        title: cardBadgeTitle(item),
                        icon: cardBadgeGlyph(item),
                        isSelected: selectedCardBadge == item,
                        isLocked: item.requiresLimitless && !hasSpyCardCustomizationAccess && selectedCardBadge != item
                    ) {
                        selectCardBadge(item)
                    }
                }
            }

            if !hasSpyCardCustomizationAccess {
                Text(localized(
                    en: "BASE CARD ACTIVE // LIMITLESS UNLOCKS ALL FIELD SKINS, SIGNALS AND BADGES",
                    ru: "БАЗОВАЯ КАРТА АКТИВНА // LIMITLESS ОТКРЫВАЕТ ВСЕ ОБШИВКИ, СИГНАЛЫ И ЗНАКИ",
                    es: "TARJETA BASE ACTIVA // LIMITLESS DESBLOQUEA TODOS LOS ESTILOS, ACENTOS E INSIGNIAS"
                ))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(SpyTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private func customizationLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(SpyTheme.faint)
    }

    private func customizationButton(
        title: String,
        icon: String,
        isSelected: Bool,
        isLocked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(icon)
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.35)
                    .spyFitted(scale: 0.58)

                Spacer(minLength: 0)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .black))
                }
            }
            .foregroundStyle(isSelected ? SpyTheme.red : (isLocked ? SpyTheme.faint : SpyTheme.muted))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? SpyTheme.red.opacity(0.09) : SpyTheme.black)
            .overlay(Rectangle().stroke(isSelected ? SpyTheme.red : SpyTheme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func accentButton(_ item: SpyCardAccentID) -> some View {
        let isSelected = selectedCardAccent == item
        let isLocked = item.requiresLimitless && !hasSpyCardCustomizationAccess && selectedCardAccent != item
        let color = cardAccentColor(item)

        return Button {
            if isLocked {
                appState.presentedSheet = .pricing
            } else {
                selectedCardAccent = item
                HapticManager.shared.fire(.tabSelection)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .shadow(color: color.opacity(isSelected ? 0.55 : 0), radius: 5)

                Text(cardAccentTitle(item))
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.25)
                    .spyFitted(scale: 0.55)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .black))
                }
            }
            .foregroundStyle(isSelected ? color : (isLocked ? SpyTheme.faint : SpyTheme.muted))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? color.opacity(0.07) : SpyTheme.black)
            .overlay(Rectangle().stroke(isSelected ? color : SpyTheme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func selectCardTheme(_ item: SpyCardThemeID) {
        if item.requiresLimitless && !hasSpyCardCustomizationAccess && selectedCardTheme != item {
            appState.presentedSheet = .pricing
        } else {
            selectedCardTheme = item
            HapticManager.shared.fire(.tabSelection)
        }
    }

    private func selectCardBadge(_ item: SpyCardBadgeID) {
        if item.requiresLimitless && !hasSpyCardCustomizationAccess && selectedCardBadge != item {
            appState.presentedSheet = .pricing
        } else {
            selectedCardBadge = item
            HapticManager.shared.fire(.tabSelection)
        }
    }

    private var hasSpyCardCustomizationAccess: Bool {
        appState.hasLimitlessAccess
    }

    private func cardThemeTitle(_ item: SpyCardThemeID) -> String {
        switch item {
        case .field: localized(en: "FIELD", ru: "ПОЛЕ", es: "CAMPO")
        case .blacksite: localized(en: "BLACKSITE", ru: "БЛЭКСАЙТ", es: "BLACKSITE")
        case .dossier: localized(en: "DOSSIER", ru: "ДОСЬЕ", es: "DOSSIER")
        }
    }

    private func cardThemeIcon(_ item: SpyCardThemeID) -> String {
        switch item {
        case .field: "▦"
        case .blacksite: "◼"
        case .dossier: "⌁"
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

    private var hasPremiumAvatarAccess: Bool {
        appState.membershipBenefits?.premiumAvatars == true
    }

    private var hasAdvancedStatistics: Bool {
        appState.membershipBenefits?.advancedStatistics == true
    }

    private var premiumAvatarLockMessage: String {
        if appState.membershipTier == .free {
            return localized(
                en: "LOCKED FOR FREE // TAP AN AVATAR TO VIEW LIMITLESS",
                ru: "ЗАКРЫТО ДЛЯ FREE // НАЖМИ, ЧТОБЫ ОТКРЫТЬ LIMITLESS",
                es: "BLOQUEADO EN FREE // TOCA PARA VER LIMITLESS"
            )
        }

        return localized(
            en: "MEMBERSHIP STATUS REQUIRED // TAP TO VERIFY ACCESS",
            ru: "НУЖЕН СТАТУС ПОДПИСКИ // НАЖМИ ДЛЯ ПРОВЕРКИ",
            es: "SE REQUIERE MEMBRESIA // TOCA PARA VERIFICAR"
        )
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
        .disabled(isSaving || isSavingLanguage || isDeleting || appState.isSynchronizingLanguage)
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
        guard let email = appState.user?.email else { return }

        if appState.shouldUsePreviewData {
            history = GameHistory.previewArchive
            return
        }

        do {
            let loadedHistory = try await appState.client.gameHistory(email: email, limit: nil)
            try Task.checkCancellation()
            guard appState.user?.email == email else { return }
            history = loadedHistory
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription.uppercased()
            statusKind = .error
        }
    }

    private func save() async {
        guard !isSaving, !isSavingLanguage, !isDeleting else { return }
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
        guard selectedLanguage != language,
              !isSaving,
              !isSavingLanguage,
              !isDeleting,
              !appState.isSynchronizingLanguage else { return }

        let previousLanguage = appState.language
        selectedLanguage = language
        isSavingLanguage = true
        status = ""
        statusKind = nil
        HapticManager.shared.fire(.tabSelection)

        Task {
            defer { isSavingLanguage = false }

            do {
                try await appState.setLanguage(language)
                status = language.languageSavedMessage
                statusKind = .success
            } catch {
                selectedLanguage = previousLanguage
                try? await appState.setLanguage(previousLanguage, syncRemote: false)
                status = language.languageFailedMessage
                statusKind = .error
                HapticManager.shared.fire(.notification(.warning))
            }
        }
    }

    private func deleteAccount() async {
        guard !isDeleting, !isSaving, !isSavingLanguage else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await appState.client.deleteAccount()
            showDeleteConfirmation = false
            appState.logout()
        } catch {
            showDeleteConfirmation = false
            status = error.localizedDescription.uppercased()
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }
}

private enum ProfileStatusKind {
    case success
    case error
}
