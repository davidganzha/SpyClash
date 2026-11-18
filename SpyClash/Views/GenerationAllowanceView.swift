import SwiftUI

/// Only embedded in explicit word-generation setup. Never presented at a round
/// boundary, on launch, or as a prerequisite for using saved word packs.
struct GenerationAllowanceView: View {
    @Environment(AppState.self) private var appState
    var isGenerating = false
    var roomID: String? = nil
    @State private var watchTask: Task<Void, Never>?
    @State private var showLimitless = false

    private var store: GenerationRewardStore { appState.generationRewards }
    private var copy: GenerationRewardCopy { GenerationRewardCopy(language: appState.language) }

    private var allowanceContent: some View {
        Group {
            if let status = store.snapshot, store.showsTestAdControls {
                testAdControls(status)
            } else if let status = store.snapshot, status.enabled {
                if status.unlimited {
                    Label(copy.unlimited, systemImage: "infinity")
                        .font(SpyTheme.gameFont(size: 15, relativeTo: .subheadline))
                        .foregroundStyle(SpyTheme.text)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        GenerationBalanceReadout(status: status, language: appState.language)
                        if status.needsReward {
                            if store.isAwaitingReward {
                                Label(copy.notice(.confirming), systemImage: "clock")
                                    .foregroundStyle(SpyTheme.amber)
                            } else if status.adAvailable && RewardedGenerationAdPresenter.shared.isConfigured {
                                Button {
                                    watchTask?.cancel()
                                    watchTask = Task { await appState.watchGenerationRewardAd(roomID: roomID) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "play.fill")
                                        Text(copy.watchAction)
                                            .font(SpyTheme.gameFont(size: 19, weight: .bold, relativeTo: .headline))
                                        Spacer(minLength: 4)
                                        Text("+1")
                                            .font(SpyTheme.brandFont(size: 25))
                                            .monospacedDigit()
                                    }
                                    .padding(.horizontal, 15)
                                    .frame(minHeight: 48)
                                    .foregroundStyle(.white)
                                    .background(SpyTheme.redDeep, in: CutCornerShape(cut: 9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(SpyWebPressStyle())
                                .disabled(isGenerating || !store.canWatch)
                                .accessibilityLabel(copy.watch)
                                .accessibilityIdentifier("generation.watchAd")
                                Text(copy.offerTerms)
                                    .foregroundStyle(SpyTheme.bodyText)
                            } else if store.notice != .unavailable {
                                Text(copy.notice(.unavailable))
                                    .foregroundStyle(SpyTheme.bodyText)
                            }
                            if appState.membership.canPurchase {
                                Button { showLimitless = true } label: {
                                    Label("LIMITLESS", systemImage: "infinity")
                                        .font(SpyTheme.brandFont(size: 19))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(SpyWebPressStyle())
                                .disabled(store.isWatching)
                            }
                        }
                        if let notice = store.notice,
                           notice != .earned, notice != .limitReached,
                           notice != .confirming || !status.needsReward {
                            Text(copy.notice(notice))
                                .foregroundStyle(SpyTheme.bodyText)
                                .accessibilityIdentifier("generation.notice")
                        }
                    }
                    .font(SpyTheme.gameFont(size: 15, relativeTo: .subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    var body: some View {
        Group {
#if DEBUG
            if UnityAdsTestConfiguration.current.isEnabled && !appState.shouldUsePreviewData {
                UnityAdsTestControl(isGenerating: isGenerating)
            }
#endif
#if DEBUG && targetEnvironment(simulator)
            if RewardedGenerationAdPresenter.shared.permitsLocalSampleTest(isPreview: appState.shouldUsePreviewData) {
                VStack(alignment: .leading, spacing: 12) {
                    SimulatorSampleAdTestControl(isGenerating: isGenerating)
                    allowanceContent
                }
            } else {
                allowanceContent
            }
#else
            allowanceContent
#endif
        }
        .preference(key: GenerationPresentationSource.self, value: true)
        .task(id: appState.membershipScope) {
            appState.bindMembershipAccount()
            _ = await store.refresh()
        }
        .task(id: "\(store.pendingAttemptID?.uuidString ?? "none")|\(store.isAwaitingReward)") {
            while store.isAwaitingReward && store.pendingAttemptID != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await store.recoverPending()
            }
        }
        .sheet(isPresented: $showLimitless) {
            PricingView().spyInterfaceScale().presentationDetents([.large])
        }
        .onDisappear {
            watchTask?.cancel()
            store.cancelPresentation()
        }
    }

    private func testAdControls(_ status: GenerationRewardStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.testTitle)
            Text(copy.bonus(status.bonusCredits))
                .foregroundStyle(SpyTheme.green)
                .accessibilityIdentifier("generation.bonusCredits")
            Text(copy.testDisclosure).foregroundStyle(SpyTheme.muted)
            if store.isAwaitingReward {
                Label(copy.notice(.confirming), systemImage: "clock").foregroundStyle(SpyTheme.amber)
            } else if status.testAdAvailable {
                Button {
                    watchTask?.cancel()
                    watchTask = Task { await store.watch(testAd: true) }
                } label: {
                    Label(store.isWatching ? copy.preparing : copy.testWatch, systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(SpyButtonStyle(variant: .outline, labelFont: SpyTheme.gameFont(size: 15, weight: .bold, relativeTo: .subheadline)))
                .disabled(isGenerating || !store.canWatchTestAd)
                .accessibilityIdentifier("generation.watchTestAd")
            }
            if let notice = store.notice, notice != .confirming {
                Text(copy.notice(notice))
                    .foregroundStyle(notice == .earned ? SpyTheme.green : SpyTheme.muted)
                    .accessibilityIdentifier("generation.notice")
            }
        }
        .font(SpyTheme.gameFont(size: 15, relativeTo: .subheadline))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpyTheme.panel, in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Shows Google's sample creative in the real game without changing its account,
/// generation allowance, or reward-recovery state.
private struct SimulatorSampleAdTestControl: View {
    @Environment(AppState.self) private var appState
    let isGenerating: Bool
    @State private var watchTask: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var notice: SampleNotice?

    private enum SampleNotice: Equatable { case completed, incomplete, unavailable }
    private var presenter: RewardedGenerationAdPresenter { .shared }
    private var store: GenerationRewardStore { appState.generationRewards }
    private var copy: GenerationRewardCopy { GenerationRewardCopy(language: appState.language) }
    private var canWatch: Bool {
        presenter.permitsLocalSampleTest(isPreview: appState.shouldUsePreviewData)
            && appState.membershipScope.isAuthenticated && !isGenerating
            && !store.isWatching && !store.isAwaitingReward && store.pendingAttemptID == nil
            && operationID == nil && presenter.canOfferAds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.text("TEST AD", "ТЕСТОВАЯ РЕКЛАМА", "ANUNCIO DE PRUEBA", "ТЕСТОВА РЕКЛАМА"))
            Text(copy.text(
                "Google test ad. Your generation balance stays unchanged.",
                "Тестовая реклама Google. Баланс генераций не меняется.",
                "Anuncio de prueba de Google. Tu saldo de generaciones no cambia.",
                "Тестова реклама Google. Баланс генерацій не змінюється."
            ))
            .foregroundStyle(SpyTheme.muted)
            Button(action: watch) {
                Label(operationID == nil ? copy.text(
                    "Watch a test ad", "Посмотреть тестовую рекламу", "Ver anuncio de prueba", "Переглянути тестову рекламу"
                ) : copy.preparing, systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(SpyButtonStyle(variant: .outline, labelFont: SpyTheme.gameFont(size: 15, weight: .bold, relativeTo: .subheadline)))
            .disabled(!canWatch)
            .accessibilityIdentifier("generation.watchSampleAd")
            if let notice {
                Text(noticeText(notice))
                    .foregroundStyle(notice == .completed ? SpyTheme.green : SpyTheme.muted)
                    .accessibilityIdentifier("generation.sampleAdNotice")
            }
        }
        .font(SpyTheme.gameFont(size: 15, relativeTo: .subheadline))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpyTheme.panel, in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
        .onChange(of: appState.membershipScope) { _, _ in cancel() }
        .onChange(of: isGenerating) { _, generating in if generating { cancel() } }
        .onDisappear { cancel() }
    }

    private func watch() {
        guard canWatch else { return }
        let id = UUID(), scope = appState.membershipScope
        operationID = id
        notice = nil
        watchTask = Task {
            defer {
                if operationID == id { operationID = nil; watchTask = nil }
            }
            do {
                let completed = try await presenter.presentLocalSampleTest(isPreview: appState.shouldUsePreviewData)
                guard !Task.isCancelled, operationID == id, appState.membershipScope == scope else { return }
                notice = completed ? .completed : .incomplete
            } catch {
                guard !Task.isCancelled, operationID == id, appState.membershipScope == scope else { return }
                if !(error is CancellationError) { notice = .unavailable }
            }
        }
    }

    private func cancel() {
        watchTask?.cancel()
        if operationID != nil { presenter.cancelPendingPresentation() }
        watchTask = nil
        operationID = nil
        notice = nil
    }

    private func noticeText(_ notice: SampleNotice) -> String {
        switch notice {
        case .completed:
            copy.text("Test viewing completed.", "Тестовый просмотр завершён.", "Visualización de prueba completada.", "Тестовий перегляд завершено.")
        case .incomplete:
            copy.text("Test ad closed before completion.", "Тестовая реклама закрыта до завершения.", "Anuncio de prueba cerrado antes de terminar.", "Тестову рекламу закрито до завершення.")
        case .unavailable:
            copy.text("Test ad unavailable. Try again.", "Тестовая реклама недоступна. Попробуй ещё раз.", "Anuncio de prueba no disponible. Inténtalo de nuevo.", "Тестова реклама недоступна. Спробуй ще раз.")
        }
    }
}
#endif

struct AdvertisingPrivacyButton: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        if RewardedGenerationAdPresenter.shared.privacyOptionsRequired {
            Button {
                Task {
                    do { try await RewardedGenerationAdPresenter.shared.presentPrivacyOptions() }
                    catch { appState.showToast(GenerationRewardCopy(language: appState.language).notice(.unavailable), kind: .error) }
                }
            } label: {
                Label(GenerationRewardCopy(language: appState.language).privacy, systemImage: "hand.raised")
                    .font(SpyTheme.gameFont(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("generation.adPrivacy")
        }
    }
}

#if DEBUG
struct GenerationRewardsPreview: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        ZStack {
            SpyBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SpyWordmark(fontSize: 30)
                    Text("ТВОИ ТЕМЫ").font(SpyTheme.gameFont(size: 24, weight: .bold, relativeTo: .title2))
                    Text("Тестовая реклама Google · локальная проверка. Настоящие генерации и аккаунты не изменяются.")
                        .font(SpyTheme.gameFont(size: 14, relativeTo: .footnote)).foregroundStyle(SpyTheme.muted)
                    GenerationAllowanceView()
                    Button("Сгенерировать тестовый набор") {
                        _ = appState.generationRewards.consumePreviewGeneration()
                    }
                    .buttonStyle(SpyButtonStyle(variant: .outline, labelFont: SpyTheme.gameFont(size: 15, weight: .bold, relativeTo: .subheadline)))
                    .disabled(appState.generationRewards.isWatching)
                    .accessibilityIdentifier("generation.previewGenerate")
                    AdvertisingPrivacyButton()
                }
                .padding(20)
            }
        }
    }
}
#endif
