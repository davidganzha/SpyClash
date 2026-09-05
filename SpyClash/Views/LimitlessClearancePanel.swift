import SwiftUI

/// Restores the pre-alpha clearance presentation without coupling its reveal
/// animation to entitlement state. Only verified access opens the locks.
struct LimitlessClearancePanel<Controls: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let copy: LimitlessCopy
    let hasAccess: Bool
    let status: String
    let displayPrice: String?
    @ViewBuilder let controls: () -> Controls

    @State private var phase = 0
    @State private var scannerActive = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            capabilities
            controls()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(SpyTheme.black.opacity(0.45))
        }
        .background {
            ZStack {
                SpyTheme.black
                LinearGradient(
                    colors: [SpyTheme.red.opacity(0.14), SpyTheme.redDeep.opacity(0.035), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(CutCornerShape(cut: 14))
        .overlay {
            CutCornerShape(cut: 14).stroke(
                LinearGradient(
                    colors: [SpyTheme.red.opacity(0.82), SpyTheme.strokeStrong, SpyTheme.redDeep.opacity(0.48)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1
            )
        }
        .overlay(alignment: .topLeading) { cornerMark.padding(1) }
        .overlay(alignment: .bottomTrailing) { cornerMark.rotationEffect(.degrees(180)).padding(1) }
        .shadow(color: SpyTheme.red.opacity(0.20), radius: 28)
        .shadow(color: .black.opacity(0.62), radius: 28, y: 18)
        .overlay {
            if phase < 2, !reduceMotion {
                bootSequence
                    .clipShape(CutCornerShape(cut: 14))
                    .transition(.opacity)
            }
        }
        // The decorative boot screen must not cover a tappable purchase button.
        .allowsHitTesting(phase >= 2 || reduceMotion)
        .accessibilityHidden(phase < 2 && !reduceMotion)
        .task(id: reduceMotion) { await reveal() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.clearance)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1.4).foregroundStyle(SpyTheme.red)
                Text(copy.fieldKit)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.8).foregroundStyle(SpyTheme.faint)
                HStack(spacing: 6) {
                    Circle().fill(hasAccess ? SpyTheme.green : SpyTheme.muted).frame(width: 4, height: 4)
                    Text(status.uppercased())
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.5)
                }
                .foregroundStyle(hasAccess ? SpyTheme.green : SpyTheme.muted)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(SpyTheme.black.opacity(0.6), in: CutCornerShape(cut: 6))
                .overlay(CutCornerShape(cut: 6).stroke(SpyTheme.strokeStrong, lineWidth: 1))
                .accessibilityIdentifier("limitless.access-state")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("LIMITLESS")
                    .font(SpyTheme.brandFont(size: 38)).tracking(6)
                    .lineLimit(1).minimumScaleFactor(0.6).hidden()
                    .overlay(alignment: .leading) {
                        if phase >= 2 || reduceMotion {
                            AnimatedTitle(text: "LIMITLESS", delay: 0.02, fontSize: 38, letterSpacing: 6)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("LIMITLESS")
                        }
                    }
                Text(copy.mission)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.5).foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !hasAccess {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayPrice ?? copy.appStorePrice)
                        .font(SpyTheme.brandFont(size: displayPrice == nil ? 22 : 48))
                        .foregroundStyle(SpyTheme.red)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if displayPrice != nil {
                        Text("/ \(copy.week)").font(SpyTheme.micro).foregroundStyle(SpyTheme.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(alignment: .trailing) {
            Image(systemName: "infinity")
                .font(.system(size: 132, weight: .black))
                .foregroundStyle(SpyTheme.red.opacity(0.055))
                .offset(x: 70).accessibilityHidden(true)
        }
        .clipped()
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(copy.capabilities)
                Spacer(minLength: 8)
                Text("03/03 · \(hasAccess ? copy.enabled : copy.preview)")
                    .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.3).foregroundStyle(SpyTheme.faint)
            .padding(.bottom, 10)

            capability(index: 0, icon: "infinity", title: copy.unlimitedTitle, detail: copy.ai)
            capability(index: 1, icon: "paintbrush.pointed.fill", title: copy.customizationTitle, detail: copy.customization)
            capability(index: 2, icon: "chart.bar.xaxis", title: copy.statisticsTitle, detail: copy.statisticsDetail)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func capability(index: Int, icon: String, title: String, detail: String) -> some View {
        let revealed = reduceMotion || phase >= index + 3
        return HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(SpyTheme.faint).padding(.top, 4)
            Image(systemName: icon).font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpyTheme.red).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .heavy, design: .monospaced))
                Text(detail).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SpyTheme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: hasAccess ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hasAccess ? SpyTheme.green : SpyTheme.faint)
                .padding(.top, 3)
        }
        .frame(minHeight: 58, alignment: .center)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [SpyTheme.red.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1).scaleEffect(x: revealed ? 1 : 0, anchor: .leading)
        }
        .opacity(revealed ? 1 : 0.12)
        .blur(radius: revealed || reduceMotion ? 0 : 2.5)
        .offset(x: revealed || reduceMotion ? 0 : -14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail). \(hasAccess ? copy.enabled : copy.locked)")
        .accessibilityIdentifier("limitless.capability.\(index)")
    }

    private var bootSequence: some View {
        GeometryReader { proxy in
            ZStack {
                SpyTheme.black
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, SpyTheme.red.opacity(0.52), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 92).blur(radius: 8)
                    .offset(y: scannerActive ? proxy.size.height / 2 + 48 : -proxy.size.height / 2 - 118)
                VStack(spacing: 18) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 27, weight: .black)).foregroundStyle(SpyTheme.red)
                        .shadow(color: SpyTheme.red.opacity(0.72), radius: 18)
                        .frame(width: 68, height: 68)
                        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.red.opacity(0.52), lineWidth: 1))
                    Text("LIMITLESS").font(SpyTheme.brandFont(size: 30)).tracking(5)
                    Text(copy.clearance).font(SpyTheme.micro).foregroundStyle(SpyTheme.muted)
                    HStack(spacing: 7) {
                        ForEach(0..<3) { _ in
                            Rectangle().fill(SpyTheme.red).frame(width: 34, height: 2)
                                .scaleEffect(x: scannerActive ? 1 : 0.12, anchor: .leading)
                        }
                    }
                    // This is presentation, not purchase confirmation.
                    Text(copy.scanning).font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyTheme.faint)
                }
                .padding(16).multilineTextAlignment(.center)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var cornerMark: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 18))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: 18, y: 0))
        }
        .stroke(SpyTheme.red, lineWidth: 2)
        .frame(width: 18, height: 18).accessibilityHidden(true)
    }

    @MainActor
    private func reveal() async {
        guard !reduceMotion else { phase = 6; return }
        guard phase < 6 else { return }
        HapticManager.shared.prepareLimitlessPresentation()
        do {
            try await Task.sleep(for: .milliseconds(120))
            withAnimation(.timingCurve(0.20, 0.78, 0.28, 1, duration: 0.58)) {
                phase = 1
                scannerActive = true
            }
            HapticManager.shared.playLimitlessCharge()
            try await Task.sleep(for: .milliseconds(580))
            withAnimation(.easeOut(duration: 0.38)) { phase = 2 }
            for index in 0..<3 {
                try await Task.sleep(for: .milliseconds(index == 0 ? 260 : 320))
                withAnimation(.timingCurve(0.16, 0.84, 0.28, 1, duration: 0.42)) { phase = index + 3 }
                HapticManager.shared.playLimitlessUnlock(index: index)
            }
            try await Task.sleep(for: .milliseconds(360))
            phase = 6
            HapticManager.shared.playLimitlessCompletion()
        } catch { /* Dismissal cancels the sequence and remaining haptics. */ }
    }
}

struct LimitlessCommandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .black, design: .monospaced))
            .tracking(0.7).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .background(SpyTheme.red, in: CutCornerShape(cut: 10))
            .overlay(CutCornerShape(cut: 10).stroke(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: SpyTheme.red.opacity(0.30), radius: configuration.isPressed ? 8 : 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}
