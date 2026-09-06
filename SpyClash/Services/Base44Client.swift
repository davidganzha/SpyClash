import Foundation

enum AppleNativeAuthPhase {
    case verifyingIdentity
    case establishingSession
}

enum RoomActionTransportPolicy {
    static func timeoutInterval(for action: String) -> TimeInterval? {
        switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "submit_spy_guess":
            10
        case "request_vote", "cast_detective_vote", "kick_player", "leave_room", "close_room":
            8
        case "get_room":
            4
        default:
            nil
        }
    }
}

enum RoomExitRevisionPolicy {
    static func expectedRevision(roomRevision: Int?) -> Int {
        max(roomRevision ?? 0, 0)
    }
}

/// The coordinator already retries Live Activity token mutations. Keeping
/// those requests single-attempt at the HTTP layer prevents one coordinator
/// retry from expanding into several identical backend writes.
struct PushNotificationTransportRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let retriesTypedLeaseConflict: Bool

    static func policy(for action: String) -> Self {
        switch action {
        case "register_live_activity_token", "unregister_live_activity_token":
            return Self(maximumAttempts: 1, retriesTypedLeaseConflict: false)
        case "register_device":
            return Self(maximumAttempts: 3, retriesTypedLeaseConflict: true)
        default:
            return Self(maximumAttempts: 3, retriesTypedLeaseConflict: false)
        }
    }
}

enum FinishedRoomLobbyReturnRecoveryPolicy {
    static func accepts(room: GameRoom?, expectedRoomID: String) -> Bool {
        guard let room,
              room.id == expectedRoomID,
              room.normalizedStatus == "waiting",
              room.matchID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank == nil,
              room.gameStartedAt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank == nil,
              room.terminalReconciliationPending != true,
              (room.readyPlayers ?? []).isEmpty else { return false }
        return true
    }
}

enum ReplayVoteCommitRecoveryPolicy {
    static func accepts(
        room: GameRoom?,
        expectedRoomID: String,
        expectedSourceMatchID: String,
        currentUserEmail: String
    ) -> Bool {
        guard let room,
              room.id == expectedRoomID,
              !expectedSourceMatchID.isEmpty else { return false }
        let currentUserKey = currentUserEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !currentUserKey.isEmpty else { return false }

        switch room.normalizedStatus {
        case "finished", "ended":
            guard room.matchID?
                .trimmingCharacters(in: .whitespacesAndNewlines) == expectedSourceMatchID else {
                return false
            }
            return (room.readyPlayers ?? []).contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == currentUserKey
            }
        case "roulette", "playing":
            return room.replaySourceMatchID?
                .trimmingCharacters(in: .whitespacesAndNewlines) == expectedSourceMatchID
        default:
            return false
        }
    }
}

@MainActor
@Observable
final class Base44Client {
    static let multiSpyCapability = "multi_spy_v1"
    static let appID = "69a0e57fa939f578082f8091"
    static let appBaseURL = URL(string: "https://spyclash.com")!

    private let session: URLSession
    private var token: String?
    private var tokenGeneration = UUID()

    var hasSessionToken: Bool {
        token?.isEmpty == false
    }

    var currentAccessToken: String? {
        token?.isEmpty == false ? token : nil
    }

    var sessionGeneration: UUID { tokenGeneration }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setToken(_ token: String) {
        if self.token != token { tokenGeneration = UUID() }
        self.token = token
    }

    func clearToken() {
        tokenGeneration = UUID()
        token = nil
    }

    func currentUser() async throws -> SpyUser {
        try await request("/apps/\(Self.appID)/entities/User/me", method: "GET")
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        let response: LoginResponse = try await request(
            "/apps/\(Self.appID)/auth/login",
            method: "POST",
            body: ["email": email, "password": password]
        )
        // The owning authentication attempt commits credentials only after
        // checking it was not cancelled or replaced while this request ran.
        return response
    }

    func register(email: String, password: String) async throws {
        let _: EmptyResponse = try await request(
            "/apps/\(Self.appID)/auth/register",
            method: "POST",
            body: ["email": email, "password": password]
        )
    }

    func verify(email: String, code: String) async throws -> VerifyResponse {
        try await request(
            "/apps/\(Self.appID)/auth/verify-otp",
            method: "POST",
            body: ["email": email, "otp_code": code]
        )
    }

    func resendOTP(email: String) async throws {
        let _: EmptyResponse = try await request(
            "/apps/\(Self.appID)/auth/resend-otp",
            method: "POST",
            body: ["email": email]
        )
    }

    func requestPasswordReset(email: String) async throws {
        let _: EmptyResponse = try await request(
            "/apps/\(Self.appID)/auth/reset-password-request",
            method: "POST",
            body: ["email": email]
        )
    }

    func resetPassword(token: String, newPassword: String) async throws {
        let _: EmptyResponse = try await request(
            "/apps/\(Self.appID)/auth/reset-password",
            method: "POST",
            body: ["reset_token": token, "new_password": newPassword]
        )
    }

    func autoRegisterUser(appleBindingTicket: String? = nil, accessToken: String? = nil) async throws -> SpyUser {
        let token = try requireAccessToken(accessToken)

        // A valid SSO identity is not yet an app user at this point. Base44's
        // function gateway rejects that bearer token before autoRegisterUser
        // can provision it, so send it in the encrypted body and let the
        // backend verify it directly with Base44.
        var payload = ["access_token": token]
        if let appleBindingTicket, !appleBindingTicket.isEmpty {
            payload["apple_binding_ticket"] = appleBindingTicket
        }
        let response: AutoRegisterUserResponse = try await request(
            "/apps/\(Self.appID)/functions/autoRegisterUser",
            method: "POST",
            body: payload,
            includeAuthorization: false
        )
        if let user = response.user {
            return user
        }

        // Keep a safe fallback while older function deployments are still
        // propagating. The optimized backend always returns the verified user.
        return try await request(
            "/apps/\(Self.appID)/entities/User/me", method: "GET",
            authorizationToken: token
        )
    }

    func registerPushDevice(
        installationID: String,
        apnsToken: String,
        environment: PushEnvironment,
        alertAuthorized: Bool,
        locale: String,
        appVersion: String
    ) async throws -> PushRegistrationResponse {
        try await pushNotificationAction(
            PushNotificationActionPayload(
                action: "register_device",
                accessToken: try requireAccessToken(),
                installationID: installationID,
                apnsToken: apnsToken,
                environment: environment.rawValue,
                bundleID: Bundle.main.bundleIdentifier ?? "com.spyclash.ios",
                locale: locale,
                appVersion: appVersion,
                alertAuthorized: alertAuthorized,
                preferences: PushNotificationPreferences()
            )
        )
    }

    func unregisterPushDevice(
        installationID: String,
        accessToken: String? = nil
    ) async throws {
        let _: EmptyResponse = try await pushNotificationAction(
            PushNotificationActionPayload(
                action: "unregister_device",
                accessToken: try requireAccessToken(accessToken),
                installationID: installationID
            )
        )
    }

    func registerLiveActivityToken(
        installationID: String,
        tokenKind: LiveActivityPushTokenKind,
        token: String,
        environment: PushEnvironment,
        locale: String,
        activityID: String? = nil,
        roomID: String? = nil,
        matchID: String? = nil
    ) async throws -> PushRegistrationResponse {
        try await pushNotificationAction(
            PushNotificationActionPayload(
                action: "register_live_activity_token",
                accessToken: try requireAccessToken(),
                installationID: installationID,
                environment: environment.rawValue,
                bundleID: Bundle.main.bundleIdentifier ?? "com.spyclash.ios",
                locale: locale,
                tokenKind: tokenKind.rawValue,
                liveActivityToken: token,
                activityID: activityID,
                roomID: roomID,
                matchID: matchID
            )
        )
    }

    func unregisterLiveActivityToken(
        installationID: String,
        tokenKind: LiveActivityPushTokenKind,
        activityID: String? = nil,
        matchID: String? = nil
    ) async throws {
        let _: EmptyResponse = try await pushNotificationAction(
            PushNotificationActionPayload(
                action: "unregister_live_activity_token",
                accessToken: try requireAccessToken(),
                installationID: installationID,
                tokenKind: tokenKind.rawValue,
                activityID: activityID,
                matchID: matchID
            )
        )
    }

    func roomJoinURL(code: String) -> URL {
        var components = URLComponents(url: Self.appBaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.fragment = "/Home?join=\(code.uppercased())"
        return components.url!
    }

    func nativeRoomJoinURL(code: String) -> URL {
        var components = URLComponents()
        components.scheme = "spyclash"
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "code", value: code.uppercased())
        ]
        return components.url ?? roomJoinURL(code: code)
    }

    func roomJoinURL(code: String, target: RoomQRTarget) -> URL {
        switch target {
        case .web:
            roomJoinURL(code: code)
        case .ios:
            nativeRoomJoinURL(code: code)
        }
    }

    func refreshRoom(
        id: String,
        timeoutInterval: TimeInterval? = nil,
        allowsTypedConflictRetry: Bool = true
    ) async throws -> GameRoom? {
        do {
            return try await roomAction(
                "get_room",
                roomID: id,
                requestTimeoutInterval: timeoutInterval,
                allowsTypedConflictRetry: allowsTypedConflictRetry
            )
        } catch let error as Base44Error where error.statusCode == 404 {
            return nil
        }
    }

    func activeRoom(preferredRoomID: String? = nil) async throws -> GameRoom? {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        let room: GameRoom? = try await request(
            "/apps/\(Self.appID)/functions/gameRoomAction",
            method: "POST",
            body: GameRoomActionPayload(
                action: "get_active_room",
                accessToken: token,
                roomID: preferredRoomID
            ),
            includeAuthorization: false
        )
        return room
    }

    func createRoom(for user: SpyUser) async throws -> GameRoom {
        let player = capablePlayer(for: user)
        return try await roomAction("create_room", player: player)
    }

    func join(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        let player = capablePlayer(for: user)
        return try await roomAction(
            "join_room",
            roomID: room.id,
            player: player,
            joinMembershipID: UUID().uuidString.lowercased(),
            expectedMembershipID: room.viewerMembershipID
        )
    }

    /// Re-joining a restored waiting room is intentionally idempotent. Besides
    /// confirming membership, it upgrades a player record created by an older
    /// client with the capabilities supported by this build before the lobby is
    /// exposed for host mutations.
    func resumeWaitingRoom(_ room: GameRoom, user: SpyUser) async throws -> GameRoom {
        guard room.normalizedStatus == "waiting" else { return room }
        return try await join(room: room, user: user)
    }

    func join(
        code: String,
        user: SpyUser,
        expectedMembershipID: String? = nil
    ) async throws -> GameRoom {
        let expectedToken = try requireAccessToken()
        let player = capablePlayer(for: user)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let joinMembershipID = UUID().uuidString.lowercased()
        var completedRetries = 0

        while true {
            try Task.checkCancellation()
            guard token == expectedToken else { throw CancellationError() }
            do {
                let room = try await roomAction(
                    "join_room",
                    roomCode: normalizedCode,
                    player: player,
                    joinMembershipID: joinMembershipID,
                    expectedMembershipID: expectedMembershipID,
                    allowsTypedConflictRetry: false
                )
                guard token == expectedToken else { throw CancellationError() }
                return room
            } catch let error as Base44Error {
                guard token == expectedToken else { throw CancellationError() }
                guard let delay = RoomJoinRetryPolicy.delayMilliseconds(
                    for: error,
                    completedRetries: completedRetries
                ) else {
                    throw error
                }
                completedRetries += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private func capablePlayer(for user: SpyUser) -> Player {
        Player(
            email: user.email,
            name: user.callSign,
            avatar: user.avatar ?? "🕵️",
            clientCapabilities: [Self.multiSpyCapability]
        )
    }

    func beginReadyCheck(room: GameRoom) async throws -> GameRoom {
        try await roomAction("begin_ready_check", roomID: room.id)
    }

    func returnToWaiting(room: GameRoom) async throws -> GameRoom {
        try await roomAction("return_to_waiting", roomID: room.id)
    }

    func voteReturnToLobby(room: GameRoom, vote: Bool) async throws -> GameRoom {
        try await roomAction(
            "vote_return_to_lobby",
            roomID: room.id,
            returnToLobbyVote: vote,
            expectedMatchID: room.matchID
        )
    }

    func kickPlayer(room: GameRoom, player: Player) async throws -> GameRoom {
        try await kickPlayer(
            room: room,
            targetUserID: player.userID,
            targetEmail: player.email,
            expectedTargetMembershipID: player.membershipID
        )
    }

    func kickPlayer(
        room: GameRoom,
        targetUserID: String?,
        targetEmail: String,
        expectedTargetMembershipID: String? = nil
    ) async throws -> GameRoom {
        let normalizedUserID = targetUserID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let normalizedEmail = targetEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTargetMembershipID = expectedTargetMembershipID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ??
            room.playersList.first(where: { candidate in
                if let normalizedUserID {
                    return candidate.userID?
                        .trimmingCharacters(in: .whitespacesAndNewlines) == normalizedUserID
                }
                return candidate.email.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(normalizedEmail) == .orderedSame
            })?.membershipID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        return try await roomAction(
            "kick_player",
            roomID: room.id,
            targetUserID: normalizedUserID,
            targetEmail: normalizedUserID == nil ? normalizedEmail : nil,
            expectedTargetMembershipID: resolvedTargetMembershipID
        )
    }

    func resetRoomForReplay(room: GameRoom) async throws -> GameRoom {
        try await roomAction(
            "reset_room_for_replay",
            roomID: room.id,
            gameMode: room.gameModeValue,
            gameDurationSeconds: room.gameDurationSeconds ?? 900
        )
    }

    func returnFinishedRoomToLobby(room: GameRoom) async throws -> GameRoom {
        do {
            return try await roomAction(
                "return_finished_room_to_lobby",
                roomID: room.id,
                gameMode: room.gameModeValue,
                gameDurationSeconds: room.gameDurationSeconds ?? 900
            )
        } catch {
            guard !RequestCancellationPolicy.isCancellation(error) else {
                throw error
            }
            if let recovered = try? await refreshRoom(id: room.id),
               FinishedRoomLobbyReturnRecoveryPolicy.accepts(
                   room: recovered,
                   expectedRoomID: room.id
               ) {
                return recovered
            }
            throw error
        }
    }

    func votePlayAgain(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        let expectedSourceMatchID = room.matchID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            return try await roomAction(
                "vote_play_again",
                roomID: room.id,
                expectedMatchID: expectedSourceMatchID.nilIfBlank
            )
        } catch {
            guard !RequestCancellationPolicy.isCancellation(error) else {
                throw error
            }
            if let recovered = try? await refreshRoom(id: room.id),
               ReplayVoteCommitRecoveryPolicy.accepts(
                   room: recovered,
                   expectedRoomID: room.id,
                   expectedSourceMatchID: expectedSourceMatchID,
                   currentUserEmail: user.email
               ) {
                return recovered
            }
            throw error
        }
    }

    func toggleReady(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        try await roomAction("toggle_ready", roomID: room.id)
    }

    func updateGameMode(room: GameRoom, mode: SpyGameMode) async throws -> GameRoom {
        try await roomAction("update_game_mode", roomID: room.id, mode: mode)
    }

    func updateGameDuration(room: GameRoom, durationSeconds: Int) async throws -> GameRoom {
        try await roomAction(
            "update_game_duration",
            roomID: room.id,
            gameDurationSeconds: durationSeconds
        )
    }

    func updateLobbyState(
        room: GameRoom,
        mutationID: String,
        expectedRevision: Int,
        state: LobbyStatePayload
    ) async throws -> GameRoom {
        try await roomAction(
            "update_lobby_state",
            roomID: room.id,
            mutationID: mutationID,
            expectedRevision: expectedRevision,
            state: state
        )
    }

    func makeGameStartPlan(
        room: GameRoom,
        wordPacks: [WordPack],
        selectedPackID: String?,
        gameMode: SpyGameMode,
        durationSeconds: Int,
        forcedAskerEmail: String? = nil
    ) throws -> GameStartPlan {
        let players = room.players ?? []
        guard players.count >= 3 else {
            throw Base44Error(message: "Need at least 3 operatives.")
        }

        let shuffledPlayers = players.shuffled()
        let mission = try Self.pickMissionWord(
            for: room,
            from: wordPacks,
            selectedPackID: selectedPackID
        )
        let asker = forcedAskerEmail.flatMap { email in
            shuffledPlayers.first { $0.email == email }
        } ?? shuffledPlayers[0]
        let askerIndex = shuffledPlayers.firstIndex { $0.email == asker.email } ?? 0
        let answererIndex = (askerIndex + 1) % shuffledPlayers.count
        let answerer = shuffledPlayers[answererIndex]
        let feedback = players.map { PlayerFeedback(email: $0.email, likes: 0, dislikes: 0) }

        return GameStartPlan(
            rouletteTargetEmail: asker.email,
            payload: StartGamePayload(
                status: "playing",
                secretWord: mission.word,
                word: mission.word,
                category: mission.category,
                roundNumber: 1,
                questionsInRound: 0,
                currentAskerEmail: asker.email,
                currentAnswererEmail: answerer.email,
                gameDurationSeconds: durationSeconds,
                questionPhase: "asking",
                currentAnswer: "",
                spyGuess: "",
                playerFeedback: feedback,
                wordPool: mission.pool,
                gameMode: gameMode.rawValue,
                cardsRead: [],
                readyPlayers: [],
                spectators: [],
                voteRequests: [],
                detectiveVotes: [],
                eliminatedEmails: [],
                winner: ""
            )
        )
    }

    func armRoulette(room: GameRoom, plan: GameStartPlan) async throws -> GameRoom {
        try await roomAction(
            "arm_roulette",
            roomID: room.id,
            plan: plan.payload,
            rouletteTargetEmail: plan.rouletteTargetEmail,
            expectedLobbyRevision: room.lobbyRevision
        )
    }

    func completeGameStart(room: GameRoom, plan: GameStartPlan) async throws -> GameRoom {
        try await completeGameStart(room: room, plan: plan.payload)
    }

    func completeGameStart(room: GameRoom) async throws -> GameRoom {
        try await completeGameStart(room: room, plan: nil)
    }

    private func completeGameStart(
        room: GameRoom,
        plan: StartGamePayload?
    ) async throws -> GameRoom {
        do {
            return try await roomAction(
                "complete_game_start",
                roomID: room.id,
                plan: plan
            )
        } catch let conflict as Base44Error
            where conflict.isRetryableRoomActionConflict {
            do {
                if let authoritativeRoom = try await refreshRoom(id: room.id),
                   Self.canAdoptCompletedGameStart(
                       authoritativeRoom,
                       expectedRoomID: room.id
                   ) {
                    return authoritativeRoom
                }
            } catch {
                if RequestCancellationPolicy.isCancellation(error) {
                    throw error
                }
            }
            throw conflict
        }
    }

    static func canAdoptCompletedGameStart(
        _ room: GameRoom,
        expectedRoomID: String
    ) -> Bool {
        room.id == expectedRoomID &&
            room.normalizedStatus == "playing" &&
            room.matchID?.nilIfBlank != nil
    }

    func startGame(room: GameRoom, wordPacks: [WordPack]) async throws -> GameRoom {
        let plan = try makeGameStartPlan(
            room: room,
            wordPacks: wordPacks,
            selectedPackID: nil,
            gameMode: room.gameModeValue,
            durationSeconds: room.gameDurationSeconds ?? 900,
            forcedAskerEmail: room.rouletteTargetEmail
        )
        let rouletteRoom = try await armRoulette(room: room, plan: plan)
        try await Task.sleep(for: .seconds(2))
        return try await completeGameStart(room: rouletteRoom, plan: plan)
    }

    func markRoleCardRead(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        try await roomAction("mark_role_card_read", roomID: room.id)
    }

    func pauseGame(room: GameRoom) async throws -> GameRoom {
        try await roomAction("pause_game", roomID: room.id)
    }

    func resumeGame(room: GameRoom) async throws -> GameRoom {
        try await roomAction("resume_game", roomID: room.id)
    }

    func advanceQuestion(room: GameRoom) async throws -> GameRoom {
        try await roomAction("advance_question", roomID: room.id)
    }

    func advanceAssociation(room: GameRoom) async throws -> GameRoom {
        try await roomAction("advance_association", roomID: room.id)
    }

    func startAssociation(room: GameRoom) async throws -> GameRoom {
        try await roomAction("start_association", roomID: room.id)
    }

    func stopAssociationSpin(room: GameRoom) async throws -> GameRoom {
        try await roomAction("stop_association_spin", roomID: room.id)
    }

    func markAnswerHeard(room: GameRoom) async throws -> GameRoom {
        try await roomAction("mark_answer_heard", roomID: room.id)
    }

    func continueRound(room: GameRoom) async throws -> GameRoom {
        try await roomAction("continue_round", roomID: room.id)
    }


    func requestVote(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        try await roomAction(
            "request_vote",
            roomID: room.id,
            expectedMatchID: room.matchID
        )
    }

    func castDetectiveVote(
        room: GameRoom,
        user: SpyUser,
        targetEmail: String,
        expectedVoteRoundID: String,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> GameRoom {
        try await roomAction(
            "cast_detective_vote",
            roomID: room.id,
            targetEmail: targetEmail,
            expectedDetectiveVoteRoundID: expectedVoteRoundID,
            requestTimeoutInterval: timeoutInterval
        )
    }

    func submitSpyGuess(room: GameRoom, user: SpyUser, guess: String) async throws -> GameRoom {
        let normalizedGuess = guess.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await roomAction(
            "submit_spy_guess",
            roomID: room.id,
            guess: normalizedGuess,
            expectedMatchID: room.matchID
        )
    }

    func finalizeExpiredRoom(room: GameRoom) async throws -> GameRoom {
        try await roomAction(
            "finalize_expired_room",
            roomID: room.id,
            expectedMatchID: room.matchID,
            expectedGameStartedAt: room.gameStartedAt
        )
    }

    func leaveRoom(room: GameRoom, user: SpyUser) async throws {
        try await leaveRoom(
            roomID: room.id,
            expectedRevision: RoomExitRevisionPolicy.expectedRevision(
                roomRevision: room.roomRevision
            ),
            expectedMembershipID: room.viewerMembershipID
        )
    }

    func leaveRoom(
        roomID: String,
        expectedRevision: Int? = nil,
        expectedMembershipID: String? = nil
    ) async throws {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }
        let _: EmptyResponse = try await request(
            "/apps/\(Self.appID)/functions/gameRoomAction",
            method: "POST",
            body: GameRoomActionPayload(
                action: "leave_room",
                accessToken: token,
                roomID: roomID,
                expectedRevision: expectedRevision,
                expectedMembershipID: expectedMembershipID
            ),
            includeAuthorization: false,
            timeoutInterval: RoomActionTransportPolicy.timeoutInterval(for: "leave_room")
        )
    }

    func closeRoom(
        roomID: String,
        expectedRevision: Int? = nil,
        expectedMembershipID: String? = nil
    ) async throws {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }
        do {
            let _: EmptyResponse = try await request(
                "/apps/\(Self.appID)/functions/gameRoomAction",
                method: "POST",
                body: GameRoomActionPayload(
                    action: "close_room",
                    accessToken: token,
                    roomID: roomID,
                    expectedRevision: expectedRevision,
                    expectedMembershipID: expectedMembershipID
                ),
                includeAuthorization: false,
                timeoutInterval: RoomActionTransportPolicy.timeoutInterval(for: "close_room")
            )
        } catch let error as Base44Error where error.statusCode == 404 {
            // A repeated local-first host exit is already complete once the
            // authoritative room no longer exists.
            return
        }
    }

    func wordPacks(ownerEmail _: String) async throws -> [WordPack] {
        let packs: [WordPack] = try await wordPackAction("list")
        return packs.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func createWordPack(name: String, category: String, words: [String], ownerEmail _: String) async throws -> WordPack {
        try await wordPackAction(
            "create",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.nilIfBlank ?? name.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words
        )
    }

    func updateWordPack(pack: WordPack, name: String, category: String, words: [String]) async throws -> WordPack {
        try await wordPackAction(
            "update",
            packID: pack.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category.nilIfBlank ?? name.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words
        )
    }

    func deleteWordPack(id: String) async throws {
        let _: EmptyResponse = try await wordPackAction("delete", packID: id)
    }

    func generateWordPack(
        theme: String,
        count: Int,
        requestID: UUID,
        excluding excludedWords: [String] = [],
        preferFresh: Bool = false
    ) async throws -> GeneratedWordPack {
        let expectedToken = try requireAccessToken()
        let expectedTokenGeneration = tokenGeneration
        let payload = GenerateWordPackPayload(
            theme: theme.trimmingCharacters(in: .whitespacesAndNewlines),
            count: count, requestID: requestID,
            excludedWords: excludedWords, preferFresh: preferFresh
        )
        let encodedPayload = try JSONEncoder.base44.encode(payload)
        var completedRetries = 0
        while true {
            try Task.checkCancellation()
            guard token == expectedToken, tokenGeneration == expectedTokenGeneration else { throw CancellationError() }
            do {
                let generated: GeneratedWordPack = try await request(
                    "/apps/\(Self.appID)/functions/generateWordPack",
                    method: "POST", encodedBody: encodedPayload
                )
                try Task.checkCancellation()
                guard token == expectedToken, tokenGeneration == expectedTokenGeneration else { throw CancellationError() }
                return generated
            } catch let error as Base44Error {
                try Task.checkCancellation()
                guard token == expectedToken, tokenGeneration == expectedTokenGeneration else { throw CancellationError() }
                guard let delay = WordGenerationRetryPolicy.delayMilliseconds(
                    for: error, completedRetries: completedRetries
                ) else { throw error }
                completedRetries += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    func gameHistory(userID: String, email: String, limit: Int? = nil) async throws -> [GameHistory] {
        let pageSize = 100
        let requestedLimit = limit.map { max(0, $0) }
        if requestedLimit == 0 { return [] }

        var history: [GameHistory] = []
        var seenIDs = Set<String>()
        var successfulQueries = 0
        var firstError: Error?

        let queries = [
            ["player_user_id": userID],
            ["player_email": email]
        ].filter { query in
            !(query.values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        for query in queries {
            var skip = 0
            do {
                while true {
                    let page: [GameHistory] = try await filterEntity(
                        "GameHistory",
                        query: query,
                        sort: "-created_date",
                        limit: pageSize,
                        skip: skip
                    )
                    history.append(contentsOf: page.filter { record in
                        seenIDs.insert(record.id).inserted && record.isOnlineHistoryMatch
                    })
                    guard page.count == pageSize else { break }
                    skip += page.count
                }
                successfulQueries += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if successfulQueries == 0, let firstError { throw firstError }
        history = GameHistoryAnalytics.deduplicatedVisibleHistory(
            history,
            currentUserID: userID
        )
        history.sort { ($0.createdDate ?? "") > ($1.createdDate ?? "") }
        return requestedLimit.map { Array(history.prefix($0)) } ?? history
    }

    func leaderboard() async throws -> [LeaderboardEntry] {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }
        let response: LeaderboardResponse = try await request(
            "/apps/\(Self.appID)/functions/gameRoomAction",
            method: "POST",
            body: GameRoomActionPayload(action: "get_leaderboard", accessToken: token),
            includeAuthorization: false
        )
        return response.entries
    }

    func updateProfile(
        displayName: String,
        avatar: String,
        language: AppLanguage,
        spyCardTheme: SpyCardThemeID,
        spyCardAccent: SpyCardAccentID,
        spyCardBadge: SpyCardBadgeID
    ) async throws -> SpyUser {
        let boundedDisplayName = try PublicDisplayNameSafety.validatedForSave(displayName)
        let fields = [
            "display_name": boundedDisplayName,
            "avatar": avatar,
            "language": language.rawValue,
            "spy_card_theme": spyCardTheme.rawValue,
            "spy_card_accent": spyCardAccent.rawValue,
            "spy_card_badge": spyCardBadge.rawValue
        ]
        do {
            return try await communityAction("update_profile", fields: fields)
        } catch let error as Base44Error where error.statusCode == 400 || error.statusCode == 404 {
            return try await request(
                "/apps/\(Self.appID)/entities/User/me",
                method: "PUT",
                body: fields
            )
        }
    }

    func updateLanguage(_ language: AppLanguage) async throws -> SpyUser {
        try await request(
            "/apps/\(Self.appID)/entities/User/me",
            method: "PUT",
            body: ["language": language.rawValue]
        )
    }

    func completeOnboarding(_ submission: OnboardingSubmission) async throws -> SpyUser {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        let updatedUser: SpyUser = try await request(
            "/apps/\(Self.appID)/entities/User/me",
            method: "PUT",
            body: OnboardingCompletionPayload(submission: submission)
        )
        guard updatedUser.onboardingCompleted == true,
              (updatedUser.onboardingVersion ?? 1) >= submission.version else {
            throw Base44Error(
                message: "Onboarding completion was not confirmed.",
                statusCode: 502,
                retryable: true
            )
        }
        return updatedUser
    }

    func deleteAccount() async throws -> AccountDeletionResult {
        let result: AccountDeletionResult = try await invokeFunction(
            "deleteAccount",
            body: EmptyPayload()
        )
        guard result.success else {
            throw Base44Error(message: "Account deletion was not confirmed.")
        }
        return result
    }

    func communityState() async throws -> CommunityState {
        try await communityAction("state", retriesTransientReadFailures: true)
    }

    func updateRadarInvitePolicy(_ policy: RadarInvitePolicy) async throws -> RadarInvitePolicy {
        let response: RadarInvitePolicySyncResponse = try await communityAction(
            "set_radar_invite_policy",
            fields: ["radar_invite_policy": policy.rawValue]
        )
        guard let confirmed = RadarInvitePolicy(rawValue: response.radarInvitePolicy) else {
            throw Base44Error(message: "Invalid Radar invite policy response.", statusCode: 502)
        }
        guard confirmed == policy else {
            throw Base44Error(message: "Radar invite policy was not confirmed.", statusCode: 502)
        }
        return confirmed
    }

    func communityDirectory(query: String = "", offset: Int = 0, limit: Int = 24) async throws -> CommunityDirectoryPage {
        try await communityAction(
            "directory",
            fields: [
                "query": query,
                "offset": String(offset),
                "limit": String(limit)
            ],
            retriesTransientReadFailures: true
        )
    }

    func communityProfile(userID: String) async throws -> CommunityProfileDetail {
        try await communityAction(
            "profile",
            fields: ["target_user_id": userID],
            retriesTransientReadFailures: true
        )
    }

    func searchCommunity(spyID: String) async throws -> CommunitySearchResult {
        try await communityAction(
            "search",
            fields: ["spy_id": spyID],
            retriesTransientReadFailures: true
        )
    }

    func sendFriendRequest(spyID: String) async throws -> CommunityState {
        try await communityAction("send_request", fields: ["spy_id": spyID])
    }

    func sendFriendRequest(userID: String) async throws -> CommunityState {
        try await communityAction("send_request", fields: ["target_user_id": userID])
    }

    func communityRelationshipAction(_ action: String, friendshipID: String) async throws -> CommunityState {
        try await communityAction(
            action,
            fields: ["friendship_id": friendshipID],
            retriesIdempotentMutationFailures: true
        )
    }

    func blockCommunityUser(userID: String) async throws -> CommunityState {
        try await communityAction("block", fields: ["target_user_id": userID])
    }

    func unblockCommunityUser(friendshipID: String) async throws -> CommunityState {
        try await communityAction("unblock", fields: ["friendship_id": friendshipID])
    }

    func reportCommunityUser(
        userID: String,
        reason: CommunityReportReason
    ) async throws -> CommunityActionAcknowledgement {
        try await communityAction(
            "report",
            fields: [
                "target_user_id": userID,
                "report_type": "user",
                "reason": reason.rawValue
            ]
        )
    }

    func reportCommunityComment(
        commentID: String,
        reason: CommunityReportReason
    ) async throws -> CommunityActionAcknowledgement {
        try await communityAction(
            "report",
            fields: [
                "comment_id": commentID,
                "report_type": "comment",
                "reason": reason.rawValue
            ]
        )
    }

    func addCommunityComment(userID: String, comment: String) async throws -> CommunityProfileDetail {
        try await communityAction(
            "add_comment",
            fields: [
                "target_user_id": userID,
                "comment": comment
            ]
        )
    }

    func deleteCommunityComment(commentID: String) async throws -> CommunityProfileDetail {
        try await communityAction("delete_comment", fields: ["comment_id": commentID])
    }

    func inviteCommunityOperative(userID: String, room: GameRoom) async throws -> CommunityActionAcknowledgement {
        try await communityAction(
            "invite_to_room",
            fields: [
                "target_user_id": userID,
                "room_id": room.id,
                "room_code": room.code
            ]
        )
    }

    func communityRoomInviteAction(_ action: String, inviteID: String) async throws -> CommunityInviteActionResult {
        try await communityAction(
            action,
            fields: ["invite_id": inviteID],
            retriesIdempotentMutationFailures: true
        )
    }

    func notificationInboxSummary() async throws -> NotificationInboxSummary {
        try await notificationInboxAction(
            NotificationInboxActionPayload(
                action: "summary",
                accessToken: try requireAccessToken()
            ),
            retriesTransientReadFailures: true
        )
    }

    func notificationInboxList(
        scope: NotificationInboxScope,
        cursor: String? = nil,
        limit: Int = 30
    ) async throws -> NotificationInboxPage {
        try await notificationInboxAction(
            NotificationInboxActionPayload(
                action: "list",
                accessToken: try requireAccessToken(),
                scope: scope.rawValue,
                cursor: cursor?.nilIfBlank,
                limit: min(max(limit, 1), 50)
            ),
            retriesTransientReadFailures: true
        )
    }

    func notificationInboxMarkRead(itemID: String) async throws -> NotificationInboxMutationResponse {
        let itemID = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else {
            throw Base44Error(message: "Notification identifier is required.", statusCode: 422)
        }

        return try await notificationInboxAction(
            NotificationInboxActionPayload(
                action: "mark_read",
                accessToken: try requireAccessToken(),
                itemID: itemID
            ),
            retriesIdempotentMutationFailures: true
        )
    }

    func notificationInboxMarkAllRead(
        scope: NotificationInboxScope
    ) async throws -> NotificationInboxMutationResponse {
        try await notificationInboxAction(
            NotificationInboxActionPayload(
                action: "mark_all_read",
                accessToken: try requireAccessToken(),
                scope: scope.rawValue
            ),
            retriesIdempotentMutationFailures: true
        )
    }

    func notificationInboxPublishGlobal(
        draft: NotificationGlobalDraft
    ) async throws -> NotificationGlobalPublishResponse {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else {
            throw Base44Error(message: "Notification title and body are required.", statusCode: 422)
        }
        guard title.count <= 80, body.count <= 800 else {
            throw Base44Error(message: "Notification content is too long.", statusCode: 422)
        }

        return try await notificationInboxAction(
            NotificationInboxActionPayload(
                action: "publish_global",
                accessToken: try requireAccessToken(),
                requestID: draft.requestID.uuidString.lowercased(),
                title: title,
                body: body,
                importance: draft.importance.rawValue,
                actionDeepLink: draft.actionDeepLink?.nilIfBlank
            )
        )
    }

    private func notificationInboxAction<T: Decodable>(
        _ payload: NotificationInboxActionPayload,
        retriesTransientReadFailures: Bool = false,
        retriesIdempotentMutationFailures: Bool = false
    ) async throws -> T {
        let expectedToken = payload.accessToken
        guard token == expectedToken else {
            throw CancellationError()
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard token == expectedToken else {
                throw CancellationError()
            }

            do {
                let response: T = try await request(
                    "/apps/\(Self.appID)/functions/notificationAction",
                    method: "POST",
                    body: payload,
                    includeAuthorization: false
                )
                guard token == expectedToken else {
                    throw CancellationError()
                }
                return response
            } catch let error as Base44Error {
                let delay: Int? = if retriesIdempotentMutationFailures {
                    NotificationMutationRetryPolicy.delayMilliseconds(
                        action: payload.action,
                        error: error,
                        completedRetries: attempt
                    )
                } else if retriesTransientReadFailures {
                    SupplementaryReadRetryPolicy.delayMilliseconds(
                        for: error,
                        completedRetries: attempt
                    )
                } else {
                    nil
                }
                guard let delay else {
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private func communityAction<T: Decodable>(
        _ action: String,
        fields: [String: String] = [:],
        retriesTransientReadFailures: Bool = false,
        retriesIdempotentMutationFailures: Bool = false
    ) async throws -> T {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        var payload = [
            "action": action,
            "access_token": token
        ]
        payload.merge(fields) { _, newValue in newValue }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard self.token == token else { throw CancellationError() }
            do {
                let response: T = try await request(
                    "/apps/\(Self.appID)/functions/communityAction",
                    method: "POST",
                    body: payload,
                    includeAuthorization: false
                )
                guard self.token == token else { throw CancellationError() }
                return response
            } catch let error as Base44Error {
                let delay: Int? = if retriesIdempotentMutationFailures {
                    CommunityMutationRetryPolicy.delayMilliseconds(
                        action: action,
                        error: error,
                        completedRetries: attempt
                    )
                } else if retriesTransientReadFailures {
                    SupplementaryReadRetryPolicy.delayMilliseconds(
                        for: error,
                        completedRetries: attempt
                    )
                } else {
                    nil
                }
                guard let delay else {
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    func googleLoginURL(callbackURL _: URL) -> URL {
        let mobileCallbackURL = Self.appBaseURL
            .appending(path: "/api/apps/\(Self.appID)/functions/mobileAuthCallback")
        var callbackComponents = URLComponents(
            url: mobileCallbackURL,
            resolvingAgainstBaseURL: false
        )!
        callbackComponents.queryItems = [
            URLQueryItem(name: "auth_provider", value: "google")
        ]

        var components = URLComponents(
            url: Self.appBaseURL.appending(path: "/api/apps/\(Self.appID)/auth/sso/login"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: Self.appID),
            URLQueryItem(name: "from_url", value: callbackComponents.url!.absoluteString)
        ]
        return components.url!
    }

    private func appleNativeBootstrap(for credential: AppleSignInCredential) async throws -> AppleAuthBootstrapResponse {
        var components = URLComponents(
            url: Self.appBaseURL.appending(path: "/functions/appleAuthBroker"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "action", value: "native-exchange")]

        guard let url = components.url else {
            throw Base44Error(message: "Invalid Apple authentication URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.appBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder.base44.encode(credential)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.displayableTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Base44Error(message: "Invalid Apple authentication response.")
        }

        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder.base44.decode(APIErrorEnvelope.self, from: data)
            throw Base44Error(
                message: apiError?.resolvedMessage ?? "Apple authentication failed.",
                statusCode: http.statusCode
            )
        }

        guard let bootstrap = try? JSONDecoder.base44.decode(AppleAuthBootstrapResponse.self, from: data) else {
            throw Base44Error(message: "The server returned an unreadable response.")
        }
        guard let bootstrapURL = URL(string: bootstrap.bootstrapURL),
              bootstrapURL.scheme?.lowercased() == "https",
              bootstrapURL.host?.lowercased() == Self.appBaseURL.host?.lowercased(),
              !bootstrap.bindingTicket.isEmpty,
              bootstrap.bindingTicket.count <= 512 else {
            throw Base44Error(message: "Apple authentication returned an invalid handoff URL.")
        }

        return bootstrap
    }

    func appleNativeAccessToken(
        for credential: AppleSignInCredential,
        onPhaseChange: (AppleNativeAuthPhase) -> Void = { _ in }
    ) async throws -> AppleNativeSession {
        onPhaseChange(.verifyingIdentity)
        let bootstrap = try await appleNativeBootstrap(for: credential)
        guard let bootstrapURL = URL(string: bootstrap.bootstrapURL) else {
            throw Base44Error(message: "Apple authentication returned an invalid handoff URL.")
        }
        onPhaseChange(.establishingSession)
        return AppleNativeSession(
            accessToken: try await resolveSilentAppleHandoff(from: bootstrapURL),
            bindingTicket: bootstrap.bindingTicket
        )
    }

    private func resolveSilentAppleHandoff(from bootstrapURL: URL) async throws -> String {
        let redirectDelegate = SilentAppleHandoffRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45

        let handoffSession = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { handoffSession.finishTasksAndInvalidate() }

        var request = URLRequest(url: bootstrapURL)
        request.httpMethod = "GET"
        request.setValue("application/json,text/html", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await handoffSession.data(for: request)
        } catch {
            throw Self.displayableTransportError(error)
        }
        if let redirectError = redirectDelegate.capturedError() {
            throw redirectError
        }

        let callbackURL = redirectDelegate.capturedCallbackURL()
            ?? Self.callbackURL(from: response)

        guard let callbackURL,
              callbackURL.scheme?.lowercased() == "spyclash",
              callbackURL.host?.lowercased() == "auth" else {
            let http = response as? HTTPURLResponse
            let apiError = try? JSONDecoder.base44.decode(APIErrorEnvelope.self, from: data)
            throw Base44Error(
                message: apiError?.resolvedMessage ?? "Apple authentication handoff did not return to SpyClash.",
                statusCode: http?.statusCode
            )
        }

        let queryItems = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        if let providerError = queryItems.first(where: { $0.name == "error" })?.value,
           !providerError.isEmpty {
            throw Base44Error(message: "Apple authentication failed: \(providerError).")
        }

        guard let accessToken = queryItems.first(where: { $0.name == "access_token" })?.value,
              !accessToken.isEmpty,
              accessToken.count <= 20_000 else {
            throw Base44Error(message: "Apple authentication did not return a valid access token.")
        }

        return accessToken
    }

    private static func callbackURL(from response: URLResponse) -> URL? {
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location") else {
            return nil
        }
        return URL(string: location)
    }

    private func listEntity<T: Decodable>(_ entity: String) async throws -> [T] {
        try await request("/apps/\(Self.appID)/entities/\(entity)", method: "GET")
    }

    private func filterEntity<T: Decodable>(
        _ entity: String,
        query: [String: String],
        sort: String? = nil,
        limit: Int? = nil,
        skip: Int? = nil
    ) async throws -> [T] {
        let data = try JSONSerialization.data(withJSONObject: query)
        let q = String(data: data, encoding: .utf8) ?? "{}"
        var parameters = ["q": q]
        if let sort { parameters["sort"] = sort }
        if let limit { parameters["limit"] = String(limit) }
        if let skip { parameters["skip"] = String(skip) }
        return try await request(
            "/apps/\(Self.appID)/entities/\(entity)",
            method: "GET",
            query: parameters
        )
    }

    private func createEntity<T: Decodable, Body: Encodable>(_ entity: String, body: Body) async throws -> T {
        try await request("/apps/\(Self.appID)/entities/\(entity)", method: "POST", body: body)
    }

    private func updateEntity<T: Decodable, Body: Encodable>(_ entity: String, id: String, body: Body) async throws -> T {
        try await request("/apps/\(Self.appID)/entities/\(entity)/\(id)", method: "PUT", body: body)
    }

    private func deleteEntity(_ entity: String, id: String) async throws {
        let _: EmptyResponse = try await request("/apps/\(Self.appID)/entities/\(entity)/\(id)", method: "DELETE")
    }

    private func invokeFunction<T: Decodable, Body: Encodable>(_ name: String, body: Body) async throws -> T {
        try await request("/apps/\(Self.appID)/functions/\(name)", method: "POST", body: body)
    }

    func checkSubscription() async throws -> MembershipSnapshot {
        try await membershipAction("checkSubscription", body: [:])
    }

    func prepareAppStorePurchase() async throws -> AppStorePurchaseContext {
        try await membershipAction("app-store-entitlement", body: ["action": "prepare"])
    }

    func syncAppStoreTransaction(signedTransaction: String) async throws -> AppStoreEntitlementSyncResponse {
        try await membershipAction("app-store-entitlement", body: [
            "action": "sync_transaction", "signed_transaction": signedTransaction,
        ])
    }

    private func membershipAction<T: Decodable>(_ name: String, body: [String: String]) async throws -> T {
        let expectedToken = try requireAccessToken()
        var payload = body
        payload["access_token"] = expectedToken
        let result: T = try await invokeFunction(name, body: payload)
        guard currentAccessToken == expectedToken else { throw CancellationError() }
        return result
    }

    private func pushNotificationAction<T: Decodable>(
        _ payload: PushNotificationActionPayload
    ) async throws -> T {
        let path = "/apps/\(Self.appID)/functions/pushNotificationAction"
        let expectedToken = payload.accessToken
        let enforceCurrentAccount = payload.action != "unregister_device"
        if enforceCurrentAccount, token != expectedToken {
            throw CancellationError()
        }

        let url = Self.appBaseURL.appending(path: "/api\(path)")
        var actionRequest = URLRequest(url: url)
        actionRequest.httpMethod = "POST"
        actionRequest.timeoutInterval = 30
        actionRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        actionRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        actionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        actionRequest.setValue(Self.appBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        actionRequest.setValue(Self.appID, forHTTPHeaderField: "X-App-Id")
        actionRequest.httpBody = try JSONEncoder.base44.encode(payload)

        let retryPolicy = PushNotificationTransportRetryPolicy.policy(
            for: payload.action
        )
        var attempt = 1
        while true {
            try Task.checkCancellation()
            if enforceCurrentAccount, token != expectedToken {
                throw CancellationError()
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                let result = try await session.data(for: actionRequest)
                guard let http = result.1 as? HTTPURLResponse else {
                    throw Base44Error(message: "Invalid API response.")
                }
                data = result.0
                response = http
            } catch {
                guard attempt < retryPolicy.maximumAttempts,
                      Self.isRetryablePushTransportError(error) else {
                    throw Self.displayableTransportError(error)
                }
                try await Self.waitBeforePushRetry(attempt: attempt)
                attempt += 1
                continue
            }

            let apiError = 200..<300 ~= response.statusCode
                ? nil
                : try? JSONDecoder.base44.decode(APIErrorEnvelope.self, from: data)
            if attempt < retryPolicy.maximumAttempts,
               Self.isRetryablePushHTTPStatus(
                   response.statusCode,
                   retryPolicy: retryPolicy,
                   apiError: apiError
               ) {
                try await Self.waitBeforePushRetry(
                    attempt: attempt,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                )
                attempt += 1
                continue
            }

            if enforceCurrentAccount, token != expectedToken {
                throw CancellationError()
            }

            guard 200..<300 ~= response.statusCode else {
                throw Base44Error(
                    message: apiError?.resolvedMessage ?? "Base44 request failed.",
                    statusCode: response.statusCode,
                    code: apiError?.code,
                    retryable: apiError?.retryable ?? false
                )
            }

            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            guard !data.isEmpty else {
                if attempt < retryPolicy.maximumAttempts {
                    try await Self.waitBeforePushRetry(attempt: attempt)
                    attempt += 1
                    continue
                }
                throw Base44Error(message: "Empty API response.")
            }

            do {
                return try JSONDecoder.base44.decode(T.self, from: data)
            } catch {
                if attempt < retryPolicy.maximumAttempts {
                    try await Self.waitBeforePushRetry(attempt: attempt)
                    attempt += 1
                    continue
                }
                throw Base44Error(message: "The server returned an unreadable response.")
            }
        }
    }

    private static func isRetryablePushHTTPStatus(
        _ statusCode: Int,
        retryPolicy: PushNotificationTransportRetryPolicy,
        apiError: APIErrorEnvelope?
    ) -> Bool {
        if statusCode == 409 {
            guard retryPolicy.retriesTypedLeaseConflict,
                  apiError?.retryable != false else {
                return false
            }
            let code = apiError?.code?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
            if let code, !code.isEmpty {
                return [
                    "active_lease",
                    "cas_contention",
                    "device_owner_changed"
                ].contains(code)
            }
            return apiError?.resolvedMessage ==
                "Push registration is temporarily unavailable."
        }
        return statusCode == 408 || statusCode == 425 || statusCode == 429 ||
            (500...599).contains(statusCode)
    }

    private static func isRetryablePushTransportError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .secureConnectionFailed
        ].contains(urlError.code)
    }

    private static func waitBeforePushRetry(
        attempt: Int,
        retryAfter: String? = nil
    ) async throws {
        let serverDelay = retryAfter
            .flatMap(Double.init)
            .map { min(max($0, 0), 5) }
        let exponentialDelay = min(0.35 * pow(2, Double(attempt - 1)), 2)
        let delay = serverDelay ?? exponentialDelay
        try await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
    }

    private func requireAccessToken(_ override: String? = nil) throws -> String {
        if let override, !override.isEmpty {
            return override
        }
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }
        return token
    }

    private func roomAction(
        _ action: String,
        roomID: String? = nil,
        roomCode: String? = nil,
        player: Player? = nil,
        mode: SpyGameMode? = nil,
        gameMode: SpyGameMode? = nil,
        gameDurationSeconds: Int? = nil,
        plan: StartGamePayload? = nil,
        rouletteTargetEmail: String? = nil,
        targetUserID: String? = nil,
        targetEmail: String? = nil,
        expectedTargetMembershipID: String? = nil,
        returnToLobbyVote: Bool? = nil,
        guess: String? = nil,
        winner: String? = nil,
        expectedDetectiveVoteRoundID: String? = nil,
        joinMembershipID: String? = nil,
        mutationID: String? = nil,
        expectedRevision: Int? = nil,
        expectedMembershipID: String? = nil,
        state: LobbyStatePayload? = nil,
        expectedLobbyRevision: Int? = nil,
        expectedMatchID: String? = nil,
        expectedGameStartedAt: String? = nil,
        requestTimeoutInterval: TimeInterval? = nil,
        allowsTypedConflictRetry: Bool = true
    ) async throws -> GameRoom {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        let payload = GameRoomActionPayload(
            action: action,
            accessToken: token,
            clientCapabilities: [Self.multiSpyCapability],
            roomID: roomID,
            roomCode: roomCode,
            player: player,
            mode: mode?.rawValue,
            gameMode: gameMode?.rawValue,
            gameDurationSeconds: gameDurationSeconds,
            plan: plan,
            rouletteTargetEmail: rouletteTargetEmail,
            targetUserID: targetUserID,
            targetEmail: targetEmail,
            expectedTargetMembershipID: expectedTargetMembershipID,
            returnToLobbyVote: returnToLobbyVote,
            guess: guess,
            winner: winner,
            expectedDetectiveVoteRoundID: expectedDetectiveVoteRoundID,
            joinMembershipID: joinMembershipID,
            mutationID: mutationID,
            expectedRevision: expectedRevision,
            expectedMembershipID: expectedMembershipID,
            state: state,
            expectedLobbyRevision: expectedLobbyRevision,
            expectedMatchID: expectedMatchID,
            expectedGameStartedAt: expectedGameStartedAt
        )
        // Expired-room finalization owns an authoritative read/backoff loop in
        // GameView. Latency-sensitive vote/guess calls also keep their deadline
        // at the coordinator boundary instead of silently doubling it here.
        let callerOwnsConflictRetry = !allowsTypedConflictRetry ||
            [
                "finalize_expired_room",
                "request_vote",
                "cast_detective_vote",
                "kick_player",
                "submit_spy_guess"
            ].contains(action)
        let retryDelays = callerOwnsConflictRetry ? [] : [250]
        var attempt = 0

        while true {
            try Task.checkCancellation()
            guard self.token == token else { throw CancellationError() }
            do {
                // Provider/SSO tokens are valid Base44 identity tokens, but the
                // functions gateway can reject them before the function runs.
                let room: GameRoom = try await request(
                    "/apps/\(Self.appID)/functions/gameRoomAction",
                    method: "POST",
                    body: payload,
                    includeAuthorization: false,
                    timeoutInterval: requestTimeoutInterval
                        ?? RoomActionTransportPolicy.timeoutInterval(for: action)
                )
                guard self.token == token else { throw CancellationError() }
                return room
            } catch let error as Base44Error
                where error.isRetryableRoomActionConflict && attempt < retryDelays.count {
                let delay = retryDelays[attempt]
                attempt += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private func wordPackAction<T: Decodable>(
        _ action: String,
        packID: String? = nil,
        name: String? = nil,
        category: String? = nil,
        words: [String]? = nil
    ) async throws -> T {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        let payload = WordPackActionPayload(
            action: action,
            accessToken: token,
            packID: packID,
            name: name,
            category: category,
            words: words
        )
        var completedRetries = 0

        while true {
            try Task.checkCancellation()
            guard self.token == token else { throw CancellationError() }
            do {
                let response: T = try await request(
                    "/apps/\(Self.appID)/functions/wordPackAction",
                    method: "POST",
                    body: payload,
                    includeAuthorization: false
                )
                guard self.token == token else { throw CancellationError() }
                return response
            } catch let error as Base44Error {
                guard let delay = WordPackMutationRetryPolicy.delayMilliseconds(
                    action: action,
                    error: error,
                    completedRetries: completedRetries
                ) else {
                    throw error
                }
                completedRetries += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private static func pickMissionWord(
        for room: GameRoom,
        from packs: [WordPack],
        selectedPackID: String?
    ) throws -> (word: String, category: String, pool: [WordPoolEntry]) {
        if (room.lobbyRevision ?? 0) > 0 {
            let enabledWords = (room.lobbyWordPool ?? [])
                .filter(\.enabled)
                .map(\.word)
                .cleanMissionWords
            let requestedCount = max(min(room.lobbyWordCount ?? 0, 200), 0)
            let words = Array(enabledWords.prefix(requestedCount))
            guard words.count >= 2 else {
                throw Base44Error(
                    message: "Select at least two enabled lobby words before starting.",
                    statusCode: 409
                )
            }
            let category = room.lobbyCategory?.nilIfBlank
                ?? room.lobbySourceName?.nilIfBlank
                ?? "CLASSIC"
            let pool = words.map { WordPoolEntry(word: $0, enabled: true) }
            return (
                word: words.randomElement() ?? words[0],
                category: category,
                pool: pool
            )
        }

        if let selectedPackID,
           let pack = packs.first(where: { $0.id == selectedPackID }),
           let words = pack.words?.cleanMissionWords,
           words.count >= 2 {
            let category = pack.category?.nilIfBlank ?? pack.name
            let pool = words.map { WordPoolEntry(word: $0, enabled: true) }
            return (
                word: words.randomElement() ?? words[0],
                category: category,
                pool: pool
            )
        }

        let pool = fallbackMissionWords.map { WordPoolEntry(word: $0.word, enabled: true) }
        let mission = fallbackMissionWords.randomElement() ?? (word: "Embassy", category: "CLASSIC")
        return (word: mission.word, category: mission.category, pool: pool)
    }

    private static func parseAssociationState(_ raw: String?) -> AssociationState {
        guard let data = raw?.data(using: .utf8),
              let state = try? JSONDecoder.base44.decode(AssociationState.self, from: data) else {
            return AssociationState(spoken: [], spinning: false)
        }
        return state
    }

    private static func encodeAssociationState(_ state: AssociationState) -> String {
        guard let data = try? JSONEncoder.base44.encode(state),
              let encoded = String(data: data, encoding: .utf8) else {
            return #"{"spoken":[],"spinning":false}"#
        }
        return encoded
    }

    private func request<T: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        query: [String: String] = [:],
        body: Body? = Optional<EmptyPayload>.none,
        encodedBody: Data? = nil,
        includeAuthorization: Bool = true,
        authorizationToken: String? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        var components = URLComponents(url: Self.appBaseURL.appending(path: "/api\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map(URLQueryItem.init)
        }

        guard let url = components.url else {
            throw Base44Error(message: "Invalid API URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeoutInterval, timeoutInterval > 0 {
            request.timeoutInterval = timeoutInterval
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.appBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.appID, forHTTPHeaderField: "X-App-Id")
        if includeAuthorization, let token = authorizationToken ?? token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let encodedBody {
            request.httpBody = encodedBody
        } else if let body {
            request.httpBody = try JSONEncoder.base44.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.displayableTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Base44Error(message: "Invalid API response.")
        }

        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder.base44.decode(APIErrorEnvelope.self, from: data)
            let retryAfterSeconds = apiError?.retryAfterSeconds
                ?? http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw Base44Error(
                message: apiError?.resolvedMessage ?? "Base44 request failed.",
                statusCode: http.statusCode,
                code: apiError?.code,
                retryable: apiError?.retryable ?? false,
                retryAfterSeconds: retryAfterSeconds,
                retryPhase: apiError?.retryPhase,
                effectsStarted: apiError?.effectsStarted
            )
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        if data.isEmpty {
            throw Base44Error(message: "Empty API response.", statusCode: http.statusCode)
        }

        guard let decoded = try? JSONDecoder.base44.decode(T.self, from: data) else {
            throw Base44Error(message: "The server returned an unreadable response.")
        }
        return decoded
    }

    private static func displayableTransportError(_ error: Error) -> Error {
        if error is Base44Error {
            return error
        }
        if RequestCancellationPolicy.isCancellation(error) {
            return CancellationError()
        }
        return Base44Error(message: "Network request failed.", retryable: true)
    }
}

private final class SilentAppleHandoffRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let allowedHTTPSHosts: Set<String> = [
        "spyclash.com",
        "app.base44.com"
    ]
    private static let maximumRedirects = 12

    private let lock = NSLock()
    private var callbackURL: URL?
    private var redirectError: Base44Error?
    private var redirectCount = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            record(error: Base44Error(message: "Apple authentication returned an invalid redirect."))
            completionHandler(nil)
            return
        }

        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        if scheme == "spyclash" {
            guard host == "auth" else {
                record(error: Base44Error(message: "Apple authentication returned an invalid app callback."))
                completionHandler(nil)
                return
            }
            record(callbackURL: url)
            completionHandler(nil)
            return
        }

        guard scheme == "https",
              let host,
              Self.allowedHTTPSHosts.contains(host) else {
            record(error: Base44Error(message: "Apple authentication attempted an untrusted redirect."))
            completionHandler(nil)
            return
        }

        lock.lock()
        redirectCount += 1
        let exceedsLimit = redirectCount > Self.maximumRedirects
        lock.unlock()

        guard !exceedsLimit else {
            record(error: Base44Error(message: "Apple authentication exceeded the redirect limit."))
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    func capturedCallbackURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return callbackURL
    }

    func capturedError() -> Base44Error? {
        lock.lock()
        defer { lock.unlock() }
        return redirectError
    }

    private func record(callbackURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.callbackURL = callbackURL
    }

    private func record(error: Base44Error) {
        lock.lock()
        defer { lock.unlock() }
        if redirectError == nil {
            redirectError = error
        }
    }
}

private let fallbackMissionWords = [
    (word: "Embassy", category: "CLASSIC"),
    (word: "Submarine", category: "CLASSIC"),
    (word: "Casino", category: "CLASSIC"),
    (word: "Airport", category: "CLASSIC"),
    (word: "Museum", category: "CLASSIC"),
    (word: "Space Station", category: "CLASSIC"),
    (word: "Royal Palace", category: "CLASSIC"),
    (word: "Train Station", category: "CLASSIC"),
    (word: "Hospital", category: "CLASSIC"),
    (word: "Movie Set", category: "CLASSIC"),
    (word: "University", category: "CLASSIC"),
    (word: "Research Lab", category: "BLACK OPS"),
    (word: "Cruise Ship", category: "TRAVEL"),
    (word: "Bank Vault", category: "BLACK OPS"),
    (word: "Military Base", category: "BLACK OPS"),
    (word: "Opera House", category: "CLASSIC"),
    (word: "Desert Camp", category: "TRAVEL"),
    (word: "Arctic Station", category: "BLACK OPS")
]

struct EmptyPayload: Encodable {}

private struct NotificationInboxActionPayload: Encodable {
    let action: String
    let accessToken: String
    let scope: String?
    let cursor: String?
    let limit: Int?
    let itemID: String?
    let requestID: String?
    let title: String?
    let body: String?
    let importance: String?
    let actionDeepLink: String?

    init(
        action: String,
        accessToken: String,
        scope: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil,
        itemID: String? = nil,
        requestID: String? = nil,
        title: String? = nil,
        body: String? = nil,
        importance: String? = nil,
        actionDeepLink: String? = nil
    ) {
        self.action = action
        self.accessToken = accessToken
        self.scope = scope
        self.cursor = cursor
        self.limit = limit
        self.itemID = itemID
        self.requestID = requestID
        self.title = title
        self.body = body
        self.importance = importance
        self.actionDeepLink = actionDeepLink
    }

    enum CodingKeys: String, CodingKey {
        case action
        case accessToken = "access_token"
        case scope
        case cursor
        case limit
        case itemID = "item_id"
        case requestID = "request_id"
        case title
        case body
        case importance
        case actionDeepLink = "action_deep_link"
    }
}

enum PushEnvironment: String, Encodable, Sendable {
    case sandbox
    case production

    static var current: Self {
#if DEBUG
        .sandbox
#else
        .production
#endif
    }
}

enum LiveActivityPushTokenKind: String, Encodable, Sendable {
    case pushToStart = "push_to_start"
    case activity
}

struct PushRegistrationResponse: Decodable, Sendable {
    let ok: Bool
    let registrationID: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case ok
        case registrationID = "registration_id"
        case updatedAt = "updated_at"
    }
}

private struct PushNotificationPreferences: Encodable {
    let friendRequests = true
    let roomInvites = true
    let gameUpdates = true
    let announcements = true

    enum CodingKeys: String, CodingKey {
        case friendRequests = "friend_requests"
        case roomInvites = "room_invites"
        case gameUpdates = "game_updates"
        case announcements
    }
}

private struct PushNotificationActionPayload: Encodable {
    let action: String
    let accessToken: String
    let installationID: String
    let apnsToken: String?
    let environment: String?
    let bundleID: String?
    let locale: String?
    let appVersion: String?
    let alertAuthorized: Bool?
    let preferences: PushNotificationPreferences?
    let tokenKind: String?
    let liveActivityToken: String?
    let activityID: String?
    let roomID: String?
    let matchID: String?

    init(
        action: String,
        accessToken: String,
        installationID: String,
        apnsToken: String? = nil,
        environment: String? = nil,
        bundleID: String? = nil,
        locale: String? = nil,
        appVersion: String? = nil,
        alertAuthorized: Bool? = nil,
        preferences: PushNotificationPreferences? = nil,
        tokenKind: String? = nil,
        liveActivityToken: String? = nil,
        activityID: String? = nil,
        roomID: String? = nil,
        matchID: String? = nil
    ) {
        self.action = action
        self.accessToken = accessToken
        self.installationID = installationID
        self.apnsToken = apnsToken
        self.environment = environment
        self.bundleID = bundleID
        self.locale = locale
        self.appVersion = appVersion
        self.alertAuthorized = alertAuthorized
        self.preferences = preferences
        self.tokenKind = tokenKind
        self.liveActivityToken = liveActivityToken
        self.activityID = activityID
        self.roomID = roomID
        self.matchID = matchID
    }

    enum CodingKeys: String, CodingKey {
        case action
        case accessToken = "access_token"
        case installationID = "installation_id"
        case apnsToken = "apns_token"
        case environment
        case bundleID = "bundle_id"
        case locale
        case appVersion = "app_version"
        case alertAuthorized = "alert_authorized"
        case preferences
        case tokenKind = "token_kind"
        case liveActivityToken = "live_activity_token"
        case activityID = "activity_id"
        case roomID = "room_id"
        case matchID = "match_id"
    }
}

private struct APIErrorEnvelope: Decodable {
    let message: String?
    let error: String?
    let errorDescription: String?
    let code: String?
    let retryable: Bool?
    let retryAfterSeconds: Int?
    let retryPhase: String?
    let effectsStarted: Bool?

    enum CodingKeys: String, CodingKey {
        case message
        case error
        case errorDescription = "error_description"
        case code
        case retryable
        case retryAfterSeconds = "retry_after_seconds"
        case retryPhase = "retry_phase"
        case effectsStarted = "effects_started"
    }

    var resolvedMessage: String? { message ?? errorDescription ?? error }
}

private struct AppleAuthBootstrapResponse: Decodable {
    let bootstrapURL: String
    let bindingTicket: String

    enum CodingKeys: String, CodingKey {
        case bootstrapURL = "bootstrap_url"
        case bindingTicket = "binding_ticket"
    }
}

struct AppleNativeSession {
    let accessToken: String
    let bindingTicket: String
}

struct AccountDeletionResult: Decodable {
    let success: Bool
    let manualAppleRevocationRequired: Bool

    enum CodingKeys: String, CodingKey {
        case success
        case manualAppleRevocationRequired = "manual_apple_revocation_required"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        manualAppleRevocationRequired = try container.decodeIfPresent(
            Bool.self,
            forKey: .manualAppleRevocationRequired
        ) ?? false
    }
}

private struct AutoRegisterUserResponse: Decodable {
    let user: SpyUser?
}

private struct OnboardingCompletionPayload: Encodable {
    let language: String
    let onboardingCompleted: Bool
    let onboardingVersion: Int
    let onboardingCompletedAt: Date
    let acquisitionSource: String

    init(submission: OnboardingSubmission) {
        language = submission.language.rawValue
        onboardingCompleted = true
        onboardingVersion = submission.version
        onboardingCompletedAt = submission.completedAt
        acquisitionSource = submission.acquisitionSource.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case language
        case onboardingCompleted = "onboarding_completed"
        case onboardingVersion = "onboarding_version"
        case onboardingCompletedAt = "onboarding_completed_at"
        case acquisitionSource = "acquisition_source"
    }
}

struct Base44Error: LocalizedError {
    let message: String
    var statusCode: Int?
    var code: String?
    var retryable = false
    var retryAfterSeconds: Int?
    var retryPhase: String?
    var effectsStarted: Bool?

    init(
        message: String,
        statusCode: Int? = nil,
        code: String? = nil,
        retryable: Bool = false,
        retryAfterSeconds: Int? = nil,
        retryPhase: String? = nil,
        effectsStarted: Bool? = nil
    ) {
        self.message = message
        self.statusCode = statusCode
        self.code = code
        self.retryable = retryable
        self.retryAfterSeconds = retryAfterSeconds
        self.retryPhase = retryPhase
        self.effectsStarted = effectsStarted
    }

    var errorDescription: String? {
        let resolvedMessage = localizedMessage(for: AppLanguage.stored)
        if isRetryableAccountDeletion { return resolvedMessage }
        return statusCode.map { "\(resolvedMessage) [\($0)]" } ?? resolvedMessage
    }

    func localizedMessage(for language: AppLanguage) -> String {
        if isRetryableAccountDeletion {
            return accountDeletionRetryMessage(for: language)
        }
        guard language == .uk else { return message }

        if let localized = Self.ukrainianMessages[message] {
            return localized
        }
        if message.range(of: #"[іїєґІЇЄҐ]"#, options: .regularExpression) != nil {
            return message
        }

        switch normalizedCode {
        case "client_update_required":
            return "Оновіть SpyClash, щоб продовжити."
        case "spy_count_invalid_for_player_count":
            return "Обрана кількість шпигунів не підходить для цієї кількості гравців."
        case "active_lease", "cas_contention":
            return "Дані зараз оновлюються. Спробуйте ще раз."
        default:
            break
        }

        guard let statusCode else {
            return "Не вдалося виконати запит. Спробуйте ще раз."
        }
        switch statusCode {
        case 401:
            return "Увійдіть до акаунта, щоб продовжити."
        case 403:
            return "У вас немає доступу до цієї дії."
        case 404:
            return "Запитувані дані не знайдено."
        case 409:
            return "Дані змінилися. Оновіть екран і спробуйте ще раз."
        case 422:
            return "Перевірте введені дані й спробуйте ще раз."
        case 429:
            return "Забагато запитів. Спробуйте трохи пізніше."
        case 500...599:
            return "Сервіс тимчасово недоступний. Спробуйте ще раз."
        default:
            return "Не вдалося виконати запит. Спробуйте ще раз."
        }
    }

    private static let ukrainianMessages: [String: String] = [
        "Authentication required.": "Увійдіть до акаунта, щоб продовжити.",
        "Room join failed after retry.": "Не вдалося приєднатися до кімнати. Спробуйте ще раз.",
        "Need at least 3 operatives.": "Потрібно щонайменше 3 оперативники.",
        "Account deletion was not confirmed.": "Видалення акаунта не підтверджено.",
        "Invalid Radar invite policy response.": "Радар повернув недійсні налаштування запрошень.",
        "Radar invite policy was not confirmed.": "Налаштування запрошень Радара не підтверджено.",
        "Notification identifier is required.": "Потрібен ідентифікатор сповіщення.",
        "Notification title and body are required.": "Потрібні заголовок і текст сповіщення.",
        "Notification content is too long.": "Текст сповіщення задовгий.",
        "Invalid Apple authentication URL.": "Недійсне посилання автентифікації Apple.",
        "Invalid Apple authentication response.": "Недійсна відповідь автентифікації Apple.",
        "Apple authentication returned an invalid handoff URL.": "Apple повернула недійсне посилання для входу.",
        "Apple authentication did not return a valid access token.": "Apple не повернула дійсний токен доступу.",
        "Invalid API URL.": "Недійсне посилання API.",
        "Invalid API response.": "Недійсна відповідь сервера.",
        "Network request failed.": "Перевірте з’єднання з мережею та спробуйте ще раз.",
        "Empty API response.": "Сервер повернув порожню відповідь.",
        "The server returned an unreadable response.": "Не вдалося прочитати відповідь сервера.",
        "Apple authentication returned an invalid redirect.": "Apple повернула недійсне перенаправлення.",
        "Apple authentication returned an invalid app callback.": "Apple повернула недійсне посилання до застосунку.",
        "Apple authentication attempted an untrusted redirect.": "Apple спробувала виконати ненадійне перенаправлення.",
        "Apple authentication exceeded the redirect limit.": "Під час входу з Apple перевищено ліміт перенаправлень.",
        "Select at least two enabled lobby words before starting.": "Перед початком оберіть щонайменше два активні слова.",
        "Lobby room changed.": "Кімната лобі змінилася.",
        "Lobby settings are still synchronizing.": "Налаштування лобі ще синхронізуються.",
        "Lobby update was not confirmed.": "Оновлення лобі не підтверджено.",
        "Notification was not marked as read.": "Не вдалося позначити сповіщення як прочитане.",
        "Notifications were not marked as read.": "Не вдалося позначити сповіщення як прочитані.",
        "Global notification was not published.": "Не вдалося опублікувати глобальне сповіщення.",
        "Notification scope mismatch.": "Область сповіщення не збігається."
    ]

    var isRetryableRoomJoinConflict: Bool {
        guard statusCode == 409 else { return false }
        if isRetryableRoomActionConflict { return true }
        let normalized = message.lowercased()
        return normalized.contains("could not be verified")
            || normalized.contains("room membership changed")
            || normalized.contains("room changed; retry")
    }

    var isRetryableRoomActionConflict: Bool {
        guard statusCode == 409, retryable else { return false }
        let normalizedCode = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "active_lease",
            "cas_contention",
            "return_to_lobby_requires_leases"
        ].contains(normalizedCode)
    }

    var isClientUpdateRequired: Bool {
        statusCode == 426 || normalizedCode == "client_update_required"
    }

    var isSpyCountInvalidForPlayerCount: Bool {
        normalizedCode == "spy_count_invalid_for_player_count"
    }

    var isRoomAccessRevoked: Bool {
        statusCode == 403 && [
            "room_access_revoked",
            "room_departed"
        ].contains(normalizedCode)
    }

    var isRetryableAccountDeletion: Bool {
        guard statusCode == 503, retryable else { return false }
        return normalizedCode == "apple_revocation_unavailable"
            || normalizedCode.hasPrefix("account_deletion_")
            || normalizedCode.hasPrefix("apple_account_deletion_")
    }

    private func accountDeletionRetryMessage(for language: AppLanguage) -> String {
        let seconds = max(retryAfterSeconds ?? 600, 1)
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))
        switch language {
        case .en:
            return "Account deletion is safely paused. Try again in \(minutes) min."
        case .es:
            return "La eliminación de la cuenta está pausada de forma segura. Inténtalo de nuevo en \(minutes) min."
        case .ru:
            return "Удаление аккаунта безопасно приостановлено. Повторите через \(minutes) мин."
        case .uk:
            return "Видалення акаунта безпечно призупинено. Спробуйте знову через \(minutes) хв."
        }
    }

    private var normalizedCode: String {
        code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

enum RoomJoinRetryPolicy {
    private static let fallbackDelays = [250, 650]

    static func delayMilliseconds(
        for error: Base44Error,
        completedRetries: Int
    ) -> Int? {
        guard error.isRetryableRoomJoinConflict,
              fallbackDelays.indices.contains(completedRetries) else {
            return nil
        }
        let fallback = fallbackDelays[completedRetries]
        guard let retryAfterSeconds = error.retryAfterSeconds else {
            return fallback
        }
        return max(fallback, min(max(retryAfterSeconds, 0), 2) * 1_000)
    }
}

enum CommunityMutationRetryPolicy {
    private static let idempotentActions = Set([
        "accept",
        "decline",
        "accept_room_invite",
        "decline_room_invite",
        "consume_room_invite"
    ])
    private static let fallbackDelays = [250, 650]

    static func delayMilliseconds(
        action: String,
        error: Base44Error,
        completedRetries: Int
    ) -> Int? {
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard idempotentActions.contains(normalizedAction),
              fallbackDelays.indices.contains(completedRetries) else {
            return nil
        }

        let retryableFailure = error.isRetryableRoomActionConflict
            || (error.statusCode == 429 && error.retryable)
            || (error.statusCode == 503 && (error.retryable || error.code == nil))
        guard retryableFailure else { return nil }

        let fallback = fallbackDelays[completedRetries]
        guard let retryAfterSeconds = error.retryAfterSeconds else {
            return fallback
        }
        return max(fallback, min(max(retryAfterSeconds, 0), 3) * 1_000)
    }
}

enum NotificationMutationRetryPolicy {
    private static let idempotentActions = Set(["mark_read", "mark_all_read"])
    private static let fallbackDelays = [250, 650]

    static func delayMilliseconds(
        action: String,
        error: Base44Error,
        completedRetries: Int
    ) -> Int? {
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard idempotentActions.contains(normalizedAction),
              fallbackDelays.indices.contains(completedRetries) else {
            return nil
        }
        let retryableFailure = error.isRetryableRoomActionConflict
            || (error.statusCode == 429 && error.retryable)
            || (error.statusCode == 503 && (error.retryable || error.code == nil))
        guard retryableFailure else { return nil }
        let fallback = fallbackDelays[completedRetries]
        guard let retryAfterSeconds = error.retryAfterSeconds else {
            return fallback
        }
        return max(fallback, min(max(retryAfterSeconds, 0), 3) * 1_000)
    }
}

enum WordGenerationRetryPolicy {
    private static let fallbackDelays = [250, 650]

    static func delayMilliseconds(for error: Base44Error, completedRetries: Int) -> Int? {
        guard error.statusCode == 409,
              ["active_lease", "cas_contention"].contains(error.code),
              error.retryable,
              error.retryPhase == "before_effects",
              error.effectsStarted == false,
              fallbackDelays.indices.contains(completedRetries) else { return nil }
        let fallback = fallbackDelays[completedRetries]
        guard let seconds = error.retryAfterSeconds else { return fallback }
        return max(fallback, min(max(seconds, 0), 3) * 1_000)
    }
}

enum WordPackMutationRetryPolicy {
    private static let mutationActions = Set(["create", "update", "delete"])
    private static let fallbackDelays = [250, 650]

    static func delayMilliseconds(
        action: String,
        error: Base44Error,
        completedRetries: Int
    ) -> Int? {
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mutationActions.contains(normalizedAction),
              error.isRetryableRoomActionConflict,
              fallbackDelays.indices.contains(completedRetries) else {
            return nil
        }
        let fallback = fallbackDelays[completedRetries]
        guard let retryAfterSeconds = error.retryAfterSeconds else {
            return fallback
        }
        return max(fallback, min(max(retryAfterSeconds, 0), 3) * 1_000)
    }
}

enum CommunityRoomInviteCleanupPolicy {
    static func shouldClearAfterFailure(_ error: Base44Error) -> Bool {
        error.statusCode == 404 ||
            (error.statusCode == 409 && !error.retryable)
    }
}

enum SupplementaryReadRetryPolicy {
    static func delayMilliseconds(
        for error: Base44Error,
        completedRetries: Int
    ) -> Int? {
        guard completedRetries == 0 else { return nil }
        switch error.statusCode {
        case 429:
            guard error.retryable else { return nil }
        case 503:
            // Older deployed functions did not include the retryable field.
            guard error.retryable || error.code == nil else { return nil }
        default:
            return nil
        }

        let seconds = min(max(error.retryAfterSeconds ?? 2, 1), 15)
        return seconds * 1_000
    }
}

enum RequestCancellationPolicy {
    static func isCancellation(_ error: Error) -> Bool {
        var candidate: Error? = error
        for _ in 0..<4 {
            guard let current = candidate else { return false }
            if current is CancellationError { return true }

            let nsError = current as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                return true
            }
            candidate = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }
}

struct GameStartPlan: Hashable {
    let rouletteTargetEmail: String
    fileprivate let payload: StartGamePayload
}

private struct CreateRoomPayload: Encodable {
    let code: String
    let hostEmail: String
    let status: String
    let players: [Player]
    let gameMode: String
    let gameDurationSeconds: Int
    let readyPlayers: [String]
    let winner: String

    enum CodingKeys: String, CodingKey {
        case code
        case hostEmail = "host_email"
        case status
        case players
        case gameMode = "game_mode"
        case gameDurationSeconds = "game_duration_seconds"
        case readyPlayers = "ready_players"
        case winner
    }
}

fileprivate struct StartGamePayload: Encodable, Hashable {
    let status: String
    let secretWord: String
    let word: String
    let category: String
    let roundNumber: Int
    let questionsInRound: Int
    let currentAskerEmail: String
    let currentAnswererEmail: String
    let gameDurationSeconds: Int
    let questionPhase: String
    let currentAnswer: String
    let spyGuess: String
    let playerFeedback: [PlayerFeedback]
    let wordPool: [WordPoolEntry]
    let gameMode: String
    let cardsRead: [String]
    let readyPlayers: [String]
    let spectators: [String]
    let voteRequests: [String]
    let detectiveVotes: [VoteRecord]
    let eliminatedEmails: [String]
    let winner: String

    enum CodingKeys: String, CodingKey {
        case status
        case secretWord = "secret_word"
        case word
        case category
        case roundNumber = "round_number"
        case questionsInRound = "questions_in_round"
        case currentAskerEmail = "current_asker_email"
        case currentAnswererEmail = "current_answerer_email"
        case gameDurationSeconds = "game_duration_seconds"
        case questionPhase = "question_phase"
        case currentAnswer = "current_answer"
        case spyGuess = "spy_guess"
        case playerFeedback = "player_feedback"
        case wordPool = "word_pool"
        case gameMode = "game_mode"
        case cardsRead = "cards_read"
        case readyPlayers = "ready_players"
        case spectators
        case voteRequests = "vote_requests"
        case detectiveVotes = "detective_votes"
        case eliminatedEmails = "eliminated_emails"
        case winner
    }
}

private struct GameRoomActionPayload: Encodable {
    let action: String
    let accessToken: String
    let clientCapabilities: [String]?
    let roomID: String?
    let roomCode: String?
    let player: Player?
    let mode: String?
    let gameMode: String?
    let gameDurationSeconds: Int?
    let plan: StartGamePayload?
    let rouletteTargetEmail: String?
    let targetUserID: String?
    let targetEmail: String?
    let expectedTargetMembershipID: String?
    let returnToLobbyVote: Bool?
    let guess: String?
    let winner: String?
    let expectedDetectiveVoteRoundID: String?
    let joinMembershipID: String?
    let mutationID: String?
    let expectedRevision: Int?
    let expectedMembershipID: String?
    let state: LobbyStatePayload?
    let expectedLobbyRevision: Int?
    let expectedMatchID: String?
    let expectedGameStartedAt: String?

    init(
        action: String,
        accessToken: String,
        clientCapabilities: [String]? = ["multi_spy_v1"],
        roomID: String? = nil,
        roomCode: String? = nil,
        player: Player? = nil,
        mode: String? = nil,
        gameMode: String? = nil,
        gameDurationSeconds: Int? = nil,
        plan: StartGamePayload? = nil,
        rouletteTargetEmail: String? = nil,
        targetUserID: String? = nil,
        targetEmail: String? = nil,
        expectedTargetMembershipID: String? = nil,
        returnToLobbyVote: Bool? = nil,
        guess: String? = nil,
        winner: String? = nil,
        expectedDetectiveVoteRoundID: String? = nil,
        joinMembershipID: String? = nil,
        mutationID: String? = nil,
        expectedRevision: Int? = nil,
        expectedMembershipID: String? = nil,
        state: LobbyStatePayload? = nil,
        expectedLobbyRevision: Int? = nil,
        expectedMatchID: String? = nil,
        expectedGameStartedAt: String? = nil
    ) {
        self.action = action
        self.accessToken = accessToken
        self.clientCapabilities = clientCapabilities
        self.roomID = roomID
        self.roomCode = roomCode
        self.player = player
        self.mode = mode
        self.gameMode = gameMode
        self.gameDurationSeconds = gameDurationSeconds
        self.plan = plan
        self.rouletteTargetEmail = rouletteTargetEmail
        self.targetUserID = targetUserID
        self.targetEmail = targetEmail
        self.expectedTargetMembershipID = expectedTargetMembershipID
        self.returnToLobbyVote = returnToLobbyVote
        self.guess = guess
        self.winner = winner
        self.expectedDetectiveVoteRoundID = expectedDetectiveVoteRoundID
        self.joinMembershipID = joinMembershipID
        self.mutationID = mutationID
        self.expectedRevision = expectedRevision
        self.expectedMembershipID = expectedMembershipID
        self.state = state
        self.expectedLobbyRevision = expectedLobbyRevision
        self.expectedMatchID = expectedMatchID
        self.expectedGameStartedAt = expectedGameStartedAt
    }

    enum CodingKeys: String, CodingKey {
        case action
        case accessToken = "access_token"
        case clientCapabilities = "client_capabilities"
        case roomID = "room_id"
        case roomCode = "room_code"
        case player
        case mode
        case gameMode = "game_mode"
        case gameDurationSeconds = "game_duration_seconds"
        case plan
        case rouletteTargetEmail = "roulette_target_email"
        case targetUserID = "target_user_id"
        case targetEmail = "target_email"
        case expectedTargetMembershipID = "expected_target_membership_id"
        case returnToLobbyVote = "return_to_lobby_vote"
        case guess
        case winner
        case expectedDetectiveVoteRoundID = "expected_vote_round_id"
        case joinMembershipID = "join_membership_id"
        case mutationID = "mutation_id"
        case expectedRevision = "expected_revision"
        case expectedMembershipID = "expected_membership_id"
        case state
        case expectedLobbyRevision = "expected_lobby_revision"
        case expectedMatchID = "expected_match_id"
        case expectedGameStartedAt = "expected_game_started_at"
    }
}

private struct LeaderboardResponse: Decodable {
    let entries: [LeaderboardEntry]
}

private struct ReadyCheckPayload: Encodable {
    let status: String
    let readyPlayers: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case readyPlayers = "ready_players"
    }
}

private struct ReadyPlayersPayload: Encodable {
    let readyPlayers: [String]

    enum CodingKeys: String, CodingKey {
        case readyPlayers = "ready_players"
    }
}

private struct ReplayResetPayload: Encodable {
    let gameMode: String
    let gameDurationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case status
        case spyEmail = "spy_email"
        case secretWord = "secret_word"
        case word
        case category
        case spyGuess = "spy_guess"
        case detectiveVotes = "detective_votes"
        case winner
        case cardsRead = "cards_read"
        case voteRequests = "vote_requests"
        case spectators
        case eliminatedEmails = "eliminated_emails"
        case readyPlayers = "ready_players"
        case questionPhase = "question_phase"
        case questionsInRound = "questions_in_round"
        case roundNumber = "round_number"
        case currentAnswer = "current_answer"
        case currentAnswerFeedback = "current_answer_feedback"
        case currentAskerEmail = "current_asker_email"
        case currentAnswererEmail = "current_answerer_email"
        case rouletteTargetEmail = "roulette_target_email"
        case playerFeedback = "player_feedback"
        case wordPool = "word_pool"
        case gameStartedAt = "game_started_at"
        case countdownStartedAt = "countdown_started_at"
        case gameMode = "game_mode"
        case gameDurationSeconds = "game_duration_seconds"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("waiting", forKey: .status)
        try container.encode("", forKey: .spyEmail)
        try container.encode("", forKey: .secretWord)
        try container.encode("", forKey: .word)
        try container.encode("", forKey: .category)
        try container.encode("", forKey: .spyGuess)
        try container.encode([VoteRecord](), forKey: .detectiveVotes)
        try container.encode("", forKey: .winner)
        try container.encode([String](), forKey: .cardsRead)
        try container.encode([String](), forKey: .voteRequests)
        try container.encode([String](), forKey: .spectators)
        try container.encode([String](), forKey: .eliminatedEmails)
        try container.encode([String](), forKey: .readyPlayers)
        try container.encode("asking", forKey: .questionPhase)
        try container.encode(0, forKey: .questionsInRound)
        try container.encode(1, forKey: .roundNumber)
        try container.encode("", forKey: .currentAnswer)
        try container.encodeNil(forKey: .currentAnswerFeedback)
        try container.encode("", forKey: .currentAskerEmail)
        try container.encode("", forKey: .currentAnswererEmail)
        try container.encode("", forKey: .rouletteTargetEmail)
        try container.encode([PlayerFeedback](), forKey: .playerFeedback)
        try container.encode([WordPoolEntry](), forKey: .wordPool)
        try container.encodeNil(forKey: .gameStartedAt)
        try container.encodeNil(forKey: .countdownStartedAt)
        try container.encode(gameMode, forKey: .gameMode)
        try container.encode(gameDurationSeconds, forKey: .gameDurationSeconds)
    }
}

private struct GameModePayload: Encodable {
    let gameMode: String

    enum CodingKeys: String, CodingKey {
        case gameMode = "game_mode"
    }
}

private struct RoulettePayload: Encodable {
    let status: String
    let rouletteTargetEmail: String

    enum CodingKeys: String, CodingKey {
        case status
        case rouletteTargetEmail = "roulette_target_email"
    }
}

private struct CardsReadPayload: Encodable {
    let cardsRead: [String]

    enum CodingKeys: String, CodingKey {
        case cardsRead = "cards_read"
    }
}

private struct AssociationAdvancePayload: Encodable {
    let roundNumber: Int
    let currentAskerEmail: String
    let currentAnswer: String
    let questionPhase: String

    enum CodingKeys: String, CodingKey {
        case roundNumber = "round_number"
        case currentAskerEmail = "current_asker_email"
        case currentAnswer = "current_answer"
        case questionPhase = "question_phase"
    }
}

private struct StartTimerPayload: Encodable {
    let cardsRead: [String]
    let readyPlayers: [String]
    let gameStartedAt: Date
    let gameDurationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case cardsRead = "cards_read"
        case readyPlayers = "ready_players"
        case gameStartedAt = "game_started_at"
        case gameDurationSeconds = "game_duration_seconds"
    }
}

private struct QuestionPhasePayload: Encodable {
    let questionPhase: String

    enum CodingKeys: String, CodingKey {
        case questionPhase = "question_phase"
    }
}

private struct AdvanceQuestionPayload: Encodable {
    let currentAskerEmail: String
    let currentAnswererEmail: String
    let questionsInRound: Int
    let currentAnswer: String
    let questionPhase: String

    enum CodingKeys: String, CodingKey {
        case currentAskerEmail = "current_asker_email"
        case currentAnswererEmail = "current_answerer_email"
        case questionsInRound = "questions_in_round"
        case currentAnswer = "current_answer"
        case questionPhase = "question_phase"
    }
}

private struct VoteRequestsPayload: Encodable {
    let voteRequests: [String]

    enum CodingKeys: String, CodingKey {
        case voteRequests = "vote_requests"
    }
}

private struct DetectiveVotesPayload: Encodable {
    let detectiveVotes: [VoteRecord]

    enum CodingKeys: String, CodingKey {
        case detectiveVotes = "detective_votes"
    }
}

private struct DetectiveWinPayload: Encodable {
    let detectiveVotes: [VoteRecord]
    let winner: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case detectiveVotes = "detective_votes"
        case winner
        case status
    }
}

private struct SpyGuessPayload: Encodable {
    let spyGuess: String
    let winner: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case spyGuess = "spy_guess"
        case winner
        case status
    }
}

private struct FalseAccusationPayload: Encodable {
    let detectiveVotes: [VoteRecord]
    let voteRequests: [String]
    let spectators: [String]

    enum CodingKeys: String, CodingKey {
        case detectiveVotes = "detective_votes"
        case voteRequests = "vote_requests"
        case spectators
    }
}

private struct FinishRoomPayload: Encodable {
    let status: String
    let winner: String
}

private struct LeaveRoomPayload: Encodable {
    let players: [Player]
    let status: String
    let spectators: [String]
    let voteRequests: [String]
    let detectiveVotes: [VoteRecord]

    enum CodingKeys: String, CodingKey {
        case players
        case status
        case spectators
        case voteRequests = "vote_requests"
        case detectiveVotes = "detective_votes"
    }
}

private struct WordPackActionPayload: Encodable {
    let action: String
    let accessToken: String
    let packID: String?
    let name: String?
    let category: String?
    let words: [String]?

    enum CodingKeys: String, CodingKey {
        case action
        case accessToken = "access_token"
        case packID = "pack_id"
        case name
        case category
        case words
    }
}

private struct GenerateWordPackPayload: Encodable {
    let theme: String
    let count: Int
    let requestID: UUID
    let excludedWords: [String]
    let preferFresh: Bool

    enum CodingKeys: String, CodingKey {
        case theme
        case count
        case requestID = "request_id"
        case excludedWords = "exclude_words"
        case preferFresh = "prefer_fresh"
    }
}

private struct AssociationState: Codable {
    let spoken: [String]
    let spinning: Bool
}

private extension Array where Element == String {
    var cleanMissionWords: [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension JSONDecoder {
    static var base44: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var base44: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
