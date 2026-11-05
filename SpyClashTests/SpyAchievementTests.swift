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

    func testGameplayStatisticsNeverGrantPaymentAwards() throws {
        let awards = SpyAchievementCatalog.progress(games: Int.max, wins: Int.max, spyWins: Int.max, detectiveWins: Int.max)
        for id in [SpyAchievementID.loyalty3, .loyalty6, .loyalty12] {
            let award = try XCTUnwrap(awards.first { $0.id == id.rawValue })
            XCTAssertEqual(award.progress, 0)
            XCTAssertFalse(award.isUnlocked)
        }
    }

    func testLoyaltyProgressUsesServerPaymentsAndCanonicalTierTargets() throws {
        let awards = SpyAchievementCatalog.normalized([
            SpyAchievementProgress(id: "loyalty_3", progress: 6, target: 99),
            SpyAchievementProgress(id: "loyalty_6", progress: 6, target: 1),
            SpyAchievementProgress(id: "loyalty_12", progress: 6, target: -1)
        ])
        let first = try XCTUnwrap(awards.first { $0.id == "loyalty_3" })
        let second = try XCTUnwrap(awards.first { $0.id == "loyalty_6" })
        let third = try XCTUnwrap(awards.first { $0.id == "loyalty_12" })
        XCTAssertEqual(first.target, 3)
        XCTAssertEqual(first.progress, 3)
        XCTAssertTrue(first.isUnlocked)
        XCTAssertEqual(second.target, 6)
        XCTAssertTrue(second.isUnlocked)
        XCTAssertEqual(third.target, 12)
        XCTAssertEqual(third.progress, 6)
        XCTAssertFalse(third.isUnlocked)
    }

    func testMissingOrInvalidPaymentProgressCannotUnlockLoyalty() throws {
        let awards = SpyAchievementCatalog.normalized([
            SpyAchievementProgress(id: "loyalty_3", progress: -10, target: 0),
            SpyAchievementProgress(id: "loyalty_6", progress: 5, target: 1)
        ])
        for id in [SpyAchievementID.loyalty3, .loyalty6, .loyalty12] {
            XCTAssertFalse(try XCTUnwrap(awards.first { $0.id == id.rawValue }).isUnlocked)
        }
        XCTAssertEqual(awards.first { $0.id == "loyalty_3" }?.progress, 0)
        XCTAssertEqual(awards.first { $0.id == "loyalty_12" }?.progress, 0)
    }
}
