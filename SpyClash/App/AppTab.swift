import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case game
    case local
    case leaderboard
    case packs
    case history
    case profile

    var id: String { rawValue }

    static let primaryCases: [AppTab] = [.home, .packs, .profile]

    static func primaryCases(hasActiveRoom: Bool) -> [AppTab] {
        primaryCases
    }

    var showsBottomDock: Bool {
        switch self {
        case .game, .local:
            false
        default:
            true
        }
    }

    var dockRepresentative: AppTab {
        switch self {
        case .local:
            .home
        case .leaderboard, .history:
            .profile
        default:
            self
        }
    }

    var title: String {
        switch self {
        case .home: "HOME"
        case .game: "ROOM"
        case .local: "LOCAL"
        case .leaderboard: "RANK"
        case .packs: "PACKS"
        case .history: "HIST"
        case .profile: "PROFILE"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .game: "scope"
        case .local: "person.3.fill"
        case .leaderboard: "trophy.fill"
        case .packs: "shippingbox.fill"
        case .history: "clock.fill"
        case .profile: "person.crop.circle.fill"
        }
    }

    @MainActor
    @ViewBuilder
    func makeContentView() -> some View {
        switch self {
        case .home: HomeView()
        case .game: GameView()
        case .local: LocalGameView()
        case .leaderboard: LeaderboardView()
        case .packs: WordPacksView()
        case .history: HistoryView()
        case .profile: ProfileView()
        }
    }
}
