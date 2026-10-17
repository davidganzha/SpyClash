import XCTest
#if SPYCLASH_SUPABASE_STAGING_TESTS
@testable import SpyClashSupabaseStaging
#else
@testable import SpyClash
#endif

final class CommunityResponsivenessTests: XCTestCase {
    func testNavigationOrMutationInvalidatesAnOlderProfileCatchUp() {
        var requests = CommunityProfileRequestState()
        let catchUp = requests.begin()
        let navigation = requests.begin()
        XCTAssertFalse(requests.accepts(catchUp))
        XCTAssertTrue(requests.accepts(navigation))
        requests.invalidate()
        XCTAssertFalse(requests.accepts(navigation))
    }

    func testProfileReadCannotOverwriteASignalThatStartedAfterIt() {
        var requests = CommunityProfileRequestState()
        let request = requests.begin()
        XCTAssertTrue(requests.accepts(request, signalGeneration: 4, currentSignalGeneration: 4))
        XCTAssertFalse(requests.accepts(request, signalGeneration: 4, currentSignalGeneration: 5))
        XCTAssertTrue(requests.accepts(request), "The current request can still clear its own loading indicator.")
        _ = requests.begin()
        XCTAssertFalse(requests.accepts(request, signalGeneration: 5, currentSignalGeneration: 5))
    }

    func testAcceptProjectsFriendImmediatelyWithoutDuplicatingExistingPair() throws {
        let request = relationship("request", profileID: "friend", status: "pending", direction: "incoming")
        let original = state(friends: [relationship("old-friend", profileID: "friend")], incoming: [request])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "accept", friendshipID: request.id))

        let pending = change.applying(to: original)

        XCTAssertTrue(pending.incoming.isEmpty)
        XCTAssertEqual(pending.friends.map(\.id), [request.id])
        XCTAssertEqual(pending.friends.first?.status, "accepted")
        XCTAssertEqual(original.incoming, [request], "The server snapshot remains available for rollback.")
    }

    func testFailedAcceptRestoresRequestAndKeepsUnrelatedIncomingUpdate() throws {
        let request = relationship("request", profileID: "friend", status: "pending", direction: "incoming")
        let original = state(incoming: [request])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "accept", friendshipID: request.id))
        let projected = change.applying(to: original)
        let newRequest = relationship("new-request", profileID: "another", status: "pending", direction: "incoming")
        let current = state(friends: projected.friends, incoming: projected.incoming + [newRequest])

        let rolledBack = change.rollingBack(in: current)

        XCTAssertTrue(rolledBack.friends.isEmpty)
        XCTAssertEqual(Set(rolledBack.incoming.map(\.id)), [request.id, newRequest.id])
    }

    func testOptimisticChangesAndRollbackNeverCrossAccounts() throws {
        let request = relationship("request", profileID: "friend", status: "pending", direction: "incoming")
        let original = state(incoming: [request])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "accept", friendshipID: request.id))
        let otherAccount = state(actor: "other-account", friends: [relationship("their-friend", profileID: "friend")])

        XCTAssertEqual(change.applying(to: otherAccount), otherAccount)
        XCTAssertEqual(change.rollingBack(in: otherAccount), otherAccount)
    }

    func testDecliningDuplicatePendingRequestDoesNotRemoveConfirmedFriend() throws {
        let request = relationship("request", profileID: "friend", status: "pending", direction: "incoming")
        let friend = relationship("friendship", profileID: "friend")
        let original = state(friends: [friend], incoming: [request])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "decline", friendshipID: request.id))

        let projected = change.applying(to: original)

        XCTAssertTrue(projected.incoming.isEmpty)
        XCTAssertEqual(projected.friends, [friend])
        XCTAssertEqual(change.rollingBack(in: projected), original)
    }

    func testRemovalIsImmediateAndRollbackPreservesOtherFriends() throws {
        let friend = relationship("friendship", profileID: "friend")
        let original = state(friends: [friend])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "remove_friend", friendshipID: friend.id))
        let projected = change.applying(to: original)
        XCTAssertTrue(projected.friends.isEmpty)
        let anotherFriend = relationship("another-friendship", profileID: "another")

        let rolledBack = change.rollingBack(in: state(friends: projected.friends + [anotherFriend]))

        XCTAssertEqual(Set(rolledBack.friends.map(\.id)), [friend.id, anotherFriend.id])
    }

    func testCancelOnlyChangesOutgoingRequestAndCanBeRolledBack() throws {
        let outgoing = relationship("request", profileID: "friend", status: "pending", direction: "outgoing")
        let incoming = relationship("incoming", profileID: "someone", status: "pending", direction: "incoming")
        let original = state(incoming: [incoming], outgoing: [outgoing])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "cancel_request", friendshipID: outgoing.id))

        let projected = change.applying(to: original)

        XCTAssertTrue(projected.outgoing.isEmpty)
        XCTAssertEqual(projected.incoming, [incoming])
        XCTAssertEqual(change.rollingBack(in: projected), original)
    }

    func testWrongDirectionUnknownIDAndUnsupportedActionCannotCreateProjection() {
        let friend = relationship("friendship", profileID: "friend")
        let original = state(friends: [friend])
        XCTAssertNil(CommunityOptimisticRelationshipChange(state: original, action: "accept", friendshipID: friend.id))
        XCTAssertNil(CommunityOptimisticRelationshipChange(state: original, action: "remove_friend", friendshipID: "missing"))
        XCTAssertNil(CommunityOptimisticRelationshipChange(state: original, action: "block", friendshipID: friend.id))
    }

    func testConfirmedBlockWinsOverOptimisticAcceptAndItsRollback() throws {
        let request = relationship("request", profileID: "friend", status: "pending", direction: "incoming")
        let original = state(incoming: [request])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "accept", friendshipID: request.id))
        let pending = change.applying(to: original)
        let blocked = relationship("block", profileID: "friend", status: "blocked")
        let current = CommunityState(me: original.me, friends: pending.friends, incoming: [request], outgoing: [], blocked: [blocked])

        for reconciled in [change.applying(to: current), change.rollingBack(in: current)] {
            XCTAssertTrue(reconciled.friends.isEmpty)
            XCTAssertTrue(reconciled.incoming.isEmpty)
            XCTAssertEqual(reconciled.blocked, [blocked])
        }
    }

    func testProjectionAndRollbackPreserveRoomInvitesAndBlockedPlayers() throws {
        let request = relationship("request", profileID: "friend", status: "pending", direction: "incoming")
        let blocked = relationship("blocked", profileID: "blocked-user", status: "blocked")
        let invite = CommunityRoomInvite(id: "invite", status: "pending", roomID: "room", roomCode: "123-456", createdAt: "2026-10-17T12:00:00Z", sender: profile("sender"))
        let original = CommunityState(me: profile("me"), friends: [], incoming: [request], outgoing: [], blocked: [blocked], incomingRoomInvites: [invite])
        let change = try XCTUnwrap(CommunityOptimisticRelationshipChange(state: original, action: "accept", friendshipID: request.id))
        let projected = change.applying(to: original)
        XCTAssertEqual(projected.blocked, [blocked])
        XCTAssertEqual(projected.incomingRoomInvites, [invite])
        XCTAssertEqual(change.rollingBack(in: projected), original)
    }

    private func state(actor: String = "me", friends: [CommunityRelationship] = [], incoming: [CommunityRelationship] = [], outgoing: [CommunityRelationship] = []) -> CommunityState {
        CommunityState(me: profile(actor), friends: friends, incoming: incoming, outgoing: outgoing)
    }

    private func relationship(_ id: String, profileID: String, status: String = "accepted", direction: String = "outgoing") -> CommunityRelationship {
        CommunityRelationship(id: id, status: status, direction: direction, profile: profile(profileID))
    }

    private func profile(_ id: String) -> PublicSpyProfile {
        PublicSpyProfile(id: id, spyID: "123-456", displayName: id, avatar: "🕵️",
                         spyCardTheme: "field", spyCardAccent: "signal_red", spyCardBadge: "operative",
                         rating: 0, gamesPlayed: 0, gamesWon: 0, winRate: 0)
    }
}
