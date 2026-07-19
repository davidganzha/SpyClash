import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var history: [GameHistory] = []
    @State private var isLoading = false
    @State private var status = ""

    private var copy: HistoryCopy {
        appState.language.history
    }

    var body: some View {
        PageChrome(eyebrow: copy.eyebrow, status: copy.status) {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryPanel
                content
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
        }
        .task {
            if !appState.shouldUsePreviewData && appState.membership == nil {
                await appState.refreshSubscription()
            }
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                AnimatedTitle(
                    text: copy.title.uppercased(),
                    delay: 0.20,
                    fontSize: 34,
                    letterSpacing: 1.5
                )
                Text(copy.subtitle)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)
                    .spyKicker(lines: 2)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .disabled(isLoading)
        }
        .spyWebEntrance(duration: 0.40, y: -8)
    }

    private var summaryPanel: some View {
        SpyPanel(accent: SpyTheme.green, motionDelay: 0.25) {
            HStack {
                metric(copy.games, summaryGamesLabel)
                metric(copy.wins, "\(wins)")
                metric(copy.rate, "\(winRate)%")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            SpyPanel(motionDelay: 0.35) {
                HStack(spacing: 12) {
                    SpySpinner(size: 20, accent: SpyTheme.red)
                    Text(copy.loading)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker(lines: 2)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            }
        } else if history.isEmpty {
            SpyPanel(motionDelay: 0.35) {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(SpyTheme.red)
                    Text(copy.empty)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker(lines: 2, alignment: .center)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }

            if appState.membershipTier == .free {
                upgradeArchivePanel
            }
        } else {
            if hasAdvancedStatistics {
                advancedAnalyticsPanel
            }

            ForEach(Array(visibleHistory.enumerated()), id: \.element.id) { index, item in
                historyRow(item, index: index)
            }

            if appState.membershipTier == .free {
                upgradeArchivePanel
            } else if appState.membershipTier == nil {
                membershipUnavailablePanel
            }
        }

        if !status.isEmpty {
            Text(status)
                .font(SpyTheme.micro)
                .tracking(0.35)
                .foregroundStyle(SpyTheme.red)
                .spyFitted(lines: 2, scale: 0.62)
                .spyWebEntrance(delay: 0.35, duration: 0.40, y: 8)
        }
    }

    private var sortedHistory: [GameHistory] {
        history.sorted { ($0.createdDate ?? "") > ($1.createdDate ?? "") }
    }

    private var visibleHistory: [GameHistory] {
        guard !hasFullHistory else { return sortedHistory }
        return Array(sortedHistory.prefix(historyLimit))
    }

    private var metricsHistory: [GameHistory] {
        hasAdvancedStatistics ? sortedHistory : visibleHistory
    }

    private var hasFullHistory: Bool {
        appState.membershipBenefits?.fullHistory == true
    }

    private var hasAdvancedStatistics: Bool {
        appState.membershipBenefits?.advancedStatistics == true
    }

    private var historyLimit: Int {
        max(1, appState.membershipBenefits?.historyLimit ?? 5)
    }

    private var summaryGamesLabel: String {
        hasFullHistory || history.count <= visibleHistory.count
            ? "\(visibleHistory.count)"
            : "\(visibleHistory.count)/\(history.count)"
    }

    private var wins: Int {
        metricsHistory.filter { $0.won == true }.count
    }

    private var winRate: Int {
        guard !metricsHistory.isEmpty else { return 0 }
        return Int((Double(wins) / Double(metricsHistory.count) * 100).rounded())
    }

    private var advancedAnalyticsPanel: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0.30) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(SpyTheme.red)
                    Text(localized(
                        en: "LIMITLESS ANALYTICS",
                        ru: "АНАЛИТИКА LIMITLESS",
                        es: "ANALITICA LIMITLESS"
                    ))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.64)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    analyticsMetric(
                        localized(en: "SPY WIN RATE", ru: "ПОБЕДЫ ШПИОНА", es: "VICTORIAS ESPIA"),
                        value: "\(roleWinRate("spy"))%",
                        accent: SpyTheme.red
                    )
                    analyticsMetric(
                        localized(en: "DETECTIVE WIN RATE", ru: "ПОБЕДЫ ДЕТЕКТИВА", es: "VICTORIAS DETECTIVE"),
                        value: "\(roleWinRate("detective"))%",
                        accent: SpyTheme.green
                    )
                }

                HStack(spacing: 10) {
                    analyticsMetric(
                        localized(en: "CURRENT STREAK", ru: "ТЕКУЩАЯ СЕРИЯ", es: "RACHA ACTUAL"),
                        value: "\(currentWinStreak)",
                        accent: SpyTheme.amber
                    )
                    analyticsMetric(
                        localized(en: "AVG LOBBY", ru: "СРЕДНЕЕ ЛОББИ", es: "LOBBY PROMEDIO"),
                        value: averageLobbySize,
                        accent: .white
                    )
                }
            }
        }
    }

    private var upgradeArchivePanel: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0.38) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(SpyTheme.red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(localized(
                            en: "FREE ARCHIVE // RECENT \(historyLimit)",
                            ru: "АРХИВ FREE // ПОСЛЕДНИЕ \(historyLimit)",
                            es: "ARCHIVO FREE // ULTIMAS \(historyLimit)"
                        ))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(.white)

                        Text(localized(
                            en: "LIMITLESS unlocks the complete match archive, role win rates, streaks and lobby analytics.",
                            ru: "LIMITLESS открывает весь архив матчей, победы по ролям, серии и аналитику лобби.",
                            es: "LIMITLESS abre todo el archivo, victorias por rol, rachas y analitica de lobby."
                        ))
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    appState.presentedSheet = .pricing
                } label: {
                    Label(
                        localized(en: "UNLOCK FULL ARCHIVE", ru: "ОТКРЫТЬ ВЕСЬ АРХИВ", es: "ABRIR ARCHIVO COMPLETO"),
                        systemImage: "bolt.fill"
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
            }
        }
    }

    private var membershipUnavailablePanel: some View {
        HStack(spacing: 9) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
            Text(localized(
                en: "MEMBERSHIP STATUS UNAVAILABLE // SHOWING RECENT HISTORY",
                ru: "СТАТУС ПОДПИСКИ НЕДОСТУПЕН // ПОКАЗАНА НЕДАВНЯЯ ИСТОРИЯ",
                es: "ESTADO NO DISPONIBLE // MOSTRANDO HISTORIAL RECIENTE"
            ))
        }
        .font(.system(size: 8, weight: .bold, design: .monospaced))
        .tracking(0.06)
        .foregroundStyle(SpyTheme.amber)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpyTheme.amber.opacity(0.06))
        .overlay(Rectangle().stroke(SpyTheme.amber.opacity(0.28)))
    }

    private func analyticsMetric(_ title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(SpyTheme.brandFont(size: 25))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(0.06)
                .foregroundStyle(SpyTheme.faint)
                .spyFitted(lines: 2, scale: 0.58)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func roleWinRate(_ role: String) -> Int {
        let matches = sortedHistory.filter { $0.role?.lowercased() == role }
        guard !matches.isEmpty else { return 0 }
        let roleWins = matches.filter { $0.won == true }.count
        return Int((Double(roleWins) / Double(matches.count) * 100).rounded())
    }

    private var currentWinStreak: Int {
        sortedHistory.prefix { $0.won == true }.count
    }

    private var averageLobbySize: String {
        let lobbySizes = sortedHistory.compactMap(\.playerCount).filter { $0 > 0 }
        guard !lobbySizes.isEmpty else { return "—" }
        let average = Double(lobbySizes.reduce(0, +)) / Double(lobbySizes.count)
        return String(format: "%.1f", average)
    }

    private func localized(en: String, ru: String, es: String) -> String {
        switch appState.language {
        case .ru: ru
        case .es: es
        default: en
        }
    }

    private func historyRow(_ item: GameHistory, index: Int) -> some View {
        let won = item.won == true
        let role = copy.roleLabel(item.role).uppercased()
        let accent = won ? SpyTheme.green : SpyTheme.red

        return SpyPanel(accent: accent, motionDelay: 0, animatesEntrance: false) {
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 5) {
                    Text(item.role == "spy" ? "🕵️" : "🔍")
                        .font(.system(size: 24))
                    Text(role)
                        .font(.system(size: 9, weight: .bold, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.62, alignment: .center)
                }
                .frame(width: 54)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text((item.word ?? "?").uppercased())
                            .font(.system(size: 18, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(scale: 0.56)
                        Text((item.category ?? copy.categoryFallback).uppercased())
                            .font(.system(size: 9, weight: .bold, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(SpyTheme.dim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }

                    HStack(spacing: 8) {
                        Text("\(item.playerCount ?? 0) \(copy.operatives)")
                        Text("//")
                        Text(item.roomCode?.uppercased() ?? copy.roomFallback)
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.dim)
                }

                Spacer()

                Text(copy.resultLabel(won: won))
                    .font(.system(size: 11, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(accent)
                    .spyFitted(scale: 0.58, alignment: .center)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(accent.opacity(0.1))
                    .overlay(Rectangle().stroke(accent.opacity(0.35)))
            }
        }
        .spyWebEntrance(
            delay: 0.35 + (Double(index) * 0.05),
            duration: 0.45,
            x: -20,
            y: 0
        )
    }

    private func metric(_ title: String, _ value: String) -> some View {
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

    private func load() async {
        guard !isLoading else { return }
        if appState.shouldUsePreviewData {
            history = GameHistory.previewArchive
            status = ""
            isLoading = false
            return
        }

        guard let email = appState.user?.email else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loadedHistory = try await appState.client.gameHistory(
                email: email,
                limit: hasFullHistory ? nil : historyLimit
            )
            try Task.checkCancellation()
            guard appState.user?.email == email else { return }
            history = loadedHistory
            status = ""
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription.uppercased()
        }
    }
}
