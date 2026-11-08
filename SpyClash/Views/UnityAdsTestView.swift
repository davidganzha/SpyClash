#if DEBUG
import SwiftUI

/// Uses the actual app and SDK without installing a preview account or credits.
struct UnityAdsTestPreview: View {
    @Environment(AppState.self) private var appState
    let close: () -> Void
    private var copy: GenerationRewardCopy { .init(language: appState.language) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("UNITY ADS")
                    .font(SpyTheme.brandFont(size: 36))
                Text(copy.text("AD PREVIEW", "ПРОСМОТР РЕКЛАМЫ", "VISTA PREVIA DEL ANUNCIO", "ПЕРЕГЛЯД РЕКЛАМИ"))
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                UnityAdsTestControl(isGenerating: false)
                Button(action: close) {
                    Text(copy.text("Return to SpyClash", "Вернуться в SpyClash", "Volver a SpyClash", "Повернутися в SpyClash"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(UnityAdsTestPresenter.shared.isBusy)
                .accessibilityIdentifier("unityAd.return")
            }
            .padding(24)
            .padding(.top, 48)
        }
        .background(SpyBackground())
    }
}

struct UnityAdsTestControl: View {
    @Environment(AppState.self) private var appState
    let isGenerating: Bool
    @State private var watchTask: Task<Void, Never>?
    @State private var result: Bool?
    @State private var failed = false
    private var presenter: UnityAdsTestPresenter { .shared }
    private var copy: GenerationRewardCopy { .init(language: appState.language) }
    private var canWatch: Bool {
        UnityAdsTestConfiguration.current.isEnabled && !appState.shouldUsePreviewData
            && !isGenerating && !presenter.isBusy && !RewardedGenerationAdPresenter.shared.isBusy
            && !appState.generationRewards.isWatching && !appState.generationRewards.isAwaitingReward
            && appState.generationRewards.pendingAttemptID == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.text("UNITY ADS · TEST", "UNITY ADS · ТЕСТ", "UNITY ADS · PRUEBA", "UNITY ADS · ТЕСТ"))
                .foregroundStyle(SpyTheme.green)
            Text(copy.text(
                "A Unity test ad will open full screen. This preview does not add generation credits.",
                "Тестовая реклама Unity откроется на весь экран. Этот просмотр не начисляет генерации.",
                "Se abrirá un anuncio de prueba de Unity a pantalla completa. Esta vista previa no añade generaciones.",
                "Тестова реклама Unity відкриється на весь екран. Цей перегляд не нараховує генерації."
            ))
            .foregroundStyle(SpyTheme.muted)
            Button(action: watch) {
                Label(presenter.isBusy ? copy.preparing : copy.text(
                    "Watch Unity Ads", "Посмотреть Unity Ads", "Ver Unity Ads", "Переглянути Unity Ads"
                ), systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(SpyButtonStyle(variant: .outline))
            .disabled(!canWatch)
            .accessibilityIdentifier("unityAd.watch")
            if let result {
                Text(result ? copy.text(
                    "Test viewing completed.", "Тестовый просмотр завершён.", "Visualización de prueba completada.", "Тестовий перегляд завершено."
                ) : copy.text(
                    "Test ad closed.", "Тестовая реклама закрыта.", "Anuncio de prueba cerrado.", "Тестову рекламу закрито."
                ))
                .foregroundStyle(SpyTheme.green)
                .accessibilityIdentifier("unityAd.result")
            }
            if failed {
                Text(copy.text(
                    "Unity could not load this test ad. Try again.",
                    "Unity не удалось загрузить тестовую рекламу. Попробуй ещё раз.",
                    "Unity no pudo cargar el anuncio de prueba. Inténtalo de nuevo.",
                    "Unity не вдалося завантажити тестову рекламу. Спробуй ще раз."
                ))
                .foregroundStyle(SpyTheme.amber)
                .accessibilityIdentifier("unityAd.error")
            }
        }
        .font(SpyTheme.mono)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpyTheme.panel, in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
        .onChange(of: isGenerating) { _, value in if value { cancel() } }
        .onChange(of: appState.membershipScope) { _, _ in cancel() }
        .onDisappear {
            // UIKit covers this view while the chosen full-screen ad plays.
            // Keep its result task alive until the SDK returns to this screen.
            if presenter.status != .presenting { cancel() }
        }
    }

    private func watch() {
        guard canWatch else { return }
        result = nil
        failed = false
        watchTask = Task {
            do {
                let completed = try await presenter.present()
                guard !Task.isCancelled else { return }
                result = completed
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failed = true
                print("[UnityAdsTest] \(error.localizedDescription)")
            }
        }
    }

    private func cancel() {
        watchTask?.cancel()
        watchTask = nil
        presenter.cancelPendingPresentation()
    }
}
#endif
