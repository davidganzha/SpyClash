import XCTest
@testable import SpyClash

final class SpyAchievementTests: XCTestCase {
    func testPublicProfileFromOlderServerRemainsDecodable() throws {
        let data = Data(#"{"id":"agent","spy_id":"123-456","display_name":"Agent","avatar":"🕵️","spy_card_theme":"field","spy_card_accent":"signal_red","spy_card_badge":"operative","rating":30,"games_played":10,"games_won":4,"win_rate":40,"spy_games_won":1,"detective_games_won":3}"#.utf8)
        let profile = try JSONDecoder().decode(PublicSpyProfile.self, from: data)
        XCTAssertNil(profile.achievements)
        XCTAssertTrue(try XCTUnwrap(profile.achievementProgress.first { $0.id == "field_agent" }).isUnlocked)
        XCTAssertEqual(profile.achievementProgress.first { $0.id == "double_agent" }?.progress, 1)
    }

    func testServerAwardsOverrideRankedCountsForUnrankedMultiplayer() throws {
        let profile = PublicSpyProfile(id: "agent", spyID: "123-456", displayName: "Agent", avatar: "🕵️", spyCardTheme: "field", spyCardAccent: "signal_red", spyCardBadge: "operative", rating: 0, gamesPlayed: 0, gamesWon: 0, winRate: 0, achievements: [SpyAchievementProgress(id: "first_mission", progress: 1, target: 1)])
        XCTAssertTrue(try XCTUnwrap(profile.achievementProgress.first { $0.id == "first_mission" }).isUnlocked)
        XCTAssertFalse(try XCTUnwrap(profile.achievementProgress.first { $0.id == "ghost" }).isUnlocked)
    }

    func testFutureAwardIDsAndMalformedProgressDoNotBreakCollection() {
        let values = SpyAchievementCatalog.normalized([
            SpyAchievementProgress(id: "future_award", progress: 1, target: 1),
            SpyAchievementProgress(id: "veteran", progress: Int.max, target: -1),
            SpyAchievementProgress(id: "ghost", progress: -5, target: 1)
        ])
        XCTAssertEqual(values.count, SpyAchievementID.allCases.count)
        XCTAssertEqual(values.first { $0.id == "veteran" }?.boundedProgress, 50)
        XCTAssertEqual(values.first { $0.id == "ghost" }?.boundedProgress, 0)
        XCTAssertFalse(values.contains { $0.id == "future_award" })
    }
}
