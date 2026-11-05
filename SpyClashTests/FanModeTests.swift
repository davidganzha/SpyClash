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

    func testConceptNeedsEveryEligibleVoterAndSplitBallotContinues() {
        let all = FanScenario.allSpies.localTarget
        let no = FanScenario.noSpies.localTarget
        let firstTwo = [LocalPrivateVote(voterIndex: 0, targetIndex: all), LocalPrivateVote(voterIndex: 1, targetIndex: all)]
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: firstTwo), .pending)
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: firstTwo + [.init(voterIndex: 2, targetIndex: all)]), .concept(.allSpies))
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: firstTwo + [.init(voterIndex: 2, targetIndex: no)]), .cancelled)
        XCTAssertNil(FanVotePolicy.appending(voter: 0, target: no, active: [0, 1, 2], votes: firstTwo))
        XCTAssertNil(FanVotePolicy.appending(voter: 4, target: no, active: [0, 1, 2], votes: []))
        XCTAssertNil(FanVotePolicy.appending(voter: 0, target: 0, active: [0, 1, 2], votes: []))
    }

    func testPlayerAccusationAndInvalidVotesDoNotResolveAConcept() {
        let votes = [LocalPrivateVote(voterIndex: 0, targetIndex: 2), LocalPrivateVote(voterIndex: 1, targetIndex: 2)]
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: votes), .player(2))
        let invalid = [LocalPrivateVote(voterIndex: 9, targetIndex: -1), .init(voterIndex: 0, targetIndex: -1), .init(voterIndex: 0, targetIndex: -1)]
        XCTAssertEqual(FanVotePolicy.decision(active: [0, 1, 2], votes: invalid), .pending)
    }

    @MainActor
    func testLobbySettingsRoundTripAndConceptRecoveryScope() throws {
        var room = GameRoom.previewRoom(status: "playing")
        room.fanModeEnabled = true
        room.fanAllSpiesChance = 99
        room.fanNoSpiesChance = 1
        room.matchID = "fan-test-match"
        room.detectiveVoteRoundID = "fan-vote"
        let actor = try XCTUnwrap(room.activePlayers.first?.email)
        XCTAssertNotNil(DetectiveVoteCastScope(room: room, actorEmail: actor, targetEmail: FanScenario.noSpies.voteTarget))
        room.fanModeEnabled = false
        XCTAssertNil(DetectiveVoteCastScope(room: room, actorEmail: actor, targetEmail: FanScenario.noSpies.voteTarget))
        room.fanModeEnabled = true
        let encoded = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(GameRoom.self, from: encoded)
        XCTAssertEqual(decoded.fanSettings, room.fanSettings)
        XCTAssertNil(decoded.fanScenario)
    }
}
