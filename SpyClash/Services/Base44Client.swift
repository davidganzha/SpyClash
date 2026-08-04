import Foundation

enum AppleNativeAuthPhase {
    case verifyingIdentity
    case establishingSession
}

@MainActor
@Observable
final class Base44Client {
    static let appID = "69a0e57fa939f578082f8091"
    static let appBaseURL = URL(string: "https://spyclash.com")!

    private let session: URLSession
    private var token: String?

    var hasSessionToken: Bool {
        token?.isEmpty == false
    }

    var currentAccessToken: String? {
        token?.isEmpty == false ? token : nil
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setToken(_ token: String) {
        self.token = token
    }

    func clearToken() {
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
        setToken(response.accessToken)
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

    func autoRegisterUser(email: String) async throws {
        let _: EmptyResponse = try await invokeFunction("autoRegisterUser", body: ["email": email])
    }

    func autoRegisterUser(appleBindingTicket: String? = nil) async throws -> SpyUser {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

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
        return try await currentUser()
    }

    func checkSubscription() async throws -> SubscriptionStatus {
        try await invokeFunction("checkSubscription", body: EmptyPayload())
    }

    func membership() async throws -> Membership {
        Membership(subscriptionStatus: try await checkSubscription())
    }

    func prepareAppStorePurchase() async throws -> AppStorePurchaseContext {
        try await invokeFunction(
            "app-store-entitlement",
            body: ["action": "prepare"]
        )
    }

    func syncAppStoreTransaction(
        signedTransaction: String
    ) async throws -> AppStoreEntitlementSyncResponse {
        try await invokeFunction(
            "app-store-entitlement",
            body: [
                "action": "sync_transaction",
                "signed_transaction": signedTransaction
            ]
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

    func refreshRoom(id: String) async throws -> GameRoom? {
        do {
            return try await roomAction("get_room", roomID: id)
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
        let player = Player(email: user.email, name: user.callSign, avatar: user.avatar ?? "🕵️")
        return try await roomAction("create_room", player: player)
    }

    func join(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        let player = Player(email: user.email, name: user.callSign, avatar: user.avatar ?? "🕵️")
        return try await roomAction("join_room", roomID: room.id, player: player)
    }

    func join(code: String, user: SpyUser) async throws -> GameRoom {
        let player = Player(email: user.email, name: user.callSign, avatar: user.avatar ?? "🕵️")
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let retryDelays = [250, 650]

        for attempt in 0...retryDelays.count {
            do {
                return try await roomAction(
                    "join_room",
                    roomCode: normalizedCode,
                    player: player
                )
            } catch let error as Base44Error
                where error.isRetryableRoomJoinConflict && attempt < retryDelays.count {
                try await Task.sleep(for: .milliseconds(retryDelays[attempt]))
            }
        }

        throw Base44Error(message: "Room join failed after retry.", statusCode: 409)
    }

    func beginReadyCheck(room: GameRoom) async throws -> GameRoom {
        try await roomAction("begin_ready_check", roomID: room.id)
    }

    func returnToWaiting(room: GameRoom) async throws -> GameRoom {
        try await roomAction("return_to_waiting", roomID: room.id)
    }

    func resetRoomForReplay(room: GameRoom) async throws -> GameRoom {
        try await roomAction(
            "reset_room_for_replay",
            roomID: room.id,
            gameMode: room.gameModeValue,
            gameDurationSeconds: room.gameDurationSeconds ?? 900
        )
    }

    func votePlayAgain(room: GameRoom, user: SpyUser) async throws -> GameRoom {
        try await roomAction("vote_play_again", roomID: room.id)
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
        let spy = shuffledPlayers.randomElement() ?? shuffledPlayers[0]
        let mission = Self.pickMissionWord(from: wordPacks, selectedPackID: selectedPackID)
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
                spyEmail: spy.email,
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
        try await roomAction("complete_game_start", roomID: room.id, plan: plan.payload)
    }

    func completeGameStart(room: GameRoom) async throws -> GameRoom {
        try await roomAction("complete_game_start", roomID: room.id)
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
        try await roomAction("request_vote", roomID: room.id)
    }

    func castDetectiveVote(room: GameRoom, user: SpyUser, targetEmail: String) async throws -> GameRoom {
        try await roomAction("cast_detective_vote", roomID: room.id, targetEmail: targetEmail)
    }

    func submitSpyGuess(room: GameRoom, user: SpyUser, guess: String) async throws -> GameRoom {
        let normalizedGuess = guess.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await roomAction("submit_spy_guess", roomID: room.id, guess: normalizedGuess)
    }

    func finalizeExpiredRoom(room: GameRoom) async throws -> GameRoom {
        try await roomAction("finalize_expired_room", roomID: room.id)
    }

    func leaveRoom(room: GameRoom, user: SpyUser) async throws {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }
        let _: EmptyResponse = try await request(
            "/apps/\(Self.appID)/functions/gameRoomAction",
            method: "POST",
            body: GameRoomActionPayload(action: "leave_room", accessToken: token, roomID: room.id),
            includeAuthorization: false
        )
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
        try await invokeFunction(
            "generateWordPack",
            body: GenerateWordPackPayload(
                theme: theme.trimmingCharacters(in: .whitespacesAndNewlines),
                count: count,
                requestID: requestID,
                excludedWords: excludedWords,
                preferFresh: preferFresh
            )
        )
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
                        seenIDs.insert(record.id).inserted && record.isOnlineCompetitiveMatch
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
        let boundedDisplayName = displayName.boundedUnicodeScalars(48)
        return try await request(
            "/apps/\(Self.appID)/entities/User/me",
            method: "PUT",
            body: [
                "display_name": boundedDisplayName,
                "avatar": avatar,
                "language": language.rawValue,
                "spy_card_theme": spyCardTheme.rawValue,
                "spy_card_accent": spyCardAccent.rawValue,
                "spy_card_badge": spyCardBadge.rawValue
            ]
        )
    }

    func updateLanguage(_ language: AppLanguage) async throws -> SpyUser {
        try await request(
            "/apps/\(Self.appID)/entities/User/me",
            method: "PUT",
            body: ["language": language.rawValue]
        )
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
        try await communityAction(action, fields: ["friendship_id": friendshipID])
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
        try await communityAction(action, fields: ["invite_id": inviteID])
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
            )
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
            )
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
        retriesTransientReadFailures: Bool = false
    ) async throws -> T {
        let expectedToken = payload.accessToken
        guard token == expectedToken else {
            throw CancellationError()
        }

        let retryDelays = [180, 520]
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
            } catch let error as Base44Error
                where retriesTransientReadFailures &&
                    error.statusCode == 503 &&
                    attempt < retryDelays.count {
                let delay = retryDelays[attempt]
                attempt += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private func communityAction<T: Decodable>(
        _ action: String,
        fields: [String: String] = [:],
        retriesTransientReadFailures: Bool = false
    ) async throws -> T {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        var payload = [
            "action": action,
            "access_token": token
        ]
        payload.merge(fields) { _, newValue in newValue }

        let retryDelays = [180, 520]
        var attempt = 0
        while true {
            do {
                return try await request(
                    "/apps/\(Self.appID)/functions/communityAction",
                    method: "POST",
                    body: payload,
                    includeAuthorization: false
                )
            } catch let error as Base44Error
                where retriesTransientReadFailures && error.statusCode == 503 && attempt < retryDelays.count {
                let delay = retryDelays[attempt]
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

        let (data, response) = try await session.data(for: request)
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

        let bootstrap = try JSONDecoder.base44.decode(AppleAuthBootstrapResponse.self, from: data)
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

        let (data, response) = try await handoffSession.data(for: request)
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

        var attempt = 1
        let maximumAttempts = 3
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
                guard attempt < maximumAttempts,
                      Self.isRetryablePushTransportError(error) else {
                    throw error
                }
                try await Self.waitBeforePushRetry(attempt: attempt)
                attempt += 1
                continue
            }

            let apiError = 200..<300 ~= response.statusCode
                ? nil
                : try? JSONDecoder.base44.decode(APIErrorEnvelope.self, from: data)
            if attempt < maximumAttempts,
               Self.isRetryablePushHTTPStatus(
                   response.statusCode,
                   action: payload.action,
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
                if attempt < maximumAttempts {
                    try await Self.waitBeforePushRetry(attempt: attempt)
                    attempt += 1
                    continue
                }
                throw Base44Error(message: "Empty API response.")
            }

            do {
                return try JSONDecoder.base44.decode(T.self, from: data)
            } catch {
                if attempt < maximumAttempts {
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
        action: String,
        apiError: APIErrorEnvelope?
    ) -> Bool {
        if statusCode == 409 {
            // Live Activity requests already own a longer bounded retry policy.
            // Keep the transport-level 409 retry limited to alert-device
            // registration so that request recovers from a short
            // BillingIdentityLifecycle collision without multiplying retries.
            guard action == "register_device",
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
        targetEmail: String? = nil,
        guess: String? = nil,
        winner: String? = nil,
        mutationID: String? = nil,
        expectedRevision: Int? = nil,
        state: LobbyStatePayload? = nil,
        expectedLobbyRevision: Int? = nil
    ) async throws -> GameRoom {
        guard let token, !token.isEmpty else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        // Provider/SSO tokens are valid Base44 identity tokens, but the
        // functions gateway can reject them before the function runs. Pass
        // the token inside the encrypted HTTPS body, then let the backend
        // verify it directly with Base44 (the same flow as autoRegisterUser).
        return try await request(
            "/apps/\(Self.appID)/functions/gameRoomAction",
            method: "POST",
            body: GameRoomActionPayload(
                action: action,
                accessToken: token,
                roomID: roomID,
                roomCode: roomCode,
                player: player,
                mode: mode?.rawValue,
                gameMode: gameMode?.rawValue,
                gameDurationSeconds: gameDurationSeconds,
                plan: plan,
                rouletteTargetEmail: rouletteTargetEmail,
                targetEmail: targetEmail,
                guess: guess,
                winner: winner,
                mutationID: mutationID,
                expectedRevision: expectedRevision,
                state: state,
                expectedLobbyRevision: expectedLobbyRevision
            ),
            includeAuthorization: false
        )
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

        return try await request(
            "/apps/\(Self.appID)/functions/wordPackAction",
            method: "POST",
            body: WordPackActionPayload(
                action: action,
                accessToken: token,
                packID: packID,
                name: name,
                category: category,
                words: words
            ),
            includeAuthorization: false
        )
    }

    private static func pickMissionWord(
        from packs: [WordPack],
        selectedPackID: String?
    ) -> (word: String, category: String, pool: [WordPoolEntry]) {
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

    private func shouldSpyWin(room: GameRoom) -> Bool {
        guard let spyEmail = room.spyEmail?.nilIfBlank else { return false }
        let active = room.activePlayers
        guard active.contains(where: { $0.email == spyEmail }) else { return false }
        let detectiveCount = active.filter { $0.email != spyEmail }.count
        return detectiveCount <= 1
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
        includeAuthorization: Bool = true
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.appBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.appID, forHTTPHeaderField: "X-App-Id")
        if includeAuthorization, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder.base44.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Base44Error(message: "Invalid API response.")
        }

        guard 200..<300 ~= http.statusCode else {
            let apiError = try? JSONDecoder.base44.decode(APIErrorEnvelope.self, from: data)
            throw Base44Error(
                message: apiError?.resolvedMessage ?? "Base44 request failed.",
                statusCode: http.statusCode,
                code: apiError?.code,
                retryable: apiError?.retryable ?? false
            )
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        if data.isEmpty {
            throw Base44Error(message: "Empty API response.", statusCode: http.statusCode)
        }

        return try JSONDecoder.base44.decode(T.self, from: data)
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

    enum CodingKeys: String, CodingKey {
        case message
        case error
        case errorDescription = "error_description"
        case code
        case retryable
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

struct Base44Error: LocalizedError {
    let message: String
    var statusCode: Int?
    var code: String?
    var retryable = false

    init(
        message: String,
        statusCode: Int? = nil,
        code: String? = nil,
        retryable: Bool = false
    ) {
        self.message = message
        self.statusCode = statusCode
        self.code = code
        self.retryable = retryable
    }

    var errorDescription: String? {
        statusCode.map { "\(message) [\($0)]" } ?? message
    }

    var isRetryableRoomJoinConflict: Bool {
        guard statusCode == 409 else { return false }
        let normalized = message.lowercased()
        return normalized.contains("could not be verified")
            || normalized.contains("room membership changed")
            || normalized.contains("room changed; retry")
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
    let spyEmail: String
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
        case spyEmail = "spy_email"
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
    let roomID: String?
    let roomCode: String?
    let player: Player?
    let mode: String?
    let gameMode: String?
    let gameDurationSeconds: Int?
    let plan: StartGamePayload?
    let rouletteTargetEmail: String?
    let targetEmail: String?
    let guess: String?
    let winner: String?
    let mutationID: String?
    let expectedRevision: Int?
    let state: LobbyStatePayload?
    let expectedLobbyRevision: Int?

    init(
        action: String,
        accessToken: String,
        roomID: String? = nil,
        roomCode: String? = nil,
        player: Player? = nil,
        mode: String? = nil,
        gameMode: String? = nil,
        gameDurationSeconds: Int? = nil,
        plan: StartGamePayload? = nil,
        rouletteTargetEmail: String? = nil,
        targetEmail: String? = nil,
        guess: String? = nil,
        winner: String? = nil,
        mutationID: String? = nil,
        expectedRevision: Int? = nil,
        state: LobbyStatePayload? = nil,
        expectedLobbyRevision: Int? = nil
    ) {
        self.action = action
        self.accessToken = accessToken
        self.roomID = roomID
        self.roomCode = roomCode
        self.player = player
        self.mode = mode
        self.gameMode = gameMode
        self.gameDurationSeconds = gameDurationSeconds
        self.plan = plan
        self.rouletteTargetEmail = rouletteTargetEmail
        self.targetEmail = targetEmail
        self.guess = guess
        self.winner = winner
        self.mutationID = mutationID
        self.expectedRevision = expectedRevision
        self.state = state
        self.expectedLobbyRevision = expectedLobbyRevision
    }

    enum CodingKeys: String, CodingKey {
        case action
        case accessToken = "access_token"
        case roomID = "room_id"
        case roomCode = "room_code"
        case player
        case mode
        case gameMode = "game_mode"
        case gameDurationSeconds = "game_duration_seconds"
        case plan
        case rouletteTargetEmail = "roulette_target_email"
        case targetEmail = "target_email"
        case guess
        case winner
        case mutationID = "mutation_id"
        case expectedRevision = "expected_revision"
        case state
        case expectedLobbyRevision = "expected_lobby_revision"
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
