import XCTest
@testable import SpyClash

@MainActor
final class GameInvitationCenterTests: XCTestCase {
    func testIndependentPermissionsAndStableQueue() throws {
        let center = GameInvitationCenter()
        var account = try user("me")
        center.bind(user: account)
        let friend = profile("friend"), stranger = profile("stranger")
        let friendInvite = invite("friend-invite", from: friend, date: "2026-11-05T10:01:00Z")
        let strangerInvite = invite("stranger-invite", from: stranger, date: "2026-11-05T10:00:00Z")
        let state = CommunityState(me: profile("me"), friends: [CommunityRelationship(id: "f", status: "accepted", direction: "incoming", profile: friend)], incoming: [], outgoing: [], blocked: [], incomingRoomInvites: [friendInvite, strangerInvite])
        center.install(state)
        XCTAssertEqual(center.current?.id, friendInvite.id)
        account.strangerInvitationsAllowed = true
        center.bind(user: account)
        XCTAssertEqual(center.current?.id, strangerInvite.id)
        account.friendInvitationsAllowed = false
        account.strangerInvitationsAllowed = false
        center.bind(user: account)
        XCTAssertNil(center.current)
    }

    func testAccountSwitchClearsQueueCallbackAndRejectsLateSnapshot() throws {
        let center = GameInvitationCenter()
        center.bind(user: try user("first"))
        let sender = profile("friend")
        let state = CommunityState(me: profile("first"), friends: [CommunityRelationship(id: "f", status: "accepted", direction: "incoming", profile: sender)], incoming: [], outgoing: [], blocked: [], incomingRoomInvites: [invite("i", from: sender)])
        center.install(state)
        center.onDecision = { _, _ in XCTFail("Old account handler must not survive") }
        center.busyInviteID = "i"
        center.errorMessage = "Old account error"
        center.bind(user: try user("second"))
        center.install(state)
        XCTAssertNil(center.current)
        XCTAssertNil(center.onDecision)
        XCTAssertNil(center.busyInviteID)
        XCTAssertNil(center.errorMessage)
    }

    func testBusyDecisionCannotJoinAgainAndSnapshotRemovalDismisses() throws {
        let center = GameInvitationCenter()
        center.bind(user: try user("me"))
        let sender = profile("friend"), invitation = invite("i", from: profile("friend"))
        let relationship = CommunityRelationship(id: "f", status: "accepted", direction: "incoming", profile: sender)
        center.install(CommunityState(me: profile("me"), friends: [relationship], incoming: [], outgoing: [], blocked: [], incomingRoomInvites: [invitation]))
        var decisions = 0
        center.onDecision = { id, _ in decisions += 1; center.busyInviteID = id }
        center.decide(invitation, accept: true)
        center.decide(invitation, accept: true)
        XCTAssertEqual(decisions, 1)
        center.install(CommunityState(me: profile("me"), friends: [relationship], incoming: [], outgoing: [], blocked: [], incomingRoomInvites: []))
        XCTAssertNil(center.current)
    }

    func testJoinErrorSurvivesRefreshButClearsForRetryAndNextInvitation() throws {
        let center = GameInvitationCenter()
        center.bind(user: try user("me"))
        let sender = profile("friend"), invitation = invite("i", from: profile("friend"))
        let relationship = CommunityRelationship(id: "f", status: "accepted", direction: "incoming", profile: sender)
        let state = CommunityState(me: profile("me"), friends: [relationship], incoming: [], outgoing: [], blocked: [], incomingRoomInvites: [invitation])
        center.install(state)
        center.errorMessage = "Room unavailable"
        center.install(state)
        XCTAssertEqual(center.errorMessage, "Room unavailable")
        var attempted = false
        center.onDecision = { _, _ in attempted = true }
        center.decide(invitation, accept: true)
        XCTAssertTrue(attempted)
        XCTAssertNil(center.errorMessage)
        center.errorMessage = "Retry failed"
        center.install(CommunityState(me: profile("me"), friends: [relationship], incoming: [], outgoing: [], blocked: [], incomingRoomInvites: [invite("next", from: sender)]))
        XCTAssertNil(center.errorMessage)
    }

#if DEBUG
    func testPreviewProfileCannotReportSuccessfulRealRoomJoin() async {
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, saveStoredToken: { _ in }, clearStoredToken: {})
        state.isUIPreviewMode = true
        state.language = .ru
        let joined = await state.joinRoom(code: "ABC123")
        XCTAssertFalse(joined)
        XCTAssertNil(state.activeRoom)
        XCTAssertEqual(state.deepLinkStatus, state.previewInvitationJoinMessage)
    }
#endif

    private func user(_ id: String) throws -> SpyUser {
        try JSONDecoder().decode(SpyUser.self, from: JSONSerialization.data(withJSONObject: ["id": id, "email": "\(id)@example.test"]))
    }

    private func profile(_ id: String) -> PublicSpyProfile {
        PublicSpyProfile(id: id, spyID: "123-456", displayName: id, avatar: "🕵️", spyCardTheme: "field", spyCardAccent: "signal_red", spyCardBadge: "operative", rating: 0, gamesPlayed: 0, gamesWon: 0, winRate: 0)
    }

    private func invite(_ id: String, from sender: PublicSpyProfile, date: String = "2026-11-05T10:00:00Z") -> CommunityRoomInvite {
        CommunityRoomInvite(id: id, status: "pending", roomID: "room", roomCode: "ABC123", createdAt: date, sender: sender)
    }
}
