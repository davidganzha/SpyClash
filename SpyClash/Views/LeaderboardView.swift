import SwiftUI

struct LeaderboardView: View {
    @Environment(AppState.self) private var appState

    @State private var entries: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var status = ""

    private var copy: LeaderboardCopy {
        appState.language.leaderboard
    }

    var body: some View {
        PageChrome(eyebrow: copy.eyebrow, status: copy.status) {
            VStack(alignment: .leading, spacing: 14) {
                header
                topThreeStrip
                board
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
        }
        .task {
            await load()
        }
        .onChange(of: status) { _, message in
            publishLeaderboardError(message)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                AnimatedTitle(
                    text: copy.title.uppercased(),
                    delay: 0.20,
                    fontSize: 31,
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
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
        }
        .spyWebEntrance(duration: 0.40, y: -8)
    }

    @ViewBuilder
    private var topThreeStrip: some View {
        if !entries.isEmpty {
            SpyPanel(accent: SpyTheme.amber, motionDelay: 0.25) {
                HStack(spacing: 8) {
                    ForEach(Array(entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        topAgentCard(entry: entry, rank: index + 1)
                            .spyWebEntrance(
                                delay: 0.25 + (Double(index) * 0.06),
                                duration: 0.40,
                                y: 10,
                                scale: 0.92
                            )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var board: some View {
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
        } else if entries.isEmpty {
            SpyPanel(motionDelay: 0.35) {
                VStack(spacing: 12) {
                    Image(systemName: "trophy")
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
        } else {
            SpyPanel(motionDelay: 0.35) {
                VStack(spacing: 0) {
                    boardHeader
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        rankRow(entry: entry, rank: index + 1)
                    }
                }
            }
        }
    }

    private func publishLeaderboardError(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appState.showToast(message, kind: .error)
        status = ""
    }

    private var boardHeader: some View {
        HStack {
            Text(copy.rankHeader)
                .frame(width: 34, alignment: .leading)
            Text(copy.playerHeader)
            Spacer()
            Text(copy.ratingHeader)
                .frame(width: 68, alignment: .trailing)
            Text(copy.winsHeader)
                .frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(0.04)
        .foregroundStyle(SpyTheme.dim)
        .padding(.bottom, 10)
    }

    private func topAgentCard(entry: LeaderboardEntry, rank: Int) -> some View {
        VStack(spacing: 5) {
            Text(rankMedal(rank))
                .font(.system(size: 24))
            Text(displayName(for: entry).uppercased())
                .font(.system(size: 10, weight: .black, design: .default))
                .tracking(0.02)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(entry.rating >= 0 ? "+" : "")\(entry.rating)")
                .font(.system(size: 17, weight: .black, design: .default))
                .foregroundStyle(rankColor(rank))
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(rankColor(rank).opacity(0.08))
        .overlay(Rectangle().stroke(rankColor(rank).opacity(0.24)))
    }

    private func rankRow(entry: LeaderboardEntry, rank: Int) -> some View {
        HStack(spacing: 10) {
            Text(rank <= 3 ? rankMedal(rank) : "#\(rank)")
                .font(.system(size: rank <= 3 ? 17 : 12, weight: .black, design: .monospaced))
                .foregroundStyle(rank <= 3 ? rankColor(rank) : SpyTheme.dim)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName(for: entry).uppercased())
                    .font(.system(size: 11, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(copy.detail(games: entry.games, winRate: entry.winRate))
                    .font(.system(size: 9, weight: .semibold, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58)
            }

            Spacer()

            Text("\(entry.rating >= 0 ? "+" : "")\(entry.rating)")
                .font(.system(size: 15, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(entry.rating >= 0 ? SpyTheme.green : SpyTheme.red)
                .frame(width: 68, alignment: .trailing)

            Text("\(entry.wins)")
                .font(SpyTheme.micro)
                .foregroundStyle(SpyTheme.green)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SpyTheme.stroke.opacity(rank == entries.count ? 0 : 1))
                .frame(height: 1)
        }
        .spyWebEntrance(
            delay: 0.40 + (Double(rank - 1) * 0.05),
            duration: 0.45,
            x: -20,
            y: 0
        )
    }

    private func load() async {
        if appState.shouldUsePreviewData {
            entries = Self.rank(GameHistory.previewLeaderboardPool)
            status = ""
            isLoading = false
            return
        }

        guard appState.user != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await appState.client.leaderboard()
            status = ""
        } catch {
            status = error.localizedDescription.uppercased()
        }
    }

    private static func rank(_ history: [GameHistory]) -> [LeaderboardEntry] {
        var table: [String: (rating: Int, games: Int, wins: Int, losses: Int)] = [:]

        for item in history {
            guard let email = item.playerEmail?.nilIfBlank else { continue }
            var current = table[email] ?? (rating: 0, games: 0, wins: 0, losses: 0)
            current.games += 1
            if item.won == true {
                current.wins += 1
                current.rating += item.role == "detective" ? 30 : 60
            } else {
                current.losses += 1
                current.rating += item.role == "detective" ? -20 : -40
            }
            table[email] = current
        }

        return table
            .map { email, stats in
                LeaderboardEntry(
                    id: email,
                    displayName: email.components(separatedBy: "@").first ?? email,
                    rating: stats.rating,
                    games: stats.games,
                    wins: stats.wins,
                    losses: stats.losses,
                    isCurrentUser: false
                )
            }
            .sorted { lhs, rhs in
                if lhs.rating == rhs.rating {
                    return lhs.wins > rhs.wins
                }
                return lhs.rating > rhs.rating
            }
    }

    private func displayName(for entry: LeaderboardEntry) -> String {
        if entry.isCurrentUser {
            return "YOU"
        }
        guard entry.displayName.count > 18 else { return entry.displayName }
        return String(entry.displayName.prefix(17)) + "…"
    }

    private func rankMedal(_ rank: Int) -> String {
        switch rank {
        case 1: "🥇"
        case 2: "🥈"
        case 3: "🥉"
        default: "#\(rank)"
        }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: SpyTheme.amber
        case 2: Color(red: 192 / 255, green: 192 / 255, blue: 192 / 255)
        case 3: Color(red: 205 / 255, green: 127 / 255, blue: 50 / 255)
        default: SpyTheme.dim
        }
    }
}
