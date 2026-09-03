import Foundation
import XCTest
@testable import SpyClash

@MainActor
final class Base44ClientRoomActionTests: XCTestCase {
    func testRoomExitRevisionNeverSubstitutesLegacyLobbyRevision() {
        XCTAssertEqual(
            RoomExitRevisionPolicy.expectedRevision(roomRevision: nil),
            0
        )
        XCTAssertEqual(
            RoomExitRevisionPolicy.expectedRevision(roomRevision: 17),
            17
        )
        XCTAssertEqual(
            RoomExitRevisionPolicy.expectedRevision(roomRevision: -1),
            0
        )
    }

    func testPublicDisplayNameSafetyBlocksKnownRootAcrossCommonEvasions() {
        let blockedVariants = [
            "zalupa",
            "Z.A.L.U.P.A",
            "z a l u p a",
            "za lu pa",
            "zal upa",
            "zal u p a",
            "z4lup4",
            "za\u{200B}lupa",
            "з-а-л-у-п-а",
            "за лу па",
            "zаlupa",
            "3a1up4",
            "zаluрa",
            "z@lup@",
            "za|upa",
            "pza lupa"
        ]

        for value in blockedVariants {
            XCTAssertTrue(
                PublicDisplayNameSafety.containsBlockedRoot(value),
                "Expected blocked display name variant: \(value)"
            )
            XCTAssertEqual(
                PublicDisplayNameSafety.sanitizedForDisplay(value),
                PublicDisplayNameSafety.fallback
            )
        }

        for value in ["Pizza Lupin", "Zalina", "Lupin", "Paula Z.", "Red Raven", "za lupus"] {
            XCTAssertFalse(
                PublicDisplayNameSafety.containsBlockedRoot(value),
                "Expected safe display name: \(value)"
            )
            XCTAssertEqual(
                PublicDisplayNameSafety.sanitizedForDisplay(value),
                value
            )
        }
    }

    func testPublicDisplayNameSafetyCleansUntrustedRenderedValue() {
        XCTAssertEqual(
            PublicDisplayNameSafety.sanitizedForDisplay("  Red\n\tRaven\u{200B}  "),
            "Red Raven"
        )
        XCTAssertEqual(
            PublicDisplayNameSafety.sanitizedForDisplay("   "),
            PublicDisplayNameSafety.fallback
        )
    }

    func testRadarInvitationSanitizesInboundHostCallSign() {
        let invitation = RadarIncomingInvitation(
            roomCode: "ABC123",
            hostCallSign: "з а л у п а",
            hostAvatar: "🕵️"
        )

        XCTAssertEqual(invitation.hostCallSign, PublicDisplayNameSafety.fallback)
    }

    func testUpdateProfileRejectsUnsafeDisplayNameBeforeNetworkRequest() async {
        MockURLProtocol.requestHandler = nil

        do {
            _ = try await makeClient().updateProfile(
                displayName: "z.4.l.u.p.4",
                avatar: "🕵️",
                language: .en,
                spyCardTheme: .field,
                spyCardAccent: .signalRed,
                spyCardBadge: .operative
            )
            XCTFail("Expected unsafe display name to be rejected.")
        } catch let error as PublicDisplayNameValidationError {
            XCTAssertEqual(error, .objectionableContent)
            XCTAssertEqual(
                error.message(for: .ru),
                "Имя содержит недопустимый текст."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateProfileCarriesCurrentLanguageForOldBackendCompatibility() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"id":"user-1","email":"operative@example.com"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        _ = try await makeClient().updateProfile(
            displayName: "Red Raven",
            avatar: "🕵️",
            language: .uk,
            spyCardTheme: .field,
            spyCardAccent: .signalRed,
            spyCardBadge: .operative
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "update_profile")
        XCTAssertEqual(body["language"] as? String, "uk")
    }

    func testDeleteAccountPreservesStructuredRetryDelay() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Retry-After": "601"
                ]
            )!
            let payload = #"{"error":"Account deletion is incomplete.","code":"apple_revocation_unavailable","retryable":true,"retry_after_seconds":600}"#
            return (response, Data(payload.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        do {
            _ = try await makeClient().deleteAccount()
            XCTFail("Expected account deletion to remain retryable.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.code, "apple_revocation_unavailable")
            XCTAssertTrue(error.retryable)
            XCTAssertEqual(error.retryAfterSeconds, 600)
            XCTAssertTrue(error.isRetryableAccountDeletion)
            XCTAssertEqual(
                error.localizedMessage(for: .ru),
                "Удаление аккаунта безопасно приостановлено. Повторите через 10 мин."
            )
            XCTAssertEqual(
                error.localizedMessage(for: .uk),
                "Видалення акаунта безпечно призупинено. Спробуйте знову через 10 хв."
            )
        }
    }

    func testCastDetectiveVoteSendsCapturedVoteRoundID() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        var room = GameRoom.previewRoom(status: "voting")
        room.detectiveVoteRoundID = "vote-round-a"
        let actor = try XCTUnwrap(room.playersList.first?.email)
        let target = try XCTUnwrap(room.playersList.dropFirst().first?.email)
        let user = SpyUser(
            id: "actor",
            email: actor,
            fullName: nil,
            displayName: nil,
            avatar: nil,
            language: nil,
            role: nil,
            isVerified: nil,
            rating: nil,
            gamesPlayed: nil,
            gamesWon: nil,
            remoteSpyID: nil,
            spyCardTheme: nil,
            spyCardAccent: nil,
            spyCardBadge: nil,
            radarInvitePolicy: nil
        )

        _ = try await makeClient().castDetectiveVote(
            room: room,
            user: user,
            targetEmail: target,
            expectedVoteRoundID: "vote-round-a"
        )

        let body = try XCTUnwrap(recorder.requestBodies().last)
        XCTAssertEqual(body["action"] as? String, "cast_detective_vote")
        XCTAssertEqual(body["target_email"] as? String, target)
        XCTAssertEqual(body["expected_vote_round_id"] as? String, "vote-round-a")
        XCTAssertNil(body["expected_detective_vote_round_id"])
    }

    func testRoundWrappersSendServerActionNames() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "playing")

        _ = try await client.startAssociation(room: room)
        _ = try await client.stopAssociationSpin(room: room)
        _ = try await client.markAnswerHeard(room: room)
        _ = try await client.continueRound(room: room)

        XCTAssertEqual(
            try recorder.requestBodies().map { try XCTUnwrap($0["action"] as? String) },
            ["start_association", "stop_association_spin", "mark_answer_heard", "continue_round"]
        )
        XCTAssertTrue(
            try recorder.requestBodies().allSatisfy {
                ($0["room_id"] as? String) == room.id &&
                    ($0["access_token"] as? String) == "test-token"
            }
        )
    }

    func testLobbyReturnVoteAndKickWrappersEncodeExplicitSafePayloads() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "playing")
        let stableTarget = Player(
            email: "stable@example.com",
            name: "Stable",
            avatar: "🕵️",
            userID: "user-stable",
            membershipID: "membership-stable-7"
        )
        let legacyTarget = Player(
            email: "legacy@example.com",
            name: "Legacy",
            avatar: "🎭"
        )

        _ = try await client.voteReturnToLobby(room: room, vote: true)
        _ = try await client.voteReturnToLobby(room: room, vote: false)
        _ = try await client.kickPlayer(room: room, player: stableTarget)
        _ = try await client.kickPlayer(room: room, player: legacyTarget)
        _ = try await client.returnFinishedRoomToLobby(room: room)

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies[0]["action"] as? String, "vote_return_to_lobby")
        XCTAssertEqual(bodies[0]["return_to_lobby_vote"] as? Bool, true)
        XCTAssertEqual(bodies[0]["expected_match_id"] as? String, room.matchID)
        XCTAssertEqual(bodies[1]["return_to_lobby_vote"] as? Bool, false)
        XCTAssertEqual(bodies[1]["expected_match_id"] as? String, room.matchID)

        XCTAssertEqual(bodies[2]["action"] as? String, "kick_player")
        XCTAssertEqual(bodies[2]["target_user_id"] as? String, "user-stable")
        XCTAssertNil(bodies[2]["target_email"])
        XCTAssertEqual(
            bodies[2]["expected_target_membership_id"] as? String,
            "membership-stable-7"
        )

        XCTAssertEqual(bodies[3]["action"] as? String, "kick_player")
        XCTAssertNil(bodies[3]["target_user_id"])
        XCTAssertEqual(bodies[3]["target_email"] as? String, "legacy@example.com")
        XCTAssertNil(bodies[3]["expected_target_membership_id"])

        XCTAssertEqual(bodies[4]["action"] as? String, "return_finished_room_to_lobby")
        XCTAssertEqual(bodies[4]["room_id"] as? String, room.id)
    }

    func testFinishedLobbyReturnRecoversACommittedLostResponse() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let body = try XCTUnwrap(recorder.requestBodies().last)
            let action = try XCTUnwrap(body["action"] as? String)
            if action == "return_finished_room_to_lobby" {
                throw URLError(.timedOut)
            }
            XCTAssertEqual(action, "get_room")
            return MockURLProtocol.roomResponse(
                for: request,
                id: GameRoom.previewRoom(status: "finished").id,
                status: "waiting",
                matchID: nil
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        var finished = GameRoom.previewRoom(status: "finished")
        finished.matchID = "match-finished"
        let recovered = try await makeClient().returnFinishedRoomToLobby(room: finished)
        XCTAssertEqual(recovered.normalizedStatus, "waiting")
        XCTAssertNil(recovered.matchID)
        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["return_finished_room_to_lobby", "get_room"]
        )
    }

    func testFinishedLobbyReturnRecoveryRejectsAnotherActiveGeneration() {
        var active = GameRoom.previewRoom(status: "playing")
        active.matchID = "next-match"
        XCTAssertFalse(
            FinishedRoomLobbyReturnRecoveryPolicy.accepts(
                room: active,
                expectedRoomID: active.id
            )
        )
    }

    func testReplayVoteCarriesFinishedMatchGeneration() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        var finished = GameRoom.previewRoom(status: "finished")
        finished.matchID = "match-finished-13"
        let user = makeRadarUser(id: "user-1", avatar: "🕵️", rating: 0, policy: .ask)
        _ = try await makeClient().votePlayAgain(room: finished, user: user)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "vote_play_again")
        XCTAssertEqual(body["room_id"] as? String, finished.id)
        XCTAssertEqual(body["expected_match_id"] as? String, "match-finished-13")
    }

    func testReplayVoteRecoversServerOwnedAutoStartAfterLostResponse() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let action = try XCTUnwrap(recorder.requestBodies().last?["action"] as? String)
            if action == "vote_play_again" {
                throw URLError(.timedOut)
            }
            XCTAssertEqual(action, "get_room")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"id":"preview-room-finished","code":"REPLAY","status":"roulette","match_id":"","replay_source_match_id":"match-finished-13","players":[]}"#
            return (response, Data(payload.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        var finished = GameRoom.previewRoom(status: "finished")
        finished.matchID = "match-finished-13"
        let user = makeRadarUser(id: "user-1", avatar: "🕵️", rating: 0, policy: .ask)
        let recovered = try await makeClient().votePlayAgain(room: finished, user: user)

        XCTAssertEqual(recovered.normalizedStatus, "roulette")
        XCTAssertEqual(recovered.replaySourceMatchID, "match-finished-13")
        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["vote_play_again", "get_room"]
        )
    }

    func testReplayVoteRecoveryRejectsAnotherReplayGeneration() {
        var roulette = GameRoom.previewRoom(status: "roulette")
        roulette.replaySourceMatchID = "newer-match"
        XCTAssertFalse(
            ReplayVoteCommitRecoveryPolicy.accepts(
                room: roulette,
                expectedRoomID: roulette.id,
                expectedSourceMatchID: "older-match",
                currentUserEmail: roulette.playersList[0].email
            )
        )

        var committedVote = GameRoom.previewRoom(status: "finished")
        committedVote.matchID = "older-match"
        committedVote.readyPlayers = [committedVote.playersList[0].email]
        XCTAssertTrue(
            ReplayVoteCommitRecoveryPolicy.accepts(
                room: committedVote,
                expectedRoomID: committedVote.id,
                expectedSourceMatchID: "older-match",
                currentUserEmail: committedVote.playersList[0].email.uppercased()
            )
        )
    }

    func testGameRoomDecodesAddressableLobbyPlayersAndCanonicalReturnVotes() throws {
        let room = try JSONDecoder().decode(
            GameRoom.self,
            from: Data(
                #"{"id":"room-1","code":"ABC123","status":"playing","players":[{"user_id":"user-1","email":"p1@example.com","name":"P1","avatar":"🕵️"},{"user_id":"user-2","email":"p2@example.com","name":"P2","avatar":"🎭"}],"ready_players":[" P1@EXAMPLE.COM ","p1@example.com","stale@example.com"]}"#.utf8
            )
        )

        XCTAssertEqual(room.playersList.map(\.userID), ["user-1", "user-2"])
        XCTAssertTrue(room.hasReturnToLobbyVote(email: "p1@example.com"))
        XCTAssertFalse(room.hasReturnToLobbyVote(email: "p2@example.com"))
        XCTAssertEqual(room.returnToLobbyVoteCount, 1)
    }

    func testRefreshRoomPreservesTypedAccessRevocationOutcome() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"error":"Not a player in this room","code":"room_access_revoked"}"#
            return (response, Data(payload.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        do {
            _ = try await makeClient().refreshRoom(id: "room-kicked")
            XCTFail("Expected a typed access-revoked response.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.code, "room_access_revoked")
            XCTAssertTrue(error.isRoomAccessRevoked)
            XCTAssertFalse(LobbySyncRetryPolicy.isRetryable(error))
        }
    }

    func testRoundActionRetriesOneTypedPreActionLeaseConflict() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count == 1 {
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let payload = #"{"error":"Account identity is being updated.","code":"active_lease","retryable":true}"#
                return (response, Data(payload.utf8))
            }
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "playing")

        _ = try await client.markAnswerHeard(room: room)

        XCTAssertEqual(try recorder.requestBodies().count, 2)
    }

    func testReturnToLobbyVoteRetriesWhenTheServerReroutesAFinalVoteToLeases() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count == 1 {
                return MockURLProtocol.leaseConflictResponse(
                    for: request,
                    code: "return_to_lobby_requires_leases",
                    retryable: true
                )
            }
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "playing")
        _ = try await makeClient().voteReturnToLobby(room: room, vote: true)

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(
            bodies.allSatisfy { ($0["action"] as? String) == "vote_return_to_lobby" }
        )
        XCTAssertTrue(
            bodies.allSatisfy { ($0["expected_match_id"] as? String) == room.matchID }
        )
    }

    func testExpiredFinalizationOwnsRetryAndSendsExactMatchScope() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        var room = GameRoom.previewRoom(status: "playing")
        room.matchID = "match-finalize"
        room.gameStartedAt = "2026-08-31T08:00:00.000Z"
        do {
            _ = try await makeClient().finalizeExpiredRoom(room: room)
            XCTFail("Expected the coordinator-owned retryable conflict.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "active_lease")
            XCTAssertTrue(error.retryable)
        }

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0]["action"] as? String, "finalize_expired_room")
        XCTAssertEqual(bodies[0]["expected_match_id"] as? String, room.matchID)
        XCTAssertEqual(
            bodies[0]["expected_game_started_at"] as? String,
            room.gameStartedAt
        )
    }

    func testDetectiveVoteCastDoesNotAddHiddenTransportRetry() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "voting")
        let user = makeRadarUser(id: "actor", avatar: "🕵️", rating: 0, policy: .ask)
        let target = try XCTUnwrap(room.playersList.dropFirst().first?.email)
        do {
            _ = try await makeClient().castDetectiveVote(
                room: room,
                user: user,
                targetEmail: target,
                expectedVoteRoundID: "vote-round-1",
                timeoutInterval: 1.25
            )
            XCTFail("Expected the coordinator-owned vote conflict.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "active_lease")
            XCTAssertTrue(error.retryable)
        }

        XCTAssertEqual(try recorder.requestBodies().count, 1)
        XCTAssertEqual(recorder.requestTimeoutIntervals(), [1.25])
    }

    func testKickUsesOneBoundedMutationAttemptBeforeCoordinatorRecovery() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "waiting")
        let target = try XCTUnwrap(room.playersList.dropFirst().first)
        do {
            _ = try await makeClient().kickPlayer(room: room, player: target)
            XCTFail("Expected the coordinator-owned kick recovery path.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "active_lease")
            XCTAssertTrue(error.retryable)
        }

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies.count, 1, "Kick must never replay a mutation inside the client.")
        XCTAssertEqual(bodies[0]["action"] as? String, "kick_player")
        XCTAssertEqual(recorder.requestTimeoutIntervals(), [8])
    }

    func testScopedUncertainCommitReadUsesOneBoundedRequest() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        do {
            _ = try await makeClient().refreshRoom(
                id: "room-uncertain-commit",
                timeoutInterval: RoomActionTransportPolicy.timeoutInterval(for: "get_room"),
                allowsTypedConflictRetry: false
            )
            XCTFail("Expected the single authoritative read to surface its conflict.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "active_lease")
        }

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0]["action"] as? String, "get_room")
        XCTAssertEqual(recorder.requestTimeoutIntervals(), [4])
    }

    func testCompleteGameStartAdoptsAuthoritativePlayingRoomAfterConflictRetryExhausts() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let requestCount = try recorder.requestBodies().count
            if requestCount <= 2 {
                return MockURLProtocol.leaseConflictResponse(
                    for: request,
                    code: "active_lease",
                    retryable: true
                )
            }
            return MockURLProtocol.roomResponse(
                for: request,
                id: "preview-room-roulette",
                status: "playing",
                matchID: "match-committed"
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "roulette")
        let completed = try await makeClient().completeGameStart(room: room)

        XCTAssertEqual(completed.id, room.id)
        XCTAssertEqual(completed.normalizedStatus, "playing")
        XCTAssertEqual(completed.matchID, "match-committed")
        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["complete_game_start", "complete_game_start", "get_room"]
        )
    }

    func testCompleteGameStartRethrowsOriginalConflictWhenAuthoritativeRoomIsStillRoulette() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let requestCount = try recorder.requestBodies().count
            if requestCount <= 2 {
                return MockURLProtocol.leaseConflictResponse(
                    for: request,
                    code: "cas_contention",
                    retryable: true
                )
            }
            return MockURLProtocol.roomResponse(
                for: request,
                id: "preview-room-roulette",
                status: "roulette",
                matchID: "match-not-committed"
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "roulette")
        do {
            _ = try await makeClient().completeGameStart(room: room)
            XCTFail("Expected the original typed conflict to be rethrown.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "cas_contention")
            XCTAssertTrue(error.retryable)
        }

        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["complete_game_start", "complete_game_start", "get_room"]
        )
    }

    func testCompleteGameStartDoesNotRetryOrReconcileNonRetryableConflict() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: false
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "roulette")
        do {
            _ = try await makeClient().completeGameStart(room: room)
            XCTFail("Expected the non-retryable conflict to be rethrown.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "active_lease")
            XCTAssertFalse(error.retryable)
        }

        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["complete_game_start"]
        )
    }

    func testCompleteGameStartPreservesCancellationFromAuthoritativeRefresh() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count <= 2 {
                return MockURLProtocol.leaseConflictResponse(
                    for: request,
                    code: "active_lease",
                    retryable: true
                )
            }
            throw URLError(.cancelled)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "roulette")
        do {
            _ = try await makeClient().completeGameStart(room: room)
            XCTFail("Expected cancellation from the reconciliation read.")
        } catch {
            XCTAssertTrue(RequestCancellationPolicy.isCancellation(error))
        }

        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["complete_game_start", "complete_game_start", "get_room"]
        )
    }

    func testCompletedGameStartAdoptionRequiresSamePlayingRoomAndMatchIdentity() {
        let playing = GameRoom.previewRoom(status: "playing")
        XCTAssertTrue(
            Base44Client.canAdoptCompletedGameStart(
                playing,
                expectedRoomID: playing.id
            )
        )
        XCTAssertFalse(
            Base44Client.canAdoptCompletedGameStart(
                playing,
                expectedRoomID: "different-room"
            )
        )

        var missingMatch = playing
        missingMatch.matchID = "  "
        XCTAssertFalse(
            Base44Client.canAdoptCompletedGameStart(
                missingMatch,
                expectedRoomID: missingMatch.id
            )
        )

        var roulette = playing
        roulette.status = "roulette"
        XCTAssertFalse(
            Base44Client.canAdoptCompletedGameStart(
                roulette,
                expectedRoomID: roulette.id
            )
        )
    }

    func testRequestCancellationPolicyRecognizesTaskTransportAndUnderlyingCancellation() {
        XCTAssertTrue(RequestCancellationPolicy.isCancellation(CancellationError()))
        XCTAssertTrue(RequestCancellationPolicy.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(
            RequestCancellationPolicy.isCancellation(
                NSError(
                    domain: "SpyClashTests.Wrapper",
                    code: 1,
                    userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)]
                )
            )
        )
        XCTAssertFalse(RequestCancellationPolicy.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(
            RequestCancellationPolicy.isCancellation(
                Base44Error(
                    message: "Account identity is being updated.",
                    statusCode: 409,
                    code: "active_lease",
                    retryable: true
                )
            )
        )
    }

    func testRoomIDLeaveWrapperSendsImmediateCleanupAction() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        try await client.leaveRoom(
            roomID: "room-dismissed",
            expectedRevision: 17
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "leave_room")
        XCTAssertEqual(body["room_id"] as? String, "room-dismissed")
        XCTAssertEqual(body["access_token"] as? String, "test-token")
        XCTAssertEqual(body["expected_revision"] as? Int, 17)
        XCTAssertEqual(recorder.requestTimeoutIntervals().first, 8)
    }

    func testRoomIDCloseWrapperSendsDedicatedBoundedCleanupAction() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }

        try await makeClient().closeRoom(
            roomID: "room-host-dismissed",
            expectedRevision: 22
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "close_room")
        XCTAssertEqual(body["room_id"] as? String, "room-host-dismissed")
        XCTAssertEqual(body["access_token"] as? String, "test-token")
        XCTAssertEqual(body["expected_revision"] as? Int, 22)
        XCTAssertEqual(recorder.requestTimeoutIntervals().first, 8)
    }

    func testCloseRoomTreatsMissingRoomAsAlreadyClosed() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"message":"Room not found."}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        try await makeClient().closeRoom(roomID: "room-already-closed")

        XCTAssertEqual(try recorder.requestBodies().count, 1)
        XCTAssertEqual(
            try recorder.requestBodies().first?["action"] as? String,
            "close_room"
        )
    }

    func testLatencySensitiveRoomActionsUseBoundedRequestDeadlines() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "playing")
        let user = makeRadarUser(id: "actor", avatar: "🕵️", rating: 0, policy: .ask)
        let targetEmail = try XCTUnwrap(room.playersList.dropFirst().first?.email)

        _ = try await client.requestVote(room: room, user: user)
        _ = try await client.castDetectiveVote(
            room: room,
            user: user,
            targetEmail: targetEmail,
            expectedVoteRoundID: "vote-round-1"
        )
        _ = try await client.submitSpyGuess(room: room, user: user, guess: "Cipher")
        _ = try await client.kickPlayer(
            room: room,
            player: try XCTUnwrap(room.playersList.dropFirst().first)
        )
        _ = try await client.refreshRoom(id: room.id)

        XCTAssertEqual(
            try recorder.requestBodies().map { try XCTUnwrap($0["action"] as? String) },
            [
                "request_vote",
                "cast_detective_vote",
                "submit_spy_guess",
                "kick_player",
                "get_room"
            ]
        )
        XCTAssertEqual(recorder.requestTimeoutIntervals(), [8, 8, 10, 8, 4])
        XCTAssertEqual(RoomActionTransportPolicy.timeoutInterval(for: "kick_player"), 8)

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies[0]["expected_match_id"] as? String, room.matchID)
        XCTAssertEqual(bodies[2]["expected_match_id"] as? String, room.matchID)
    }

    func testRawTargetKickResolvesMembershipGenerationFromRoomSnapshot() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        var room = GameRoom.previewRoom(status: "waiting")
        var target = try XCTUnwrap(room.playersList.dropFirst().first)
        target.userID = "target-user-current"
        target.membershipID = "membership-target-current"
        room.players = room.playersList.map {
            $0.email == target.email ? target : $0
        }

        _ = try await makeClient().kickPlayer(
            room: room,
            targetUserID: target.userID,
            targetEmail: target.email
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "kick_player")
        XCTAssertEqual(body["target_user_id"] as? String, "target-user-current")
        XCTAssertEqual(
            body["expected_target_membership_id"] as? String,
            "membership-target-current"
        )
    }

    func testHostRoomProjectionDecodesTargetMembershipGenerationForKickCAS() throws {
        let room = try JSONDecoder().decode(
            GameRoom.self,
            from: Data(
                #"{"id":"room-host","code":"ABC123","status":"waiting","viewer_membership_id":"membership-host","players":[{"user_id":"target-user","membership_id":"membership-target","email":"target@example.com","name":"Target","avatar":"🕵️"}]}"#.utf8
            )
        )

        XCTAssertEqual(room.viewerMembershipID, "membership-host")
        XCTAssertEqual(room.playersList.first?.userID, "target-user")
        XCTAssertEqual(room.playersList.first?.membershipID, "membership-target")
    }

    func testActiveRoomSendsPreferredIDAndDecodesNull() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("null".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = try await client.activeRoom(preferredRoomID: "room-from-web")

        XCTAssertNil(room)
        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "get_active_room")
        XCTAssertEqual(body["room_id"] as? String, "room-from-web")
        XCTAssertEqual(body["access_token"] as? String, "test-token")
    }

    func testResumeWaitingRoomUsesIdempotentJoinToUpgradePlayerCapability() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let user = makeRadarUser(id: "restored-host", avatar: "🕵️", rating: 0, policy: .ask)
        let waitingRoom = GameRoom.previewRoom(status: "waiting")

        _ = try await client.resumeWaitingRoom(waitingRoom, user: user)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "join_room")
        XCTAssertEqual(body["room_id"] as? String, waitingRoom.id)
        XCTAssertEqual(body["client_capabilities"] as? [String], ["multi_spy_v1"])
        let player = try XCTUnwrap(body["player"] as? [String: Any])
        XCTAssertEqual(player["email"] as? String, user.email)
        XCTAssertEqual(player["client_capabilities"] as? [String], ["multi_spy_v1"])
    }

    func testResumeNonWaitingRoomDoesNotMutateMembership() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let user = makeRadarUser(id: "active-player", avatar: "🕵️", rating: 0, policy: .ask)
        let playingRoom = GameRoom.previewRoom(status: "playing")

        let returned = try await client.resumeWaitingRoom(playingRoom, user: user)

        XCTAssertEqual(returned, playingRoom)
        XCTAssertTrue(try recorder.requestBodies().isEmpty)
    }

    func testJoinRetriesTypedLeaseConflictWithinThreeRequestBudget() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count <= 2 {
                return MockURLProtocol.leaseConflictResponse(
                    for: request,
                    code: "active_lease",
                    retryable: true
                )
            }
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let user = makeRadarUser(
            id: "joining-user",
            avatar: "🕵️",
            rating: 0,
            policy: .ask
        )
        let expectedMembershipID = "membership_generation_previous"
        let joined = try await makeClient().join(
            code: "ABC123",
            user: user,
            expectedMembershipID: expectedMembershipID
        )

        XCTAssertEqual(joined.id, "room-1")
        let requestBodies = try recorder.requestBodies()
        XCTAssertEqual(
            requestBodies.compactMap { $0["action"] as? String },
            ["join_room", "join_room", "join_room"]
        )
        let joinMembershipIDs = requestBodies.compactMap {
            $0["join_membership_id"] as? String
        }
        XCTAssertEqual(joinMembershipIDs.count, 3)
        XCTAssertEqual(Set(joinMembershipIDs).count, 1)
        XCTAssertFalse(try XCTUnwrap(joinMembershipIDs.first).isEmpty)
        XCTAssertEqual(
            requestBodies.compactMap { $0["expected_membership_id"] as? String },
            Array(repeating: expectedMembershipID, count: 3)
        )
    }

    func testRoomConflictPreservesHeaderOnlyRetryDelay() async throws {
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true,
                retryAfter: "1"
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        do {
            _ = try await makeClient().kickPlayer(
                room: GameRoom.previewRoom(status: "waiting"),
                targetUserID: "target-user",
                targetEmail: "target@example.com"
            )
            XCTFail("Expected a typed room conflict.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "active_lease")
            XCTAssertTrue(error.retryable)
            XCTAssertEqual(error.retryAfterSeconds, 1)
        }
    }

    func testJoinStopsAfterThreeRequestsWhenLeaseConflictPersists() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let user = makeRadarUser(
            id: "joining-user",
            avatar: "🕵️",
            rating: 0,
            policy: .ask
        )
        do {
            _ = try await makeClient().join(code: "ABC123", user: user)
            XCTFail("Expected bounded lease contention.")
        } catch let error as Base44Error {
            XCTAssertEqual(error.code, "active_lease")
        }

        XCTAssertEqual(try recorder.requestBodies().count, 3)
    }

    func testJoinRetryStopsAfterAccountSwitch() async throws {
        let recorder = RequestRecorder()
        let firstRequest = expectation(description: "First JOIN request started")
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count == 1 {
                firstRequest.fulfill()
            }
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let user = makeRadarUser(
            id: "joining-user",
            avatar: "🕵️",
            rating: 0,
            policy: .ask
        )
        let mutation = Task {
            try await client.join(code: "ABC123", user: user)
        }
        await fulfillment(of: [firstRequest], timeout: 1)
        client.setToken("replacement-token")

        do {
            _ = try await mutation.value
            XCTFail("Expected the old-account JOIN retry to be cancelled.")
        } catch is CancellationError {
            // Expected: the old player payload must not be sent under the new token.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(try recorder.requestBodies().count, 1)
    }

    func testJoinRejectsSuccessfulOldAccountResponseAfterAccountSwitch() async throws {
        let recorder = RequestRecorder()
        let requestStarted = expectation(description: "JOIN request started")
        let responseGate = ResponseGate()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            requestStarted.fulfill()
            responseGate.wait()
            return MockURLProtocol.roomResponse(for: request)
        }
        defer {
            responseGate.release()
            MockURLProtocol.requestHandler = nil
        }

        let client = makeClient()
        let user = makeRadarUser(
            id: "joining-user",
            avatar: "🕵️",
            rating: 0,
            policy: .ask
        )
        let mutation = Task {
            try await client.join(code: "ABC123", user: user)
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        client.setToken("replacement-token")
        responseGate.release()

        do {
            _ = try await mutation.value
            XCTFail("Expected the old-account JOIN response to be rejected.")
        } catch is CancellationError {
            // Expected: a successful response cannot cross an account boundary.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(try recorder.requestBodies().count, 1)
    }

    func testWordPackCreateRetriesOnlyTypedPreActionLeaseConflict() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count <= 2 {
                return MockURLProtocol.leaseConflictResponse(
                    for: request,
                    code: "active_lease",
                    retryable: true
                )
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"id":"pack-1","name":"Places","category":"Places","words":["Embassy","Harbor"]}"#
            return (response, Data(payload.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let pack = try await makeClient().createWordPack(
            name: "Places",
            category: "Places",
            words: ["Embassy", "Harbor"],
            ownerEmail: "operative@example.com"
        )

        XCTAssertEqual(pack.id, "pack-1")
        XCTAssertEqual(
            try recorder.requestBodies().compactMap { $0["action"] as? String },
            ["create", "create", "create"]
        )
    }

    func testCommunityMutationRetryStopsAfterAccountSwitch() async throws {
        let recorder = RequestRecorder()
        let firstRequest = expectation(description: "First community request started")
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            if try recorder.requestBodies().count == 1 {
                firstRequest.fulfill()
            }
            return MockURLProtocol.leaseConflictResponse(
                for: request,
                code: "active_lease",
                retryable: true
            )
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let mutation = Task {
            try await client.communityRelationshipAction(
                "accept",
                friendshipID: "friendship-1"
            )
        }
        await fulfillment(of: [firstRequest], timeout: 1)
        client.setToken("replacement-token")

        do {
            _ = try await mutation.value
            XCTFail("Expected the old-account retry to be cancelled.")
        } catch is CancellationError {
            // Expected: the second request must never use the captured token.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(try recorder.requestBodies().count, 1)
    }

    func testSavedPackExclusionsAreFrozenIntoStartPlanAndTransport() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let disabledKeys = Set([RoomWordPoolFilter.key("removed")])
        let activeWords = RoomWordPoolFilter.activeWords(
            [" keep-a ", "removed", "KEEP-A", "keep-b"],
            excluding: disabledKeys
        )
        XCTAssertEqual(activeWords, ["keep-a", "keep-b"])

        let pack = WordPack(
            id: "pack-1",
            name: "Fresh pack",
            category: "TEST",
            words: activeWords,
            ownerEmail: "operative@example.com",
            isPublic: false
        )
        let client = makeClient()
        let room = GameRoom.previewRoom(status: "waiting")
        let plan = try client.makeGameStartPlan(
            room: room,
            wordPacks: [pack],
            selectedPackID: pack.id,
            gameMode: .questions,
            durationSeconds: 600
        )

        _ = try await client.armRoulette(room: room, plan: plan)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        let planBody = try XCTUnwrap(body["plan"] as? [String: Any])
        let secretWord = try XCTUnwrap(planBody["secret_word"] as? String)
        let pool = try XCTUnwrap(planBody["word_pool"] as? [[String: Any]])
        let transportedWords = try pool.map { try XCTUnwrap($0["word"] as? String) }

        XCTAssertEqual(Set(transportedWords), Set(activeWords))
        XCTAssertTrue(pool.allSatisfy { ($0["enabled"] as? Bool) == true })
        XCTAssertTrue(activeWords.contains(secretWord))
        XCTAssertFalse(transportedWords.contains("removed"))
    }

    func testAuthoritativeGeneratedLobbyDrivesStartPlanDespiteLocalPackID() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        var room = GameRoom.previewRoom(status: "waiting")
        room.lobbyRevision = 7
        room.lobbyWordSource = "ai"
        room.lobbySourcePackID = nil
        room.lobbySourceName = "World map"
        room.lobbyCategory = "COUNTRIES"
        room.lobbyWordCount = 2
        room.lobbyWordPool = [
            LobbyWordPoolEntry(word: "Bulgaria"),
            LobbyWordPoolEntry(word: "Removed", enabled: false),
            LobbyWordPoolEntry(word: "Romania"),
            LobbyWordPoolEntry(word: "Moldova")
        ]

        let plan = try client.makeGameStartPlan(
            room: room,
            wordPacks: [],
            selectedPackID: "generated",
            gameMode: .questions,
            durationSeconds: 900
        )
        _ = try await client.armRoulette(room: room, plan: plan)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        let planBody = try XCTUnwrap(body["plan"] as? [String: Any])
        let secretWord = try XCTUnwrap(planBody["secret_word"] as? String)
        let pool = try XCTUnwrap(planBody["word_pool"] as? [[String: Any]])
        let transportedWords = try pool.map { try XCTUnwrap($0["word"] as? String) }

        XCTAssertEqual(transportedWords, ["Bulgaria", "Romania"])
        XCTAssertTrue(transportedWords.contains(secretWord))
        XCTAssertEqual(planBody["category"] as? String, "COUNTRIES")
    }

    func testReplayPlanUsesPreservedAuthoritativeLobbyAfterGameplayPoolWasCleared() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        var resetRoom = GameRoom.previewRoom(status: "waiting")
        resetRoom.matchID = nil
        resetRoom.wordPool = []
        resetRoom.secretWord = nil
        resetRoom.word = nil
        resetRoom.readyPlayers = []
        resetRoom.lobbyRevision = 9
        resetRoom.lobbyWordSource = "saved"
        resetRoom.lobbySourcePackID = "saved-pack"
        resetRoom.lobbySourceName = "Preserved deck"
        resetRoom.lobbyCategory = "ARCHIVE"
        resetRoom.lobbyWordCount = 2
        resetRoom.lobbyWordPool = [
            LobbyWordPoolEntry(word: "Cipher"),
            LobbyWordPoolEntry(word: "Embassy"),
            LobbyWordPoolEntry(word: "Disabled", enabled: false)
        ]
        let staleLocalPack = WordPack(
            id: "stale-local",
            name: "Stale",
            category: "WRONG",
            words: ["Wrong A", "Wrong B"],
            ownerEmail: "operative@example.com",
            isPublic: false
        )

        let plan = try client.makeGameStartPlan(
            room: resetRoom,
            wordPacks: [staleLocalPack],
            selectedPackID: staleLocalPack.id,
            gameMode: .associations,
            durationSeconds: 60
        )
        _ = try await client.armRoulette(room: resetRoom, plan: plan)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        let planBody = try XCTUnwrap(body["plan"] as? [String: Any])
        let pool = try XCTUnwrap(planBody["word_pool"] as? [[String: Any]])
        let transportedWords = try pool.map { try XCTUnwrap($0["word"] as? String) }

        XCTAssertEqual(transportedWords, ["Cipher", "Embassy"])
        XCTAssertEqual(planBody["category"] as? String, "ARCHIVE")
        XCTAssertFalse(transportedWords.contains("Wrong A"))
    }

    func testGameRoomDecodesAuthoritativeLobbyProjection() throws {
        let room = try JSONDecoder().decode(
            GameRoom.self,
            from: Data(
                #"{"id":"room-1","code":"ABC123","lobby_schema_version":1,"lobby_revision":7,"lobby_word_source":"ai","lobby_source_pack_id":"pack-1","lobby_source_name":"Night Ops","lobby_theme":"espionage","lobby_category":"COVERT","lobby_word_count":42,"lobby_word_count_mode":"custom","lobby_word_pool":[{"id":"word-1","word":"Embassy","enabled":false},{"id":"word-2","word":"Cipher"}]}"#.utf8
            )
        )

        XCTAssertEqual(room.lobbySchemaVersion, 1)
        XCTAssertEqual(room.lobbyRevision, 7)
        XCTAssertEqual(room.lobbyWordSource, "ai")
        XCTAssertEqual(room.lobbySourcePackID, "pack-1")
        XCTAssertEqual(room.lobbySourceName, "Night Ops")
        XCTAssertEqual(room.lobbyTheme, "espionage")
        XCTAssertEqual(room.lobbyCategory, "COVERT")
        XCTAssertEqual(room.lobbyWordCount, 42)
        XCTAssertEqual(room.lobbyWordCountMode, "custom")
        XCTAssertEqual(room.lobbyWordPool?.map(\.id), ["word-1", "word-2"])
        XCTAssertEqual(room.lobbyWordPool?.map(\.enabled), [false, true])
    }

    func testLobbyStatePayloadEncodesExactBackendKeys() throws {
        let payload = LobbyStatePayload(
            gameMode: .associations,
            gameDurationSeconds: 300,
            spyCount: 3,
            spiesKnowEachOther: true,
            lobbyWordSource: .manual,
            lobbySourcePackID: nil,
            lobbySourceName: "Hand-picked",
            lobbyTheme: nil,
            lobbyCategory: "CUSTOM",
            lobbyWordCount: 2,
            lobbyWordCountMode: .custom,
            lobbyWordPool: [
                LobbyWordPoolEntry(id: "word-1", word: "Embassy"),
                LobbyWordPoolEntry(word: "Cipher", enabled: false)
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )

        XCTAssertEqual(object["game_mode"] as? String, "associations")
        XCTAssertEqual(object["game_duration_seconds"] as? Int, 300)
        XCTAssertEqual(object["lobby_spy_count"] as? Int, 3)
        XCTAssertEqual(object["spies_know_each_other"] as? Bool, true)
        XCTAssertNil(object["spy_count"])
        XCTAssertEqual(object["lobby_word_source"] as? String, "manual")
        XCTAssertNil(object["lobby_source_pack_id"])
        XCTAssertEqual(object["lobby_source_name"] as? String, "Hand-picked")
        XCTAssertNil(object["lobby_theme"])
        XCTAssertEqual(object["lobby_category"] as? String, "CUSTOM")
        XCTAssertEqual(object["lobby_word_count"] as? Int, 2)
        XCTAssertEqual(object["lobby_word_count_mode"] as? String, "custom")

        let words = try XCTUnwrap(object["lobby_word_pool"] as? [[String: Any]])
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0]["id"] as? String, "word-1")
        XCTAssertEqual(words[0]["word"] as? String, "Embassy")
        XCTAssertEqual(words[0]["enabled"] as? Bool, true)
        XCTAssertNil(words[1]["id"])
        XCTAssertEqual(words[1]["enabled"] as? Bool, false)
    }

    func testUpdateLobbyStateSendsRevisionedMutationEnvelope() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let room = GameRoom.previewRoom(status: "waiting")
        let state = LobbyStatePayload(
            gameMode: .questions,
            gameDurationSeconds: 900,
            spyCount: 2,
            spiesKnowEachOther: false,
            lobbyWordSource: .saved,
            lobbySourcePackID: "pack-1",
            lobbySourceName: "Classic",
            lobbyTheme: nil,
            lobbyCategory: "CLASSIC",
            lobbyWordCount: 25,
            lobbyWordCountMode: .recommended,
            lobbyWordPool: [LobbyWordPoolEntry(id: "word-1", word: "Embassy")]
        )

        _ = try await client.updateLobbyState(
            room: room,
            mutationID: "mutation-7",
            expectedRevision: 6,
            state: state
        )

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "update_lobby_state")
        XCTAssertEqual(body["room_id"] as? String, room.id)
        XCTAssertEqual(body["access_token"] as? String, "test-token")
        XCTAssertEqual(body["mutation_id"] as? String, "mutation-7")
        XCTAssertEqual(body["expected_revision"] as? Int, 6)
        XCTAssertEqual(body["client_capabilities"] as? [String], ["multi_spy_v1"])
        let encodedState = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(encodedState["game_mode"] as? String, "questions")
        XCTAssertEqual(encodedState["lobby_source_pack_id"] as? String, "pack-1")
        XCTAssertEqual(encodedState["lobby_spy_count"] as? Int, 2)
        XCTAssertEqual(encodedState["spies_know_each_other"] as? Bool, false)
        XCTAssertNil(encodedState["spy_count"])
    }

    func testUpdateGameModeUsesDedicatedFastAction() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let room = GameRoom.previewRoom(status: "waiting")
        _ = try await makeClient().updateGameMode(room: room, mode: .associations)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "update_game_mode")
        XCTAssertEqual(body["room_id"] as? String, room.id)
        XCTAssertEqual(body["mode"] as? String, "associations")
        XCTAssertNil(body["state"])
        XCTAssertNil(body["expected_revision"])
    }

    func testCreateAndJoinAdvertiseMultiSpyCapabilityInsidePlayerAndTopLevel() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        let user = makeRadarUser(id: "multi-spy", avatar: "🥷", rating: 0, policy: .ask)

        _ = try await client.createRoom(for: user)
        _ = try await client.join(code: "ABC123", user: user)

        let bodies = try recorder.requestBodies()
        XCTAssertEqual(bodies.compactMap { $0["action"] as? String }, ["create_room", "join_room"])
        for body in bodies {
            XCTAssertEqual(body["client_capabilities"] as? [String], ["multi_spy_v1"])
            let player = try XCTUnwrap(body["player"] as? [String: Any])
            XCTAssertEqual(player["client_capabilities"] as? [String], ["multi_spy_v1"])
        }
    }

    func testArmRouletteSendsExpectedLobbyRevision() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            return MockURLProtocol.roomResponse(for: request)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = makeClient()
        var room = GameRoom.previewRoom(status: "waiting")
        room.lobbyRevision = 12
        room.lobbyWordCount = 2
        room.lobbyWordPool = [
            LobbyWordPoolEntry(word: "Embassy"),
            LobbyWordPoolEntry(word: "Cipher")
        ]
        let plan = try client.makeGameStartPlan(
            room: room,
            wordPacks: [],
            selectedPackID: nil,
            gameMode: .questions,
            durationSeconds: 900
        )

        _ = try await client.armRoulette(room: room, plan: plan)

        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "arm_roulette")
        XCTAssertEqual(body["expected_lobby_revision"] as? Int, 12)
        XCTAssertEqual(body["client_capabilities"] as? [String], ["multi_spy_v1"])
        let planBody = try XCTUnwrap(body["plan"] as? [String: Any])
        XCTAssertNil(planBody["spy_email"], "The backend, not iOS, must assign spy identities.")
    }

    func testRadarInvitePolicyUsesAuthenticatedCommunityActionContract() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            try recorder.append(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"radar_invite_policy":"automatic"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let confirmed = try await makeClient().updateRadarInvitePolicy(.automatic)

        XCTAssertEqual(confirmed, .automatic)
        let body = try XCTUnwrap(recorder.requestBodies().first)
        XCTAssertEqual(body["action"] as? String, "set_radar_invite_policy")
        XCTAssertEqual(body["radar_invite_policy"] as? String, "automatic")
        XCTAssertEqual(body["access_token"] as? String, "test-token")
        XCTAssertTrue(try XCTUnwrap(recorder.requestURLs().first).absoluteString.contains("communityAction"))
    }

    func testRadarInvitePolicyFallbackMigratesLegacyValueOnlyOnceAndScopesAccounts() throws {
        let suiteName = "Base44ClientRoomActionTests.RadarInvitePolicy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("automatic", forKey: RadarInvitePolicy.legacyStorageKey)

        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-a", defaults: defaults), .automatic)
        XCTAssertNil(defaults.string(forKey: RadarInvitePolicy.legacyStorageKey))
        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-b", defaults: defaults), .ask)

        RadarInvitePolicy.blocked.persist(for: "account-b", defaults: defaults)
        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-a", defaults: defaults), .automatic)
        XCTAssertEqual(RadarInvitePolicy.stored(for: "account-b", defaults: defaults), .ask)
    }

    func testRadarInvitePolicyKeepsBlockedForWireCompatibilityButNotSelection() {
        XCTAssertEqual(RadarInvitePolicy.selectableCases, [.ask, .automatic])
        XCTAssertEqual(RadarInvitePolicy.blocked.selectableValue, .ask)
        XCTAssertEqual(RadarInvitePolicy(rawValue: "blocked"), .blocked)
    }

    func testSpyUserDecodesSharedRadarInvitePolicyField() throws {
        let user = try JSONDecoder().decode(
            SpyUser.self,
            from: Data(#"{"id":"user-1","email":"operative@example.com","radar_invite_policy":"blocked"}"#.utf8)
        )

        XCTAssertEqual(user.radarInvitePolicy, "blocked")
    }

    func testPendingRadarRetryProtectsLocalPolicyFromStaleSameAccountRefresh() {
        XCTAssertTrue(
            AppState.hasUncommittedRadarInvitePolicy(
                userID: "user-1",
                syncOwnerUserID: "user-1",
                syncState: .pendingRetry,
                hasQueuedWrite: false
            )
        )
        XCTAssertFalse(
            AppState.hasUncommittedRadarInvitePolicy(
                userID: "user-2",
                syncOwnerUserID: "user-1",
                syncState: .pendingRetry,
                hasQueuedWrite: false
            )
        )
        XCTAssertFalse(
            AppState.hasUncommittedRadarInvitePolicy(
                userID: "user-1",
                syncOwnerUserID: "user-1",
                syncState: .synced,
                hasQueuedWrite: false
            )
        )
    }

    func testRadarPresenceSnapshotRoundTripsAvailabilityPolicyAndRevision() throws {
        let snapshot = RadarPresenceSnapshot(
            availability: .inGame,
            invitePolicy: .blocked,
            revision: 42
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RadarPresenceSnapshot.self, from: encoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(object["availability"] as? String, "in_game")
        XCTAssertEqual(object["invitePolicy"] as? String, "blocked")
        XCTAssertEqual(object["revision"] as? Int, 42)
    }

    func testRadarPresenceVersionRejectsStaleDiscoveryAfterLiveUpdate() {
        XCTAssertTrue(
            RadarPresenceVersionPolicy.shouldApply(incoming: 12, current: 11)
        )
        XCTAssertTrue(
            RadarPresenceVersionPolicy.shouldApply(incoming: 12, current: 12)
        )
        XCTAssertFalse(
            RadarPresenceVersionPolicy.shouldApply(incoming: 11, current: 12)
        )
        XCTAssertFalse(
            RadarPresenceVersionPolicy.shouldApply(incoming: nil, current: 12)
        )
        XCTAssertTrue(
            RadarPresenceVersionPolicy.shouldApply(incoming: nil, current: 0)
        )
    }

    func testRadarPresenceTransitionsBlockAndUnblockExistingCard() {
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .blocked,
                currentState: .waiting
            ),
            .blocked
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .ask,
                currentState: .blocked
            )
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .automatic,
                currentState: .accepted
            )
        )
        XCTAssertNil(
            RadarInvitationInteractionPolicy.state(
                after: .available,
                invitePolicy: .automatic,
                currentState: .inGame
            )
        )
        XCTAssertEqual(
            RadarInvitationInteractionPolicy.action(
                invitePolicy: .automatic,
                availability: .available,
                invitationState: nil
            ),
            .send
        )
    }

    func testRadarRoomInviteQueuesBehindPresenceConnectionAttempt() {
        XCTAssertTrue(
            RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: false,
                hasPresenceAttempt: true,
                isConnecting: false
            )
        )
        XCTAssertTrue(
            RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: false,
                hasPresenceAttempt: false,
                isConnecting: true
            )
        )
        XCTAssertFalse(
            RadarRoomInviteDeliveryPolicy.shouldQueueForActiveConnectionAttempt(
                hasRangingAttempt: false,
                hasPresenceAttempt: false,
                isConnecting: false
            )
        )
    }

    func testBlockingRadarInvitesDismissesExistingIncomingCard() {
        let radar = RadarNearbyService()
        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "ABC123",
                hostCallSign: "Host",
                hostAvatar: "🕵️"
            )
        )

        radar.setInvitePolicy(.blocked)
        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "XYZ789",
                hostCallSign: "Second Host",
                hostAvatar: "🥷"
            )
        )

        XCTAssertNil(radar.incomingInvitation)
    }

    func testRadarDoesNotResurrectUntrackedWireInvitation() {
        let radar = RadarNearbyService()

        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "ABC123",
                hostCallSign: "Host",
                hostAvatar: "🕵️",
                wireInvitationID: "cancelled-invite",
                sourcePeerID: "lost-peer"
            )
        )

        XCTAssertNil(radar.incomingInvitation)
    }

    func testRadarProfileRefreshPreservesInviteButAccountChangeClearsIt() {
        let radar = RadarNearbyService()
        let originalUser = makeRadarUser(
            id: "account-a",
            avatar: "🕵️",
            rating: 10,
            policy: .ask
        )
        let refreshedUser = makeRadarUser(
            id: "account-a",
            avatar: "🥷",
            rating: 25,
            policy: .ask
        )
        let nextAccount = makeRadarUser(
            id: "account-b",
            avatar: "🕶️",
            rating: 0,
            policy: .ask
        )
        let invitation = RadarIncomingInvitation(
            roomCode: "ABC123",
            hostCallSign: "Host",
            hostAvatar: "🕵️"
        )

        radar.configure(user: originalUser)
        radar.presentForConfirmation(invitation)
        radar.configure(user: refreshedUser)

        XCTAssertEqual(radar.incomingInvitation, invitation)

        radar.configure(user: nextAccount)

        XCTAssertNil(radar.incomingInvitation)
    }

    func testRadarCombinedProfileAndLegacyBlockedPolicyMigratesToAsk() {
        let radar = RadarNearbyService()
        radar.configure(
            user: makeRadarUser(
                id: "account-a",
                avatar: "🕵️",
                rating: 10,
                policy: .ask
            )
        )
        radar.presentForConfirmation(
            RadarIncomingInvitation(
                roomCode: "ABC123",
                hostCallSign: "Host",
                hostAvatar: "🕵️"
            )
        )

        radar.configure(
            user: makeRadarUser(
                id: "account-a",
                avatar: "🥷",
                rating: 25,
                policy: .blocked
            )
        )

        XCTAssertNotNil(radar.incomingInvitation)
        XCTAssertEqual(radar.invitePolicy, .ask)
    }

    private func makeRadarUser(
        id: String,
        avatar: String,
        rating: Int,
        policy: RadarInvitePolicy
    ) -> SpyUser {
        SpyUser(
            id: id,
            email: "\(id)@example.com",
            fullName: nil,
            displayName: id,
            avatar: avatar,
            language: nil,
            role: nil,
            isVerified: nil,
            rating: rating,
            gamesPlayed: 3,
            gamesWon: 2,
            remoteSpyID: id == "account-a" ? "123456" : "654321",
            spyCardTheme: nil,
            spyCardAccent: nil,
            spyCardBadge: nil,
            radarInvitePolicy: policy.rawValue
        )
    }

    private func makeClient() -> Base44Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("test-token")
        return client
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    private var urls: [URL] = []
    private var timeoutIntervals: [TimeInterval] = []

    func append(_ request: URLRequest) throws {
        let data = try Self.bodyData(from: request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        lock.lock()
        bodies.append(body)
        if let url = request.url {
            urls.append(url)
        }
        timeoutIntervals.append(request.timeoutInterval)
        lock.unlock()
    }

    func requestBodies() throws -> [[String: Any]] {
        lock.lock()
        let snapshot = bodies
        lock.unlock()
        return snapshot
    }

    func requestURLs() -> [URL] {
        lock.lock()
        let snapshot = urls
        lock.unlock()
        return snapshot
    }

    func requestTimeoutIntervals() -> [TimeInterval] {
        lock.lock()
        let snapshot = timeoutIntervals
        lock.unlock()
        return snapshot
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotDecodeContentData)
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ResponseGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func release() {
        semaphore.signal()
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func roomResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let payload = #"{"id":"room-1","code":"ABC123","status":"playing","players":[]}"#
        return (response, Data(payload.utf8))
    }

    static func roomResponse(
        for request: URLRequest,
        id: String,
        status: String,
        matchID: String?
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        var room: [String: Any] = [
            "id": id,
            "code": "ABC123",
            "status": status,
            "players": []
        ]
        if let matchID {
            room["match_id"] = matchID
        }
        return (response, try! JSONSerialization.data(withJSONObject: room))
    }

    static func leaseConflictResponse(
        for request: URLRequest,
        code: String,
        retryable: Bool,
        retryAfter: String? = nil
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter {
            headers["Retry-After"] = retryAfter
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 409,
            httpVersion: nil,
            headerFields: headers
        )!
        let payload: [String: Any] = [
            "error": "Account identity is being updated.",
            "code": code,
            "retryable": retryable
        ]
        return (response, try! JSONSerialization.data(withJSONObject: payload))
    }
}
