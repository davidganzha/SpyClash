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

    func primaryNeighbor(for direction: TabSwipeDirection) -> AppTab? {
        guard let index = Self.primaryCases.firstIndex(of: self) else { return nil }

        let targetIndex = switch direction {
        case .previous: index - 1
        case .next: index + 1
        }

        guard Self.primaryCases.indices.contains(targetIndex) else { return nil }
        return Self.primaryCases[targetIndex]
    }

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

enum TabSwipeDirection: Equatable {
    case previous
    case next
}

struct TabSwipeResolver {
    static let gestureMinimumDistance: CGFloat = 18
    static let minimumTranslation: CGFloat = 56
    static let horizontalDominanceRatio: CGFloat = 1.30

    static func resolve(
        translation: CGSize,
        isTextInputActive: Bool = false,
        isInteractiveHorizontalControlActive: Bool = false
    ) -> TabSwipeDirection? {
        guard !isTextInputActive,
              !isInteractiveHorizontalControlActive else {
            return nil
        }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)

        guard horizontal >= minimumTranslation,
              horizontal > vertical * horizontalDominanceRatio else {
            return nil
        }

        return translation.width < 0 ? .next : .previous
    }
}
