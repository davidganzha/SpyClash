import Foundation
import XCTest
@testable import SpyClash

final class OnlineIntroPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "account-a"

    func testLateServerTimestampDoesNotSkipLocalCardSequence() throws {
        var presentation = OnlineIntroPresentation()
        let room = introRoom(timestamp: "2026-01-01T00:00:00Z")
        presentation.update(room: room, accountID: account, now: now)

        let session = try XCTUnwrap(presentation.active)
        XCTAssertEqual(session.startedAt, now)
        XCTAssertEqual(session.remainingDuration(at: now), 3)

        presentation.update(room: playingRoom(from: room), accountID: account, now: now.addingTimeInterval(0.2))
        XCTAssertEqual(try XCTUnwrap(presentation.revealDelay(
            room: playingRoom(from: room), accountID: account, now: now.addingTimeInterval(0.2)
        )), 2.35, accuracy: 0.0001)
        XCTAssertFalse(presentation.beginRevealIfReady(
            room: playingRoom(from: room), accountID: account, now: now.addingTimeInterval(0.2)
        ))
        XCTAssertEqual(presentation.active?.id, session.id)
    }

    func testDissolveFitsInsideThreeSecondSequenceWhenDestinationIsReady() throws {
        var presentation = OnlineIntroPresentation()
        let room = introRoom()
        presentation.update(room: room, accountID: account, now: now)
        let playing = playingRoom(from: room)
        presentation.update(room: playing, accountID: account, now: now.addingTimeInterval(1))

        XCTAssertFalse(presentation.beginRevealIfReady(
            room: playing, accountID: account, now: now.addingTimeInterval(2.54)
        ))
        XCTAssertTrue(presentation.beginRevealIfReady(
            room: playing, accountID: account, now: now.addingTimeInterval(2.55)
        ))
        let id = try XCTUnwrap(presentation.active?.id)
        XCTAssertFalse(presentation.finishReveal(id: id, now: now.addingTimeInterval(2.99)))
        XCTAssertTrue(presentation.finishReveal(id: id, now: now.addingTimeInterval(3)))
        XCTAssertNil(presentation.active)
    }

    func testRepeatedSnapshotsPreserveLocalClockAndOriginalRoster() throws {
        var presentation = OnlineIntroPresentation()
        var room = introRoom()
        presentation.update(room: room, accountID: account, now: now)
        let original = try XCTUnwrap(presentation.active)
        room.players = Array(room.playersList.prefix(2))
        presentation.update(room: room, accountID: account, now: now.addingTimeInterval(1.5))

        XCTAssertEqual(presentation.active?.id, original.id)
        XCTAssertEqual(presentation.active?.startedAt, now)
        XCTAssertEqual(presentation.active?.room.playersList.count, 3)
    }

    func testWaitsForAuthoritativeGameplayAfterVisualSequenceEnds() throws {
        var presentation = OnlineIntroPresentation()
        let room = introRoom()
        presentation.update(room: room, accountID: account, now: now)
        let delayed = now.addingTimeInterval(9)

        XCTAssertNil(presentation.revealDelay(room: room, accountID: account, now: delayed))
        XCTAssertFalse(presentation.beginRevealIfReady(room: room, accountID: account, now: delayed))
        XCTAssertNotNil(presentation.active)

        let playing = playingRoom(from: room)
        presentation.update(room: playing, accountID: account, now: delayed)
        XCTAssertTrue(presentation.beginRevealIfReady(room: playing, accountID: account, now: delayed))
        XCTAssertFalse(presentation.beginRevealIfReady(room: playing, accountID: account, now: delayed))
        let id = try XCTUnwrap(presentation.active?.id)
        XCTAssertFalse(presentation.finishReveal(id: id, now: delayed.addingTimeInterval(0.44)))
        XCTAssertTrue(presentation.finishReveal(id: id, now: delayed.addingTimeInterval(0.45)))
        XCTAssertNil(presentation.active)
    }

    func testDirectJoinIntoGameplayDoesNotPlayIntro() {
        var presentation = OnlineIntroPresentation()
        presentation.update(room: playingRoom(from: introRoom()), accountID: account, now: now)
        XCTAssertNil(presentation.active)
    }

    func testNewIntroInSameRoomStartsNewSessionAndRejectsOldCompletion() throws {
        var presentation = OnlineIntroPresentation()
        let room = introRoom()
        presentation.update(room: room, accountID: account, now: now)
        let oldID = try XCTUnwrap(presentation.active?.id)
        XCTAssertTrue(presentation.beginRevealIfReady(
            room: playingRoom(from: room), accountID: account, now: now.addingTimeInterval(3)
        ))

        let nextStart = now.addingTimeInterval(3.1)
        presentation.update(room: introRoom(timestamp: "next-match"), accountID: account, now: nextStart)
        XCTAssertNotEqual(presentation.active?.id, oldID)
        XCTAssertEqual(presentation.active?.startedAt, nextStart)
        XCTAssertFalse(presentation.finishReveal(id: oldID, now: now.addingTimeInterval(10)))
        XCTAssertNotNil(presentation.active)
    }

    func testLeavingLogoutAndTerminalStatesCancelPendingPresentation() {
        for status in ["waiting", "ready_voting", "finished", "ended"] {
            var presentation = OnlineIntroPresentation()
            var room = introRoom()
            presentation.update(room: room, accountID: account, now: now)
            room.status = status
            presentation.update(room: room, accountID: account, now: now)
            XCTAssertNil(presentation.active, "Unexpected overlay for \(status)")
        }

        var presentation = OnlineIntroPresentation()
        let room = introRoom()
        presentation.update(room: room, accountID: account, now: now)
        presentation.update(room: nil, accountID: account, now: now)
        XCTAssertNil(presentation.active)
        presentation.update(room: room, accountID: account, now: now)
        presentation.update(room: room, accountID: nil, now: now)
        XCTAssertNil(presentation.active)
    }

    func testUnrelatedGameplayCannotRevealOldRoomOrAccount() {
        for mismatch in ["room", "account", "intro"] {
            var presentation = OnlineIntroPresentation()
            let room = introRoom()
            presentation.update(room: room, accountID: account, now: now)
            var playing = playingRoom(from: room)
            if mismatch == "room" {
                playing = GameRoom.previewRoom(status: "cards-last")
                playing.introStartedAt = room.introStartedAt
            }
            if mismatch == "intro" { playing.introStartedAt = "another-intro" }
            let currentAccount = mismatch == "account" ? "another-account" : account
            XCTAssertFalse(presentation.beginRevealIfReady(
                room: playing, accountID: currentAccount, now: now.addingTimeInterval(10)
            ))
            presentation.update(room: playing, accountID: currentAccount, now: now)
            XCTAssertNil(presentation.active, "Unexpected overlay after \(mismatch) changed")
        }
    }

    func testMissingTimestampHasStablePendingIdentity() throws {
        var presentation = OnlineIntroPresentation()
        var room = introRoom()
        room.introStartedAt = nil
        presentation.update(room: room, accountID: account, now: now)
        let id = try XCTUnwrap(presentation.active?.id)
        room.introStartedAt = "  "
        presentation.update(room: room, accountID: account, now: now.addingTimeInterval(1))
        XCTAssertEqual(presentation.active?.id, id)
        XCTAssertEqual(presentation.active?.startedAt, now)
    }

    func testLostDestinationInvalidatesRunningFadeWithoutRestartingSequence() throws {
        var presentation = OnlineIntroPresentation()
        let room = introRoom()
        presentation.update(room: room, accountID: account, now: now)
        XCTAssertTrue(presentation.beginRevealIfReady(
            room: playingRoom(from: room), accountID: account, now: now.addingTimeInterval(3)
        ))
        let oldID = try XCTUnwrap(presentation.active?.id)
        presentation.update(room: room, accountID: account, now: now.addingTimeInterval(3.1))

        XCTAssertEqual(presentation.active?.startedAt, now)
        XCTAssertNil(presentation.active?.exitingAt)
        XCTAssertNotEqual(presentation.active?.id, oldID)
        XCTAssertFalse(presentation.finishReveal(id: oldID, now: now.addingTimeInterval(10)))
    }

    private func introRoom(timestamp: String = "2026-11-05T12:00:00Z") -> GameRoom {
        var room = GameRoom.previewRoom(status: "roulette")
        room.introStartedAt = timestamp
        return room
    }

    private func playingRoom(from room: GameRoom) -> GameRoom {
        var playing = room
        playing.status = "playing"
        return playing
    }
}

final class SpyGameIntroChoreographyTests: XCTestCase {
    func testFlightUsesItsWholeDurationInsteadOfArrivingDuringFirstFrames() {
        // The previous clamped spring reached its destination after only 15%
        // of a flight. Early frames should remain near the departing deck.
        XCTAssertLessThan(SpyGameIntroChoreography.phase(0.15, from: 0, to: 1), 0.1)
        XCTAssertEqual(SpyGameIntroChoreography.phase(0.5, from: 0, to: 1), 0.5, accuracy: 0.000001)
        XCTAssertLessThan(SpyGameIntroChoreography.phase(0.9, from: 0, to: 1), 1)
        XCTAssertEqual(SpyGameIntroChoreography.phase(1, from: 0, to: 1), 1)
    }

    func testCardsStayFiniteBoundedAndMoveForwardForSmallAndLargeFormations() {
        for count in [6, 12] {
            for index in 0..<count {
                var previous = 0.0
                for step in -100...1100 {
                    let progress = Double(step) / 1_000
                    let spread = SpyGameIntroChoreography.spread(progress, index: index, count: count)
                    XCTAssertTrue(spread.isFinite)
                    XCTAssertGreaterThanOrEqual(spread, -1e-12)
                    XCTAssertLessThanOrEqual(spread, 1 + 1e-12)
                    XCTAssertGreaterThanOrEqual(spread, previous - 1e-12)
                    previous = spread
                }
                XCTAssertEqual(previous, 1)
            }
        }
    }

    func testMotionComesToRestAtBothEndsAndPulseSettlesWithoutRepeating() {
        let step = 0.0001
        let startSlope = SpyGameIntroChoreography.phase(step, from: 0, to: 1) / step
        let endSlope = (1 - SpyGameIntroChoreography.phase(1 - step, from: 0, to: 1)) / step
        XCTAssertLessThan(abs(startSlope), 0.0001)
        XCTAssertLessThan(abs(endSlope), 0.0001)
        XCTAssertEqual(SpyGameIntroChoreography.pulse(0), 0)
        XCTAssertEqual(SpyGameIntroChoreography.pulse(0.70), 1)
        XCTAssertEqual(SpyGameIntroChoreography.pulse(0.84), 0)
        XCTAssertEqual(SpyGameIntroChoreography.pulse(1), 0)
        XCTAssertEqual(SpyGameIntroChoreography.pulse(10), 0)
    }
}
