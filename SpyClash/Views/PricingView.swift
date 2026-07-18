import StoreKit
import SwiftUI

struct PricingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRefreshingAccess = false
    @State private var statusText = ""
    @State private var statusKind: PricingStatusKind?
    @State private var hasAppeared = false
    @State private var revealStep = 0
    @State private var scannerActive = false
    @State private var heroFlash = false

    private var copy: PricingCopy {
        appState.language.pricing
    }

    var body: some View {
        PageChrome(
            eyebrow: pricingEyebrow,
            status: "LIMITLESS",
            showsPageTopEdge: false,
            topReserve: 0
        ) {
            VStack(spacing: 14) {
                premiumUpgradePanel
                legalDetails
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .overlay {
            GeometryReader { proxy in
                sheetCloseButton
                    .position(
                        x: proxy.size.width - 44,
                        y: max(66, proxy.safeAreaInsets.top - 6)
                    )
            }
        }
        .task {
            await runLimitlessPresentation()
        }
        .task {
            await appState.storeKit.loadProduct()
            if !appState.shouldUsePreviewData && appState.membership == nil {
                await appState.synchronizeCommerceAccess()
            }
        }
    }

    private var pricingEyebrow: String {
        localized(en: "// PRICING", ru: "// ПОДПИСКА", es: "// PRICING")
    }

    private var breadcrumbRow: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .black))
                    Text(localized(en: "HOME", ru: "ДОМОЙ", es: "INICIO"))
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.14)
                .foregroundStyle(SpyTheme.dim)
            }
            .buttonStyle(SpyWebPressStyle())
            .spyHitTarget()

            Text("/")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(SpyTheme.strokeStrong)

            Text(localized(en: "PRICING", ru: "ПОДПИСКА", es: "PRICING"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.14)
                .foregroundStyle(SpyTheme.red)

            Spacer(minLength: 12)
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : -8)
    }

    private var sheetCloseButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(SpyTheme.muted)
                .frame(width: 44, height: 44)
                .background(SpyTheme.black.opacity(0.88), in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                .contentShape(CutCornerShape(cut: 8))
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityLabel(localized(en: "CLOSE", ru: "ЗАКРЫТЬ", es: "CERRAR"))
    }

    private var premiumUpgradePanel: some View {
        VStack(spacing: 0) {
            limitlessHero
            capabilitiesSection
            purchaseSection
        }
        .background {
            ZStack {
                SpyTheme.black
                LinearGradient(
                    colors: [
                        SpyTheme.red.opacity(0.14),
                        SpyTheme.redDeep.opacity(0.035),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(CutCornerShape(cut: 14))
        .overlay {
            CutCornerShape(cut: 14)
                .stroke(
                    LinearGradient(
                        colors: [SpyTheme.red.opacity(0.82), SpyTheme.strokeStrong, SpyTheme.redDeep.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.red)
                .padding(1)
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: SpyTheme.red)
                .rotationEffect(.degrees(180))
                .padding(1)
        }
        .shadow(color: SpyTheme.red.opacity(0.20), radius: 28)
        .shadow(color: .black.opacity(0.62), radius: 28, y: 18)
        .overlay {
            if !heroIsRevealed {
                bootSequenceOverlay
                    .clipShape(CutCornerShape(cut: 14))
                    .transition(.opacity)
            }
        }
        .overlay {
            SpyTheme.red
                .opacity(heroFlash ? 0.16 : 0)
                .blendMode(.screen)
                .clipShape(CutCornerShape(cut: 14))
                .allowsHitTesting(false)
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 18)
    }

    private var bootSequenceOverlay: some View {
        GeometryReader { proxy in
            ZStack {
                SpyTheme.black

                LinearGradient(
                    colors: [SpyTheme.red.opacity(0.16), .clear, SpyTheme.redDeep.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, SpyTheme.red.opacity(0.04), SpyTheme.red.opacity(0.52), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 92)
                    .blur(radius: 8)
                    .offset(y: scannerActive ? proxy.size.height + 48 : -118)
                    .animation(
                        .timingCurve(0.20, 0.78, 0.28, 1, duration: 0.58),
                        value: scannerActive
                    )

                VStack(spacing: 18) {
                    ZStack {
                        CutCornerShape(cut: 12)
                            .stroke(SpyTheme.red.opacity(0.18), lineWidth: 1)
                            .frame(width: 92, height: 92)
                            .scaleEffect(scannerActive ? 1.12 : 0.82)
                            .opacity(scannerActive ? 0 : 0.72)

                        CutCornerShape(cut: 10)
                            .stroke(SpyTheme.red.opacity(0.52), lineWidth: 1)
                            .frame(width: 68, height: 68)

                        Image(systemName: "bolt.fill")
                            .font(.system(size: 27, weight: .black))
                            .foregroundStyle(SpyTheme.red)
                            .shadow(color: SpyTheme.red.opacity(0.72), radius: 18)
                    }
                    .animation(.easeOut(duration: 0.46), value: scannerActive)

                    VStack(spacing: 7) {
                        Text("LIMITLESS")
                            .font(SpyTheme.brandFont(size: 30))
                            .tracking(5)
                            .foregroundStyle(.white)

                        Text(localized(
                            en: "PREMIUM CLEARANCE PROTOCOL",
                            ru: "ПРОТОКОЛ ПРЕМИУМ ДОПУСКА",
                            es: "PROTOCOLO DE ACCESO PREMIUM"
                        ))
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.14)
                        .foregroundStyle(SpyTheme.muted)
                    }

                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { index in
                            Rectangle()
                                .fill(SpyTheme.red)
                                .frame(width: 34, height: 2)
                                .scaleEffect(x: scannerActive ? 1 : 0.12, anchor: .leading)
                                .opacity(scannerActive ? 1 : 0.24)
                                .animation(
                                    .easeOut(duration: 0.28).delay(Double(index) * 0.07),
                                    value: scannerActive
                                )
                        }
                    }

                    Text(scannerActive
                         ? localized(en: "CLEARANCE ACCEPTED", ru: "ДОПУСК ПОДТВЕРЖДЕН", es: "ACCESO CONFIRMADO")
                         : localized(en: "ESTABLISHING SECURE LINK", ru: "УСТАНОВКА ЗАЩИЩЕННОГО КАНАЛА", es: "ESTABLECIENDO CANAL SEGURO"))
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.12)
                        .foregroundStyle(scannerActive ? SpyTheme.red : SpyTheme.faint)
                        .contentTransition(.numericText())
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var limitlessHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 34, height: 34)
                    .background(SpyTheme.red.opacity(0.08), in: CutCornerShape(cut: 7))
                    .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.red.opacity(0.50), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(en: "PREMIUM CLEARANCE", ru: "ПРЕМИУМ ДОПУСК", es: "ACCESO PREMIUM"))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.16)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.72)

                    Text(localized(en: "FIELD KIT // LEVEL 01", ru: "ПОЛЕВОЙ НАБОР // УРОВЕНЬ 01", es: "KIT DE CAMPO // NIVEL 01"))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.65)
                }

                Spacer(minLength: 8)
                accessStatusBadge
            }

            ZStack(alignment: .leading) {
                Text("∞")
                    .font(.system(size: 132, weight: .black, design: .default))
                    .foregroundStyle(SpyTheme.red.opacity(0.055))
                    .offset(x: 128, y: -8)
                    .scaleEffect(heroIsRevealed ? 1 : 0.68)
                    .rotationEffect(.degrees(heroIsRevealed ? 0 : -9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    ZStack(alignment: .leading) {
                        Text("LIMITLESS")
                            .font(SpyTheme.brandFont(size: 38))
                            .tracking(6)
                            .opacity(0)

                        if heroIsRevealed {
                            AnimatedTitle(
                                text: "LIMITLESS",
                                delay: 0.02,
                                fontSize: 38,
                                letterSpacing: 6
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                        }
                    }

                    Text(localized(
                        en: "REMOVE THE CEILING FROM EVERY MISSION.",
                        ru: "СНИМИ ОГРАНИЧЕНИЯ С КАЖДОЙ МИССИИ.",
                        es: "ELIMINA LOS LIMITES DE CADA MISION."
                    ))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.65)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            HStack(alignment: .bottom, spacing: 7) {
                if let displayPrice = appState.storeKit.displayPrice {
                    Text(displayPrice)
                        .font(SpyTheme.brandFont(size: 48))
                        .foregroundStyle(SpyTheme.red)
                        .lineLimit(1)

                    Text("/ \(subscriptionPeriodLabel)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.10)
                        .foregroundStyle(SpyTheme.dim)
                        .padding(.bottom, 6)
                } else {
                    Text(localized(
                        en: "PRICE FROM APP STORE",
                        ru: "ЦЕНА ИЗ APP STORE",
                        es: "PRECIO DE APP STORE"
                    ))
                    .font(SpyTheme.brandFont(size: 22))
                    .foregroundStyle(SpyTheme.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Text(capabilityCountLabel)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.faint)
                    .padding(.bottom, 7)
                    .spyFitted(scale: 0.66)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .opacity(heroIsRevealed ? 1 : 0)
        .blur(radius: heroIsRevealed ? 0 : 8)
        .offset(y: heroIsRevealed ? 0 : 14)
        .scaleEffect(heroIsRevealed ? 1 : 0.975, anchor: .top)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .timingCurve(0.16, 0.84, 0.28, 1, duration: 0.48),
            value: heroIsRevealed
        )
    }

    private var accessStatusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(membershipCategoryAccent)
                .frame(width: 6, height: 6)
                .shadow(color: membershipCategoryAccent, radius: 6)

            Text("\(localized(en: "CURRENT", ru: "ТЕКУЩИЙ", es: "ACTUAL")) • \(membershipCategoryLabel)")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.10)
        }
        .foregroundStyle(membershipCategoryAccent)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(membershipCategoryAccent.opacity(0.07), in: CutCornerShape(cut: 6))
        .overlay(CutCornerShape(cut: 6).stroke(membershipCategoryAccent.opacity(0.35), lineWidth: 1))
    }

    private var membershipCategoryLabel: String {
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

    private var membershipCategoryAccent: Color {
        switch appState.membershipTier {
        case .limitless: SpyTheme.green
        case .free: SpyTheme.muted
        case nil: SpyTheme.amber
        }
    }

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(capabilitiesHeading)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.14)
                    .foregroundStyle(SpyTheme.red)

                Spacer()

                Text(capabilityProgressLabel)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.faint)
            }
            .padding(.bottom, 8)

            ForEach(Array(copy.features.enumerated()), id: \.element.id) { index, item in
                capabilityRow(index: index, feature: item)

                if index < copy.features.count - 1 {
                    Rectangle()
                        .fill(SpyTheme.stroke)
                        .frame(height: 1)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(SpyTheme.black.opacity(0.36))
        .overlay(alignment: .top) {
            Rectangle().fill(SpyTheme.red.opacity(0.24)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(SpyTheme.stroke).frame(height: 1)
        }
        .opacity(heroIsRevealed ? 1 : 0)
    }

    private func capabilityRow(index: Int, feature: PricingFeature) -> some View {
        let isPresented = capabilityIsRevealed(index)
        let isUnlocked = isPresented && appState.hasLimitlessAccess

        return HStack(alignment: .center, spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(SpyTheme.faint)
                .frame(width: 20)

            Image(systemName: feature.systemImage)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(isPresented ? SpyTheme.red : SpyTheme.faint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(0.06)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.66)
                Text(feature.detail)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 3, scale: 0.68)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(isUnlocked ? SpyTheme.green.opacity(0.88) : SpyTheme.faint)
                .rotation3DEffect(.degrees(isPresented ? 0 : -72), axis: (x: 0, y: 1, z: 0))
        }
        .frame(minHeight: 58)
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [SpyTheme.red.opacity(0.88), SpyTheme.red.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .scaleEffect(x: isPresented ? 1 : 0, anchor: .leading)
        }
        .opacity(isPresented ? 1 : 0.10)
        .blur(radius: isPresented ? 0 : 2.5)
        .offset(x: isPresented ? 0 : -14)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .timingCurve(0.16, 0.84, 0.28, 1, duration: 0.42),
            value: isPresented
        )
        .accessibilityHidden(!isPresented)
    }

    private var purchaseSection: some View {
        VStack(spacing: 10) {
            Button {
                Task { await performPrimaryAction() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isBusy ? "antenna.radiowaves.left.and.right" : "bolt.fill")
                        .font(.system(size: 17, weight: .black))
                        .symbolEffect(.pulse, options: isBusy ? .repeating : .default, value: isBusy)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(primaryActionTitle)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(0.08)
                            .spyFitted(lines: 2, scale: 0.60)

                        Text(appState.hasLimitlessAccess
                             ? localized(en: "VERIFY PREMIUM CLEARANCE", ru: "ПРОВЕРИТЬ ПРЕМИУМ ДОПУСК", es: "VERIFICAR ACCESO PREMIUM")
                             : appState.membershipTier == .free
                                ? purchaseOfferLine
                                : localized(en: "SYNC ACCOUNT ENTITLEMENT", ru: "СИНХРОНИЗАЦИЯ ДОСТУПА", es: "SINCRONIZAR ACCESO"))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.06)
                            .foregroundStyle(.white.opacity(0.68))
                            .spyFitted(lines: 2, scale: 0.62)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: appState.membershipTier == .free ? "arrow.up.right" : "arrow.clockwise")
                        .font(.system(size: 14, weight: .black))
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(LimitlessCommandButtonStyle())
            .disabled(isBusy)

            HStack(spacing: 8) {
                Button {
                    Task { await restorePurchases() }
                } label: {
                    secondaryActionLabel(
                        localized(en: "RESTORE PURCHASES", ru: "ВОССТАНОВИТЬ ПОКУПКИ", es: "RESTAURAR COMPRAS"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(SpyWebPressStyle())
                .disabled(isBusy)

                if hasAppleEntitlement {
                    Button {
                        Task { await manageSubscription() }
                    } label: {
                        secondaryActionLabel(
                            localized(en: "MANAGE", ru: "УПРАВЛЯТЬ", es: "GESTIONAR"),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .disabled(isBusy)
                }
            }

            if !statusText.isEmpty {
                statusBanner
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                Text(localized(en: "APP STORE PURCHASE", ru: "ПОКУПКА В APP STORE", es: "COMPRA EN APP STORE"))
                Circle().frame(width: 3, height: 3)
                Text(localized(en: "CANCEL ANYTIME", ru: "ОТМЕНА В ЛЮБОЙ МОМЕНТ", es: "CANCELA CUANDO QUIERAS"))
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.06)
            .foregroundStyle(SpyTheme.faint)
            .spyFitted(scale: 0.64, alignment: .center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .opacity(presentationIsComplete ? 1 : 0)
        .blur(radius: presentationIsComplete ? 0 : 5)
        .offset(y: presentationIsComplete ? 0 : 16)
        .allowsHitTesting(presentationIsComplete)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .timingCurve(0.16, 0.84, 0.28, 1, duration: 0.46),
            value: presentationIsComplete
        )
    }

    private var primaryActionTitle: String {
        if isBusy {
            return appState.membershipTier == .free
                ? copy.busyTitle(isActive: false)
                : copy.checkingAccess
        }

        switch appState.membershipTier {
        case .limitless:
            return copy.actionTitle(isActive: true)
        case .free:
            return copy.actionTitle(isActive: false)
        case nil:
            return localized(
                en: "VERIFY MEMBERSHIP",
                ru: "ПРОВЕРИТЬ ПОДПИСКУ",
                es: "VERIFICAR MEMBRESIA"
            )
        }
    }

    private var isBusy: Bool {
        isRefreshingAccess
            || appState.storeKit.purchaseState.isBusy
            || appState.storeKit.isSynchronizingEntitlements
    }

    private var hasAppleEntitlement: Bool {
        appState.membership?.providers.contains("apple") == true
    }

    private var purchaseOfferLine: String {
        if let price = appState.storeKit.displayPrice {
            return "\(price) / \(subscriptionPeriodLabel) // APP STORE"
        }

        switch appState.storeKit.productState {
        case .loading:
            return localized(
                en: "LOADING APP STORE PRICE",
                ru: "ЗАГРУЗКА ЦЕНЫ ИЗ APP STORE",
                es: "CARGANDO PRECIO DE APP STORE"
            )
        case .unavailable:
            return localized(
                en: "APP STORE PRODUCT NOT CONFIGURED",
                ru: "ТОВАР APP STORE ЕЩЕ НЕ НАСТРОЕН",
                es: "PRODUCTO DE APP STORE SIN CONFIGURAR"
            )
        case .idle, .ready:
            return localized(
                en: "PRICE PROVIDED BY APP STORE",
                ru: "ЦЕНА БУДЕТ ПОЛУЧЕНА ИЗ APP STORE",
                es: "PRECIO PROPORCIONADO POR APP STORE"
            )
        }
    }

    private var subscriptionPeriodLabel: String {
        guard let period = appState.storeKit.product?.subscription?.subscriptionPeriod else {
            return localized(en: "WEEK", ru: "НЕДЕЛЯ", es: "SEMANA")
        }

        let value = period.value
        let unit: String
        switch period.unit {
        case .day:
            unit = value == 1
                ? localized(en: "DAY", ru: "ДЕНЬ", es: "DIA")
                : localized(en: "DAYS", ru: "ДНЕЙ", es: "DIAS")
        case .week:
            unit = value == 1
                ? localized(en: "WEEK", ru: "НЕДЕЛЯ", es: "SEMANA")
                : localized(en: "WEEKS", ru: "НЕДЕЛЬ", es: "SEMANAS")
        case .month:
            unit = value == 1
                ? localized(en: "MONTH", ru: "МЕСЯЦ", es: "MES")
                : localized(en: "MONTHS", ru: "МЕСЯЦЕВ", es: "MESES")
        case .year:
            unit = value == 1
                ? localized(en: "YEAR", ru: "ГОД", es: "ANO")
                : localized(en: "YEARS", ru: "ЛЕТ", es: "ANOS")
        @unknown default:
            unit = localized(en: "PERIOD", ru: "ПЕРИОД", es: "PERIODO")
        }

        return value == 1 ? unit : "\(value) \(unit)"
    }

    private var subscriptionLegalText: String {
        let price = appState.storeKit.displayPrice
            ?? localized(en: "The displayed price", ru: "Указанная цена", es: "El precio mostrado")
        let period = subscriptionPeriodLabel.lowercased()

        return localized(
            en: "\(price) per \(period). Payment is charged to your Apple Account at confirmation. The subscription renews automatically unless cancelled at least 24 hours before the current period ends. LIMITLESS access stays synced with your SpyClash account.",
            ru: "\(price) за период (\(period)). Оплата списывается с аккаунта Apple при подтверждении. Подписка продлевается автоматически, если не отменить ее минимум за 24 часа до конца текущего периода. LIMITLESS синхронизируется с аккаунтом SpyClash.",
            es: "\(price) por \(period). El pago se carga a tu Cuenta de Apple al confirmar. La suscripción se renueva automáticamente salvo que se cancele al menos 24 horas antes del fin del periodo. LIMITLESS se sincroniza con tu cuenta de SpyClash."
        )
    }

    private func secondaryActionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
                .spyFitted(lines: 2, scale: 0.58)
        }
        .font(.system(size: 8, weight: .black, design: .monospaced))
        .tracking(0.06)
        .foregroundStyle(SpyTheme.muted)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(SpyTheme.black.opacity(0.48), in: CutCornerShape(cut: 7))
        .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.strokeStrong, lineWidth: 1))
        .contentShape(CutCornerShape(cut: 7))
    }

    private var legalDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localized(en: "SUBSCRIPTION PROTOCOL", ru: "ПРОТОКОЛ ПОДПИСКИ", es: "PROTOCOLO DE SUSCRIPCION"))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.14)
                    .foregroundStyle(SpyTheme.dim)

                Spacer()

                Text(localized(en: "AUTO-RENEWS", ru: "АВТОПРОДЛЕНИЕ", es: "AUTORENOVACION"))
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.red.opacity(0.72))
            }

            Text(subscriptionLegalText)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineSpacing(3)
            .foregroundStyle(SpyTheme.dim)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                legalButton(localized(en: "TERMS", ru: "УСЛОВИЯ", es: "TERMINOS"), kind: .terms)
                legalButton(localized(en: "PRIVACY", ru: "КОНФИДЕНЦИАЛЬНОСТЬ", es: "PRIVACIDAD"), kind: .privacy)
            }
        }
        .padding(14)
        .background(SpyTheme.dark.opacity(0.78), in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke.opacity(0.90), lineWidth: 1))
        .opacity(presentationIsComplete ? 1 : 0)
        .offset(y: presentationIsComplete ? 0 : 10)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .easeOut(duration: 0.34).delay(0.10),
            value: presentationIsComplete
        )
    }

    private func legalButton(_ title: String, kind: LegalSheetKind) -> some View {
        Button {
            presentLegal(kind)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .spyFitted(scale: 0.62)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.08)
            .foregroundStyle(SpyTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(SpyTheme.black.opacity(0.55), in: CutCornerShape(cut: 7))
            .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.strokeStrong, lineWidth: 1))
            .contentShape(CutCornerShape(cut: 7))
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var statusBanner: some View {
        SpyToast(
            text: statusText,
            kind: statusToastKind
        )
    }

    private var statusToastKind: SpyToast.Kind {
        switch statusKind {
        case .success: .success
        case .warning: .warning
        case .info, nil: .info
        case .error: .error
        }
    }

    private func cornerMark(color: Color) -> some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 18, y: 0))
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 18))
        }
        .stroke(color, lineWidth: 1.5)
        .frame(width: 18, height: 18)
    }

    private var heroIsRevealed: Bool {
        reduceMotion || revealStep >= 2
    }

    private var presentationIsComplete: Bool {
        reduceMotion || revealStep >= finalRevealStep
    }

    private var finalRevealStep: Int {
        copy.features.count + 3
    }

    private var capabilityPresentedCount: Int {
        guard heroIsRevealed else { return 0 }
        return min(copy.features.count, max(0, revealStep - 2))
    }

    private var capabilitiesHeading: String {
        appState.hasLimitlessAccess
            ? localized(
                en: "// LIMITLESS CAPABILITIES ACTIVE",
                ru: "// ВОЗМОЖНОСТИ LIMITLESS АКТИВНЫ",
                es: "// CAPACIDADES LIMITLESS ACTIVAS"
            )
            : localized(
                en: "// LIMITLESS CAPABILITIES PREVIEW",
                ru: "// ПРЕВЬЮ ВОЗМОЖНОСТЕЙ LIMITLESS",
                es: "// VISTA PREVIA LIMITLESS"
            )
    }

    private var capabilityProgressLabel: String {
        if appState.hasLimitlessAccess {
            return String(format: "%02d / %02d ACTIVE", capabilityPresentedCount, copy.features.count)
        }
        return String(
            format: "%02d / %02d %@",
            capabilityPresentedCount,
            copy.features.count,
            localized(en: "PREVIEW", ru: "ПРЕВЬЮ", es: "PREVIA")
        )
    }

    private var capabilityCountLabel: String {
        String(
            format: "%02d %@",
            copy.features.count,
            localized(en: "CAPABILITIES", ru: "ВОЗМОЖНОСТЕЙ", es: "CAPACIDADES")
        )
    }

    private func capabilityIsRevealed(_ index: Int) -> Bool {
        reduceMotion || revealStep >= index + 3
    }

    @MainActor
    private func runLimitlessPresentation() async {
        guard !hasAppeared else { return }

        if reduceMotion {
            hasAppeared = true
            scannerActive = true
            revealStep = finalRevealStep
            return
        }

        HapticManager.shared.prepareLimitlessPresentation()

        guard await presentationPause(milliseconds: 90) else { return }
        withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.38)) {
            hasAppeared = true
        }

        guard await presentationPause(milliseconds: 120) else { return }
        withAnimation(.timingCurve(0.20, 0.78, 0.28, 1, duration: 0.58)) {
            revealStep = 1
            scannerActive = true
        }
        HapticManager.shared.playLimitlessCharge()

        guard await presentationPause(milliseconds: 520) else { return }
        withAnimation(.timingCurve(0.12, 0.88, 0.22, 1, duration: 0.48)) {
            revealStep = 2
            heroFlash = true
        }

        guard await presentationPause(milliseconds: 130) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            heroFlash = false
        }

        for index in copy.features.indices {
            guard await presentationPause(milliseconds: index == 0 ? 260 : 320) else { return }
            withAnimation(.timingCurve(0.16, 0.84, 0.28, 1, duration: 0.42)) {
                revealStep = index + 3
            }
            HapticManager.shared.playLimitlessUnlock(index: index)
        }

        guard await presentationPause(milliseconds: 360) else { return }
        withAnimation(.timingCurve(0.12, 0.88, 0.22, 1, duration: 0.48)) {
            revealStep = finalRevealStep
        }
        HapticManager.shared.playLimitlessCompletion()
    }

    private func presentationPause(milliseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .en: en
        case .ru: ru
        case .es: es
        }
    }

    private func presentLegal(_ kind: LegalSheetKind) {
        appState.presentedSheet = .legal(kind)
    }

    private func performPrimaryAction() async {
        if appState.hasLimitlessAccess {
            await refreshAccess(showResult: true)
        } else if appState.membershipTier == .free {
            await purchaseLimitless()
        } else {
            await refreshAccess(showResult: true)
        }
    }

    private func refreshAccess(showResult: Bool) async {
        isRefreshingAccess = true
        if showResult {
            statusText = ""
            statusKind = nil
        }
        defer { isRefreshingAccess = false }

        await appState.synchronizeCommerceAccess()

        guard showResult else {
            return
        }

        if case .unavailable = appState.membershipSyncState {
            statusText = appState.membership == nil
                ? localized(
                    en: "MEMBERSHIP STATUS UNAVAILABLE",
                    ru: "СТАТУС ПОДПИСКИ НЕДОСТУПЕН",
                    es: "ESTADO DE MEMBRESIA NO DISPONIBLE"
                )
                : localized(
                    en: "SYNC UNAVAILABLE // LAST VERIFIED CATEGORY RETAINED",
                    ru: "СИНХРОНИЗАЦИЯ НЕДОСТУПНА // СОХРАНЕН ПОСЛЕДНИЙ СТАТУС",
                    es: "SINCRONIZACION NO DISPONIBLE // ESTADO CONSERVADO"
                )
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
            return
        }

        if appState.hasLimitlessAccess {
            statusText = copy.accessActive
            statusKind = .success
            HapticManager.shared.fire(.milestone)
        } else {
            statusText = copy.accessNotActive
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func purchaseLimitless() async {
        statusText = ""
        statusKind = nil

        // Reconcile both Stripe and Apple immediately before presenting the
        // App Store sheet. A cached FREE state must never invite a second paid
        // subscription after the user has already upgraded on the web.
        isRefreshingAccess = true
        await appState.synchronizeCommerceAccess()
        isRefreshingAccess = false

        if appState.hasLimitlessAccess {
            statusText = copy.accessActive
            statusKind = .success
            HapticManager.shared.fire(.milestone)
            return
        }
        guard case .synced = appState.membershipSyncState,
              appState.membershipTier == .free else {
            statusText = localized(
                en: "PURCHASE BLOCKED // VERIFY EXISTING ACCESS AND RETRY",
                ru: "ПОКУПКА ПРИОСТАНОВЛЕНА // ПРОВЕРЬ ДОСТУП И ПОВТОРИ",
                es: "COMPRA PAUSADA // VERIFICA TU ACCESO Y REINTENTA"
            )
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
            return
        }

        switch await appState.storeKit.purchaseLimitless() {
        case .purchased:
            await appState.refreshSubscription()
            statusText = appState.hasLimitlessAccess ? copy.accessActive : copy.accessNotActive
            statusKind = appState.hasLimitlessAccess ? .success : .error
            if appState.hasLimitlessAccess {
                HapticManager.shared.fire(.milestone)
            } else {
                HapticManager.shared.fire(.notification(.error))
            }
        case .pending:
            statusText = localized(
                en: "PURCHASE PENDING APPROVAL",
                ru: "ПОКУПКА ОЖИДАЕТ ПОДТВЕРЖДЕНИЯ",
                es: "COMPRA PENDIENTE DE APROBACION"
            )
            statusKind = .warning
            HapticManager.shared.fire(.notification(.warning))
        case .cancelled:
            statusText = ""
            statusKind = nil
        case .failed(let message):
            showStoreKitFailure(message)
        case .restored, .noPurchases:
            break
        }
    }

    private func restorePurchases() async {
        statusText = ""
        statusKind = nil

        switch await appState.storeKit.restorePurchases() {
        case .restored:
            await appState.refreshSubscription()
            if appState.hasLimitlessAccess {
                statusText = localized(
                    en: "APP STORE PURCHASE RESTORED",
                    ru: "ПОКУПКА APP STORE ВОССТАНОВЛЕНА",
                    es: "COMPRA DE APP STORE RESTAURADA"
                )
                statusKind = .success
                HapticManager.shared.fire(.milestone)
            } else {
                statusText = copy.accessNotActive
                statusKind = .error
                HapticManager.shared.fire(.notification(.error))
            }
        case .noPurchases:
            await appState.refreshSubscription()
            statusText = localized(
                en: "NO ACTIVE APP STORE PURCHASES FOUND",
                ru: "АКТИВНЫЕ ПОКУПКИ APP STORE НЕ НАЙДЕНЫ",
                es: "NO SE ENCONTRARON COMPRAS ACTIVAS"
            )
            statusKind = .info
            HapticManager.shared.fire(.tabSelection)
        case .cancelled:
            statusText = ""
            statusKind = nil
        case .failed(let message):
            showStoreKitFailure(message)
        case .purchased, .pending:
            break
        }
    }

    private func manageSubscription() async {
        statusText = ""
        statusKind = nil
        isRefreshingAccess = true
        defer { isRefreshingAccess = false }

        do {
            try await appState.storeKit.showManageSubscriptions()
            await appState.synchronizeCommerceAccess()
        } catch {
            statusText = error.localizedDescription.uppercased()
            statusKind = .error
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func showStoreKitFailure(_ message: String) {
        if case .unavailable = appState.storeKit.productState {
            statusText = copy.appStoreUnavailable
        } else {
            statusText = message.uppercased()
        }
        statusKind = .error
        HapticManager.shared.fire(.notification(.error))
    }
}

private struct LimitlessCommandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(SpyTheme.red, in: CutCornerShape(cut: 10))
            .overlay {
                CutCornerShape(cut: 10)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.16 : 0), lineWidth: 1)
            }
            .contentShape(CutCornerShape(cut: 10))
            .shadow(color: SpyTheme.red.opacity(configuration.isPressed ? 0.16 : 0.30), radius: configuration.isPressed ? 8 : 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isEnabled)
    }
}

private enum PricingStatusKind {
    case success
    case error
    case warning
    case info
}
