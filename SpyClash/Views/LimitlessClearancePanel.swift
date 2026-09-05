import SwiftUI

/// Visual blocks transplanted from e4c1997 PricingView, not reinterpreted.
/// Only membership/product values and controls are supplied by the current IAP flow.
struct LimitlessClearancePanel<Controls: View, Legal: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let copy: LimitlessCopy
    let hasAccess: Bool
    let membershipCategoryLabel: String
    let membershipCategoryAccent: Color
    let displayPrice: String?
    let subscriptionPeriodLabel: String
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let legal: () -> Legal

    @State private var hasAppeared = false
    @State private var revealStep = 0
    @State private var scannerActive = false
    @State private var heroFlash = false

    var body: some View {
        VStack(spacing: 14) {
            premiumUpgradePanel
            legal()
                .opacity(presentationIsComplete ? 1 : 0)
                .offset(y: presentationIsComplete ? 0 : 10)
                .allowsHitTesting(presentationIsComplete)
                .accessibilityHidden(!presentationIsComplete)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.34).delay(0.10),
                    value: presentationIsComplete
                )
        }
        .task(id: reduceMotion) { await runLimitlessPresentation() }
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
                            es: "PROTOCOLO DE ACCESO PREMIUM", uk: "ПРОТОКОЛ ПРЕМІУМ ДОПУСКУ"))
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
                         ? localized(en: "PREVIEW READY", ru: "ПРЕВЬЮ ГОТОВО", es: "VISTA PREVIA LISTA", uk: "ПЕРЕГЛЯД ГОТОВИЙ")
                         : localized(en: "ESTABLISHING SECURE LINK", ru: "УСТАНОВКА ЗАЩИЩЕННОГО КАНАЛА", es: "ESTABLECIENDO CANAL SEGURO", uk: "ВСТАНОВЛЕННЯ ЗАХИЩЕНОГО КАНАЛУ"))
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
                    Text(localized(en: "PREMIUM CLEARANCE", ru: "ПРЕМИУМ ДОПУСК", es: "ACCESO PREMIUM", uk: "ПРЕМІУМ ДОПУСК"))
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.16)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.72)

                    Text(localized(en: "FIELD KIT // LEVEL 01", ru: "ПОЛЕВОЙ НАБОР // УРОВЕНЬ 01", es: "KIT DE CAMPO // NIVEL 01", uk: "ПОЛЬОВИЙ НАБІР // РІВЕНЬ 01"))
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
                        es: "ELIMINA LOS LIMITES DE CADA MISION.", uk: "ЗНІМИ ОБМЕЖЕННЯ З КОЖНОЇ МІСІЇ."))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.65)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            HStack(alignment: .bottom, spacing: 7) {
                if let displayPrice = displayPrice {
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
                        es: "PRECIO DE APP STORE", uk: "ЦІНА З APP STORE"))
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

            Text("\(localized(en: "CURRENT", ru: "ТЕКУЩИЙ", es: "ACTUAL", uk: "ПОТОЧНИЙ")) • \(membershipCategoryLabel)")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.10)
        }
        .foregroundStyle(membershipCategoryAccent)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(membershipCategoryAccent.opacity(0.07), in: CutCornerShape(cut: 6))
        .overlay(CutCornerShape(cut: 6).stroke(membershipCategoryAccent.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("limitless.access-state")
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

    private func capabilityRow(index: Int, feature: LimitlessFeature) -> some View {
        let isPresented = capabilityIsRevealed(index)
        let isUnlocked = isPresented && hasAccess

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(feature.title). \(feature.detail). \(hasAccess ? copy.enabled : copy.locked)")
        .accessibilityIdentifier("limitless.capability.\(index)")
        .accessibilityHidden(!isPresented)
    }


    private var purchaseSection: some View {
        controls()
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .opacity(presentationIsComplete ? 1 : 0)
            .blur(radius: presentationIsComplete ? 0 : 5)
            .offset(y: presentationIsComplete ? 0 : 16)
            .allowsHitTesting(presentationIsComplete)
            .accessibilityHidden(!presentationIsComplete)
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .timingCurve(0.16, 0.84, 0.28, 1, duration: 0.46),
                value: presentationIsComplete
            )
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
        hasAccess
            ? localized(
                en: "// LIMITLESS CAPABILITIES ACTIVE",
                ru: "// ВОЗМОЖНОСТИ LIMITLESS АКТИВНЫ",
                es: "// CAPACIDADES LIMITLESS ACTIVAS", uk: "// МОЖЛИВОСТІ LIMITLESS АКТИВНІ")
            : localized(
                en: "// LIMITLESS CAPABILITIES PREVIEW",
                ru: "// ПРЕВЬЮ ВОЗМОЖНОСТЕЙ LIMITLESS",
                es: "// VISTA PREVIA LIMITLESS", uk: "// ПЕРЕГЛЯД МОЖЛИВОСТЕЙ LIMITLESS")
    }

    private var capabilityProgressLabel: String {
        if hasAccess {
            return String(format: "%02d / %02d ACTIVE", capabilityPresentedCount, copy.features.count)
        }
        return String(
            format: "%02d / %02d %@",
            capabilityPresentedCount,
            copy.features.count,
            localized(en: "PREVIEW", ru: "ПРЕВЬЮ", es: "PREVIA", uk: "ПЕРЕГЛЯД")
        )
    }

    private var capabilityCountLabel: String {
        String(
            format: "%02d %@",
            copy.features.count,
            localized(en: "CAPABILITIES", ru: "ВОЗМОЖНОСТЕЙ", es: "CAPACIDADES", uk: "МОЖЛИВОСТЕЙ")
        )
    }

    private func capabilityIsRevealed(_ index: Int) -> Bool {
        reduceMotion || revealStep >= index + 3
    }

    @MainActor
    private func runLimitlessPresentation() async {
        if reduceMotion {
            hasAppeared = true
            scannerActive = true
            revealStep = finalRevealStep
            heroFlash = false
            return
        }
        guard !hasAppeared else { return }

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


    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        copy.text(en, ru, es, uk)
    }
}
