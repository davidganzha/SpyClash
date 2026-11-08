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
    @State private var failure: UnityAdsTestError?
    private var presenter: UnityAdsTestPresenter { .shared }
    private var isTestMode: Bool { UnityAdsTestConfiguration.current.isTestMode }
    private var copy: GenerationRewardCopy { .init(language: appState.language) }
    private var canWatch: Bool {
        UnityAdsTestConfiguration.current.isEnabled && !appState.shouldUsePreviewData
            && !isGenerating && !presenter.isBusy && !RewardedGenerationAdPresenter.shared.isBusy
            && !appState.generationRewards.isWatching && !appState.generationRewards.isAwaitingReward
            && appState.generationRewards.pendingAttemptID == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isTestMode
                ? copy.text("UNITY ADS · TEST", "UNITY ADS · ТЕСТ", "UNITY ADS · PRUEBA", "UNITY ADS · ТЕСТ")
                : copy.text("UNITY ADS · LIVE", "UNITY ADS · РЕАЛЬНАЯ РЕКЛАМА", "UNITY ADS · ANUNCIO REAL", "UNITY ADS · РЕАЛЬНА РЕКЛАМА"))
                .foregroundStyle(SpyTheme.green)
            Text(isTestMode ? copy.text(
                "A Unity test ad will open full screen. This preview does not add generation credits.",
                "Тестовая реклама Unity откроется на весь экран. Этот просмотр не начисляет генерации.",
                "Se abrirá un anuncio de prueba de Unity a pantalla completa. Esta vista previa no añade generaciones.",
                "Тестова реклама Unity відкриється на весь екран. Цей перегляд не нараховує генерації."
            ) : copy.text(
                "Unity will request a real ad and open it full screen if available. This preview does not add generation credits.",
                "Unity запросит настоящую рекламу и откроет её на весь экран, если она доступна. Этот просмотр не начисляет генерации.",
                "Unity solicitará un anuncio real y lo abrirá a pantalla completa si está disponible. Esta vista previa no añade generaciones.",
                "Unity запитає справжню рекламу й відкриє її на весь екран, якщо вона доступна. Цей перегляд не нараховує генерації."
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
                    "Viewing completed.", "Просмотр завершён.", "Visualización completada.", "Перегляд завершено."
                ) : copy.text(
                    "Ad closed.", "Реклама закрыта.", "Anuncio cerrado.", "Рекламу закрито."
                ))
                .foregroundStyle(SpyTheme.green)
                .accessibilityIdentifier("unityAd.result")
            }
            if let failure {
                let message = failureCopy(for: failure)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.title)
                    Text(message.detail)
                }
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
        failure = nil
        watchTask = Task {
            do {
                let completed = try await presenter.present()
                guard !Task.isCancelled else { return }
                result = completed
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failure = (error as? UnityAdsTestError) ?? .presentationFailed(error.localizedDescription)
                print("[UnityAdsTest] \(error.localizedDescription)")
            }
        }
    }

    private func failureCopy(for error: UnityAdsTestError) -> (title: String, detail: String) {
        switch error {
        case .presentationFailed, .presentationUnavailable:
            return (
                copy.text("Ad did not open", "Реклама не открылась", "El anuncio no se abrió", "Реклама не відкрилася"),
                copy.text(
                    "Unity could not start the ad. Try again later.",
                    "Unity не удалось начать показ. Попробуй позже.",
                    "Unity no pudo iniciar el anuncio. Inténtalo más tarde.",
                    "Unity не вдалося почати показ. Спробуй пізніше."
                )
            )
        case .timedOut:
            return (
                copy.text("Unity did not respond", "Unity не ответила", "Unity no respondió", "Unity не відповіла"),
                copy.text(
                    "The ad took too long to prepare. Check your connection and try again.",
                    "Подготовка рекламы заняла слишком много времени. Проверь соединение и попробуй снова.",
                    "El anuncio tardó demasiado en prepararse. Comprueba tu conexión e inténtalo de nuevo.",
                    "Підготовка реклами тривала надто довго. Перевір з’єднання та спробуй знову."
                )
            )
        case .alreadyPresenting:
            return (
                copy.text("Another screen is open", "Уже открыт другой экран", "Ya hay otra pantalla abierta", "Уже відкрито інший екран"),
                copy.text(
                    "Close the other advertising screen, then try again.",
                    "Закрой другой рекламный экран и попробуй снова.",
                    "Cierra la otra pantalla de publicidad e inténtalo de nuevo.",
                    "Закрий інший рекламний екран і спробуй знову."
                )
            )
        case .unavailable, .initializationFailed, .loadFailed, .incompatibleInitialization:
            return (
                copy.text("Ad unavailable", "Реклама недоступна", "Anuncio no disponible", "Реклама недоступна"),
                copy.text(
                    "Unity could not prepare an ad. Try again later.",
                    "Unity не удалось подготовить рекламу. Попробуй позже.",
                    "Unity no pudo preparar un anuncio. Inténtalo más tarde.",
                    "Unity не вдалося підготувати рекламу. Спробуй пізніше."
                )
            )
        }
    }

    private func cancel() {
        watchTask?.cancel()
        watchTask = nil
        presenter.cancelPendingPresentation()
    }
}
#endif
