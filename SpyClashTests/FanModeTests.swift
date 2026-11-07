import XCTest
@testable import SpyClash

final class FanModeTests: XCTestCase {
    func testProbabilityBoundariesAndDisabledMode() {
        let settings = FanModeSettings(isEnabled: true, allSpiesChance: 35, noSpiesChance: 25)
        let scenarios = (0..<100).map { settings.scenario(roll: $0) }
        XCTAssertEqual(scenarios.filter { $0 == .allSpies }.count, 35)
        XCTAssertEqual(scenarios.filter { $0 == .noSpies }.count, 25)
        XCTAssertEqual(scenarios.filter { $0 == .standard }.count, 40)
        XCTAssertEqual(FanModeSettings().scenario(roll: 0), .standard)
        XCTAssertEqual(FanModeSettings(isEnabled: true, allSpiesChance: 99, noSpiesChance: 99).normalized.noSpiesChance, 1)
        XCTAssertEqual(FanModeSettings(isEnabled: true, allSpiesChance: 0, noSpiesChance: 0).scenario(roll: 0), .standard)
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
