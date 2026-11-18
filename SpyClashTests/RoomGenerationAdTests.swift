import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class RoomGenerationAdTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func room() -> GameRoom {
        var room = GameRoom.previewRoom(status: "waiting")
        room.players = Array(room.playersList.prefix(3))
        return room
    }
    private func offer(_ room: GameRoom, id: UUID = UUID(), duration: TimeInterval = 180) -> RoomGenerationAdOffer {
        let formatter = ISO8601DateFormatter()
        return .init(id: id, hostEmail: room.hostEmail!, startedAt: formatter.string(from: now), expiresAt: formatter.string(from: now.addingTimeInterval(duration)))
    }

    func testThreePlayerOfferHasTwoOptionalGuestsAndNoHostPrompt() throws {
        var room = room(); room.roomGenerationAd = offer(room)
        let players = room.playersList
        XCTAssertEqual(players.count, 3)
        XCTAssertNil(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: room.hostEmail, now: now))
        for guest in players.dropFirst() {
            XCTAssertEqual(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: guest.email, now: now), room.roomGenerationAd)
        }
        XCTAssertNil(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: "outsider@example.test", now: now))
        let roundtrip = try JSONDecoder().decode(GameRoom.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(roundtrip.roomGenerationAd, room.roomGenerationAd)
    }

    func testExpiredWrongHostAndPlayingRoomCannotPresentGuestAds() {
        var room = room(); room.roomGenerationAd = offer(room)
        let guest = room.playersList[1].email
        XCTAssertNil(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: guest, now: now.addingTimeInterval(181)))
        room.status = "playing"
        XCTAssertNil(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: guest, now: now))
        room.status = "waiting"; room.hostEmail = guest
        XCTAssertNil(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: room.playersList[2].email, now: now))
        room = self.room(); room.roomGenerationAd = offer(room, duration: 181)
        XCTAssertNil(RoomGenerationAdOfferPolicy.guestOffer(in: room, viewerEmail: guest, now: now))
    }

    func testOneTimeConsentStartsOnlyNextNewForegroundSignal() {
        var choice = RoomGenerationAdGuestConsent()
        let scope = RoomGenerationAdGuestScope(roomID: "room", userID: "guest")
        let first = UUID(), second = UUID()
        choice.bind(scope, currentOfferID: nil)
        XCTAssertFalse(choice.isArmed)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        XCTAssertEqual(choice.receive(first, isForeground: true), first)
        XCTAssertFalse(choice.isArmed)
        XCTAssertNil(choice.receive(first, isForeground: true), "Realtime duplicate must not replay an ad.")
        _ = choice.receive(nil, isForeground: true)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        XCTAssertNil(choice.receive(first, isForeground: true), "Replayed old session cannot use new consent.")
        XCTAssertEqual(choice.receive(second, isForeground: true), second)
        XCTAssertFalse(choice.isArmed)
    }

    func testExistingOfferBackgroundAndAccountOrRoomChangesNeverAutoplay() {
        var choice = RoomGenerationAdGuestConsent()
        let current = UUID(), next = UUID()
        choice.bind(.init(roomID: "room", userID: "guest"), currentOfferID: current)
        choice.setArmed(true, currentOfferID: current, isForeground: true)
        XCTAssertFalse(choice.isArmed)
        XCTAssertNil(choice.receive(current, isForeground: true))
        _ = choice.receive(nil, isForeground: true)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        choice.enteredBackground()
        XCTAssertNil(choice.receive(next, isForeground: false))
        XCTAssertNil(choice.receive(next, isForeground: true))
        XCTAssertFalse(choice.isArmed)
        _ = choice.receive(nil, isForeground: true)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        choice.bind(.init(roomID: "room", userID: "other-account"), currentOfferID: nil)
        XCTAssertFalse(choice.isArmed)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        choice.bind(.init(roomID: "other-room", userID: "other-account"), currentOfferID: nil)
        XCTAssertFalse(choice.isArmed)
        choice.bind(nil, currentOfferID: nil)
        XCTAssertNil(choice.receive(UUID(), isForeground: true))
    }

    func testExistingOrBackgroundOfferCannotReplayAfterReentryAndFreshConsent() {
        var choice = RoomGenerationAdGuestConsent()
        let first = UUID(), missed = UUID(), fresh = UUID()
        choice.bind(.init(roomID: "room", userID: "guest"), currentOfferID: first)
        _ = choice.receive(nil, isForeground: true)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        XCTAssertNil(choice.receive(first, isForeground: true))
        XCTAssertNil(choice.receive(missed, isForeground: false))
        _ = choice.receive(nil, isForeground: true)
        choice.setArmed(true, currentOfferID: nil, isForeground: true)
        XCTAssertNil(choice.receive(missed, isForeground: true))
        XCTAssertEqual(choice.receive(fresh, isForeground: true), fresh)
    }

    func testUIPreviewHostNeverPublishesRoomAction() async throws {
#if DEBUG
        let room = room()
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, saveStoredToken: { _ in }, clearStoredToken: {})
        state.isUIPreviewMode = true
        state.user = try JSONDecoder().decode(SpyUser.self, from: JSONSerialization.data(withJSONObject: ["id": "preview-owner", "email": room.hostEmail!]))
        state.activeRoom = room
        state.publishRoomGenerationAdPresentation(true, roomID: room.id)
        await state.roomGenerationAdPublication.waitForPendingPublication()
        XCTAssertFalse(state.roomGenerationAdPublication.hasActivePublication, "Preview cannot enqueue a real room action.")
        XCTAssertNil(state.activeRoom?.roomGenerationAd)
#else
        throw XCTSkip("UI previews exist in Debug builds only.")
#endif
    }

    func testHostBeginAndEndDoNotWaitForTwoGuestChoicesOrRewardConfirmation() async {
        let room = room(), publisher = RoomAdPublisherMock(), coordinator = RoomGenerationAdPublicationCoordinator()
        publisher.holdBegin = true
        var snapshots: [GameRoom] = []
        coordinator.update(true, room: room, client: publisher, ownsContext: { true }, onSnapshot: { snapshots.append($0) })
        for _ in 0..<20 where publisher.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(publisher.calls.map(\.presenting), [true])
        // End arrives while the room network is still pending. There is no
        // guest receipt/acknowledgement or generation-reward client to await.
        coordinator.update(false, room: room, client: publisher, ownsContext: { true }, onSnapshot: { snapshots.append($0) })
        XCTAssertEqual(publisher.calls.count, 1)
        publisher.releaseBegin()
        await coordinator.waitForPendingPublication()
        XCTAssertEqual(publisher.calls.map(\.presenting), [true, false])
        XCTAssertEqual(Set(publisher.calls.map(\.sessionID)).count, 1)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertNil(snapshots.last?.roomGenerationAd)
    }

    func testLeavingRoomDropsQueuedPresentationAndLateReadback() async {
        let room = room(), publisher = RoomAdPublisherMock(), coordinator = RoomGenerationAdPublicationCoordinator()
        var owns = true, snapshots = 0
        publisher.holdBegin = true
        coordinator.update(true, room: room, client: publisher, ownsContext: { owns }, onSnapshot: { _ in snapshots += 1 })
        for _ in 0..<20 where publisher.calls.isEmpty { await Task.yield() }
        owns = false
        coordinator.reconcile(roomID: nil)
        publisher.releaseBegin()
        await coordinator.waitForPendingPublication()
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(publisher.calls.count, 1)
    }
}

@MainActor
private final class RoomAdPublisherMock: RoomGenerationAdPublishingClient {
    struct Call { let sessionID: UUID; let presenting: Bool }
    var calls: [Call] = []
    var holdBegin = false
    private var continuation: CheckedContinuation<Void, Never>?
    func releaseBegin() { continuation?.resume(); continuation = nil }
    func publishRoomGenerationAd(room: GameRoom, sessionID: UUID, isPresenting: Bool) async throws -> GameRoom {
        calls.append(.init(sessionID: sessionID, presenting: isPresenting))
        if isPresenting && holdBegin { await withCheckedContinuation { continuation = $0 } }
        var result = room
        if isPresenting {
            let formatter = ISO8601DateFormatter(), now = Date()
            result.roomGenerationAd = .init(id: sessionID, hostEmail: room.hostEmail!, startedAt: formatter.string(from: now), expiresAt: formatter.string(from: now.addingTimeInterval(180)))
        } else { result.roomGenerationAd = nil }
        return result
    }
}
