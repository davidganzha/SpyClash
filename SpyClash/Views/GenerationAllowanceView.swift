import SwiftUI

/// Only embedded in explicit word-generation setup. Never presented at a round
/// boundary, on launch, or as a prerequisite for using saved word packs.
struct GenerationAllowanceView: View {
    @Environment(AppState.self) private var appState
    var isGenerating = false
    @State private var watchTask: Task<Void, Never>?
    @State private var showLimitless = false

    private var store: GenerationRewardStore { appState.generationRewards }
    private var copy: GenerationRewardCopy { GenerationRewardCopy(language: appState.language) }

    var body: some View {
        Group {
            if let status = store.snapshot, store.showsTestAdControls {
                testAdControls(status)
            } else if let status = store.snapshot, status.enabled {
                VStack(alignment: .leading, spacing: 10) {
                    if status.unlimited {
                        Label(copy.unlimited, systemImage: "infinity")
                            .foregroundStyle(SpyTheme.green)
                    } else {
                        Text(copy.free(status.freeRemaining ?? 0, limit: status.dailyLimit))
                            .accessibilityIdentifier("generation.freeRemaining")
                        if status.bonusCredits > 0 {
                            Text(copy.bonus(status.bonusCredits))
                                .foregroundStyle(SpyTheme.green)
                                .accessibilityIdentifier("generation.bonusCredits")
                        }
                        if let reset = status.resetsAt {
                            Text(copy.reset(reset)).font(SpyTheme.micro).foregroundStyle(SpyTheme.muted)
                        }
                        if status.needsReward {
                            Text(copy.disclosure).font(SpyTheme.mono).foregroundStyle(SpyTheme.muted)
                            if store.isAwaitingReward {
                                Label(copy.notice(.confirming), systemImage: "clock")
                                    .font(SpyTheme.mono).foregroundStyle(SpyTheme.amber)
                            } else if status.adAvailable && RewardedGenerationAdPresenter.shared.isConfigured {
                                Button {
                                    watchTask?.cancel()
                                    watchTask = Task { await store.watch() }
                                } label: {
                                    Label(store.isWatching ? copy.preparing : copy.watch, systemImage: "play.rectangle")
                                        .frame(maxWidth: .infinity)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .buttonStyle(SpyButtonStyle(variant: .outline))
                                .disabled(isGenerating || !store.canWatch)
                                .accessibilityIdentifier("generation.watchAd")
                            } else {
                                Text(copy.notice(.unavailable)).font(SpyTheme.mono).foregroundStyle(SpyTheme.muted)
                            }
                            if appState.membership.canPurchase {
                                Button("LIMITLESS") { showLimitless = true }
                                    .buttonStyle(SpyButtonStyle(variant: .outline))
                                    .disabled(store.isWatching)
                            }
                            Text(copy.alternative).font(SpyTheme.micro).foregroundStyle(SpyTheme.muted)
                        }
                        if let notice = store.notice, notice != .confirming || !status.needsReward {
                            Text(copy.notice(notice)).font(SpyTheme.mono)
                                .foregroundStyle(notice == .earned ? SpyTheme.green : SpyTheme.muted)
                                .accessibilityIdentifier("generation.notice")
                        }
                    }
                }
                .font(SpyTheme.mono)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SpyTheme.panel, in: CutCornerShape(cut: 10))
                .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
            }
        }
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
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isGenerating || !store.canWatchTestAd)
                .accessibilityIdentifier("generation.watchTestAd")
            }
            if let notice = store.notice, notice != .confirming {
                Text(copy.notice(notice))
                    .foregroundStyle(notice == .earned ? SpyTheme.green : SpyTheme.muted)
                    .accessibilityIdentifier("generation.notice")
            }
        }
        .font(SpyTheme.mono)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpyTheme.panel, in: CutCornerShape(cut: 10))
        .overlay(CutCornerShape(cut: 10).stroke(SpyTheme.stroke, lineWidth: 1))
    }
}

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
                    Text("ТВОИ ТЕМЫ").font(.title2.bold())
                    Text("Тестовая реклама Google · локальная проверка. Настоящие генерации и аккаунты не изменяются.")
                        .font(.footnote).foregroundStyle(SpyTheme.muted)
                    GenerationAllowanceView()
                    Button("Сгенерировать тестовый набор") {
                        _ = appState.generationRewards.consumePreviewGeneration()
                    }
                    .buttonStyle(SpyButtonStyle(variant: .outline))
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
