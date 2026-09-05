import SwiftUI

extension View {
    func spyLimitlessUnlockLayer() -> some View {
        overlay { LimitlessUnlockLayer() }
    }
}

private struct LimitlessUnlockLayer: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        if let id = appState.membership.unlockPresentationID,
           appState.membership.hasAccess {
            LimitlessUnlockOverlay(presentationID: id).id(id)
        }
    }
}

private struct LimitlessUnlockOverlay: View {
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

                Text("LIMITLESS")
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .tracking(0.22)
                    .foregroundStyle(.white)

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
        .accessibilityLabel("LIMITLESS, \(statusText)")
        .task(id: presentationID) {
            let ownsFeedback = appState.membership.claimUnlockFeedback(presentationID)
            if ownsFeedback {
                UIAccessibility.post(notification: .announcement, argument: "LIMITLESS, \(statusText)")
                HapticManager.shared.prepareLimitlessPresentation()
            }
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
            if ownsFeedback && !reduceMotion { HapticManager.shared.playLimitlessCharge() }
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            if ownsFeedback { HapticManager.shared.playLimitlessCompletion() }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 900 : 1_280))
            guard !Task.isCancelled else { return }
            if !reduceMotion {
                withAnimation(.easeIn(duration: 0.28)) {
                    isVisible = false
                    contentOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            appState.membership.dismissUnlock(presentationID)
        }
    }

    private var statusText: String {
        switch appState.language {
        case .en: "ACCESS SYNCHRONIZED"
        case .ru: "ДОСТУП СИНХРОНИЗИРОВАН"
        case .es: "ACCESO SINCRONIZADO"
        case .uk: "ДОСТУП СИНХРОНІЗОВАНО"
        }
    }
}
