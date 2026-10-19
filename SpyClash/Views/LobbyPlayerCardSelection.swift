import Foundation

/// Captures both memberships so an old card cannot act on a player who has rejoined.
struct LobbyPlayerCardSelection: Identifiable, Equatable {
    let id = UUID()
    let roomID: String
    let actorID: String
    let actorEmail: String
    let actorMembershipID: String?
    let player: Player

    init?(player: Player, room: GameRoom, actorID: String?, actorEmail: String?) {
        guard let actorID = actorID?.nilIfBlank,
              let actorEmail = actorEmail?.nilIfBlank,
              let targetID = player.userID?.nilIfBlank,
              ["waiting", "ready_voting"].contains(room.normalizedStatus),
              room.playersList.filter({ $0.userID == targetID }).count == 1,
              room.playersList.contains(where: { $0 == player }),
              room.playersList.filter({ Self.sameEmail($0.email, actorEmail) || $0.userID == actorID }).count == 1,
              let actor = room.playersList.first(where: { Self.sameEmail($0.email, actorEmail) }),
              actor.userID == nil || actor.userID == actorID else { return nil }
        self.roomID = room.id
        self.actorID = actorID
        self.actorEmail = actorEmail
        self.actorMembershipID = room.viewerMembershipID ?? actor.membershipID
        self.player = player
    }

    var profileID: String { player.userID ?? "" }
    var isSelf: Bool { profileID == actorID || Self.sameEmail(player.email, actorEmail) }

    func matchesActor(room: GameRoom?, accountID: String?) -> Bool {
        guard let room, room.id == roomID, accountID == actorID,
              ["waiting", "ready_voting"].contains(room.normalizedStatus),
              room.playersList.filter({ Self.sameEmail($0.email, actorEmail) || $0.userID == actorID }).count == 1,
              let actor = room.playersList.first(where: { Self.sameEmail($0.email, actorEmail) })
        else { return false }
        return (room.viewerMembershipID ?? actor.membershipID) == actorMembershipID
            && (actor.userID == nil || actor.userID == actorID)
    }

    func currentPlayer(room: GameRoom?, accountID: String?) -> Player? {
        guard matchesActor(room: room, accountID: accountID), let room else { return nil }
        let matches = room.playersList.filter { $0.userID == profileID }
        guard matches.count == 1, let target = matches.first,
              Self.sameEmail(target.email, player.email), target.membershipID == player.membershipID
        else { return nil }
        return target
    }

    func canManage(room: GameRoom?, accountID: String?) -> Bool {
        guard let room, !isSelf, currentPlayer(room: room, accountID: accountID) != nil else { return false }
        return Self.sameEmail(room.hostEmail, actorEmail) && !Self.sameEmail(room.hostEmail, player.email)
    }

    func canAdopt(_ candidate: GameRoom, over current: GameRoom, accountID: String?, transferring: Bool) -> Bool {
        guard matchesActor(room: current, accountID: accountID),
              candidate.id == roomID,
              matchesActor(room: candidate, accountID: accountID),
              RoomPollPolicy.acceptsSnapshot(
                currentRoomRevision: current.roomRevision, currentLobbyRevision: current.lobbyRevision,
                fetchedRoomRevision: candidate.roomRevision, fetchedLobbyRevision: candidate.lobbyRevision
              ) else { return false }
        // A poll may have delivered the successful result before the request returns.
        guard Self.sameEmail(current.hostEmail, actorEmail)
                || (transferring && Self.sameEmail(current.hostEmail, player.email)) else { return false }
        if transferring {
            return matchesTransferTarget(in: current)
                && Self.sameEmail(candidate.hostEmail, player.email)
                && matchesTransferTarget(in: candidate)
        }
        if current.playersList.contains(where: { $0.userID == profileID || Self.sameEmail($0.email, player.email) }),
           currentPlayer(room: current, accountID: accountID) == nil { return false }
        return Self.sameEmail(candidate.hostEmail, actorEmail)
            && !candidate.playersList.contains { $0.userID == profileID || Self.sameEmail($0.email, player.email) }
    }

    private func matchesTransferTarget(in room: GameRoom) -> Bool {
        let targets = room.playersList.filter { $0.userID == profileID || Self.sameEmail($0.email, player.email) }
        guard targets.count == 1, let target = targets.first,
              target.userID == profileID, Self.sameEmail(target.email, player.email) else { return false }
        if target.membershipID == player.membershipID { return true }
        // After transfer the former host receives a guest projection: roster
        // memberships are hidden, but their own viewer membership stays fenced.
        return target.membershipID == nil && room.viewerMembershipID == actorMembershipID
            && actorMembershipID != nil && Self.sameEmail(room.hostEmail, player.email)
    }

    static func sameEmail(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = RoomKickPolicy.normalizedEmail(lhs), let rhs = RoomKickPolicy.normalizedEmail(rhs) else { return false }
        return lhs == rhs
    }
}
