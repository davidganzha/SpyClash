import SwiftUI
import UIKit

struct GenerationPresentationSource: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let next = nextValue()
        value = value || next
    }
}

extension View {
    func generationPresentationLayer() -> some View {
        overlayPreferenceValue(GenerationPresentationSource.self) { active in
            if active { GenerationPresentationLayer() }
        }
        .transformPreference(GenerationPresentationSource.self) { $0 = false }
    }
}

struct GenerationBalanceReadout: View {
    let status: GenerationRewardStatus
    let language: AppLanguage
    private var copy: GenerationRewardCopy { .init(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(copy.daily)
                    .font(SpyTheme.gameFont(size: 17, weight: .semibold, relativeTo: .subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let remaining = status.freeRemaining {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(remaining))
                            .font(SpyTheme.brandFont(size: 34))
                            .contentTransition(.numericText())
                        Text("/ \(status.dailyLimit)")
                            .font(SpyTheme.gameFont(size: 14, relativeTo: .subheadline))
                            .foregroundStyle(SpyTheme.bodyText)
                    }
                    .monospacedDigit()
                    .accessibilityLabel(copy.free(remaining, limit: status.dailyLimit))
                    .accessibilityIdentifier("generation.freeRemaining")
                }
            }
            if let remaining = status.freeRemaining, status.dailyLimit > 0 {
                let slots = min(status.dailyLimit, 12)
                HStack(spacing: 4) {
                    ForEach(0..<slots, id: \.self) { index in
                        Capsule()
                            .fill(Double(index) / Double(slots) < Double(remaining) / Double(status.dailyLimit)
                                  ? SpyTheme.red : Color.white.opacity(0.16))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            if status.bonusCredits > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.fill")
                    Text("+\(status.bonusCredits)").font(SpyTheme.brandFont(size: 24)).monospacedDigit()
                    Text(copy.bonusBalance).font(SpyTheme.gameFont(size: 17, weight: .semibold, relativeTo: .subheadline))
                }
                .foregroundStyle(SpyTheme.amber)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy.bonus(status.bonusCredits))
                .accessibilityIdentifier("generation.bonusCredits")
            }
            if let reset = status.resetsAt {
                Text(copy.reset(reset))
                    .font(SpyTheme.gameFont(size: 14, relativeTo: .footnote))
                    .foregroundStyle(SpyTheme.bodyText)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct GenerationPresentationLayer: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        let store = appState.generationRewards
        GenerationPresentationStage(
            phase: store.presentationPhase,
            confirmedAttempt: store.confirmedRewardAttemptID,
            copy: .init(language: appState.language),
            cancel: store.cancelPresentation,
            dismiss: store.dismissRewardCelebration
        )
    }
}

struct GenerationPresentationStage: View {
    let phase: GenerationRewardPresentationPhase
    let confirmedAttempt: UUID?
    let copy: GenerationRewardCopy
    let cancel: () -> Void
    let dismiss: (UUID) -> Void
    @SpyReduceMotion private var reduceMotion

    var body: some View {
        ZStack {
            switch phase {
            case .preparing, .readyToPresent, .presenting:
                ZStack {
                    Color.black
                    GenerationAdLoader(
                        title: copy.preparing,
                        cancelTitle: copy.text("Cancel", "Отмена", "Cancelar", "Скасувати"),
                        cancel: cancel
                    )
                        .opacity(phase == .preparing ? 1 : 0)
                        .allowsHitTesting(phase == .preparing)
                        .accessibilityHidden(phase != .preparing)
                        .animation(.easeOut(duration: reduceMotion ? 0 : 0.15), value: phase)
                }
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .accessibilityAddTraits(.isModal)
                .accessibilityIdentifier("generation.adTransition")
                .transition(.opacity)
            case .requestingConsent:
                EmptyView()
            case .idle, .confirming:
                if let attempt = confirmedAttempt {
                    GenerationRewardReveal(title: copy.rewardTitle) {
                        dismiss(attempt)
                    }
                    .id(attempt)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: phase)
    }
}

private struct GenerationAdLoader: View {
    @SpyReduceMotion private var reduceMotion
    let title: String
    let cancelTitle: String
    let cancel: () -> Void
    @State private var sweep = false
    @State private var canCancel = false

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                Circle().inset(by: 6).stroke(SpyTheme.red.opacity(0.22), style: .init(lineWidth: 3, dash: [2, 6]))
                Circle().trim(from: 0.04, to: 0.30)
                    .stroke(SpyTheme.red, style: .init(lineWidth: 2, lineCap: .round))
                    .shadow(color: SpyTheme.red, radius: 4)
                    .rotationEffect(.degrees(sweep && !reduceMotion ? 360 : 0))
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 80, height: 80)
            .accessibilityHidden(true)
            Text(title).font(SpyTheme.gameFont(size: 21, weight: .semibold, relativeTo: .headline)).foregroundStyle(.white)
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if canCancel {
                Button(cancelTitle, action: cancel)
                    .font(SpyTheme.gameFont(size: 16, relativeTo: .subheadline))
                    .foregroundStyle(SpyTheme.bodyText)
                    .frame(minWidth: 100, minHeight: 44)
                    .accessibilityIdentifier("generation.cancelPreparation")
            }
        }
        .task {
            do {
                try await Task.sleep(for: .seconds(2.5))
                canCancel = true
            } catch { }
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true }
            }
        }
    }
}

private struct GenerationRewardReveal: View {
    @SpyReduceMotion private var reduceMotion
    let title: String
    let dismiss: () -> Void
    @State private var lit = false
    @State private var fading = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.96)
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [SpyTheme.amber.opacity(0.24), .clear],
                                             center: .center, startRadius: 0, endRadius: 120))
                    Circle()
                        .stroke(SpyTheme.amber.opacity(0.44), style: .init(lineWidth: 1, dash: [1, 7]))
                        .padding(10)
                    ForEach([0.08, 0.58], id: \.self) { start in
                        Circle()
                            .trim(from: start, to: start + 0.32)
                            .stroke(SpyTheme.amber, lineWidth: 2)
                            .padding(17)
                            .rotationEffect(.degrees(lit ? -40 : -85))
                    }
                    VStack(spacing: 0) {
                        Image(systemName: "bolt.fill").font(.headline).foregroundStyle(SpyTheme.amber)
                        Text("+1").font(SpyTheme.brandFont(size: 86)).foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                }
                .frame(width: 218, height: 218)
                .scaleEffect(reduceMotion || lit ? 1 : 0.84)
                Text(title)
                    .font(SpyTheme.gameFont(size: 25, weight: .bold, relativeTo: .title3))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("+1. \(title)")
        .accessibilityIdentifier("generation.rewardReveal")
        .accessibilityAddTraits(.isModal)
        .opacity(fading ? 0 : 1)
        .task {
            UIAccessibility.post(notification: .announcement, argument: "+1. " + title)
            HapticManager.shared.fire(.notification(.success))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.46)) { lit = true }
            do {
                try await Task.sleep(for: .milliseconds(1300))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { fading = true }
                try await Task.sleep(for: .milliseconds(200))
                dismiss()
            } catch { }
        }
    }
}
