import Foundation
import Observation

/// One account-scoped presentation queue. Decisions use the inbox's existing
/// acceptance/join/cleanup flow so a failed join remains retryable.
@MainActor
@Observable
final class GameInvitationCenter {
    private(set) var accountID: String?
    private(set) var invitations: [CommunityRoomInvite] = []
    private(set) var friendIDs: Set<String> = []
    private var allowsFriends = true
    private var allowsStrangers = false
    var busyInviteID: String?
    var errorMessage: String?
    @ObservationIgnored var onDecision: ((String, Bool) -> Void)?

    var current: CommunityRoomInvite? {
        invitations.first { invite in
            friendIDs.contains(invite.sender.id) ? allowsFriends : allowsStrangers
        }
    }

    func bind(user: SpyUser?) {
        let previousID = current?.id
        if accountID != user?.id {
            invitations.removeAll()
            friendIDs.removeAll()
            busyInviteID = nil
            errorMessage = nil
            onDecision = nil
        }
        accountID = user?.id
        allowsFriends = user?.friendInvitationsAllowed ?? true
        allowsStrangers = user?.strangerInvitationsAllowed ?? false
        if current?.id != previousID { errorMessage = nil }
    }

    func install(_ state: CommunityState) {
        guard state.me.id == accountID else { return }
        let previousID = current?.id
        friendIDs = Set(state.friends.map(\.profile.id))
        let blocked = Set(state.blocked.map(\.profile.id))
        invitations = state.incomingRoomInvites
            .filter { ["pending", "accepted"].contains($0.status.lowercased()) && !blocked.contains($0.sender.id) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if current?.id != previousID { errorMessage = nil }
    }

    func decide(_ invitation: CommunityRoomInvite, accept: Bool) {
        guard busyInviteID == nil, current?.id == invitation.id else { return }
        errorMessage = nil
        onDecision?(invitation.id, accept)
    }
}
