import XCTest
@testable import SpyClash

final class FanModeTests: XCTestCase {
    func testDefaultsGiveEverySurpriseTwoPercentAndNormalGameNinety() throws {
        let settings = FanModeSettings(isEnabled: true)
        let actual = Dictionary(grouping: (0..<100).map { settings.scenario(roll: $0) }, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(actual, [.allSpies: 2, .noSpies: 2, .splitWords: 2, .uniqueWords: 2, .loneCivilian: 2, .standard: 90])
        XCTAssertEqual(settings.standardChance, 90)
        XCTAssertEqual(try JSONDecoder().decode(FanModeSettings.self, from: Data("{}".utf8)), FanModeSettings())
    }

    func testProbabilityBoundariesAndDisabledMode() {
        let settings = FanModeSettings(isEnabled: true, allSpiesChance: 35, noSpiesChance: 25,
                                       splitWordsChance: 0, uniqueWordsChance: 0, loneCivilianChance: 0)
        let scenarios = (0..<100).map { settings.scenario(roll: $0) }
        XCTAssertEqual(scenarios.filter { $0 == .allSpies }.count, 35)
        XCTAssertEqual(scenarios.filter { $0 == .noSpies }.count, 25)
        XCTAssertEqual(scenarios.filter { $0 == .standard }.count, 40)
        XCTAssertEqual(FanModeSettings().scenario(roll: 0), .standard)
        XCTAssertEqual(FanModeSettings(isEnabled: true, allSpiesChance: 99, noSpiesChance: 99).normalized.noSpiesChance, 1)
        XCTAssertEqual(FanModeSettings(isEnabled: true, allSpiesChance: 0, noSpiesChance: 0,
                                      splitWordsChance: 0, uniqueWordsChance: 0, loneCivilianChance: 0).scenario(roll: 0), .standard)
    }

    func testAllFiveProbabilityRangesAndNormalization() {
        let settings = FanModeSettings(isEnabled: true, allSpiesChance: 7, noSpiesChance: 11,
                                       splitWordsChance: 17, uniqueWordsChance: 23, loneCivilianChance: 29)
        let actual = Dictionary(grouping: (0..<100).map { settings.scenario(roll: $0) }, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(actual, [.allSpies: 7, .noSpies: 11, .splitWords: 17, .uniqueWords: 23,
                                .loneCivilian: 29, .standard: 13])
        let malformed = FanModeSettings(isEnabled: true, allSpiesChance: -5, noSpiesChance: 21,
                                        splitWordsChance: 300, uniqueWordsChance: 32, loneCivilianChance: -1).normalized
        XCTAssertEqual(malformed.noSpiesChance, 21)
        XCTAssertEqual(malformed.splitWordsChance, 79)
        XCTAssertEqual(malformed.uniqueWordsChance, 0)
        XCTAssertEqual(malformed.standardChance, 0)
        XCTAssertEqual(malformed, malformed.normalized)
    }

    func testEveryChanceSliderKeepsItsValueAndTotalFits() {
        for scenario in FanScenario.surprises {
            var settings = FanModeSettings(isEnabled: true, allSpiesChance: 20, noSpiesChance: 20,
                                           splitWordsChance: 20, uniqueWordsChance: 20, loneCivilianChance: 20)
            settings.setChance(99, for: scenario)
            XCTAssertEqual(settings.chance(for: scenario), 99)
            XCTAssertEqual(settings, settings.normalized)
            XCTAssertEqual(FanScenario.surprises.reduce(0) { $0 + settings.chance(for: $1) }, 100)
            settings.setChance(-3, for: scenario)
            XCTAssertEqual(settings.chance(for: scenario), 0)
        }
    }

    func testStoredLegacySettingsKeepTheirOriginalProbabilities() throws {
        let legacy = Data(#"{"isEnabled":true,"allSpiesChance":35,"noSpiesChance":25}"#.utf8)
        let decoded = try JSONDecoder().decode(FanModeSettings.self, from: legacy)
        XCTAssertEqual(decoded, FanModeSettings(isEnabled: true, allSpiesChance: 35, noSpiesChance: 25,
                                               splitWordsChance: 0, uniqueWordsChance: 0, loneCivilianChance: 0))
        XCTAssertEqual(decoded.standardChance, 40)
        let allSettings = FanModeSettings(isEnabled: true, splitWordsChance: 20, uniqueWordsChance: 10, loneCivilianChance: 5)
        XCTAssertEqual(try JSONDecoder().decode(FanModeSettings.self, from: JSONEncoder().encode(allSettings)), allSettings)
    }

    func testStoredCustomValuesIncludingZeroRemainUnchanged() throws {
        for settings in [
            FanModeSettings(isEnabled: true, allSpiesChance: 15, noSpiesChance: 15,
                            splitWordsChance: 0, uniqueWordsChance: 0, loneCivilianChance: 0),
            FanModeSettings(isEnabled: true, allSpiesChance: 0, noSpiesChance: 0,
                            splitWordsChance: 0, uniqueWordsChance: 0, loneCivilianChance: 0),
        ] {
            let restored = try JSONDecoder().decode(FanModeSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.normalized, settings)
        }
        let partial = try JSONDecoder().decode(FanModeSettings.self, from: Data(#"{"allSpiesChance":0,"splitWordsChance":0}"#.utf8))
        XCTAssertEqual(partial.allSpiesChance, 0)
        XCTAssertEqual(partial.splitWordsChance, 0)
        XCTAssertEqual(partial.noSpiesChance, 2)
        XCTAssertEqual(partial.uniqueWordsChance, 0)
        XCTAssertEqual(partial.loneCivilianChance, 0)
    }

    @MainActor
    func testRoomFallbackUsesNewDefaultsAndKeepsExplicitZeros() {
        var room = GameRoom.previewRoom(status: "waiting")
        room.fanModeEnabled = true
        room.fanAllSpiesChance = nil
        room.fanNoSpiesChance = nil
        room.fanSplitWordsChance = nil
        room.fanUniqueWordsChance = nil
        room.fanLoneCivilianChance = nil
        XCTAssertEqual(room.fanSettings, FanModeSettings(isEnabled: true))
        room.fanAllSpiesChance = 15
        room.fanNoSpiesChance = 15
        XCTAssertEqual(room.fanSettings.standardChance, 70)
        XCTAssertEqual(room.fanSettings.splitWordsChance, 0)
        XCTAssertEqual(room.fanSettings.uniqueWordsChance, 0)
        XCTAssertEqual(room.fanSettings.loneCivilianChance, 0)
        room.fanAllSpiesChance = 0
        room.fanNoSpiesChance = 0
        room.fanSplitWordsChance = 0
        room.fanUniqueWordsChance = 0
        room.fanLoneCivilianChance = 0
        XCTAssertEqual(room.fanSettings.standardChance, 100)
    }

    func testTwoWordsAreSplitEvenlyAndEveryoneGetsOnlyOne() throws {
        for playerCount in [3, 4, 5, 8, 12] {
            for _ in 0..<10 {
                let deal = try XCTUnwrap(FanDealPolicy.deal(scenario: .splitWords, playerCount: playerCount,
                                                          word: "Apple", pool: ["Apple", "Pear", "Plum"]))
                XCTAssertTrue(deal.spyIndices.isEmpty)
                XCTAssertEqual(Set(deal.playerWords.keys), Set(0..<playerCount))
                let groups = Dictionary(grouping: deal.playerWords.values, by: { $0 }).mapValues(\.count)
                XCTAssertEqual(groups.count, 2)
                XCTAssertNotNil(groups["Apple"])
                XCTAssertEqual(groups.values.sorted(), [playerCount / 2, playerCount - playerCount / 2])
            }
        }
    }

    func testDistinctWordsNeverRepeatOrCountBlankAndCaseDuplicates() throws {
        XCTAssertEqual(FanDealPolicy.distinctWords([" Apple ", "APPLE", "", "  ", "Pear", "pear", "ＡＰＰＬＥ"]), ["Apple", "Pear"])
        XCTAssertNil(FanDealPolicy.deal(scenario: .uniqueWords, playerCount: 3, word: "Apple",
                                       pool: ["apple", "PEAR", " pear ", " "]))
        XCTAssertNil(FanDealPolicy.deal(scenario: .splitWords, playerCount: 4, word: "Apple", pool: [" APPLE "]))
        let pool = (0..<12).map { "Word \($0)" }
        for playerCount in [3, 5, 12] {
            let deal = try XCTUnwrap(FanDealPolicy.deal(scenario: .uniqueWords, playerCount: playerCount,
                                                      word: pool[0], pool: pool))
            XCTAssertTrue(deal.spyIndices.isEmpty)
            XCTAssertEqual(Set(deal.playerWords.keys), Set(0..<playerCount))
            XCTAssertEqual(Set(deal.playerWords.values).count, playerCount)
            XCTAssertTrue(deal.playerWords.values.contains(pool[0]))
        }
    }

    func testLoneCivilianIsTheOnlyPlayerWithAWord() throws {
        for playerCount in [3, 4, 8, 12] {
            for _ in 0..<10 {
                let deal = try XCTUnwrap(FanDealPolicy.deal(scenario: .loneCivilian, playerCount: playerCount,
                                                          word: "Apple", pool: ["Apple", "Pear"]))
                XCTAssertEqual(Set(deal.spyIndices).count, playerCount - 1)
                XCTAssertEqual(deal.playerWords.count, 1)
                let civilian = try XCTUnwrap(deal.playerWords.keys.first)
                XCTAssertFalse(deal.spyIndices.contains(civilian))
                XCTAssertEqual(deal.playerWords[civilian], "Apple")
            }
        }
    }

    @MainActor
    func testNewLobbyProbabilitiesAndFinishedAssignmentsUseWireKeys() throws {
        let settings = FanModeSettings(isEnabled: true, splitWordsChance: 20, uniqueWordsChance: 10, loneCivilianChance: 5)
        let payload = LobbyStatePayload(gameMode: .questions, gameDurationSeconds: 900, fanSettings: settings,
                                       lobbyWordSource: .ai, lobbySourcePackID: nil, lobbySourceName: "Test",
                                       lobbyTheme: nil, lobbyCategory: "Test", lobbyWordCount: 2,
                                       lobbyWordCountMode: .custom, lobbyWordPool: [.init(word: "Apple"), .init(word: "Pear")])
        let encoded = try JSONEncoder().encode(payload)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(keys["fan_split_words_chance"] as? Int, 20)
        XCTAssertEqual(keys["fan_unique_words_chance"] as? Int, 10)
        XCTAssertEqual(keys["fan_lone_civilian_chance"] as? Int, 5)
        XCTAssertEqual(try JSONDecoder().decode(LobbyStatePayload.self, from: encoded), payload)
        for keyPath in [\LobbyStatePayload.fanSplitWordsChance, \.fanUniqueWordsChance, \.fanLoneCivilianChance] {
            var changed = payload
            changed[keyPath: keyPath] += 1
            XCTAssertFalse(payload.equivalentForLobbySync(to: changed))
        }
        var legacyKeys = keys
        for key in ["fan_split_words_chance", "fan_unique_words_chance", "fan_lone_civilian_chance"] { legacyKeys.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(LobbyStatePayload.self, from: JSONSerialization.data(withJSONObject: legacyKeys))
        XCTAssertEqual(legacy.fanSplitWordsChance, 0)
        XCTAssertEqual(legacy.fanUniqueWordsChance, 0)
        XCTAssertEqual(legacy.fanLoneCivilianChance, 0)
        legacyKeys.removeValue(forKey: "fan_all_spies_chance")
        legacyKeys.removeValue(forKey: "fan_no_spies_chance")
        let fresh = try JSONDecoder().decode(LobbyStatePayload.self, from: JSONSerialization.data(withJSONObject: legacyKeys))
        XCTAssertEqual([fresh.fanAllSpiesChance, fresh.fanNoSpiesChance, fresh.fanSplitWordsChance,
                        fresh.fanUniqueWordsChance, fresh.fanLoneCivilianChance], [2, 2, 2, 2, 2])

        var room = GameRoom.previewRoom(status: "finished")
        room.fanModeEnabled = true
        room.fanAllSpiesChance = settings.allSpiesChance
        room.fanNoSpiesChance = settings.noSpiesChance
        room.fanSplitWordsChance = settings.splitWordsChance
        room.fanUniqueWordsChance = settings.uniqueWordsChance
        room.fanLoneCivilianChance = settings.loneCivilianChance
        room.fanPlayerWords = ["first@example.com": "Apple", "second@example.com": "Pear"]
        room.fanScenario = FanScenario.splitWords.rawValue
        room.winner = "draw"
        let decoded = try JSONDecoder().decode(GameRoom.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded.fanSettings, settings)
        XCTAssertEqual(decoded.fanPlayerWords, room.fanPlayerWords)
        XCTAssertEqual(FinishedRoomResultPolicy.fanDrawScenario(in: decoded), .splitWords)
    }

    func testOnlyPlayersCanReceiveVotes() {
        for invalidTarget in [-1, -2, 0, 9] {
            XCTAssertNil(FanVotePolicy.appending(voter: 0, target: invalidTarget, active: [0, 1, 2], votes: []))
        }
        let votes = [LocalPrivateVote(voterIndex: 0, targetIndex: 2)]
        XCTAssertNil(FanVotePolicy.appending(voter: 0, target: 1, active: [0, 1, 2], votes: votes))
        XCTAssertNil(FanVotePolicy.appending(voter: 4, target: 1, active: [0, 1, 2], votes: []))
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: votes), .pending)
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: votes + [.init(voterIndex: 1, targetIndex: 2)]), .player(2))
    }

    func testSplitBallotContinuesAndLegacyConceptVotesCannotEndGame() {
        let split = [LocalPrivateVote(voterIndex: 0, targetIndex: 1), .init(voterIndex: 1, targetIndex: 2), .init(voterIndex: 2, targetIndex: 0)]
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: split), .cancelled)
        for target in [-1, -2] {
            let legacyVotes = (0..<3).map { LocalPrivateVote(voterIndex: $0, targetIndex: target) }
            XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: legacyVotes), .pending)
        }
        let duplicates = [LocalPrivateVote(voterIndex: 0, targetIndex: 2), .init(voterIndex: 0, targetIndex: 2), .init(voterIndex: 9, targetIndex: 2)]
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: duplicates), .pending)
    }

    @MainActor
    func testLobbySettingsRoundTripAndConceptVotesAreRejected() throws {
        var room = GameRoom.previewRoom(status: "playing")
        room.fanModeEnabled = true
        room.fanAllSpiesChance = 99
        room.fanNoSpiesChance = 1
        room.matchID = "fan-test-match"
        room.detectiveVoteRoundID = "fan-vote"
        let actor = try XCTUnwrap(room.activePlayers.first?.email)
        XCTAssertNil(DetectiveVoteCastScope(room: room, actorEmail: actor, targetEmail: "__fan_no_spies__"))
        room.fanModeEnabled = false
        XCTAssertNil(DetectiveVoteCastScope(room: room, actorEmail: actor, targetEmail: "__fan_no_spies__"))
        room.fanModeEnabled = true
        let encoded = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(GameRoom.self, from: encoded)
        XCTAssertEqual(decoded.fanSettings, room.fanSettings)
        XCTAssertNil(decoded.fanScenario)
    }
}
