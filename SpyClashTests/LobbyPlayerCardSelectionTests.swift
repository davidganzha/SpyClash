import Foundation
import XCTest
@testable import SpyClash

final class LobbyPlayerCardSelectionTests: XCTestCase {
    private func room() -> GameRoom {
        var room = GameRoom.previewRoom(status: "waiting")
        room.players = [
            Player(email: "host@example.test", name: "Host", avatar: "🕵️", userID: "host-id", membershipID: "host-membership-1"),
            Player(email: "target@example.test", name: "Target", avatar: "🎭", userID: "target-id", membershipID: "target-membership-1"),
            Player(email: "guest@example.test", name: "Guest", avatar: "👤", userID: "guest-id", membershipID: "guest-membership-1")
        ]
        room.hostEmail = "host@example.test"
        room.viewerMembershipID = "host-membership-1"
        room.roomRevision = 40
        room.lobbyRevision = 6
        return room
    }

    private func selection(in room: GameRoom, targetIndex: Int = 1, actorIndex: Int = 0) throws -> LobbyPlayerCardSelection {
        let actor = room.playersList[actorIndex]
        return try XCTUnwrap(LobbyPlayerCardSelection(
            player: room.playersList[targetIndex], room: room,
            actorID: actor.userID, actorEmail: actor.email
        ))
    }

    private func replacingRoomID(_ room: GameRoom) throws -> GameRoom {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any])
        object["id"] = "another-room"
        return try JSONDecoder().decode(GameRoom.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOnlyCurrentRosterPublicIdentityCanOpenCardInLobbyPhases() throws {
        var room = room()
        for phase in ["waiting", "ready_voting"] {
            room.status = phase
            let selected = try selection(in: room)
            XCTAssertEqual(selected.profileID, "target-id")
            XCTAssertEqual(selected.currentPlayer(room: room, accountID: "host-id"), room.playersList[1])
        }
        for phase in ["roulette", "playing", "finished", "ended"] {
            room.status = phase
            XCTAssertNil(LobbyPlayerCardSelection(player: room.playersList[1], room: room, actorID: "host-id", actorEmail: "host@example.test"))
        }
        room.status = "waiting"
        var missingID = room.playersList[1]
        missingID.userID = nil
        room.players?[1] = missingID
        XCTAssertNil(LobbyPlayerCardSelection(player: missingID, room: room, actorID: "host-id", actorEmail: "host@example.test"))
        XCTAssertNil(LobbyPlayerCardSelection(player: room.playersList[0], room: room, actorID: nil, actorEmail: "host@example.test"))
    }

    func testAccountRoomAndActorMembershipChangesInvalidateOpenCard() throws {
        let room = room()
        let selected = try selection(in: room)
        XCTAssertFalse(selected.matchesActor(room: nil, accountID: "host-id"))
        XCTAssertFalse(selected.matchesActor(room: room, accountID: "another-account"))
        XCTAssertFalse(selected.matchesActor(room: try replacingRoomID(room), accountID: "host-id"))
        var changed = room
        changed.players?[0].membershipID = "host-membership-2"
        changed.viewerMembershipID = "host-membership-2"
        XCTAssertFalse(selected.matchesActor(room: changed, accountID: "host-id"))
        changed = room
        changed.players?[0].userID = "replacement-host-id"
        XCTAssertFalse(selected.matchesActor(room: changed, accountID: "host-id"))
        changed = room
        changed.players?.removeFirst()
        XCTAssertFalse(selected.matchesActor(room: changed, accountID: "host-id"))
        changed = room
        changed.status = "playing"
        XCTAssertFalse(selected.matchesActor(room: changed, accountID: "host-id"))
    }

    func testTargetRejoinRemovalOrDuplicateIdentityInvalidatesCardButCosmeticUpdateDoesNot() throws {
        let room = room()
        let selected = try selection(in: room)
        var changed = room
        changed.players?[1].membershipID = "target-membership-2"
        XCTAssertNil(selected.currentPlayer(room: changed, accountID: "host-id"))
        changed = room
        changed.players?.remove(at: 1)
        XCTAssertNil(selected.currentPlayer(room: changed, accountID: "host-id"))
        changed = room
        changed.players?.append(room.playersList[1])
        XCTAssertNil(selected.currentPlayer(room: changed, accountID: "host-id"))
        XCTAssertNil(LobbyPlayerCardSelection(player: room.playersList[1], room: changed, actorID: "host-id", actorEmail: "host@example.test"))
        changed = room
        changed.players?[1].name = "Updated name"
        changed.players?[1].avatar = "🦊"
        XCTAssertEqual(selected.currentPlayer(room: changed, accountID: "host-id")?.name, "Updated name")
    }

    func testAmbiguousActorRosterCannotOpenOrKeepActionableCard() throws {
        let room = room()
        let selected = try selection(in: room)
        var duplicated = room
        duplicated.players?.append(room.playersList[0])
        XCTAssertNil(LobbyPlayerCardSelection(player: room.playersList[1], room: duplicated, actorID: "host-id", actorEmail: "host@example.test"))
        XCTAssertFalse(selected.matchesActor(room: duplicated, accountID: "host-id"))
        XCTAssertFalse(selected.canManage(room: duplicated, accountID: "host-id"))
    }

    func testOnlyHostCanManageOtherPlayerAndSelfCardRemainsViewable() throws {
        let room = room()
        let hostSelection = try selection(in: room)
        XCTAssertTrue(hostSelection.canManage(room: room, accountID: "host-id"))
        let selfSelection = try selection(in: room, targetIndex: 0)
        XCTAssertTrue(selfSelection.isSelf)
        XCTAssertNotNil(selfSelection.currentPlayer(room: room, accountID: "host-id"))
        XCTAssertFalse(selfSelection.canManage(room: room, accountID: "host-id"))
        let guestSelection = try selection(in: room, actorIndex: 2)
        XCTAssertFalse(guestSelection.canManage(room: room, accountID: "guest-id"))
        let guestViewingHost = try selection(in: room, targetIndex: 0, actorIndex: 2)
        XCTAssertFalse(guestViewingHost.canManage(room: room, accountID: "guest-id"))
        var transferred = room
        transferred.hostEmail = room.playersList[2].email
        XCTAssertFalse(hostSelection.canManage(room: transferred, accountID: "host-id"))
    }

    func testTransferAdoptsConfirmedHostAndAlreadyPolledSuccessWithoutRegressingRevision() throws {
        let room = room()
        let selected = try selection(in: room)
        var candidate = room
        candidate.hostEmail = room.playersList[1].email
        candidate.roomRevision = 41
        XCTAssertTrue(selected.canAdopt(candidate, over: room, accountID: "host-id", transferring: true))
        XCTAssertTrue(selected.canAdopt(candidate, over: candidate, accountID: "host-id", transferring: true))
        var newerCurrent = candidate
        newerCurrent.roomRevision = 42
        XCTAssertFalse(selected.canAdopt(candidate, over: newerCurrent, accountID: "host-id", transferring: true))
        var wrongHost = candidate
        wrongHost.hostEmail = room.playersList[2].email
        XCTAssertFalse(selected.canAdopt(wrongHost, over: room, accountID: "host-id", transferring: true))
        XCTAssertFalse(selected.canAdopt(room, over: room, accountID: "host-id", transferring: true))
    }

    func testKickAdoptsOnlyConfirmedRemovalAndAlreadyPolledSuccess() throws {
        let room = room()
        let selected = try selection(in: room)
        var candidate = room
        candidate.players?.remove(at: 1)
        candidate.roomRevision = 41
        XCTAssertTrue(selected.canAdopt(candidate, over: room, accountID: "host-id", transferring: false))
        XCTAssertTrue(selected.canAdopt(candidate, over: candidate, accountID: "host-id", transferring: false))
        XCTAssertFalse(selected.canAdopt(room, over: room, accountID: "host-id", transferring: false))
        var changedHost = candidate
        changedHost.hostEmail = room.playersList[2].email
        XCTAssertFalse(selected.canAdopt(changedHost, over: room, accountID: "host-id", transferring: false))
        var oldCandidate = candidate
        oldCandidate.roomRevision = 39
        XCTAssertFalse(selected.canAdopt(oldCandidate, over: room, accountID: "host-id", transferring: false))
    }

    func testResponsesFromAnotherRoomActorMembershipOrPhaseAreRejected() throws {
        let room = room()
        let selected = try selection(in: room)
        var candidate = room
        candidate.hostEmail = room.playersList[1].email
        candidate.roomRevision = 41
        XCTAssertFalse(selected.canAdopt(try replacingRoomID(candidate), over: room, accountID: "host-id", transferring: true))
        XCTAssertFalse(selected.canAdopt(candidate, over: room, accountID: "other-account", transferring: true))
        var changed = candidate
        changed.players?[0].membershipID = "host-membership-2"
        changed.viewerMembershipID = "host-membership-2"
        XCTAssertFalse(selected.canAdopt(changed, over: room, accountID: "host-id", transferring: true))
        changed = candidate
        changed.status = "playing"
        XCTAssertFalse(selected.canAdopt(changed, over: room, accountID: "host-id", transferring: true))
        changed = candidate
        changed.players?[1].membershipID = "target-membership-2"
        XCTAssertFalse(selected.canAdopt(changed, over: room, accountID: "host-id", transferring: true))
    }

    func testLateKickOrTransferCannotOverwriteTargetThatRejoinedInCurrentSnapshot() throws {
        let original = room()
        let selected = try selection(in: original)
        var current = original
        current.players?[1].membershipID = "target-membership-2"
        current.roomRevision = 42
        var oldTransfer = original
        oldTransfer.hostEmail = original.playersList[1].email
        oldTransfer.roomRevision = 43
        XCTAssertFalse(selected.canAdopt(oldTransfer, over: current, accountID: "host-id", transferring: true))
        var oldKick = original
        oldKick.players?.remove(at: 1)
        oldKick.roomRevision = 43
        XCTAssertFalse(selected.canAdopt(oldKick, over: current, accountID: "host-id", transferring: false))
    }

    func testTransferAdoptsRealFormerHostProjectionWhereRosterMembershipsAreRedacted() throws {
        let original = room()
        let selected = try selection(in: original)
        var projected = original
        projected.hostEmail = original.playersList[1].email
        projected.roomRevision = 41
        projected.players = projected.playersList.map { player in
            var redacted = player
            redacted.membershipID = nil
            return redacted
        }
        // room-projection keeps viewer_membership_id for every viewer, while
        // per-player membership_id is only visible to the current lobby host.
        XCTAssertEqual(projected.viewerMembershipID, "host-membership-1")
        XCTAssertTrue(selected.canAdopt(projected, over: original, accountID: "host-id", transferring: true))
        XCTAssertTrue(selected.canAdopt(projected, over: projected, accountID: "host-id", transferring: true))
        var rejoinedActor = projected
        rejoinedActor.viewerMembershipID = "host-membership-2"
        XCTAssertFalse(selected.canAdopt(rejoinedActor, over: original, accountID: "host-id", transferring: true))
    }

    func testGuestCardUsesViewerMembershipToInvalidateActorRejoinWithRedactedRoster() throws {
        var guestRoom = room()
        guestRoom.viewerMembershipID = "guest-membership-1"
        guestRoom.players = guestRoom.playersList.map { player in
            var redacted = player
            redacted.membershipID = nil
            return redacted
        }
        let selected = try selection(in: guestRoom, actorIndex: 2)
        XCTAssertTrue(selected.matchesActor(room: guestRoom, accountID: "guest-id"))
        guestRoom.viewerMembershipID = "guest-membership-2"
        XCTAssertFalse(selected.matchesActor(room: guestRoom, accountID: "guest-id"))
    }
}
