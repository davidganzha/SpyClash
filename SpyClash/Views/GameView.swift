import SwiftUI
import UIKit

enum LobbySyncFeedbackPhase: Equatable {
    case hidden
    case syncing
    case serverConfirmed(UUID)

    var serverConfirmationID: UUID? {
        guard case let .serverConfirmed(id) = self else { return nil }
        return id
    }
}

enum OnlineInputPresentationPolicy {
    struct Layout: Equatable {
        let revealsTheme: Bool
        let allowsWaitingFooter: Bool
    }

    static func layout(
        isThemeFocused: Bool,
        isSoftwareKeyboardVisible: Bool
    ) -> Layout {
        Layout(
            revealsTheme: isThemeFocused && isSoftwareKeyboardVisible,
            allowsWaitingFooter: !isSoftwareKeyboardVisible
        )
    }

    static func shouldResetCapture(for scenePhase: ScenePhase) -> Bool {
        scenePhase != .active
    }

    static func isSoftwareKeyboardVisible(
        endFrame: CGRect?,
        screenBounds: CGRect,
        isLocal: Bool
    ) -> Bool {
        SoftwareKeyboardVisibilityPolicy.isVisible(
            endFrame: endFrame,
            screenBounds: screenBounds,
            isLocal: isLocal
        )
    }
}

enum WaitingStartActionMode: Equatable {
    case action
    case syncing
    case serverConfirmed(UUID)
    case failed

    var blocksStart: Bool {
        self != .action
    }

    static func resolve(
        feedbackPhase: LobbySyncFeedbackPhase,
        isEditingLobbySlider: Bool,
        hasOptimisticChanges: Bool,
        hasSyncFailure: Bool,
        requiresServerConfirmation: Bool,
        isServerConfirmed: Bool
    ) -> WaitingStartActionMode {
        if isEditingLobbySlider || hasOptimisticChanges {
            return .syncing
        }
        if hasSyncFailure {
            return .failed
        }
        if feedbackPhase == .syncing {
            return .syncing
        }
        if requiresServerConfirmation, !isServerConfirmed {
            return .syncing
        }
        if case let .serverConfirmed(confirmationID) = feedbackPhase {
            return .serverConfirmed(confirmationID)
        }
        return .action
    }
}

enum LobbyStartGate {
    static func hasPrerequisites(
        playerCount: Int,
        isThemeSelectionReady: Bool,
        isGeneratingRoomTheme: Bool
    ) -> Bool {
        playerCount >= 3 &&
            isThemeSelectionReady &&
            !isGeneratingRoomTheme
    }

    static func isServerConfirmed(
        roomRevision: Int?,
        authoritativeState: LobbyStatePayload?,
        localState: LobbyStatePayload,
        hasOptimisticChanges: Bool,
        hasSyncFailure: Bool,
        isEditingLobbySlider: Bool
    ) -> Bool {
        guard (roomRevision ?? 0) > 0,
              let authoritativeState,
              !hasOptimisticChanges,
              !hasSyncFailure,
              !isEditingLobbySlider else { return false }
        return authoritativeState.equivalentForLobbySync(to: localState)
    }
}

struct ReplayAutoStartRequest: Equatable {
    let roomID: String
    let matchKey: String

    var operationKey: String {
        "\(roomID)|\(matchKey)"
    }
}

enum ReplayAutoStartRoomDisposition: Equatable {
    case resetRequired
    case armRequired
    case alreadyStarted
    case invalid
}

enum FinishedRoomActionPolicy {
    static func showsIndependentLeaveRoom(
        hostEmail: String?,
        currentUserEmail: String?
    ) -> Bool {
        let hostEmail = normalized(hostEmail)
        let currentUserEmail = normalized(currentUserEmail)
        guard !hostEmail.isEmpty, !currentUserEmail.isEmpty else { return true }
        return hostEmail != currentUserEmail
    }

    private static func normalized(_ email: String?) -> String {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

enum ReplayAutoStartPolicy {
    static func request(
        for room: GameRoom,
        currentUserEmail: String?
    ) -> ReplayAutoStartRequest? {
        let roomID = cleaned(room.id)
        let currentUser = normalized(currentUserEmail)
        guard !roomID.isEmpty,
              !currentUser.isEmpty,
              normalized(room.hostEmail) == currentUser,
              ["finished", "ended"].contains(room.normalizedStatus) else { return nil }

        let playerEmails = room.replayEligiblePlayersList
            .map { normalized($0.email) }
            .filter { !$0.isEmpty }
        guard playerEmails.count >= 3 else { return nil }
        let readyEmails = Set((room.readyPlayers ?? []).map(normalized).filter { !$0.isEmpty })
        guard playerEmails.allSatisfy(readyEmails.contains) else { return nil }

        let matchKey = optionalClean(room.matchID)
            .map { "match:\($0.lowercased())" }
            ?? optionalClean(room.gameStartedAt).map { "started:\($0)" }
            ?? "legacy-finished"
        return ReplayAutoStartRequest(roomID: roomID, matchKey: matchKey)
    }

    static func disposition(
        of room: GameRoom,
        for request: ReplayAutoStartRequest,
        currentUserEmail: String?
    ) -> ReplayAutoStartRoomDisposition {
        guard cleaned(room.id) == request.roomID,
              normalized(room.hostEmail) == normalized(currentUserEmail),
              !normalized(currentUserEmail).isEmpty else { return .invalid }

        switch room.normalizedStatus {
        case "finished", "ended":
            return self.request(for: room, currentUserEmail: currentUserEmail) == request
                ? .resetRequired
                : .invalid
        case "waiting":
            return .armRequired
        case "roulette", "playing":
            return .alreadyStarted
        default:
            return .invalid
        }
    }

    static func canAdopt(
        _ candidate: GameRoom,
        over current: GameRoom,
        for request: ReplayAutoStartRequest,
        currentUserEmail: String?
    ) -> Bool {
        cleaned(candidate.id) == request.roomID &&
            cleaned(current.id) == request.roomID &&
            disposition(
                of: candidate,
                for: request,
                currentUserEmail: currentUserEmail
            ) != .invalid &&
            RoomPollPolicy.acceptsSnapshot(
                currentRoomRevision: current.roomRevision,
                currentLobbyRevision: current.lobbyRevision,
                fetchedRoomRevision: candidate.roomRevision,
                fetchedLobbyRevision: candidate.lobbyRevision
            )
    }

    private static func normalized(_ value: String?) -> String {
        cleaned(value).lowercased()
    }

    private static func optionalClean(_ value: String?) -> String? {
        let value = cleaned(value)
        return value.isEmpty ? nil : value
    }

    private static func cleaned(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct ReplayAutoStartCoordinatorState: Equatable {
    private(set) var pendingRequest: ReplayAutoStartRequest?
    private var handledOperationKeys: Set<String> = []

    mutating func observe(_ request: ReplayAutoStartRequest) -> Bool {
        guard pendingRequest == nil,
              !handledOperationKeys.contains(request.operationKey) else { return false }
        handledOperationKeys.insert(request.operationKey)
        pendingRequest = request
        return true
    }

    mutating func retry(_ request: ReplayAutoStartRequest) -> Bool {
        guard pendingRequest == nil else { return false }
        handledOperationKeys.remove(request.operationKey)
        return observe(request)
    }

    mutating func finish(_ request: ReplayAutoStartRequest) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
    }
}

struct SpyGuessSubmissionScope: Equatable {
    let room: OnlineRoomMatchScope
    let guessKey: String

    init?(room: GameRoom, guess: String) {
        guard let roomScope = OnlineRoomMatchScope(room: room) else { return nil }
        let guessKey = Self.normalized(guess)
        guard !guessKey.isEmpty else { return nil }
        self.room = roomScope
        self.guessKey = guessKey
    }

    func confirmsCommit(in candidate: GameRoom) -> Bool {
        room.matches(candidate) &&
            ["finished", "ended"].contains(candidate.normalizedStatus) &&
            Self.normalized(candidate.spyGuess) == guessKey
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

enum SpyGuessSubmissionPhase: Equatable {
    case idle
    case submitting(word: String)
    case failed(word: String)

    var selectedWord: String? {
        switch self {
        case .idle:
            nil
        case let .submitting(word), let .failed(word):
            word
        }
    }

    var blocksInteraction: Bool {
        if case .submitting = self { return true }
        return false
    }

    var submittingWord: String? {
        guard case let .submitting(word) = self else { return nil }
        return word
    }

    var failedWord: String? {
        guard case let .failed(word) = self else { return nil }
        return word
    }

    static func begin(word: String, from phase: Self) -> Self? {
        guard !phase.blocksInteraction else { return nil }
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        return .submitting(word: word)
    }

    func failing() -> Self {
        guard case let .submitting(word) = self else { return self }
        return .failed(word: word)
    }
}

enum SpyGuessSheetPresentationPolicy {
    static func shouldDismiss(authoritativeRoomStatus: String?) -> Bool {
        let status = authoritativeRoomStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return status == "finished" || status == "ended"
    }
}

enum RoomAccessPagePolicy {
    static let roomCode = 0
    static let roomQR = 1
    static let radar = 2
    static let friends = 3
    static let pageCount = 4

    static func shouldStopRadar(from previousPage: Int, to nextPage: Int) -> Bool {
        previousPage == radar && nextPage != radar
    }

    static func shouldStartRadar(on page: Int) -> Bool {
        page == radar
    }
}

enum OnlineInteractionHitTargetPolicy {
    static let minimumSize: CGFloat = 44
}

struct RoomFriendsScope: Hashable {
    let accountUserID: String
    let roomID: String

    init?(accountUserID: String?, roomID: String?) {
        let accountUserID = Self.cleaned(accountUserID)
        let roomID = Self.cleaned(roomID)
        guard !accountUserID.isEmpty, !roomID.isEmpty else { return nil }
        self.accountUserID = accountUserID
        self.roomID = roomID
    }

    func matches(accountUserID: String?, roomID: String?, page: Int) -> Bool {
        guard page == RoomAccessPagePolicy.friends,
              let currentScope = RoomFriendsScope(
                  accountUserID: accountUserID,
                  roomID: roomID
              ) else { return false }
        return self == currentScope
    }

    private static func cleaned(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum RoomFriendsLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed
}

enum RoomFriendInvitationPhase: Equatable {
    case idle
    case sending
    case sent
    case failed
}

enum RoomFriendsDirectoryPolicy {
    static func acceptedDeduplicatedProfiles(from state: CommunityState) -> [PublicSpyProfile] {
        var seenProfileIDs: Set<String> = []

        return state.friends.compactMap { relationship in
            guard relationship.status
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "accepted" else { return nil }

            let profileID = normalizedProfileID(relationship.profile.id)
            guard !profileID.isEmpty,
                  seenProfileIDs.insert(profileID).inserted else { return nil }
            return relationship.profile
        }
    }

    static func normalizedProfileID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct RoomFriendsDirectoryState: Equatable {
    private(set) var scope: RoomFriendsScope?
    private(set) var loadPhase: RoomFriendsLoadPhase = .idle
    private(set) var profiles: [PublicSpyProfile] = []

    private var loadRequestID: UUID?
    private var invitationPhases: [String: RoomFriendInvitationPhase] = [:]
    private var invitationRequestIDs: [String: UUID] = [:]

    init(scope: RoomFriendsScope? = nil) {
        self.scope = scope
    }

    mutating func beginLoading(scope: RoomFriendsScope, requestID: UUID) -> Bool {
        if self.scope != scope {
            reset(to: scope)
        }
        guard loadPhase == .idle || loadPhase == .failed else { return false }
        loadPhase = .loading
        profiles = []
        loadRequestID = requestID
        invitationPhases = [:]
        invitationRequestIDs = [:]
        return true
    }

    @discardableResult
    mutating func receive(
        _ communityState: CommunityState,
        scope: RoomFriendsScope,
        requestID: UUID
    ) -> Bool {
        guard self.scope == scope,
              loadPhase == .loading,
              loadRequestID == requestID else { return false }

        profiles = RoomFriendsDirectoryPolicy.acceptedDeduplicatedProfiles(from: communityState)
        loadPhase = profiles.isEmpty ? .empty : .loaded
        loadRequestID = nil
        return true
    }

    @discardableResult
    mutating func failLoading(scope: RoomFriendsScope, requestID: UUID) -> Bool {
        guard self.scope == scope,
              loadPhase == .loading,
              loadRequestID == requestID else { return false }
        profiles = []
        loadPhase = .failed
        loadRequestID = nil
        invitationPhases = [:]
        invitationRequestIDs = [:]
        return true
    }

    /// SwiftUI can cancel and replace the view task while the Friends page is
    /// still mounted (for example during the initial page transition). Release
    /// only the exact in-flight request so its replacement can start instead of
    /// leaving the directory permanently stuck in `.loading`.
    mutating func cancelLoading(scope: RoomFriendsScope, requestID: UUID) -> Bool {
        guard self.scope == scope,
              loadPhase == .loading,
              loadRequestID == requestID else { return false }
        loadPhase = .idle
        loadRequestID = nil
        return true
    }

    mutating func deactivate() {
        self = RoomFriendsDirectoryState()
    }

    func invitationPhase(for userID: String) -> RoomFriendInvitationPhase {
        invitationPhases[RoomFriendsDirectoryPolicy.normalizedProfileID(userID)] ?? .idle
    }

    mutating func beginInvitation(
        userID: String,
        scope: RoomFriendsScope,
        requestID: UUID
    ) -> Bool {
        let profileID = RoomFriendsDirectoryPolicy.normalizedProfileID(userID)
        guard self.scope == scope,
              loadPhase == .loaded,
              profiles.contains(where: {
                  RoomFriendsDirectoryPolicy.normalizedProfileID($0.id) == profileID
              }),
              invitationPhase(for: profileID) != .sending,
              invitationPhase(for: profileID) != .sent else { return false }

        invitationPhases[profileID] = .sending
        invitationRequestIDs[profileID] = requestID
        return true
    }

    @discardableResult
    mutating func finishInvitation(
        userID: String,
        scope: RoomFriendsScope,
        requestID: UUID
    ) -> Bool {
        updateInvitation(
            userID: userID,
            scope: scope,
            requestID: requestID,
            phase: .sent
        )
    }

    @discardableResult
    mutating func failInvitation(
        userID: String,
        scope: RoomFriendsScope,
        requestID: UUID
    ) -> Bool {
        updateInvitation(
            userID: userID,
            scope: scope,
            requestID: requestID,
            phase: .failed
        )
    }

    private mutating func updateInvitation(
        userID: String,
        scope: RoomFriendsScope,
        requestID: UUID,
        phase: RoomFriendInvitationPhase
    ) -> Bool {
        let profileID = RoomFriendsDirectoryPolicy.normalizedProfileID(userID)
        guard self.scope == scope,
              invitationPhases[profileID] == .sending,
              invitationRequestIDs[profileID] == requestID else { return false }
        invitationPhases[profileID] = phase
        invitationRequestIDs[profileID] = nil
        return true
    }

    private mutating func reset(to scope: RoomFriendsScope) {
        self = RoomFriendsDirectoryState(scope: scope)
    }
}

private struct RoomFriendsLoadTaskKey: Hashable {
    let scope: RoomFriendsScope
    let attempt: Int
}

#if DEBUG
private enum RoomFriendsPreviewData {
    private static let me = PublicSpyProfile(
        id: "preview-room-host",
        spyID: "107-001",
        displayName: "Red Raven",
        avatar: "🕵️",
        spyCardTheme: "field",
        spyCardAccent: "signal_red",
        spyCardBadge: "operative",
        rating: 248,
        gamesPlayed: 31,
        gamesWon: 19,
        winRate: 61
    )

    private static let cipher = PublicSpyProfile(
        id: "preview-friend-cipher",
        spyID: "314-159",
        displayName: "Cipher Fox",
        avatar: "🦊",
        spyCardTheme: "dossier",
        spyCardAccent: "clearance_amber",
        spyCardBadge: "analyst",
        rating: 184,
        gamesPlayed: 22,
        gamesWon: 13,
        winRate: 59
    )

    private static let signal = PublicSpyProfile(
        id: "preview-friend-signal",
        spyID: "271-828",
        displayName: "Signal Ember",
        avatar: "🔥",
        spyCardTheme: "blacksite",
        spyCardAccent: "verified_green",
        spyCardBadge: "handler",
        rating: 216,
        gamesPlayed: 28,
        gamesWon: 18,
        winRate: 64
    )

    private static let pending = PublicSpyProfile(
        id: "preview-friend-pending",
        spyID: "161-803",
        displayName: "Night Index",
        avatar: "👁️",
        spyCardTheme: "blacksite",
        spyCardAccent: "signal_red",
        spyCardBadge: "ghost",
        rating: 167,
        gamesPlayed: 17,
        gamesWon: 8,
        winRate: 47
    )

    static let state = CommunityState(
        me: me,
        friends: [
            CommunityRelationship(
                id: "preview-accepted-cipher",
                status: "accepted",
                direction: "outgoing",
                profile: cipher
            ),
            CommunityRelationship(
                id: "preview-accepted-signal",
                status: "accepted",
                direction: "incoming",
                profile: signal
            ),
            CommunityRelationship(
                id: "preview-accepted-cipher-duplicate",
                status: "ACCEPTED",
                direction: "incoming",
                profile: cipher
            ),
            CommunityRelationship(
                id: "preview-pending-night",
                status: "pending",
                direction: "incoming",
                profile: pending
            )
        ],
        incoming: [],
        outgoing: [],
        blocked: [],
        incomingRoomInvites: []
    )
}
#endif

private struct RoomFriendInvitationButton: View {
    let phase: RoomFriendInvitationPhase
    let accent: Color
    let title: String
    let symbol: String
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                statusIcon

                Text(title)
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.04)
                    .lineLimit(1)
            }
            .foregroundStyle(accent)
            .frame(width: 88)
            .frame(minHeight: OnlineInteractionHitTargetPolicy.minimumSize)
            .background(accent.opacity(0.08), in: CutCornerShape(cut: 6))
            .overlay(CutCornerShape(cut: 6).stroke(accent.opacity(0.38), lineWidth: 1))
            .contentShape(CutCornerShape(cut: 6))
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.96))
        .disabled(phase == .sending || phase == .sent)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if phase == .sending {
            ProgressView()
                .controlSize(.mini)
                .tint(accent)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
        }
    }
}

struct OnlineRoomMatchScope: Equatable {
    let roomID: String
    let matchID: String?
    let gameStartedAt: String

    init?(room: GameRoom) {
        let roomID = Self.clean(room.id)
        let gameStartedAt = Self.clean(room.gameStartedAt)
        guard !roomID.isEmpty, !gameStartedAt.isEmpty else { return nil }
        self.roomID = roomID
        self.matchID = Self.optionalClean(room.matchID)
        self.gameStartedAt = gameStartedAt
    }

    func matches(_ room: GameRoom) -> Bool {
        Self.clean(room.id) == roomID &&
            Self.optionalClean(room.matchID) == matchID &&
            Self.clean(room.gameStartedAt) == gameStartedAt
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func optionalClean(_ value: String?) -> String? {
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}

struct ActiveLobbyReturnPresentation: Equatable {
    let isAvailable: Bool
    let voteCount: Int
    let playerCount: Int
    let isSelected: Bool
    let isPending: Bool
    let hasFailed: Bool

    static let unavailable = ActiveLobbyReturnPresentation(
        isAvailable: false,
        voteCount: 0,
        playerCount: 0,
        isSelected: false,
        isPending: false,
        hasFailed: false
    )
}

struct ActiveLobbyReturnRequest: Equatable {
    let id: UUID
    let scope: OnlineRoomMatchScope
    let actorKey: String
    let actorEmail: String
    let targetVote: Bool
}

enum ActiveLobbyReturnVotePhase: Equatable {
    case idle
    case pending(ActiveLobbyReturnRequest)
    case failed(scope: OnlineRoomMatchScope, actorKey: String, targetVote: Bool)
}

enum ActiveLobbyReturnPolicy {
    static func presentation(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?,
        phase: ActiveLobbyReturnVotePhase
    ) -> ActiveLobbyReturnPresentation {
        guard room.normalizedStatus == "playing",
              OnlineRoomMatchScope(room: room) != nil,
              let actorKey = actorKey(
                  accountUserID: accountUserID,
                  email: currentUserEmail
              ),
              let actorEmailKey = normalizedEmail(currentUserEmail),
              eligiblePlayerEmailKeys(in: room).contains(actorEmailKey) else {
            return .unavailable
        }

        let eligible = eligiblePlayerEmailKeys(in: room)
        var votes = canonicalVoteEmailKeys(in: room, eligible: eligible)
        var isPending = false
        var hasFailed = false

        switch phase {
        case .idle:
            break
        case let .pending(request)
            where request.scope.matches(room) && request.actorKey == actorKey:
            isPending = true
            if request.targetVote {
                votes.insert(actorEmailKey)
            } else {
                votes.remove(actorEmailKey)
            }
        case let .failed(scope, failedActorKey, _)
            where scope.matches(room) && failedActorKey == actorKey:
            hasFailed = true
        case .pending, .failed:
            break
        }

        return ActiveLobbyReturnPresentation(
            isAvailable: true,
            voteCount: votes.count,
            playerCount: eligible.count,
            isSelected: votes.contains(actorEmailKey),
            isPending: isPending,
            hasFailed: hasFailed
        )
    }

    static func request(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?,
        phase: ActiveLobbyReturnVotePhase,
        requestID: UUID
    ) -> ActiveLobbyReturnRequest? {
        guard let scope = OnlineRoomMatchScope(room: room),
              room.normalizedStatus == "playing",
              let actorKey = actorKey(
                  accountUserID: accountUserID,
                  email: currentUserEmail
              ),
              let actorEmail = cleanedEmail(currentUserEmail),
              eligiblePlayerEmailKeys(in: room).contains(actorEmail.lowercased()) else {
            return nil
        }

        if case let .pending(existing) = phase,
           existing.scope.matches(room),
           existing.actorKey == actorKey {
            return nil
        }

        let targetVote: Bool
        if case let .failed(failedScope, failedActorKey, failedTargetVote) = phase,
           failedScope == scope,
           failedActorKey == actorKey {
            targetVote = failedTargetVote
        } else {
            targetVote = !room.hasReturnToLobbyVote(email: actorEmail)
        }

        return ActiveLobbyReturnRequest(
            id: requestID,
            scope: scope,
            actorKey: actorKey,
            actorEmail: actorEmail,
            targetVote: targetVote
        )
    }

    static func canAdopt(
        candidate: GameRoom,
        over current: GameRoom,
        request: ActiveLobbyReturnRequest,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        guard request.scope.matches(current),
              actorKey(accountUserID: accountUserID, email: currentUserEmail) == request.actorKey,
              cleaned(candidate.id) == request.scope.roomID,
              RoomPollPolicy.acceptsSnapshot(
                  currentRoomRevision: current.roomRevision,
                  currentLobbyRevision: current.lobbyRevision,
                  fetchedRoomRevision: candidate.roomRevision,
                  fetchedLobbyRevision: candidate.lobbyRevision
              ) else { return false }

        if candidate.normalizedStatus == "waiting" {
            return request.targetVote &&
                cleaned(candidate.matchID).isEmpty &&
                cleaned(candidate.gameStartedAt).isEmpty
        }

        guard request.scope.matches(candidate),
              candidate.normalizedStatus == "playing" else { return false }
        return candidate.hasReturnToLobbyVote(email: request.actorEmail) == request.targetVote
    }

    static func actorKey(accountUserID: String?, email: String?) -> String? {
        let userID = cleaned(accountUserID)
        if !userID.isEmpty { return "user:\(userID)" }
        guard let email = normalizedEmail(email) else { return nil }
        return "email:\(email)"
    }

    static func eligiblePlayerEmailKeys(in room: GameRoom) -> Set<String> {
        var seenUserIDs: Set<String> = []
        var seenEmails: Set<String> = []
        for player in room.returnToLobbyEligiblePlayersList {
            guard let email = normalizedEmail(player.email) else { continue }
            let userID = cleaned(player.userID)
            guard !seenEmails.contains(email),
                  userID.isEmpty || !seenUserIDs.contains(userID) else { continue }
            seenEmails.insert(email)
            if !userID.isEmpty {
                seenUserIDs.insert(userID)
            }
        }
        return seenEmails
    }

    private static func canonicalVoteEmailKeys(
        in room: GameRoom,
        eligible: Set<String>
    ) -> Set<String> {
        Set((room.readyPlayers ?? []).compactMap { value in
            guard let email = normalizedEmail(value), eligible.contains(email) else { return nil }
            return email
        })
    }

    private static func cleanedEmail(_ value: String?) -> String? {
        let value = cleaned(value)
        return value.isEmpty ? nil : value
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        cleanedEmail(value)?.lowercased()
    }

    private static func cleaned(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct ActiveLobbyReturnVoteState: Equatable {
    private(set) var phase = ActiveLobbyReturnVotePhase.idle

    init() {}

    mutating func begin(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?,
        requestID: UUID
    ) -> ActiveLobbyReturnRequest? {
        if !phaseMatches(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ) {
            phase = .idle
        }
        guard let request = ActiveLobbyReturnPolicy.request(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail,
            phase: phase,
            requestID: requestID
        ) else { return nil }
        phase = .pending(request)
        return request
    }

    func isPending(_ request: ActiveLobbyReturnRequest) -> Bool {
        phase == .pending(request)
    }

    @discardableResult
    mutating func finish(_ request: ActiveLobbyReturnRequest) -> Bool {
        guard isPending(request) else { return false }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func fail(
        _ request: ActiveLobbyReturnRequest,
        currentRoom: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        guard isPending(request),
              request.scope.matches(currentRoom),
              ActiveLobbyReturnPolicy.actorKey(
                  accountUserID: accountUserID,
                  email: currentUserEmail
              ) == request.actorKey else { return false }
        phase = .failed(
            scope: request.scope,
            actorKey: request.actorKey,
            targetVote: request.targetVote
        )
        return true
    }

    func presentation(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> ActiveLobbyReturnPresentation {
        ActiveLobbyReturnPolicy.presentation(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail,
            phase: phase
        )
    }

    private func phaseMatches(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        let actorKey = ActiveLobbyReturnPolicy.actorKey(
            accountUserID: accountUserID,
            email: currentUserEmail
        )
        switch phase {
        case .idle:
            return true
        case let .pending(request):
            return request.scope.matches(room) && request.actorKey == actorKey
        case let .failed(scope, failedActorKey, _):
            return scope.matches(room) && failedActorKey == actorKey
        }
    }
}

enum RoomKickPhase: Equatable {
    case idle
    case sending
    case failed
}

struct RoomKickScope: Equatable {
    let roomID: String
    let actorKey: String
    let hostEmailKey: String

    init?(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) {
        let roomID = room.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomID.isEmpty,
              ["waiting", "ready_voting"].contains(room.normalizedStatus),
              let actorKey = ActiveLobbyReturnPolicy.actorKey(
                  accountUserID: accountUserID,
                  email: currentUserEmail
              ),
              let currentEmailKey = RoomKickPolicy.normalizedEmail(currentUserEmail),
              let hostEmailKey = RoomKickPolicy.normalizedEmail(room.hostEmail),
              currentEmailKey == hostEmailKey else { return nil }
        self.roomID = roomID
        self.actorKey = actorKey
        self.hostEmailKey = hostEmailKey
    }

    func matches(
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        guard let current = RoomKickScope(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ) else { return false }
        return self == current
    }
}

struct RoomKickRequest: Equatable {
    let id: UUID
    let scope: RoomKickScope
    let targetUserID: String?
    let targetEmail: String
    let targetEmailKey: String
    let targetRequestKey: String
    let targetName: String
}

struct RoomKickConfirmation: Identifiable, Equatable {
    let scope: RoomKickScope
    let targetUserID: String?
    let targetEmail: String
    let targetName: String

    var id: String {
        "\(scope.roomID)|\(RoomKickPolicy.requestKey(userID: targetUserID, email: targetEmail))"
    }
}

enum RoomKickPolicy {
    static func validatedTargetEmail(
        for player: Player,
        in room: GameRoom,
        currentUserEmail: String?
    ) -> String? {
        let email = player.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.count <= 254,
              email.range(
                  of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,
                  options: .regularExpression
              ) != nil,
              let emailKey = normalizedEmail(email),
              normalizedEmail(room.hostEmail) != emailKey,
              normalizedEmail(currentUserEmail) != emailKey,
              room.playersList.filter({ normalizedEmail($0.email) == emailKey }).count == 1 else {
            return nil
        }
        return email
    }

    static func confirmation(
        for player: Player,
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> RoomKickConfirmation? {
        guard let scope = RoomKickScope(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ) else { return nil }

        let targetEmail = player.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetEmailKey = normalizedEmail(targetEmail),
              normalizedEmail(room.hostEmail) != targetEmailKey,
              normalizedEmail(currentUserEmail) != targetEmailKey,
              room.playersList.filter({ normalizedEmail($0.email) == targetEmailKey }).count == 1 else {
            return nil
        }

        let targetUserID: String?
        if player.userID == nil {
            guard validatedTargetEmail(
                for: player,
                in: room,
                currentUserEmail: currentUserEmail
            ) != nil else { return nil }
            targetUserID = nil
        } else {
            guard let stableUserID = validatedTargetUserID(player.userID),
                  Set(
                      room.playersList.compactMap { candidate -> String? in
                          guard validatedTargetUserID(candidate.userID) == stableUserID else { return nil }
                          return normalizedEmail(candidate.email)
                      }
                  ).count == 1 else { return nil }
            targetUserID = stableUserID
        }

        let targetName = player.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return RoomKickConfirmation(
            scope: scope,
            targetUserID: targetUserID,
            targetEmail: targetEmail,
            targetName: targetName.isEmpty ? targetEmail : targetName
        )
    }

    static func canAdopt(
        candidate: GameRoom,
        over current: GameRoom,
        request: RoomKickRequest,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        request.scope.matches(
            room: current,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ) &&
            candidate.id.trimmingCharacters(in: .whitespacesAndNewlines) == request.scope.roomID &&
            candidate.normalizedStatus == "waiting" &&
            normalizedEmail(candidate.hostEmail) == request.scope.hostEmailKey &&
            targetIsAbsent(from: candidate, request: request) &&
            RoomPollPolicy.acceptsSnapshot(
                currentRoomRevision: current.roomRevision,
                currentLobbyRevision: current.lobbyRevision,
                fetchedRoomRevision: candidate.roomRevision,
                fetchedLobbyRevision: candidate.lobbyRevision
            )
    }

    static func canAdoptRecoveredSnapshot(
        candidate: GameRoom,
        over current: GameRoom,
        request: RoomKickRequest,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        request.scope.matches(
            room: current,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ) &&
            candidate.id.trimmingCharacters(in: .whitespacesAndNewlines) == request.scope.roomID &&
            ["waiting", "ready_voting"].contains(candidate.normalizedStatus) &&
            normalizedEmail(candidate.hostEmail) == request.scope.hostEmailKey &&
            targetIsAbsent(from: candidate, request: request) &&
            RoomPollPolicy.acceptsSnapshot(
                currentRoomRevision: current.roomRevision,
                currentLobbyRevision: current.lobbyRevision,
                fetchedRoomRevision: candidate.roomRevision,
                fetchedLobbyRevision: candidate.lobbyRevision
            )
    }

    static func requestKey(userID: String?, email: String) -> String {
        if let userID = validatedTargetUserID(userID) {
            return "user:\(userID)"
        }
        return "email:\(normalizedEmail(email) ?? "")"
    }

    static func targetIsAbsent(
        from candidate: GameRoom,
        request: RoomKickRequest
    ) -> Bool {
        !candidate.playersList.contains {
            matchesTarget($0, request: request)
        }
    }

    static func matchesTarget(_ player: Player, request: RoomKickRequest) -> Bool {
        if let targetUserID = request.targetUserID {
            return validatedTargetUserID(player.userID) == targetUserID
        }
        return normalizedEmail(player.email) == request.targetEmailKey
    }

    static func validatedTargetUserID(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedValue.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
            options: String.CompareOptions.regularExpression
        ) != nil else { return nil }
        return cleanedValue
    }

    static func normalizedEmail(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }
}

struct RoomKickCoordinatorState: Equatable {
    private(set) var scope: RoomKickScope?
    private var activeRequests: [String: RoomKickRequest] = [:]
    private var failedTargetKeys: Set<String> = []

    init(scope: RoomKickScope? = nil) {
        self.scope = scope
    }

    mutating func begin(
        confirmation: RoomKickConfirmation,
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?,
        requestID: UUID
    ) -> RoomKickRequest? {
        guard confirmation.scope.matches(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ),
              let player = room.playersList.first(where: {
                  RoomKickPolicy.normalizedEmail($0.email) ==
                      RoomKickPolicy.normalizedEmail(confirmation.targetEmail)
              }),
              let currentConfirmation = RoomKickPolicy.confirmation(
                  for: player,
                  room: room,
                  accountUserID: accountUserID,
                  currentUserEmail: currentUserEmail
              ),
              currentConfirmation == confirmation,
              let targetEmailKey = RoomKickPolicy.normalizedEmail(confirmation.targetEmail) else {
            return nil
        }

        if scope != confirmation.scope {
            self = RoomKickCoordinatorState(scope: confirmation.scope)
        }
        let targetRequestKey = RoomKickPolicy.requestKey(
            userID: confirmation.targetUserID,
            email: confirmation.targetEmail
        )
        guard activeRequests[targetRequestKey] == nil else { return nil }

        let request = RoomKickRequest(
            id: requestID,
            scope: confirmation.scope,
            targetUserID: confirmation.targetUserID,
            targetEmail: confirmation.targetEmail,
            targetEmailKey: targetEmailKey,
            targetRequestKey: targetRequestKey,
            targetName: confirmation.targetName
        )
        activeRequests[targetRequestKey] = request
        failedTargetKeys.remove(targetRequestKey)
        return request
    }

    func phase(
        for player: Player,
        room: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> RoomKickPhase {
        guard scope?.matches(
            room: room,
            accountUserID: accountUserID,
            currentUserEmail: currentUserEmail
        ) == true,
              let confirmation = RoomKickPolicy.confirmation(
                  for: player,
                  room: room,
                  accountUserID: accountUserID,
                  currentUserEmail: currentUserEmail
              ) else { return .idle }
        let targetRequestKey = RoomKickPolicy.requestKey(
            userID: confirmation.targetUserID,
            email: confirmation.targetEmail
        )
        if activeRequests[targetRequestKey] != nil { return .sending }
        return failedTargetKeys.contains(targetRequestKey) ? .failed : .idle
    }

    func isPending(_ request: RoomKickRequest) -> Bool {
        scope == request.scope && activeRequests[request.targetRequestKey] == request
    }

    @discardableResult
    mutating func finish(_ request: RoomKickRequest) -> Bool {
        guard isPending(request) else { return false }
        activeRequests[request.targetRequestKey] = nil
        failedTargetKeys.remove(request.targetRequestKey)
        return true
    }

    @discardableResult
    mutating func fail(
        _ request: RoomKickRequest,
        currentRoom: GameRoom,
        accountUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        guard isPending(request),
              request.scope.matches(
                  room: currentRoom,
                  accountUserID: accountUserID,
                  currentUserEmail: currentUserEmail
              ) else { return false }
        activeRequests[request.targetRequestKey] = nil
        failedTargetKeys.insert(request.targetRequestKey)
        return true
    }
}

private struct RoomKickButton: View {
    let phase: RoomKickPhase
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if phase == .sending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: phase == .failed ? "arrow.clockwise" : "person.fill.xmark")
                        .font(.system(size: 11, weight: .black))
                }
            }
            .foregroundStyle(phase == .failed ? SpyTheme.amber : SpyTheme.red)
            .frame(
                width: OnlineInteractionHitTargetPolicy.minimumSize,
                height: OnlineInteractionHitTargetPolicy.minimumSize
            )
            .background(Color.white.opacity(0.035), in: CutCornerShape(cut: 6))
            .overlay {
                CutCornerShape(cut: 6)
                    .stroke(
                        phase == .failed ? SpyTheme.amber.opacity(0.62) : SpyTheme.red.opacity(0.38),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(SpyWebPressStyle(pressedScale: 0.94))
        .disabled(phase == .sending)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(phase == .sending ? "pending" : (phase == .failed ? "failed, retry" : "ready"))
    }
}

private struct RoomKickConfirmationModifier: ViewModifier {
    let language: AppLanguage
    @Binding var confirmation: RoomKickConfirmation?
    let onConfirm: (RoomKickConfirmation) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            dialogTitle,
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: confirmation
        ) { confirmation in
            Button(removeTitle, role: .destructive) {
                onConfirm(confirmation)
            }
            Button(cancelTitle, role: .cancel) {
                self.confirmation = nil
            }
        } message: { confirmation in
            Text(message(for: confirmation))
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { value in
                if !value { confirmation = nil }
            }
        )
    }

    private var dialogTitle: String {
        guard let confirmation else {
            return text(
                en: "REMOVE OPERATIVE?",
                ru: "УДАЛИТЬ ИГРОКА?",
                es: "¿EXPULSAR OPERATIVO?",
                uk: "ВИДАЛИТИ ГРАВЦЯ?"
            )
        }
        return text(
            en: "REMOVE \(confirmation.targetName.uppercased())?",
            ru: "УДАЛИТЬ \(confirmation.targetName.uppercased())?",
            es: "¿EXPULSAR A \(confirmation.targetName.uppercased())?",
            uk: "ВИДАЛИТИ \(confirmation.targetName.uppercased())?"
        )
    }

    private var removeTitle: String {
        text(
            en: "REMOVE OPERATIVE",
            ru: "УДАЛИТЬ ИГРОКА",
            es: "EXPULSAR OPERATIVO",
            uk: "ВИДАЛИТИ ГРАВЦЯ"
        )
    }

    private var cancelTitle: String {
        text(en: "CANCEL", ru: "ОТМЕНА", es: "CANCELAR", uk: "СКАСУВАТИ")
    }

    private func message(for confirmation: RoomKickConfirmation) -> String {
        text(
            en: "\(confirmation.targetName) will be removed from this room.",
            ru: "\(confirmation.targetName) будет удалён из этой комнаты.",
            es: "\(confirmation.targetName) será expulsado de esta sala.",
            uk: "\(confirmation.targetName) буде видалено з цієї кімнати."
        )
    }

    private func text(en: String, ru: String, es: String, uk: String) -> String {
        switch language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }
}

enum OnlineAuthoritativeRoomPolicy {
    static func canAdopt(
        candidate: GameRoom,
        over current: GameRoom,
        scope: OnlineRoomMatchScope
    ) -> Bool {
        scope.matches(current) &&
            scope.matches(candidate) &&
            RoomPollPolicy.acceptsSnapshot(
                currentRoomRevision: current.roomRevision,
                currentLobbyRevision: current.lobbyRevision,
                fetchedRoomRevision: candidate.roomRevision,
                fetchedLobbyRevision: candidate.lobbyRevision
            )
    }
}

enum UncertainRoomMutationRefreshDisposition: Equatable {
    case adopt
    case retainCurrent
    case reject
}

enum UncertainRoomMutationRecoveryPolicy {
    static let maximumMutationAttempts = 1
    static let maximumAuthoritativeReads = 1

    static func shouldRefreshAfterFailure(_ error: Error) -> Bool {
        guard !RequestCancellationPolicy.isCancellation(error) else { return false }
        if let base44Error = error as? Base44Error {
            return base44Error.statusCode == nil && base44Error.retryable
        }
        return LobbySyncRetryPolicy.isRetryable(error)
    }

    static func refreshDisposition(
        candidate: GameRoom?,
        over current: GameRoom,
        scope: OnlineRoomMatchScope
    ) -> UncertainRoomMutationRefreshDisposition {
        guard scope.matches(current),
              let candidate,
              scope.matches(candidate) else { return .reject }
        return OnlineAuthoritativeRoomPolicy.canAdopt(
            candidate: candidate,
            over: current,
            scope: scope
        ) ? .adopt : .retainCurrent
    }

    static func confirmsVoteRequest(
        in room: GameRoom,
        scope: OnlineRoomMatchScope,
        actorEmail: String
    ) -> Bool {
        guard scope.matches(room) else { return false }
        let actorKey = normalizedEmail(actorEmail)
        guard !actorKey.isEmpty else { return false }
        return room.voteRequestsList.contains {
            normalizedEmail($0) == actorKey
        }
    }

    private static func normalizedEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum ExpiredRoomFinalizationCandidateDisposition: Equatable {
    case adopt
    case retryCurrent
    case stop
}

enum ExpiredRoomFinalizationRetryPolicy {
    /// The first attempt is immediate. Retry delay ramps across the first
    /// failures, then switches to a low-frequency recovery cadence so an
    /// outage cannot leave the scoped room permanently parked at 0:00.
    static let retryDelaysMilliseconds = [250, 500, 1_000, 2_000, 4_000, 6_000, 8_000]
    static let deferredRetryDelayMilliseconds = 60_000
    static let warningAfterFailedAttempts = retryDelaysMilliseconds.count

    static func delayMilliseconds(afterFailedAttempt failedAttempt: Int) -> Int {
        guard failedAttempt < retryDelaysMilliseconds.count else {
            return deferredRetryDelayMilliseconds
        }
        return retryDelaysMilliseconds[max(failedAttempt, 0)]
    }

    static func canAttempt(
        scope: OnlineRoomMatchScope,
        room: GameRoom,
        now: Date
    ) -> Bool {
        scope.matches(room) &&
            room.normalizedStatus == "playing" &&
            !room.isGamePaused &&
            OnlineTimerSnapshot(room: room, now: now).isExpired
    }

    static func disposition(
        for candidate: GameRoom,
        over current: GameRoom,
        scope: OnlineRoomMatchScope,
        now: Date
    ) -> ExpiredRoomFinalizationCandidateDisposition {
        if OnlineAuthoritativeRoomPolicy.canAdopt(
            candidate: candidate,
            over: current,
            scope: scope
        ) {
            return .adopt
        }
        return canAttempt(scope: scope, room: current, now: now)
            ? .retryCurrent
            : .stop
    }

    static func isRetryable(_ error: Error) -> Bool {
        if RequestCancellationPolicy.isCancellation(error) { return false }
        if LobbySyncRetryPolicy.isRetryable(error) { return true }
        guard let base44Error = error as? Base44Error,
              base44Error.statusCode == 409 else { return false }

        let code = base44Error.code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let code, [
            "active_lease",
            "cas_contention",
            "room_write_unverified",
            "terminal_intent_conflict",
            "terminal_intent_changed",
            "terminal_state_conflict",
            "terminal_reconciliation_pending"
        ].contains(code) {
            return true
        }

        let message = base44Error.message.lowercased()
        return code == "invalid_ranked_terminal" &&
            message.contains("deadline has not elapsed")
    }
}

enum DetectiveVoteResponseTransition: Equatable {
    case recorded
    case cancelled
}

enum DetectiveVoteResponsePolicy {
    static func classify(
        previous: GameRoom,
        authoritative: GameRoom
    ) -> DetectiveVoteResponseTransition {
        guard let scope = OnlineRoomMatchScope(room: previous),
              scope.matches(authoritative),
              previous.isVotingActive,
              authoritative.normalizedStatus == "playing",
              normalized(authoritative.winner).isEmpty,
              activePlayerEmails(previous) == activePlayerEmails(authoritative),
              authoritative.voteRequestsList.isEmpty,
              authoritative.detectiveVotesList.isEmpty else {
            return .recorded
        }
        return .cancelled
    }

    static func shouldReconcileInactiveVote(_ error: Error) -> Bool {
        guard let base44Error = error as? Base44Error,
              base44Error.statusCode == 409 else { return false }
        return normalized(base44Error.code) == "detective_vote_inactive"
    }

    private static func activePlayerEmails(_ room: GameRoom) -> Set<String> {
        let spectators = Set(room.spectatorsList.map(normalized).filter { !$0.isEmpty })
        return Set(
            room.playersList
                .map { normalized($0.email) }
                .filter { !$0.isEmpty && !spectators.contains($0) }
        )
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

enum DetectiveVoteRoundChangedFeedback: Equatable {
    case cancelled
    case silent
}

enum DetectiveVoteRoundChangedPolicy {
    static func shouldReconcile(action: String, error: Error) -> Bool {
        guard action == "cast_detective_vote",
              let base44Error = error as? Base44Error,
              base44Error.statusCode == 409 else { return false }
        return normalized(base44Error.code) == "detective_vote_round_changed"
    }

    static func feedback(
        previous: GameRoom,
        authoritative: GameRoom
    ) -> DetectiveVoteRoundChangedFeedback {
        DetectiveVoteResponsePolicy.classify(
            previous: previous,
            authoritative: authoritative
        ) == .cancelled ? .cancelled : .silent
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

struct DetectiveVoteCastScope: Equatable {
    let room: OnlineRoomMatchScope
    let actorEmail: String
    let targetEmail: String
    let voteRoundID: String

    init?(room: GameRoom, actorEmail: String, targetEmail: String) {
        guard let roomScope = OnlineRoomMatchScope(room: room) else { return nil }
        let actor = Self.normalized(actorEmail)
        let target = Self.normalized(targetEmail)
        let voteRoundID = room.detectiveVoteRoundID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let activePlayers = Self.activePlayerEmails(room)
        guard !actor.isEmpty,
              !target.isEmpty,
              !voteRoundID.isEmpty,
              actor != target,
              activePlayers.contains(actor),
              activePlayers.contains(target) else { return nil }
        self.room = roomScope
        self.actorEmail = actorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetEmail = targetEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voteRoundID = voteRoundID
    }

    func matchesActor(_ email: String?) -> Bool {
        Self.normalized(email) == Self.normalized(actorEmail)
    }

    func matchesVoteRound(_ candidate: GameRoom) -> Bool {
        Self.normalized(candidate.detectiveVoteRoundID) == Self.normalized(voteRoundID)
    }

    func hasChangedVoteRound(_ candidate: GameRoom) -> Bool {
        let candidateRound = Self.normalized(candidate.detectiveVoteRoundID)
        return !candidateRound.isEmpty && candidateRound != Self.normalized(voteRoundID)
    }

    func hasMissingVoteRound(_ candidate: GameRoom) -> Bool {
        Self.normalized(candidate.detectiveVoteRoundID).isEmpty
    }

    fileprivate var actorKey: String { Self.normalized(actorEmail) }
    fileprivate var targetKey: String { Self.normalized(targetEmail) }

    fileprivate static func activePlayerEmails(_ room: GameRoom) -> Set<String> {
        let spectators = Set(room.spectatorsList.map(normalized).filter { !$0.isEmpty })
        return Set(
            room.playersList
                .map { normalized($0.email) }
                .filter { !$0.isEmpty && !spectators.contains($0) }
        )
    }

    fileprivate static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

enum DetectiveVoteConflictResolution: Equatable {
    case persisted
    case cancelled
    case superseded
    case ejected
    case finished
    case deadline
    case retry
    case reject
}

enum DetectiveVoteConflictRecoveryPolicy {
    static let retryDelaysMilliseconds = [250, 500, 1_000]
    static let maximumRecoveryDurationMilliseconds = 2_000

    static func delayMilliseconds(
        beforeRetry retry: Int,
        elapsedMilliseconds: Int = 0
    ) -> Int? {
        guard retryDelaysMilliseconds.indices.contains(retry) else { return nil }
        let delay = retryDelaysMilliseconds[retry]
        let remaining = remainingBudgetMilliseconds(
            elapsedMilliseconds: elapsedMilliseconds
        )
        guard delay <= remaining else { return nil }
        return delay
    }

    static func remainingBudgetMilliseconds(elapsedMilliseconds: Int) -> Int {
        max(maximumRecoveryDurationMilliseconds - max(elapsedMilliseconds, 0), 0)
    }

    static func isRecoverableConflict(_ error: Error) -> Bool {
        guard !RequestCancellationPolicy.isCancellation(error),
              let base44Error = error as? Base44Error,
              base44Error.statusCode == 409,
              base44Error.retryable else { return false }
        let code = DetectiveVoteCastScope.normalized(base44Error.code)
        return code == "active_lease" || code == "cas_contention"
    }

    static func resolution(
        previous: GameRoom,
        authoritative: GameRoom,
        cast: DetectiveVoteCastScope,
        now: Date
    ) -> DetectiveVoteConflictResolution {
        guard cast.room.matches(previous),
              cast.room.matches(authoritative),
              cast.matchesVoteRound(previous) else { return .reject }
        if cast.hasChangedVoteRound(authoritative) {
            return .superseded
        }

        let status = authoritative.normalizedStatus
        if ["finished", "ended"].contains(status) ||
            !DetectiveVoteCastScope.normalized(authoritative.winner).isEmpty {
            return .finished
        }
        if authoritative.terminalReconciliationPending == true {
            return .retry
        }
        if status == "playing",
           OnlineTimerSnapshot(room: authoritative, now: now).isExpired {
            return .deadline
        }

        let previousActive = DetectiveVoteCastScope.activePlayerEmails(previous)
        let authoritativeActive = DetectiveVoteCastScope.activePlayerEmails(authoritative)
        if previousActive != authoritativeActive {
            return .ejected
        }

        if DetectiveVoteResponsePolicy.classify(
            previous: previous,
            authoritative: authoritative
        ) == .cancelled {
            return .cancelled
        }

        if cast.hasMissingVoteRound(authoritative) {
            return .superseded
        }

        guard cast.matchesVoteRound(authoritative) else { return .reject }
        let actorVotes = authoritative.detectiveVotesList.filter {
            DetectiveVoteCastScope.normalized($0.voterEmail) == cast.actorKey
        }
        if actorVotes.contains(where: {
            DetectiveVoteCastScope.normalized($0.votedForEmail) == cast.targetKey
        }) {
            return .persisted
        }

        guard
              status == "playing",
              !authoritative.isGamePaused,
              authoritative.isVotingActive,
              authoritativeActive.contains(cast.actorKey),
              authoritativeActive.contains(cast.targetKey),
              actorVotes.isEmpty else { return .reject }
        return .retry
    }
}

enum DetectiveVoteDirectSuccessDisposition: Equatable {
    case recorded
    case cancelled
    case adoptSilently
    case reconcile
}

enum DetectiveVoteDirectSuccessPolicy {
    static func disposition(
        previous: GameRoom,
        authoritative: GameRoom,
        cast: DetectiveVoteCastScope,
        now: Date
    ) -> DetectiveVoteDirectSuccessDisposition {
        switch DetectiveVoteConflictRecoveryPolicy.resolution(
            previous: previous,
            authoritative: authoritative,
            cast: cast,
            now: now
        ) {
        case .persisted:
            return .recorded
        case .cancelled:
            return .cancelled
        case .superseded, .ejected, .finished, .deadline:
            return .adoptSilently
        case .retry, .reject:
            return .reconcile
        }
    }
}

private enum DetectiveVoteConflictReconciliationOutcome {
    case resolved
    case retry
    case stop
    case rejected
    case failed(Error)
}

struct LobbySyncFeedbackSnapshot: Equatable {
    let roomID: String?
    let hasOptimisticChanges: Bool
    let lastServerConfirmedMutationID: UUID?
}

struct LobbyPresentationSnapshot: Equatable {
    let roomID: String
    let revision: Int
    let state: LobbyStatePayload
}

struct LobbyPoolIdentity: Equatable {
    let source: LobbyWordSource
    let sourcePackID: String?
    let theme: String?

    init(state: LobbyStatePayload) {
        source = state.lobbyWordSource
        sourcePackID = state.lobbySourcePackID
        theme = state.lobbyTheme
    }
}

struct DeferredLobbyUpdateState: Equatable {
    private(set) var isPending = false
    private(set) var requiresForce = false

    mutating func record(force: Bool) {
        isPending = true
        requiresForce = requiresForce || force
    }

    mutating func clear() {
        isPending = false
        requiresForce = false
    }
}

enum LobbyPresentationPolicy {
    enum AuthoritativeUpdateDisposition: Equatable {
        case apply
        case deferUpdate
        case ignore
    }

    static func authoritativeUpdateDisposition(
        appliedRevision: Int,
        incomingRevision: Int,
        currentState: LobbyStatePayload?,
        authoritativeState: LobbyStatePayload?,
        isEditingLobbySlider: Bool,
        hasOptimisticChanges: Bool,
        force: Bool,
        hasLegacyPresentationChange: Bool
    ) -> AuthoritativeUpdateDisposition {
        if isEditingLobbySlider {
            return .deferUpdate
        }
        if force {
            return .apply
        }
        if incomingRevision < appliedRevision {
            return .ignore
        }
        if hasOptimisticChanges {
            return .deferUpdate
        }
        if incomingRevision > appliedRevision || hasLegacyPresentationChange {
            return .apply
        }
        guard let currentState, let authoritativeState else {
            return .ignore
        }
        return authoritativeState.equivalentForLobbySync(to: currentState)
            ? .ignore
            : .apply
    }

    static func shouldAnimateRemoteUpdate(
        isHost: Bool,
        reduceMotion: Bool,
        isConfiguredRoom: Bool,
        isEditingLobbySlider: Bool,
        appliedRevision: Int,
        incomingRevision: Int
    ) -> Bool {
        !isHost &&
            !reduceMotion &&
            isConfiguredRoom &&
            !isEditingLobbySlider &&
            appliedRevision >= 0 &&
            incomingRevision > appliedRevision
    }

    static func shouldDeferAuthoritativeUpdate(
        isDraggingDuration: Bool,
        isDraggingWordCount: Bool,
        isDraggingSpyCount: Bool = false
    ) -> Bool {
        isDraggingDuration || isDraggingWordCount || isDraggingSpyCount
    }

    static func shouldResetExpandedPool(
        current: LobbyPoolIdentity,
        incoming: LobbyPoolIdentity,
        currentWordKeys: Set<String>,
        incomingWordKeys: Set<String>
    ) -> Bool {
        guard current == incoming else { return true }
        return !currentWordKeys.isSubset(of: incomingWordKeys)
    }

    static func shouldShowPoolPreview(totalWordCount: Int) -> Bool {
        totalWordCount > 0
    }
}

struct LobbySyncFeedbackState: Equatable {
    private(set) var phase = LobbySyncFeedbackPhase.hidden
    private var roomID: String?
    private var lastObservedServerConfirmationID: UUID?

    mutating func update(_ snapshot: LobbySyncFeedbackSnapshot) {
        guard let snapshotRoomID = snapshot.roomID else {
            reset()
            return
        }

        guard roomID == snapshotRoomID else {
            roomID = snapshotRoomID
            lastObservedServerConfirmationID = snapshot.lastServerConfirmedMutationID
            phase = snapshot.hasOptimisticChanges ? .syncing : .hidden
            return
        }

        if snapshot.hasOptimisticChanges {
            // A server-confirmed intermediate request must not turn into a
            // success badge if a newer optimistic request later fails.
            lastObservedServerConfirmationID = snapshot.lastServerConfirmedMutationID
            phase = .syncing
            return
        }

        if let confirmationID = snapshot.lastServerConfirmedMutationID,
           confirmationID != lastObservedServerConfirmationID {
            lastObservedServerConfirmationID = confirmationID
            phase = .serverConfirmed(confirmationID)
            return
        }

        if phase == .syncing {
            phase = .hidden
        }
    }

    mutating func dismissServerConfirmation(_ confirmationID: UUID) {
        guard phase == .serverConfirmed(confirmationID) else { return }
        phase = .hidden
    }

    private mutating func reset() {
        roomID = nil
        lastObservedServerConfirmationID = nil
        phase = .hidden
    }
}

struct GameView: View {
    @Environment(AppState.self) private var appState
    @SpyReduceMotion private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var status = ""
    @State private var isStarting = false
    @State private var isAdvancing = false
    @State private var isRequestingVote = false
    @State private var isCastingVote = false
    @State private var pendingDetectiveVoteTargetEmail: String?
    @State private var isMarkingCardRead = false
    @State private var isTogglingGamePause = false
    @State private var isTogglingReady = false
    @State private var lobbyPackLoadState = RoomPackLoadState.idle
    @State private var isSubmittingSpyGuess = false
    @State private var isVotingReplay = false
    @State private var isResettingRoom = false
    @State private var activeLobbyReturnVoteState = ActiveLobbyReturnVoteState()
    @State private var roomKickCoordinator = RoomKickCoordinatorState()
    @State private var roomKickConfirmation: RoomKickConfirmation?
    @State private var replayAutoStartCoordinator = ReplayAutoStartCoordinatorState()
    @State private var replayAutoStartFailedOperationKey: String?
    @State private var copiedRoomCode = false
    @State private var showsThemeBuilder = false
    @State private var appliedLobbyRevision = -1
    @State private var roomAccessPage = RoomAccessPagePolicy.roomCode
    @State private var appearedRoomMissionPanelID: String?
    @State private var roomFriendsDirectory = RoomFriendsDirectoryState()
    @State private var roomFriendsLoadAttempt = 0
    @State private var isRoomCodeVisible = false
    @State private var isRoomQRVisible = false
    @State private var roomQRFlipProgress = 0.0
    @State private var isRoomQRFlipping = false
    @State private var roomQRFlipID = UUID()
    @State private var roomQRSheenProgress: CGFloat = -1
    @State private var roomQRIsLifted = false
    @State private var preparedRoomQR: PreparedRoomQRCode?
    @State private var revealRole = false
    @State private var showSpyGuess = false
    @State private var now = Date()
    @State private var selectedGameMode = SpyGameMode.questions
    @State private var selectedDurationMinutes = 15.0
    @State private var selectedSpyCount = 1.0
    @State private var selectedSpiesKnowEachOther = false
    @State private var roomWordSource = RoomWordSource.none
    @State private var lobbyWordPacks: [WordPack] = []
    @State private var roomTheme = ""
    @State private var roomGeneratedPack: GeneratedWordPack?
    @State private var roomGeneratedLobbySource = LobbyWordSource.ai
    @State private var roomThemeFallbackSource = RoomWordSource.none
    @State private var roomThemeError = ""
    @State private var roomWordCount = 25.0
    @State private var roomCustomWordCount = 25.0
    @State private var roomWordCountMode = RoomWordCountMode.recommended
    @State private var showsAllRoomPoolWords = false
    @State private var disabledRoomPoolWordKeys: Set<String> = []
    @State private var roomThemeOperation: RoomThemeOperation?
    @State private var isSavingRoomThemePack = false
    @State private var configuredRoomID: String?
    @State private var pendingStartPlan: GameStartPlan?
    @State private var rouletteCompletionKey: String?
    @State private var isDraggingOnlineDuration = false
    @State private var isDraggingOnlineWordCount = false
    @State private var isDraggingOnlineSpyCount = false
    @State private var deferredLobbyUpdate = DeferredLobbyUpdateState()
    @State private var lobbySyncFeedbackState = LobbySyncFeedbackState()
    @State private var detectiveVoteCancellationPresentation: DetectiveVoteCancellationEvent?
    @State private var handledDetectiveVoteCancellationEventIDs: Set<String> = []
    @State private var isOnlineSoftwareKeyboardVisible = false
    @FocusState private var focusedOnlineSetupField: OnlineSetupField?

    private var copy: GameCopy {
        appState.language.game
    }

    private var roomQRTargetBinding: Binding<RoomQRTarget> {
        Binding(
            get: { appState.roomQRTarget },
            set: { appState.roomQRTarget = $0 }
        )
    }

    private var roomRadar: RadarNearbyService {
        appState.radarNearby
    }

    private var currentRoomFriendsScope: RoomFriendsScope? {
        guard roomAccessPage == RoomAccessPagePolicy.friends else { return nil }
        return RoomFriendsScope(
            accountUserID: appState.user?.id,
            roomID: appState.activeRoom?.id
        )
    }

    private var roomFriendsLoadTaskKey: RoomFriendsLoadTaskKey? {
        currentRoomFriendsScope.map {
            RoomFriendsLoadTaskKey(scope: $0, attempt: roomFriendsLoadAttempt)
        }
    }

    private func activeLobbyReturnPresentation(
        for room: GameRoom
    ) -> ActiveLobbyReturnPresentation {
        activeLobbyReturnVoteState.presentation(
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )
    }

    private var replayAutoStartTrigger: ReplayAutoStartRequest? {
        guard let room = appState.activeRoom else { return nil }
        return ReplayAutoStartPolicy.request(
            for: room,
            currentUserEmail: appState.user?.email
        )
    }

    private var selectedPackID: String? {
        switch roomWordSource {
        case .none:
            nil
        case .generated:
            "generated"
        case let .saved(id):
            id
        }
    }

    private var activeLobbyPresentationSnapshot: LobbyPresentationSnapshot? {
        guard let room = appState.activeRoom else { return nil }
        return lobbyPresentationSnapshot(for: room)
    }

    private func lobbyPresentationSnapshot(for room: GameRoom) -> LobbyPresentationSnapshot {
        let state = appState.authoritativeLobbyStatePayload(from: room) ?? LobbyStatePayload(
            gameMode: room.gameModeValue,
            gameDurationSeconds: max(60, min(room.gameDurationSeconds ?? 900, 900)),
            spyCount: room.lobbySpyCountValue,
            spiesKnowEachOther: room.spiesKnowEachOther ?? false,
            lobbyWordSource: .none,
            lobbySourcePackID: nil,
            lobbySourceName: nil,
            lobbyTheme: nil,
            lobbyCategory: nil,
            lobbyWordCount: 0,
            lobbyWordCountMode: .recommended,
            lobbyWordPool: []
        )
        return LobbyPresentationSnapshot(
            roomID: room.id,
            revision: max(room.lobbyRevision ?? 0, 0),
            state: state
        )
    }

    private func remoteLobbyUpdateAnimation(for room: GameRoom) -> Animation? {
        let snapshot = lobbyPresentationSnapshot(for: room)
        guard LobbyPresentationPolicy.shouldAnimateRemoteUpdate(
            isHost: isHost(room),
            reduceMotion: reduceMotion,
            isConfiguredRoom: configuredRoomID == room.id,
            isEditingLobbySlider: isDraggingOnlineDuration || isDraggingOnlineWordCount || isDraggingOnlineSpyCount,
            appliedRevision: appliedLobbyRevision,
            incomingRevision: snapshot.revision
        ) else { return nil }
        return .smooth(duration: 0.24)
    }

    private func displayedGameMode(for room: GameRoom) -> SpyGameMode {
        isHost(room) ? selectedGameMode : room.gameModeValue
    }

    private func displayedDurationMinutes(for room: GameRoom) -> Double {
        guard !isHost(room) else { return selectedDurationMinutes }
        return Double(max(1, min((room.gameDurationSeconds ?? 900) / 60, 15)))
    }

    private func displayedSpyCount(for room: GameRoom) -> Int {
        guard isHost(room) else { return room.lobbySpyCountValue }
        return min(max(Int(selectedSpyCount.rounded()), 1), room.maximumLobbySpyCount)
    }

    private func displayedSpiesKnowEachOther(for room: GameRoom) -> Bool {
        isHost(room) ? selectedSpiesKnowEachOther : (room.spiesKnowEachOther ?? false)
    }

    private var isLoadingLobbyPacks: Bool {
        lobbyPackLoadState == .loading
    }

    private var roomPackLoadError: String? {
        guard case let .failed(message) = lobbyPackLoadState else { return nil }
        return message
    }

    var body: some View {
        rootWithRoomKickConfirmation
        .disabled(detectiveVoteCancellationPresentation != nil)
        .allowsHitTesting(detectiveVoteCancellationPresentation == nil)
        .accessibilityHidden(detectiveVoteCancellationPresentation != nil)
        .overlay {
            if let detectiveVoteCancellationPresentation {
                DetectiveVoteCancellationOverlay(
                    event: detectiveVoteCancellationPresentation,
                    languageCode: appState.language.rawValue
                )
                .transition(.identity)
                .zIndex(100)
            }
        }
        .task(id: detectiveVoteCancellationTaskKey) {
            await presentDetectiveVoteCancellationIfNeeded()
        }
        .onChange(of: replayAutoStartTrigger, initial: true) { _, request in
            guard let request else { return }
            scheduleReplayAutoStart(request)
        }
        .task(id: replayAutoStartCoordinator.pendingRequest) {
            guard let request = replayAutoStartCoordinator.pendingRequest else { return }
            await performReplayAutoStart(request)
        }
        .onChange(of: lobbySyncFeedbackSnapshot, initial: true) { _, snapshot in
            lobbySyncFeedbackState.update(snapshot)
        }
        .task(id: lobbySyncFeedbackState.phase.serverConfirmationID) {
            guard let confirmationID = lobbySyncFeedbackState.phase.serverConfirmationID else { return }
            do {
                try await Task.sleep(for: .seconds(1.4))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                lobbySyncFeedbackState.dismissServerConfirmation(confirmationID)
            }
        }
        .task(id: appState.activeRoom?.id) {
            while !Task.isCancelled, appState.activeRoom != nil {
                now = Date()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .task(id: appState.wordPacksRevision) {
            guard appState.wordPacksRevision > 0,
                  let room = appState.activeRoom,
                  configuredRoomID == room.id,
                  ["waiting", "ready_voting"].contains(room.normalizedStatus) else { return }
            await loadLobbyWordPacks(force: true)
        }
        .task(id: expiredRoomTaskKey) {
            guard let room = appState.activeRoom,
                  room.normalizedStatus == "playing",
                  isTimeExpired(room),
                  !room.isGamePaused else { return }
            await finalizeExpiredRoomIfNeeded(room)
        }
        .onChange(of: activeRoomIsTimeExpired, initial: true) { _, isExpired in
            guard isExpired else { return }
            showSpyGuess = false
        }
        .onChange(of: activeLobbyPresentationSnapshot) { _, snapshot in
            guard let snapshot,
                  let room = appState.activeRoom,
                  room.id == snapshot.roomID else { return }
            applyAuthoritativeLobbyState(from: room)
        }
        .onChange(of: appState.activeRoom?.playersList.count) { _, _ in
            reconcileSpyCountForRosterChange()
        }
        .onChange(of: appState.roomFriendsNavigationRequest) { _, request in
            guard request != nil else { return }
            consumeRoomFriendsNavigationRequestIfNeeded()
        }
        .onChange(of: appState.lobbySettingsRollbackEpoch) { _, _ in
            guard let room = appState.activeRoom else { return }
            applyAuthoritativeLobbyState(from: room, force: true)
        }
        .onChange(of: appState.hasOptimisticLobbySettingsChanges) { wasActive, isActive in
            guard wasActive, !isActive, let room = appState.activeRoom else { return }
            applyAuthoritativeLobbyState(from: room)
        }
        .onChange(of: appState.lobbySettingsSyncFailure) { _, message in
            guard let message else { return }
            if let room = appState.activeRoom {
                applyAuthoritativeLobbyState(from: room, force: true)
            }
            appState.showToast(
                userFacingStatus(message) ?? message,
                kind: .error
            )
            HapticManager.shared.fire(.notification(.error))
        }
        .onAppear {
            updateOnlineShellChromeSuppression()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--spyclash-preview-reveal-role") {
                revealRole = true
            }
#endif
        }
        .onChange(of: appState.activeRoom?.normalizedStatus) { _, status in
            if status == "roulette" || status == "playing" {
                dismissOnlineSetupCapture()
                replayAutoStartFailedOperationKey = nil
            }
            if SpyGuessSheetPresentationPolicy.shouldDismiss(
                authoritativeRoomStatus: status
            ) {
                showSpyGuess = false
            }
            updateOnlineShellChromeSuppression()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )
        ) { notification in
            captureOnlineSoftwareKeyboardVisibility(notification)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidHideNotification
            )
        ) { _ in
            isOnlineSoftwareKeyboardVisible = false
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ShellKeyboardDismissal.requested
            )
        ) { _ in
            dismissOnlineSetupCapture()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            guard OnlineInputPresentationPolicy.shouldResetCapture(
                for: newScenePhase
            ) else { return }
            dismissOnlineSetupCapture()
            isOnlineSoftwareKeyboardVisible = false
        }
        .onDisappear {
            appState.isShellChromeSuppressed = false
        }
        .onChange(of: status) { _, message in
            publishGameToast(message)
        }
        .onChange(of: roomThemeError) { _, message in
            publishRoomThemeError(message)
        }
        .onChange(of: lobbyPackLoadState) { _, state in
            guard case let .failed(message) = state else { return }
            appState.showToast(userFacingStatus(message) ?? message, kind: .error)
        }
        .sheet(isPresented: $showSpyGuess) {
            if let room = appState.activeRoom, !isTimeExpired(room) {
                SpyGuessSheet(
                    room: room,
                    isSubmitting: isSubmittingSpyGuess,
                    copy: copy,
                    language: appState.language
                ) { word in
                    try await submitSpyGuess(room, word: word)
                }
                .spyGlobalToastLayer()
                .spyInterfaceScale()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(0)
            }
        }
    }

    // GameView contains a large legacy SwiftUI tree. Keeping that tree behind
    // a concrete boundary prevents outer feedback modifiers from forcing the
    // Swift runtime to instantiate one recursively deep generic metadata type.
    private var rootWithRoomKickConfirmation: AnyView {
        AnyView(
            typeErasedRootSurface.modifier(
                RoomKickConfirmationModifier(
                    language: appState.language,
                    confirmation: $roomKickConfirmation,
                    onConfirm: confirmRoomKick
                )
            )
        )
    }

    private var typeErasedRootSurface: AnyView {
        AnyView(
            Group {
                if let room = appState.activeRoom, showsImmersiveGameExperience(for: room) {
                    immersiveGameExperience(room)
                } else {
                    standardGameSurface
                }
            }
            .animation(reduceMotion ? nil : SpyMotion.page, value: roomSceneKey)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let room = appState.activeRoom,
                   showsWaitingFooter(for: room),
                   onlineInputPresentation.allowsWaitingFooter {
                    waitingActionBar(room)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            )
                        )
                }
            }
            .animation(reduceMotion ? nil : SpyMotion.page, value: waitingFooterSceneKey)
        )
    }

    private var standardGameSurface: some View {
        PageChrome(
            eyebrow: copy.eyebrow,
            status: appState.activeRoom.map(roomStateLabel) ?? copy.standby,
            scrollTarget: onlineInputPresentation.revealsTheme
                ? onlineThemeScrollTarget
                : nil
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if let room = appState.activeRoom {
                        switch room.normalizedStatus {
                        case "ready_voting":
                            readyVotingRoom(room)
                        case "roulette":
                            rouletteRoom(room)
                        case "playing":
                            playingRoom(room)
                        case "ended", "finished":
                            finishedRoom(room)
                        default:
                            waitingRoom(room)
                        }
                    } else {
                        emptyRoom
                    }
                }
                .id(roomSceneKey)
                .transition(.opacity)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .animation(SpyMotion.page, value: roomSceneKey)
        }
    }

    private var roomSceneKey: String {
        guard let room = appState.activeRoom else { return "empty" }
        if room.normalizedStatus == "playing" {
            let phase = room.allRoleCardsRead && room.gameStartedAt != nil ? "active" : "role-gate"
            return "\(room.id)-playing-\(phase)"
        }
        return "\(room.id)-\(room.normalizedStatus)"
    }

    private var waitingFooterSceneKey: String {
        guard let room = appState.activeRoom,
              showsWaitingFooter(for: room),
              onlineInputPresentation.allowsWaitingFooter
        else { return "hidden" }
        return "waiting-\(room.id)"
    }

    private var expiredRoomTaskKey: String {
        guard let room = appState.activeRoom,
              room.normalizedStatus == "playing",
              room.gameStartedAt != nil else { return "inactive" }
        let isExpired = isTimeExpired(room)
        let terminalRevision = isExpired
            ? String(room.roomRevision ?? room.lobbyRevision ?? 0)
            : ""
        return [
            room.id,
            room.matchID ?? "",
            room.gameStartedAt ?? "",
            String(room.isGamePaused),
            String(isExpired),
            terminalRevision
        ].joined(separator: "|")
    }

    private var activeRoomIsTimeExpired: Bool {
        guard let room = appState.activeRoom,
              room.normalizedStatus == "playing" else { return false }
        return isTimeExpired(room)
    }

    private var detectiveVoteCancellationTaskKey: String {
        guard let room = appState.activeRoom else { return "inactive" }
        return [
            room.id,
            room.detectiveVoteCancellationEventID ?? "",
            room.detectiveVoteCancellationRoundID ?? "",
            room.detectiveVoteCancellationPresentAt ?? "",
            room.detectiveVoteCancellationReason ?? ""
        ].joined(separator: "|")
    }

    private var onlineInputPresentation: OnlineInputPresentationPolicy.Layout {
        OnlineInputPresentationPolicy.layout(
            isThemeFocused: focusedOnlineSetupField == .theme,
            isSoftwareKeyboardVisible: isOnlineSoftwareKeyboardVisible
        )
    }

    private var lobbySyncFeedbackSnapshot: LobbySyncFeedbackSnapshot {
        let room = appState.activeRoom
        let hostWaitingRoomID: String?
        if let room,
           room.normalizedStatus == "waiting",
           isHost(room) {
            hostWaitingRoomID = room.id
        } else {
            hostWaitingRoomID = nil
        }

        return LobbySyncFeedbackSnapshot(
            roomID: hostWaitingRoomID,
            hasOptimisticChanges: appState.hasOptimisticLobbySettingsChanges,
            lastServerConfirmedMutationID: appState.lobbySettingsSyncState.lastServerConfirmedMutationID
        )
    }

    private var isEditingLobbySlider: Bool {
        isDraggingOnlineDuration || isDraggingOnlineWordCount || isDraggingOnlineSpyCount
    }

    private func waitingStartActionMode(for room: GameRoom) -> WaitingStartActionMode {
        WaitingStartActionMode.resolve(
            feedbackPhase: lobbySyncFeedbackState.phase,
            isEditingLobbySlider: isEditingLobbySlider,
            hasOptimisticChanges: appState.hasOptimisticLobbySettingsChanges,
            hasSyncFailure: appState.lobbySettingsSyncFailure != nil,
            requiresServerConfirmation: roomThemeSelectionIsReady,
            isServerConfirmed: lobbyStateIsServerConfirmed(for: room)
        )
    }

    private func waitingStartActionTitle(for mode: WaitingStartActionMode) -> String {
        switch mode {
        case .action:
            return isStarting
                ? localized(en: "ARMING", ru: "ЗАПУСК", es: "INICIANDO", uk: "ЗАПУСК")
                : copy.startNow
        case .syncing:
            return localized(
                en: "SYNCING WITH SERVER…",
                ru: "СИНХРОНИЗАЦИЯ С СЕРВЕРОМ…",
                es: "SINCRONIZANDO CON EL SERVIDOR…",
                uk: "СИНХРОНІЗАЦІЯ ІЗ СЕРВЕРОМ…"
            )
        case .serverConfirmed:
            return localized(
                en: "SAVED ON SERVER",
                ru: "СОХРАНЕНО НА СЕРВЕРЕ",
                es: "GUARDADO EN EL SERVIDOR",
                uk: "ЗБЕРЕЖЕНО НА СЕРВЕРІ"
            )
        case .failed:
            return localized(
                en: "SERVER SYNC FAILED",
                ru: "СИНХРОНИЗАЦИЯ НЕ УДАЛАСЬ",
                es: "FALLO DE SINCRONIZACION",
                uk: "СИНХРОНІЗАЦІЯ НЕ ВДАЛАСЯ"
            )
        }
    }

    private func waitingStartActionDetail(
        for mode: WaitingStartActionMode,
        room: GameRoom
    ) -> String {
        switch mode {
        case .action:
            return roomStartActionDetail(room)
        case .syncing:
            guard lobbyStartPrerequisitesAreMet(room) else {
                return roomStartActionDetail(room)
            }
            return localized(
                en: "START AFTER CONFIRMATION",
                ru: "СТАРТ ПОСЛЕ ПОДТВЕРЖДЕНИЯ",
                es: "INICIA TRAS CONFIRMACION",
                uk: "СТАРТ ПІСЛЯ ПІДТВЕРДЖЕННЯ"
            )
        case .serverConfirmed:
            guard lobbyStartPrerequisitesAreMet(room) else {
                return roomStartActionDetail(room)
            }
            return localized(
                en: "READY TO START",
                ru: "ГОТОВО К ЗАПУСКУ",
                es: "LISTO PARA INICIAR",
                uk: "ГОТОВО ДО ЗАПУСКУ"
            )
        case .failed:
            return localized(
                en: "CHANGE A SETTING TO RETRY",
                ru: "ИЗМЕНИ ПАРАМЕТР И ПОВТОРИ",
                es: "CAMBIA UN AJUSTE Y REINTENTA",
                uk: "ЗМІНИ ПАРАМЕТР І ПОВТОРИ"
            )
        }
    }

    private func updateOnlineShellChromeSuppression() {
        guard let status = appState.activeRoom?.normalizedStatus else {
            appState.isShellChromeSuppressed = false
            return
        }
        appState.isShellChromeSuppressed = status == "roulette" || status == "playing"
    }

    private func showsImmersiveGameExperience(for room: GameRoom) -> Bool {
        room.normalizedStatus == "roulette" || room.normalizedStatus == "playing"
    }

    @ViewBuilder
    private func immersiveGameExperience(_ room: GameRoom) -> some View {
        switch room.normalizedStatus {
        case "roulette":
            OnlineGameIntroScene(room: room, language: appState.language)
                .transition(.opacity)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .task(id: "intro-\(room.id)-\(room.introStartedAt ?? "pending")") {
                    await completeRouletteIfNeeded(room)
                }

        case "playing" where !room.allRoleCardsRead || room.gameStartedAt == nil:
            OnlineRoleRevealScene(
                room: room,
                language: appState.language,
                role: onlineRoleContent(for: room),
                cardTheme: onlineCardTheme,
                cardAccent: onlineCardAccent,
                currentUserEmail: appState.user?.email,
                isRevealed: revealRole,
                isConfirming: isMarkingCardRead,
                onReveal: revealOnlineRole,
                onConfirm: {
                    Task { await markCardRead(room) }
                },
                onLeave: {
                    Task { await leaveRoom(room) }
                }
            )
            .transition(.opacity)
            .ignoresSafeArea(.keyboard, edges: .bottom)

        case "playing":
            OnlineActiveGameScene(
                room: room,
                language: appState.language,
                role: onlineRoleContent(for: room),
                cardTheme: onlineCardTheme,
                cardAccent: onlineCardAccent,
                currentUserEmail: appState.user?.email,
                isHost: isHost(room),
                isRoleRevealed: revealRole,
                roundCommand: room.onlineRoundCommand(
                    for: appState.user?.email,
                    isHost: isHost(room),
                    isTransitioning: isTimeExpired(room) || room.isVotingActive
                ),
                isRoundTransitioning: isAdvancing,
                canStopAssociationSpin: room.canStopAssociationSpin(
                    for: appState.user?.email,
                    isHost: isHost(room)
                ) && !isTimeExpired(room),
                showsVoteRequest: shouldShowVoteRequest(room),
                canRequestVote: canCurrentUserRequestVote(room),
                isVoteRequestPending: isRequestingVote,
                canSpyGuess: canCurrentUserGuess(room),
                canCastVote: canCurrentUserCastVote(room),
                pendingVoteTargetEmail: pendingDetectiveVoteTargetEmail,
                lobbyReturn: activeLobbyReturnPresentation(for: room),
                onToggleRole: revealOnlineRole,
                onTogglePause: {
                    Task { await toggleGamePause(room) }
                },
                onRoundCommand: { command in
                    Task { await performOnlineRoundCommand(command, room: room) }
                },
                onCountdownElapsed: {
                    Task { await advanceQuestionAfterCountdown(room) }
                },
                onAssociationSpinElapsed: {
                    Task { await stopAssociationSpinAfterAnimation(room) }
                },
                onRequestVote: {
                    beginVoteRequest(room, firesHaptic: false)
                },
                onCastVote: { targetEmail in
                    beginDetectiveVote(room, targetEmail: targetEmail, firesHaptic: false)
                },
                onSpyGuess: {
                    guard canCurrentUserGuess(room) else { return }
                    showSpyGuess = true
                    HapticManager.shared.fire(.buttonPress)
                },
                onToggleLobbyReturn: {
                    beginActiveLobbyReturnVote(room)
                },
                onLeave: {
                    Task { await leaveRoom(room) }
                }
            )
            .transition(.opacity)
            .ignoresSafeArea(.keyboard, edges: .bottom)

        default:
            standardGameSurface
        }
    }

    private func revealOnlineRole() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.72, dampingFraction: 0.78)) {
            revealRole.toggle()
        }
        HapticManager.shared.fire(revealRole ? .reveal : .buttonPress)
    }

    private func onlineRoleContent(for room: GameRoom) -> MissionRoleCardContent {
        if isCurrentUserSpectator(room) {
            return .spectator
        }
        if currentUserIsSpy(room) {
            return .spy
        }
        return .detective(word: room.displayWord ?? copy.classified)
    }

    private var onlineCardTheme: SpyCardThemeID {
        SpyCardThemeID(rawValue: appState.user?.spyCardTheme ?? "") ?? .field
    }

    private var onlineCardAccent: Color {
        switch SpyCardAccentID(rawValue: appState.user?.spyCardAccent ?? "") ?? .signalRed {
        case .signalRed:
            SpyTheme.red
        case .clearanceAmber:
            SpyTheme.amber
        case .verifiedGreen:
            SpyTheme.green
        }
    }

    private func canCurrentUserRequestVote(_ room: GameRoom) -> Bool {
        detectiveVoteCancellationPresentation == nil &&
            shouldShowVoteRequest(room) &&
            !isRequestingVote &&
            !hasCurrentUserRequestedVote(room)
    }

    private func shouldShowVoteRequest(_ room: GameRoom) -> Bool {
        guard let userEmail = appState.user?.email else { return false }
        return !room.isGamePaused &&
            !isTimeExpired(room) &&
            !room.isVotingActive &&
            !isCurrentUserSpectator(room) &&
            room.activePlayers.contains { emailsMatch($0.email, userEmail) }
    }

    private func canCurrentUserGuess(_ room: GameRoom) -> Bool {
        detectiveVoteCancellationPresentation == nil &&
            !room.isGamePaused &&
            !isSubmittingSpyGuess &&
            !room.enabledWordPool.isEmpty &&
            currentUserIsSpy(room) &&
            !isTimeExpired(room) &&
            !isCurrentUserSpectator(room)
    }

    private func canCurrentUserCastVote(_ room: GameRoom) -> Bool {
        detectiveVoteCancellationPresentation == nil &&
            !room.isGamePaused &&
            !isTimeExpired(room) &&
            room.isVotingActive &&
            !isCastingVote &&
            !isCurrentUserSpectator(room) &&
            myVote(in: room) == nil
    }

    private func showsWaitingFooter(for room: GameRoom) -> Bool {
        switch room.normalizedStatus {
        case "ready_voting", "roulette", "playing", "ended", "finished":
            false
        default:
            true
        }
    }

    private func waitingRoom(_ room: GameRoom) -> some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: SpyLobbyVisualLanguage.sectionSpacing) {
                onlineSetupSlot(.mission, content: AnyView(onlineMissionPanel(room)))
                onlineSetupSlot(
                    .mode,
                    content: AnyView(
                        onlineModePanel(room)
                            .spyWebEntrance(
                                delay: SpyLobbyVisualLanguage.EntranceDelay.mode,
                                duration: 0.42,
                                y: 14
                            )
                    )
                )
                if room.canChooseLobbySpyCount {
                    onlineSetupSlot(
                        .roles,
                        content: AnyView(
                            onlineSpySettingsPanel(room)
                                .spyWebEntrance(
                                    delay: SpyLobbyVisualLanguage.EntranceDelay.roles,
                                    duration: 0.42,
                                    y: 14
                                )
                        )
                    )
                }
                onlineSetupSlot(
                    .timing,
                    content: AnyView(
                        onlineTimingPanel(room)
                            .spyWebEntrance(
                                delay: SpyLobbyVisualLanguage.EntranceDelay.timing,
                                duration: 0.42,
                                y: 14
                            )
                    )
                )
                onlineSetupSlot(
                    .players,
                    content: AnyView(
                        onlinePlayersPanel(room)
                            .spyWebEntrance(
                                delay: SpyLobbyVisualLanguage.EntranceDelay.players,
                                duration: 0.42,
                                y: 14
                            )
                    )
                )
                if isHost(room) {
                    onlineSetupSlot(
                        .intel,
                        content: AnyView(
                            onlineIntelPanel
                                .spyWebEntrance(
                                    delay: SpyLobbyVisualLanguage.EntranceDelay.intel,
                                    duration: 0.42,
                                    y: 14
                                )
                        )
                    )
                } else {
                    onlineSetupSlot(
                        .intel,
                        content: AnyView(
                            onlineGuestIntelPanel(room)
                                .spyWebEntrance(
                                    delay: SpyLobbyVisualLanguage.EntranceDelay.intel,
                                    duration: 0.42,
                                    y: 14
                                )
                        )
                    )
                }
                onlineSetupSlot(
                    .controls,
                    content: AnyView(
                        onlineControls(room)
                            .spyWebEntrance(
                                delay: SpyLobbyVisualLanguage.EntranceDelay.controls,
                                duration: 0.42,
                                y: 14
                            )
                    )
                )
            }
            .disabled(isStarting)
        }
        .frame(maxWidth: SpyLobbyVisualLanguage.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .transition(.opacity)
        .onDisappear {
            focusedOnlineSetupField = nil
            isDraggingOnlineDuration = false
            isDraggingOnlineWordCount = false
            isDraggingOnlineSpyCount = false
        }
        .task(id: room.id) {
            await configureLobby(room)
        }
    }

    private func onlineSetupSlot(
        _ panel: OnlineSetupPanel,
        content: AnyView
    ) -> OnlineSetupSlotView {
        OnlineSetupSlotView(
            content: content,
            dimmed: onlineShouldDimPanel(panel)
        )
    }

    private var onlineThemeScrollTarget: String {
        "online-room-theme-input"
    }

    private func dismissOnlineSetupCapture() {
        let shouldReconcileDeferredLobbyUpdate = deferredLobbyUpdate.isPending
        focusedOnlineSetupField = nil
        isDraggingOnlineDuration = false
        isDraggingOnlineWordCount = false
        isDraggingOnlineSpyCount = false
        if shouldReconcileDeferredLobbyUpdate {
            reconcileAuthoritativeLobbyStateAfterSliderInteraction()
        }
    }

    private func captureOnlineSoftwareKeyboardVisibility(
        _ notification: Notification
    ) {
        let endFrame = (
            notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue
        )?.cgRectValue
        let isLocal = (
            notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey]
                as? NSNumber
        )?.boolValue ?? true
        let screenBounds = (notification.object as? UIScreen)?
            .coordinateSpace.bounds ?? activeKeyboardScreenBounds

        // The off-screen end frame arrives before the dismissal animation.
        // Keep the keyboard layout until keyboardDidHide to avoid inserting
        // the footer while the keyboard still physically covers the screen.
        isOnlineSoftwareKeyboardVisible = SoftwareKeyboardVisibilityPolicy
            .capturedVisibility(
                currentlyVisible: isOnlineSoftwareKeyboardVisible,
                endFrame: endFrame,
                screenBounds: screenBounds,
                isLocal: isLocal
            )
    }

    private var activeKeyboardScreenBounds: CGRect {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted {
                $0.activationState == .foregroundActive &&
                    $1.activationState != .foregroundActive
            }
            .first?
            .screen.coordinateSpace.bounds ?? .zero
    }

    private var focusedOnlineSetupPanel: OnlineSetupPanel? {
        switch focusedOnlineSetupField {
        case .theme:
            return .intel
        case nil:
            return nil
        }
    }

    private func onlineShouldDimPanel(_ panel: OnlineSetupPanel) -> Bool {
        guard let focusedOnlineSetupPanel else { return false }
        return focusedOnlineSetupPanel != panel
    }

    private func onlineMissionPanel(_ room: GameRoom) -> some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $roomAccessPage) {
                onlineRoomCodePage(room)
                    .tag(RoomAccessPagePolicy.roomCode)

                onlineRoomQRPage(room)
                    .tag(RoomAccessPagePolicy.roomQR)

                onlineRoomRadarPage(room)
                    .tag(RoomAccessPagePolicy.radar)

                onlineRoomFriendsPage(room)
                    .tag(RoomAccessPagePolicy.friends)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: SpyLobbyVisualLanguage.heroHeight)
            .accessibilityIdentifier("onlineRoom.accessPages")
            .accessibilityValue(localized(
                en: "Page \(roomAccessPage + 1) of \(RoomAccessPagePolicy.pageCount)",
                ru: "Страница \(roomAccessPage + 1) из \(RoomAccessPagePolicy.pageCount)",
                es: "Pagina \(roomAccessPage + 1) de \(RoomAccessPagePolicy.pageCount)",
                uk: "Сторінка \(roomAccessPage + 1) із \(RoomAccessPagePolicy.pageCount)"
            ))

            roomAccessPageIndicator
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity)
        .frame(height: SpyLobbyVisualLanguage.heroHeight)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: roomAccessPage)
        .onChange(of: roomAccessPage) { previousPage, nextPage in
            HapticManager.shared.fire(.tabSelection)
            updateRoomRadarScanning(from: previousPage, to: nextPage)
            if nextPage != RoomAccessPagePolicy.friends {
                roomFriendsDirectory.deactivate()
            }
        }
        .onAppear {
            appearedRoomMissionPanelID = room.id
            roomFriendsDirectory.deactivate()
            roomFriendsLoadAttempt = 0
            roomAccessPage = initialRoomAccessPage
            isRoomCodeVisible = false
            isRoomQRVisible = false
            roomQRFlipProgress = 0
            isRoomQRFlipping = false
            roomQRFlipID = UUID()
            roomQRSheenProgress = -1
            roomQRIsLifted = false
            if RoomAccessPagePolicy.shouldStartRadar(on: roomAccessPage) {
                appState.startRadarScanning(requestCameraAccess: true)
            }
            consumeRoomFriendsNavigationRequestIfNeeded()
        }
        .onChange(of: room.id) { _, _ in
            appearedRoomMissionPanelID = room.id
            if RoomAccessPagePolicy.shouldStartRadar(on: roomAccessPage) {
                roomRadar.stopScanning()
            }
            roomFriendsDirectory.deactivate()
            roomFriendsLoadAttempt = 0
            roomAccessPage = RoomAccessPagePolicy.roomCode
            isRoomCodeVisible = false
            isRoomQRVisible = false
            roomQRFlipProgress = 0
            isRoomQRFlipping = false
            roomQRFlipID = UUID()
            roomQRSheenProgress = -1
            roomQRIsLifted = false
            preparedRoomQR = nil
        }
        .onChange(of: appState.user?.id) { _, _ in
            roomFriendsDirectory.deactivate()
            roomFriendsLoadAttempt = 0
        }
        .onDisappear {
            if appearedRoomMissionPanelID == room.id {
                appearedRoomMissionPanelID = nil
            }
            if RoomAccessPagePolicy.shouldStartRadar(on: roomAccessPage) {
                roomRadar.stopScanning()
            }
            roomFriendsDirectory.deactivate()
        }
        .task(id: roomQRPayload(for: room)) {
            await prepareRoomQRCode(payload: roomQRPayload(for: room))
        }
        .task(id: roomFriendsLoadTaskKey) {
            guard let taskKey = roomFriendsLoadTaskKey else { return }
            await loadRoomFriends(for: taskKey.scope)
        }
        .spyWebEntrance(
            delay: SpyLobbyVisualLanguage.EntranceDelay.hero,
            duration: 0.46,
            y: 12
        )
    }

    private func onlineRoomCodePage(_ room: GameRoom) -> some View {
        SpyLobbyHeroSurface {
            VStack(spacing: 0) {
                SpyLobbyHeroHeader(
                    title: localized(en: "ROOM ACCESS", ru: "ДОСТУП В КОМНАТУ", es: "ACCESO A SALA", uk: "ДОСТУП ДО КІМНАТИ"),
                    status: localized(en: "LIVE", ru: "В СЕТИ", es: "EN LINEA", uk: "У МЕРЕЖІ"),
                    count: room.playersList.count
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                VStack(spacing: 9) {
                    Text(roomCodePlainLabel)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.10)
                        .foregroundStyle(SpyTheme.dim)

                    Button {
                        if isRoomCodeVisible {
                            HapticManager.shared.fire(.buttonPress)
                        } else {
                            HapticManager.shared.fire(.reveal)
                        }
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .timingCurve(0.4, 0, 0.2, 1, duration: 0.55)
                        ) {
                            isRoomCodeVisible.toggle()
                        }
                    } label: {
                        ZStack {
                            if isRoomCodeVisible {
                                Text(room.code.uppercased())
                                    .font(SpyTheme.brandFont(size: 42))
                                    .tracking(8)
                                    .foregroundStyle(SpyTheme.red)
                                    .minimumScaleFactor(0.54)
                                    .lineLimit(1)
                                    .transition(.opacity.combined(with: .scale(scale: 0.90)))
                            } else {
                                RoomCodeSpoilerField(
                                    isActive: roomAccessPage == RoomAccessPagePolicy.roomCode
                                )
                                    .frame(maxWidth: 246, minHeight: 72)
                                    .transition(.opacity.combined(with: .scale(scale: 1.34)))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.roomCodeReveal")
                    .accessibilityLabel(
                        isRoomCodeVisible
                            ? localized(en: "Room code \(room.code). Tap to hide", ru: "Код комнаты \(room.code). Нажмите, чтобы скрыть", es: "Codigo \(room.code). Toca para ocultar", uk: "Код кімнати \(room.code). Натисніть, щоб приховати")
                            : localized(en: "Room code hidden. Tap to reveal", ru: "Код комнаты скрыт. Нажмите, чтобы показать", es: "Codigo oculto. Toca para mostrar", uk: "Код кімнати приховано. Натисніть, щоб показати")
                    )

                    Text(isRoomCodeVisible ? tapToHideRoomCode : tapToRevealRoomCode)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.dim)

                    Button {
                        copyRoomCode(room)
                    } label: {
                        roomAccessActionLabel(
                            title: copiedRoomCode ? roomCopiedTitle : roomCopyTitle,
                            systemImage: copiedRoomCode ? "checkmark" : "doc.on.doc",
                            accent: copiedRoomCode ? SpyTheme.red : SpyTheme.muted
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .frame(maxWidth: 184)
                    .accessibilityIdentifier("onlineRoom.copyCode")
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    private func onlineRoomQRPage(_ room: GameRoom) -> some View {
        let payload = roomQRPayload(for: room)
        let targetTitle = appState.roomQRTarget == .web ? "WEB" : "iOS"
        let edgeProgress = CGFloat(sin(roomQRFlipProgress * .pi))

        return ZStack(alignment: .topTrailing) {
            ZStack {
                roomQRHiddenFace(room)
                    .modifier(
                        RoomQRFlipFace(
                            progress: roomQRFlipProgress,
                            isBack: false,
                            reduceMotion: reduceMotion
                        )
                    )

                roomQRVisibleFace(room, payload: payload)
                    .modifier(
                        RoomQRFlipFace(
                            progress: roomQRFlipProgress,
                            isBack: true,
                            reduceMotion: reduceMotion
                        )
                    )
            }
            .overlay {
                RoomQRFlipSheen(progress: roomQRSheenProgress)
                    .opacity(isRoomQRFlipping && !reduceMotion ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: SpyLobbyVisualLanguage.heroHeight)
            .scaleEffect(roomQRIsLifted ? 1.018 : 1)
            .offset(y: roomQRIsLifted ? -4 : 0)
            .shadow(
                color: SpyTheme.red.opacity(isRoomQRFlipping ? 0.16 : 0.05),
                radius: isRoomQRFlipping ? 24 : 12,
                y: isRoomQRFlipping ? 10 : 6
            )
            .brightness(isRoomQRFlipping ? Double(edgeProgress) * 0.025 : 0)
            .clipShape(CutCornerShape(cut: 12))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Button {
                flipRoomQR()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: SpyLobbyVisualLanguage.heroHeight)
                    .contentShape(CutCornerShape(cut: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onlineRoom.flipQR")
            .accessibilityLabel(
                isRoomQRVisible
                    ? localized(en: "Room \(targetTitle) QR visible. Tap the card to hide", ru: "\(targetTitle) QR комнаты открыт. Нажмите на карточку, чтобы скрыть", es: "QR \(targetTitle) visible. Toca la tarjeta para ocultar", uk: "QR кімнати \(targetTitle) відкрито. Натисніть на картку, щоб приховати")
                    : localized(en: "Room QR hidden. Tap the card to flip", ru: "QR комнаты скрыт. Нажмите на карточку, чтобы перевернуть", es: "QR oculto. Toca la tarjeta para girar", uk: "QR кімнати приховано. Натисніть на картку, щоб перевернути")
            )

            if isRoomQRVisible && !isRoomQRFlipping {
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color.white.opacity(0.64))
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.54), in: CutCornerShape(cut: 7))
                            .overlay(
                                CutCornerShape(cut: 7)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .contentShape(CutCornerShape(cut: 7))
                    }
                    .buttonStyle(SpyWebPressStyle(pressedScale: 0.95))
                    .accessibilityIdentifier("onlineRoom.openQR")
                    .accessibilityLabel(localized(en: "Open large \(targetTitle) room QR", ru: "Открыть большой \(targetTitle) QR комнаты", es: "Abrir QR \(targetTitle) grande", uk: "Відкрити великий QR кімнати \(targetTitle)"))

                    RoomQRTargetToggle(
                        target: roomQRTargetBinding,
                        language: appState.language,
                        width: 44,
                        controlHeight: 76,
                        axis: .vertical
                    )
                }
                .padding(.top, 38)
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SpyLobbyVisualLanguage.heroHeight)
    }

    private func onlineRoomRadarPage(_ room: GameRoom) -> some View {
        let columns = [
            GridItem(.flexible(minimum: 0), spacing: 8),
            GridItem(.flexible(minimum: 0), spacing: 8)
        ]

        return SpyLobbyHeroSurface {
            VStack(spacing: 0) {
                SpyLobbyHeroHeader(
                    title: "RADAR",
                    status: localized(en: "NEARBY", ru: "РЯДОМ", es: "CERCA", uk: "ПОРУЧ"),
                    count: roomRadar.peers.count,
                    statusAccent: roomRadarStatusColor
                )
                    .padding(.horizontal, 18)
                    .padding(.top, 15)

                Text(roomRadarStatusText)
                    .font(.system(size: 7.5, weight: .black, design: .monospaced))
                    .tracking(0.16)
                    .foregroundStyle(roomRadarStatusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
                    .padding(.horizontal, 18)
                    .contentTransition(.opacity)

                if case .unavailable = roomRadar.scanState {
                    RadarScanRecoveryPrompt(
                        language: appState.language,
                        retryAccessibilityIdentifier: "onlineRoom.retryRadar",
                        settingsAccessibilityIdentifier: "onlineRoom.openRadarSettings",
                        compact: true
                    ) {
                        HapticManager.shared.fire(.buttonPress)
                        appState.retryRadarScanning(requestCameraAccess: true)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                } else {
                    VStack(spacing: 0) {
                        if roomRadarNeedsRangefinderRecovery {
                            RadarRangefinderAccessPrompt(
                                language: appState.language,
                                state: roomRadarRecoveryState,
                                retryAccessibilityIdentifier: "onlineRoom.rangefinder.retry",
                                settingsAccessibilityIdentifier: "onlineRoom.rangefinder.openSettings",
                                compact: true
                            ) {
                                HapticManager.shared.fire(.buttonPress)
                                appState.retryRadarRangefinderAccess()
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 6)
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: columns, spacing: 8) {
                                if roomRadar.peers.isEmpty {
                                    ForEach(0..<4, id: \.self) { index in
                                        NearbySpyIDPlaceholder(
                                            index: index,
                                            isActive: roomAccessPage == RoomAccessPagePolicy.radar && index < 2,
                                            language: appState.language
                                        )
                                    }
                                } else {
                                    ForEach(roomRadar.peers) { peer in
                                        NearbySpyIDCard(
                                            peer: peer,
                                            language: appState.language,
                                            invitationState: roomRadar.invitationState(for: peer.id)
                                        ) {
                                            inviteRoomRadarPeer(peer, to: room)
                                        }
                                        .transition(.radarPeerPresence)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 30)
                            .animation(
                                reduceMotion
                                    ? .easeOut(duration: 0.14)
                                    : .spring(response: 0.48, dampingFraction: 0.88),
                                value: roomRadar.peers.map(\.id)
                            )
                        }
                        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                        .accessibilityIdentifier("onlineRoom.radarDirectory")
                    }
                }
            }
        }
        .clipShape(CutCornerShape(cut: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized(
            en: "Radar, \(roomRadar.peers.count) nearby operatives",
            ru: "Радар, игроков рядом: \(roomRadar.peers.count)",
            es: "Radar, agentes cercanos: \(roomRadar.peers.count)",
            uk: "Радар, гравців поруч: \(roomRadar.peers.count)"
        ))
    }

    private func onlineRoomFriendsPage(_ room: GameRoom) -> some View {
        SpyLobbyHeroSurface(accent: roomFriendsStatusColor) {
            VStack(spacing: 0) {
                SpyLobbyHeroHeader(
                    title: "FRIENDS",
                    status: roomFriendsStatusTitle,
                    count: roomFriendsDirectory.profiles.count,
                    accent: roomFriendsStatusColor,
                    statusAccent: roomFriendsStatusColor
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                roomFriendsDirectoryContent(room)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(CutCornerShape(cut: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineRoom.friendsDirectory")
        .accessibilityLabel(localized(
            en: "Friends, \(roomFriendsDirectory.profiles.count) accepted operatives",
            ru: "Друзья, принято оперативников: \(roomFriendsDirectory.profiles.count)",
            es: "Amigos, agentes aceptados: \(roomFriendsDirectory.profiles.count)",
            uk: "Друзі, прийнятих оперативників: \(roomFriendsDirectory.profiles.count)"
        ))
    }

    @ViewBuilder
    private func roomFriendsDirectoryContent(_ room: GameRoom) -> some View {
        switch roomFriendsDirectory.loadPhase {
        case .idle:
            roomFriendsStateMessage(
                systemImage: "person.2",
                title: localized(
                    en: "FRIEND DIRECTORY READY",
                    ru: "СПИСОК ДРУЗЕЙ ГОТОВ",
                    es: "DIRECTORIO DE AMIGOS LISTO",
                    uk: "СПИСОК ДРУЗІВ ГОТОВИЙ"
                ),
                detail: localized(
                    en: "OPENING SECURE CHANNEL",
                    ru: "ОТКРЫВАЕМ ЗАЩИЩЁННЫЙ КАНАЛ",
                    es: "ABRIENDO CANAL SEGURO",
                    uk: "ВІДКРИВАЄМО ЗАХИЩЕНИЙ КАНАЛ"
                ),
                accent: SpyTheme.muted
            )
            .accessibilityIdentifier("onlineRoom.friends.idle")

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(SpyTheme.red)

                Text(localized(
                    en: "LOADING ACCEPTED OPERATIVES",
                    ru: "ЗАГРУЖАЕМ ПРИНЯТЫХ ДРУЗЕЙ",
                    es: "CARGANDO AGENTES ACEPTADOS",
                    uk: "ЗАВАНТАЖУЄМО ПРИЙНЯТИХ ДРУЗІВ"
                ))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 24)
            .accessibilityIdentifier("onlineRoom.friends.loading")

        case .loaded:
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    ForEach(roomFriendsDirectory.profiles) { profile in
                        roomFriendInvitationRow(profile, room: room)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 31)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .accessibilityIdentifier("onlineRoom.friends.loaded")

        case .empty:
            roomFriendsStateMessage(
                systemImage: "person.2.slash",
                title: localized(
                    en: "NO ACCEPTED FRIENDS YET",
                    ru: "ПОКА НЕТ ПРИНЯТЫХ ДРУЗЕЙ",
                    es: "AÚN NO HAY AMIGOS ACEPTADOS",
                    uk: "ПРИЙНЯТИХ ДРУЗІВ ЩЕ НЕМАЄ"
                ),
                detail: localized(
                    en: "ADD OPERATIVES IN COMMUNITY FIRST",
                    ru: "СНАЧАЛА ДОБАВЬ ОПЕРАТИВНИКОВ В COMMUNITY",
                    es: "AÑADE AGENTES EN COMMUNITY PRIMERO",
                    uk: "СПОЧАТКУ ДОДАЙ ОПЕРАТИВНИКІВ У COMMUNITY"
                ),
                accent: SpyTheme.muted
            )
            .accessibilityIdentifier("onlineRoom.friends.empty")

        case .failed:
            VStack(spacing: 10) {
                roomFriendsStateMessage(
                    systemImage: "exclamationmark.triangle",
                    title: localized(
                        en: "FRIENDS COULD NOT LOAD",
                        ru: "НЕ УДАЛОСЬ ЗАГРУЗИТЬ ДРУЗЕЙ",
                        es: "NO SE PUDIERON CARGAR LOS AMIGOS",
                        uk: "НЕ ВДАЛОСЯ ЗАВАНТАЖИТИ ДРУЗІВ"
                    ),
                    detail: localized(
                        en: "CHECK THE CONNECTION AND RETRY",
                        ru: "ПРОВЕРЬ СОЕДИНЕНИЕ И ПОВТОРИ",
                        es: "REVISA LA CONEXIÓN Y REINTENTA",
                        uk: "ПЕРЕВІР З’ЄДНАННЯ ТА ПОВТОРИ"
                    ),
                    accent: SpyTheme.red
                )

                Button {
                    retryRoomFriendsLoad()
                } label: {
                    roomAccessActionLabel(
                        title: localized(
                            en: "RETRY",
                            ru: "ПОВТОРИТЬ",
                            es: "REINTENTAR",
                            uk: "ПОВТОРИТИ"
                        ),
                        systemImage: "arrow.clockwise",
                        accent: SpyTheme.red
                    )
                }
                .buttonStyle(SpyWebPressStyle())
                .frame(maxWidth: 150)
                .accessibilityIdentifier("onlineRoom.friends.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
            .accessibilityIdentifier("onlineRoom.friends.failed")
        }
    }

    private func roomFriendsStateMessage(
        systemImage: String,
        title: String,
        detail: String,
        accent: Color
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.08)
                .foregroundStyle(Color.white.opacity(0.74))
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.07)
                .foregroundStyle(SpyTheme.dim)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func roomFriendInvitationRow(
        _ profile: PublicSpyProfile,
        room: GameRoom
    ) -> some View {
        let invitationPhase = roomFriendsDirectory.invitationPhase(for: profile.id)
        let accent = roomFriendInvitationAccent(invitationPhase)

        return HStack(spacing: 10) {
            Text(profile.avatar)
                .font(.system(size: 21))
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.34), in: CutCornerShape(cut: 6))
                .overlay(CutCornerShape(cut: 6).stroke(SpyTheme.stroke, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.05)
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)

                Text("SPYID • \(profile.spyID)")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(SpyTheme.dim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RoomFriendInvitationButton(
                phase: invitationPhase,
                accent: accent,
                title: roomFriendInvitationTitle(invitationPhase),
                symbol: roomFriendInvitationSymbol(invitationPhase),
                accessibilityIdentifier: "onlineRoom.friendInvite.\(profile.id)",
                accessibilityLabel: localized(
                en: "Invite \(profile.displayName) to this room",
                ru: "Пригласить \(profile.displayName) в эту комнату",
                es: "Invitar a \(profile.displayName) a esta sala",
                uk: "Запросити \(profile.displayName) до цієї кімнати"
                ),
                accessibilityValue: roomFriendInvitationAccessibilityValue(invitationPhase)
            ) {
                beginRoomFriendInvitation(profile, room: room)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03), in: CutCornerShape(cut: 8))
        .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke.opacity(0.90), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineRoom.friend.\(profile.id)")
    }

    private var roomFriendsStatusColor: Color {
        switch roomFriendsDirectory.loadPhase {
        case .idle: SpyTheme.muted
        case .loading: SpyTheme.amber
        case .loaded: SpyTheme.green
        case .empty: SpyTheme.muted
        case .failed: SpyTheme.red
        }
    }

    private var roomFriendsStatusTitle: String {
        switch roomFriendsDirectory.loadPhase {
        case .idle:
            localized(en: "READY", ru: "ГОТОВО", es: "LISTO", uk: "ГОТОВО")
        case .loading:
            localized(en: "LOADING", ru: "ЗАГРУЗКА", es: "CARGANDO", uk: "ЗАВАНТАЖЕННЯ")
        case .loaded:
            localized(en: "ACCEPTED", ru: "ПРИНЯТЫ", es: "ACEPTADOS", uk: "ПРИЙНЯТІ")
        case .empty:
            localized(en: "EMPTY", ru: "ПУСТО", es: "VACÍO", uk: "ПОРОЖНЬО")
        case .failed:
            localized(en: "FAILED", ru: "ОШИБКА", es: "ERROR", uk: "ПОМИЛКА")
        }
    }

    private func roomFriendInvitationTitle(_ phase: RoomFriendInvitationPhase) -> String {
        switch phase {
        case .idle:
            localized(en: "INVITE", ru: "ПОЗВАТЬ", es: "INVITAR", uk: "ЗАПРОСИТИ")
        case .sending:
            localized(en: "SENDING", ru: "ОТПРАВКА", es: "ENVIANDO", uk: "НАДСИЛАННЯ")
        case .sent:
            localized(en: "SENT", ru: "ОТПРАВЛЕНО", es: "ENVIADO", uk: "НАДІСЛАНО")
        case .failed:
            localized(en: "RETRY", ru: "ПОВТОРИТЬ", es: "REINTENTAR", uk: "ПОВТОРИТИ")
        }
    }

    private func roomFriendInvitationSymbol(_ phase: RoomFriendInvitationPhase) -> String {
        switch phase {
        case .idle: "paperplane"
        case .sending: "paperplane"
        case .sent: "checkmark"
        case .failed: "arrow.clockwise"
        }
    }

    private func roomFriendInvitationAccent(_ phase: RoomFriendInvitationPhase) -> Color {
        switch phase {
        case .idle: SpyTheme.muted
        case .sending: SpyTheme.amber
        case .sent: SpyTheme.green
        case .failed: SpyTheme.red
        }
    }

    private func roomFriendInvitationAccessibilityValue(
        _ phase: RoomFriendInvitationPhase
    ) -> String {
        switch phase {
        case .idle:
            localized(en: "Ready", ru: "Готово", es: "Listo", uk: "Готово")
        case .sending:
            localized(en: "Sending", ru: "Отправляется", es: "Enviando", uk: "Надсилається")
        case .sent:
            localized(en: "Sent", ru: "Отправлено", es: "Enviado", uk: "Надіслано")
        case .failed:
            localized(en: "Failed, retry available", ru: "Ошибка, можно повторить", es: "Error, se puede reintentar", uk: "Помилка, можна повторити")
        }
    }

    private var roomRadarStatusColor: Color {
        if case .unavailable = roomRadar.scanState { return SpyTheme.red }
        if roomRadar.hasRecoverableRangingFailure { return SpyTheme.red }
        switch roomRadar.rangefinderAccessState {
        case .denied, .unavailable:
            return SpyTheme.red
        case .waitingForPeer, .ready, .requesting:
            return SpyTheme.amber
        case .granted, .unsupported:
            break
        }
        return roomRadar.peers.isEmpty ? SpyTheme.amber : SpyTheme.green
    }

    private var roomRadarNeedsRangefinderRecovery: Bool {
        if roomRadar.hasRecoverableRangingFailure { return true }
        return switch roomRadar.rangefinderAccessState {
        case .denied, .unavailable:
            true
        case .unsupported, .waitingForPeer, .ready, .requesting, .granted:
            false
        }
    }

    private var roomRadarRecoveryState: RadarRangefinderAccessState {
        guard roomRadar.hasRecoverableRangingFailure else {
            return roomRadar.rangefinderAccessState
        }
        switch roomRadar.rangefinderAccessState {
        case .denied, .unsupported, .unavailable:
            return roomRadar.rangefinderAccessState
        case .waitingForPeer, .ready, .requesting, .granted:
            return .unavailable
        }
    }

    private var roomRadarStatusText: String {
        if case .unavailable = roomRadar.scanState {
            return localized(
                en: "LOCAL SEARCH UNAVAILABLE",
                ru: "ЛОКАЛЬНЫЙ ПОИСК НЕДОСТУПЕН",
                es: "BÚSQUEDA LOCAL NO DISPONIBLE",
                uk: "ЛОКАЛЬНИЙ ПОШУК НЕДОСТУПНИЙ"
            )
        }
        if roomRadar.hasRecoverableRangingFailure,
           roomRadarRecoveryState == .unavailable {
            return localized(
                en: "RADAR ACTIVE · RANGEFINDER NEEDS RECONNECT",
                ru: "РАДАР АКТИВЕН · НУЖНО ПЕРЕПОДКЛЮЧИТЬ ДАЛЬНОМЕР",
                es: "RADAR ACTIVO · RECONECTA EL TELÉMETRO",
                uk: "РАДАР АКТИВНИЙ · ПЕРЕПІДКЛЮЧИ ДАЛЕКОМІР"
            )
        }
        switch roomRadar.rangefinderAccessState {
        case .waitingForPeer:
            return localized(
                en: "RADAR ACTIVE · SCANNING FOR DEVICES",
                ru: "РАДАР АКТИВЕН · ИЩЕМ УСТРОЙСТВА",
                es: "RADAR ACTIVO · BUSCANDO DISPOSITIVOS",
                uk: "РАДАР АКТИВНИЙ · ШУКАЄМО ПРИСТРОЇ"
            )
        case .ready:
            return localized(
                en: "RADAR ACTIVE · CONNECTING RANGEFINDER",
                ru: "РАДАР АКТИВЕН · ПОДКЛЮЧАЕМ ДАЛЬНОМЕР",
                es: "RADAR ACTIVO · CONECTANDO TELÉMETRO",
                uk: "РАДАР АКТИВНИЙ · ПІДКЛЮЧАЄМО ДАЛЕКОМІР"
            )
        case .requesting:
            return localized(
                en: "RADAR ACTIVE · WAITING FOR IOS",
                ru: "РАДАР АКТИВЕН · ЖДЁМ РАЗРЕШЕНИЕ IOS",
                es: "RADAR ACTIVO · ESPERANDO A IOS",
                uk: "РАДАР АКТИВНИЙ · ЧЕКАЄМО НА IOS"
            )
        case .denied:
            return localized(
                en: "RADAR ACTIVE · PRECISE DISTANCE IS OFF",
                ru: "РАДАР АКТИВЕН · ТОЧНАЯ ДИСТАНЦИЯ ВЫКЛЮЧЕНА",
                es: "RADAR ACTIVO · DISTANCIA PRECISA DESACTIVADA",
                uk: "РАДАР АКТИВНИЙ · ТОЧНУ ВІДСТАНЬ ВИМКНЕНО"
            )
        case .unavailable:
            return localized(
                en: "RADAR ACTIVE · RANGEFINDER NEEDS RECONNECT",
                ru: "РАДАР АКТИВЕН · НУЖНО ПЕРЕПОДКЛЮЧИТЬ ДАЛЬНОМЕР",
                es: "RADAR ACTIVO · RECONECTA EL TELÉMETRO",
                uk: "РАДАР АКТИВНИЙ · ПЕРЕПІДКЛЮЧИ ДАЛЕКОМІР"
            )
        case .granted, .unsupported:
            break
        }
        if roomRadar.peers.isEmpty {
            return localized(
                en: "SCANNING FOR OPEN SPYCLASH DEVICES",
                ru: "ИЩЕМ УСТРОЙСТВА С ОТКРЫТЫМ SPYCLASH",
                es: "BUSCANDO DISPOSITIVOS CON SPYCLASH",
                uk: "ШУКАЄМО ПРИСТРОЇ З ВІДКРИТИМ SPYCLASH"
            )
        }
        return localized(
            en: "TAP A SPYCARD TO SEND ROOM ACCESS",
            ru: "НАЖМИ SPYCARD, ЧТОБЫ ОТПРАВИТЬ ДОСТУП",
            es: "TOCA UNA SPYCARD PARA ENVIAR ACCESO",
            uk: "НАТИСНИ SPYCARD, ЩОБ НАДІСЛАТИ ДОСТУП"
        )
    }

    private func updateRoomRadarScanning(from previousPage: Int, to nextPage: Int) {
        if RoomAccessPagePolicy.shouldStopRadar(from: previousPage, to: nextPage) {
            roomRadar.stopScanning()
        }
        if RoomAccessPagePolicy.shouldStartRadar(on: nextPage) {
            appState.startRadarScanning(requestCameraAccess: true)
        }
    }

    private var initialRoomAccessPage: Int {
#if DEBUG
        if appState.shouldUsePreviewData,
           ProcessInfo.processInfo.arguments.contains("--spyclash-preview-room-access=friends") {
            return RoomAccessPagePolicy.friends
        }
        if appState.shouldUsePreviewData,
           ProcessInfo.processInfo.arguments.contains("--spyclash-preview-room-access=radar") {
            return RoomAccessPagePolicy.radar
        }
#endif
        return RoomAccessPagePolicy.roomCode
    }

    private func retryRoomFriendsLoad() {
        guard roomFriendsDirectory.loadPhase == .failed,
              currentRoomFriendsScope != nil else { return }
        HapticManager.shared.fire(.buttonPress)
        roomFriendsLoadAttempt &+= 1
    }

    @MainActor
    private func loadRoomFriends(for scope: RoomFriendsScope) async {
        guard scope.matches(
            accountUserID: appState.user?.id,
            roomID: appState.activeRoom?.id,
            page: roomAccessPage
        ) else { return }

        let requestID = UUID()
        guard roomFriendsDirectory.beginLoading(scope: scope, requestID: requestID) else { return }

        do {
            let communityState: CommunityState
#if DEBUG
            if appState.shouldUsePreviewData {
                await Task.yield()
                communityState = RoomFriendsPreviewData.state
            } else {
                communityState = try await appState.client.communityState()
            }
#else
            communityState = try await appState.client.communityState()
#endif

            guard !Task.isCancelled else {
                recoverCancelledRoomFriendsLoad(scope: scope, requestID: requestID)
                return
            }
            guard scope.matches(
                accountUserID: appState.user?.id,
                roomID: appState.activeRoom?.id,
                page: roomAccessPage
            ) else { return }
            _ = roomFriendsDirectory.receive(
                communityState,
                scope: scope,
                requestID: requestID
            )
        } catch is CancellationError {
            recoverCancelledRoomFriendsLoad(scope: scope, requestID: requestID)
            return
        } catch {
            guard scope.matches(
                accountUserID: appState.user?.id,
                roomID: appState.activeRoom?.id,
                page: roomAccessPage
            ) else { return }
            if roomFriendsDirectory.failLoading(scope: scope, requestID: requestID) {
                HapticManager.shared.fire(.notification(.error))
            }
        }
    }

    private func recoverCancelledRoomFriendsLoad(
        scope: RoomFriendsScope,
        requestID: UUID
    ) {
        guard scope.matches(
            accountUserID: appState.user?.id,
            roomID: appState.activeRoom?.id,
            page: roomAccessPage
        ), roomFriendsDirectory.cancelLoading(
            scope: scope,
            requestID: requestID
        ) else { return }
        roomFriendsLoadAttempt &+= 1
    }

    private func beginRoomFriendInvitation(
        _ profile: PublicSpyProfile,
        room: GameRoom
    ) {
        guard let scope = currentRoomFriendsScope else { return }
        let requestID = UUID()
        guard roomFriendsDirectory.beginInvitation(
            userID: profile.id,
            scope: scope,
            requestID: requestID
        ) else { return }

        HapticManager.shared.fire(.buttonPress)
        Task { @MainActor in
            await performRoomFriendInvitation(
                profile,
                room: room,
                scope: scope,
                requestID: requestID
            )
        }
    }

    @MainActor
    private func performRoomFriendInvitation(
        _ profile: PublicSpyProfile,
        room: GameRoom,
        scope: RoomFriendsScope,
        requestID: UUID
    ) async {
        do {
            let acknowledgement: CommunityActionAcknowledgement
#if DEBUG
            if appState.shouldUsePreviewData {
                try await Task.sleep(for: .milliseconds(420))
                acknowledgement = CommunityActionAcknowledgement(ok: true)
            } else {
                acknowledgement = try await appState.client.inviteCommunityOperative(
                    userID: profile.id,
                    room: room
                )
            }
#else
            acknowledgement = try await appState.client.inviteCommunityOperative(
                userID: profile.id,
                room: room
            )
#endif

            guard scope.matches(
                accountUserID: appState.user?.id,
                roomID: appState.activeRoom?.id,
                page: roomAccessPage
            ) else { return }

            if acknowledgement.ok {
                if roomFriendsDirectory.finishInvitation(
                    userID: profile.id,
                    scope: scope,
                    requestID: requestID
                ) {
                    HapticManager.shared.fire(.notification(.success))
                }
            } else if roomFriendsDirectory.failInvitation(
                userID: profile.id,
                scope: scope,
                requestID: requestID
            ) {
                HapticManager.shared.fire(.notification(.error))
            }
        } catch is CancellationError {
            return
        } catch {
            guard scope.matches(
                accountUserID: appState.user?.id,
                roomID: appState.activeRoom?.id,
                page: roomAccessPage
            ) else { return }
            if roomFriendsDirectory.failInvitation(
                userID: profile.id,
                scope: scope,
                requestID: requestID
            ) {
                HapticManager.shared.fire(.notification(.error))
            }
        }
    }

    private func inviteRoomRadarPeer(_ peer: RadarNearbyPeer, to room: GameRoom) {
        HapticManager.shared.fire(.buttonPress)

        Task { @MainActor in
            let result = await roomRadar.toggleInvitation(peer, to: room)
            guard roomAccessPage == RoomAccessPagePolicy.radar,
                  appState.activeRoom?.id == room.id else { return }

            switch result {
            case .sent:
                HapticManager.shared.fire(.navigation)
            case .cancelled:
                HapticManager.shared.fire(.buttonPress)
            case .blocked:
                HapticManager.shared.fire(.notification(.error))
            case .unavailable:
                HapticManager.shared.fire(.notification(.error))
            }
        }
    }

    private func flipRoomQR() {
        guard !isRoomQRFlipping else { return }

        HapticManager.shared.fire(.reveal)
        let revealsQR = !isRoomQRVisible
        let targetProgress = revealsQR ? 1.0 : 0.0
        let flipID = UUID()
        roomQRFlipID = flipID
        isRoomQRFlipping = true

        if reduceMotion {
            Task { @MainActor in
                await Task.yield()
                guard roomQRFlipID == flipID else { return }

                withAnimation(.easeOut(duration: 0.18)) {
                    roomQRFlipProgress = targetProgress
                }

                try? await Task.sleep(for: .milliseconds(180))
                guard roomQRFlipID == flipID else { return }
                isRoomQRVisible = revealsQR
                withAnimation(.easeOut(duration: 0.14)) {
                    isRoomQRFlipping = false
                }
            }
            return
        }

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            roomQRSheenProgress = revealsQR ? -1.12 : 1.12
        }

        withAnimation(.easeOut(duration: 0.09)) {
            roomQRIsLifted = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(45))
            guard roomQRFlipID == flipID else { return }

            withAnimation(.timingCurve(0.25, 0.75, 0.15, 1, duration: 0.58)) {
                roomQRFlipProgress = targetProgress
                roomQRSheenProgress = revealsQR ? 1.12 : -1.12
            }

            try? await Task.sleep(for: .milliseconds(290))
            guard roomQRFlipID == flipID else { return }
            isRoomQRVisible = revealsQR

            try? await Task.sleep(for: .milliseconds(290))
            guard roomQRFlipID == flipID else { return }

            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                roomQRIsLifted = false
            }

            try? await Task.sleep(for: .milliseconds(140))
            guard roomQRFlipID == flipID else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                isRoomQRFlipping = false
            }
        }
    }

    private func roomQRPayload(for room: GameRoom) -> String {
        appState.client
            .roomJoinURL(code: room.code, target: appState.roomQRTarget)
            .absoluteString
    }

    private func prepareRoomQRCode(payload: String) async {
        guard preparedRoomQR?.payload != payload else { return }

        let prepared = await Task.detached(priority: .userInitiated) {
            PreparedRoomQRCode(
                payload: payload,
                image: QRCodeFactory.image(from: payload)
            )
        }.value

        guard !Task.isCancelled, prepared.payload == payload else { return }
        preparedRoomQR = prepared
    }

    private func roomQRHiddenFace(_ room: GameRoom) -> some View {
        SpyLobbyHeroSurface {
            VStack(spacing: 0) {
                SpyLobbyHeroHeader(
                    title: localized(en: "QR INVITATION", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR", uk: "QR-ЗАПРОШЕННЯ"),
                    status: localized(en: "LIVE", ru: "В СЕТИ", es: "EN LINEA", uk: "У МЕРЕЖІ"),
                    count: room.playersList.count
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                Spacer(minLength: 6)

                ZStack {
                    RoomQRScanBeam(
                        isActive: roomAccessPage == RoomAccessPagePolicy.roomQR && !isRoomQRVisible && !isRoomQRFlipping
                    )

                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Color.white.opacity(0.46))
                        .shadow(color: SpyTheme.red.opacity(0.16), radius: 12)
                }
                .frame(width: 96, height: 76)

                VStack(spacing: 9) {
                    Text(qrHiddenTitle)
                        .font(SpyTheme.brandFont(size: 18))
                        .tracking(2.7)
                        .foregroundStyle(Color.white.opacity(0.86))

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, SpyTheme.red.opacity(0.72), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 46, height: 1)

                    Text(tapToFlipQR)
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .tracking(0.08)
                        .foregroundStyle(Color.white.opacity(0.34))
                }

                Spacer(minLength: 22)
            }
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private func roomQRVisibleFace(_ room: GameRoom, payload: String) -> some View {
        SpyLobbyHeroSurface {
            VStack(spacing: 0) {
                SpyLobbyHeroHeader(
                    title: localized(en: "QR INVITATION", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR", uk: "QR-ЗАПРОШЕННЯ"),
                    status: localized(en: "LIVE", ru: "В СЕТИ", es: "EN LINEA", uk: "У МЕРЕЖІ"),
                    count: room.playersList.count
                )
                .padding(.horizontal, 18)
                .padding(.top, 15)

                Spacer(minLength: 4)

                ZStack {
                    SpyTheme.dark

                    if let preparedRoomQR, preparedRoomQR.payload == payload {
                        Image(uiImage: preparedRoomQR.image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .accessibilityHidden(true)
                    } else {
                        SpySpinner(size: 26, accent: SpyTheme.red)
                    }
                }
                .frame(width: 158, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .spyQRCodeFrame(cut: 9, inset: 10)
                .accessibilityIdentifier("onlineRoom.qrCode")

                Spacer(minLength: 3)

                Text(localized(
                    en: appState.roomQRTarget == .web
                        ? "SCAN WITH ANY CAMERA · TAP TO HIDE"
                        : "OPENS IN SPYCLASH · TAP TO HIDE",
                    ru: appState.roomQRTarget == .web
                        ? "СКАНИРУЙ ЛЮБОЙ КАМЕРОЙ · ТАП — СКРЫТЬ"
                        : "ОТКРОЕТСЯ В SPYCLASH · ТАП — СКРЫТЬ",
                    es: appState.roomQRTarget == .web
                        ? "ESCANEA CON CUALQUIER CÁMARA · TOCA PARA OCULTAR"
                        : "ABRE EN SPYCLASH · TOCA PARA OCULTAR",
                    uk: appState.roomQRTarget == .web
                        ? "СКАНУЙ БУДЬ-ЯКОЮ КАМЕРОЮ · НАТИСНИ, ЩОБ ПРИХОВАТИ"
                        : "ВІДКРИЄТЬСЯ У SPYCLASH · НАТИСНИ, ЩОБ ПРИХОВАТИ"
                ))
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.05)
                .foregroundStyle(Color.white.opacity(0.38))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

                Spacer(minLength: 23)
            }
            .padding(.bottom, 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    private func roomAccessActionLabel(title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.05)
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.white.opacity(0.035), in: CutCornerShape(cut: 7))
            .overlay(CutCornerShape(cut: 7).stroke(accent.opacity(0.34), lineWidth: 1))
            .contentShape(CutCornerShape(cut: 7))
    }

    private var roomAccessPageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<RoomAccessPagePolicy.pageCount, id: \.self) { page in
                Capsule()
                    .fill(page == roomAccessPage ? SpyTheme.red : Color.white.opacity(0.20))
                    .frame(width: page == roomAccessPage ? 24 : 10, height: 3)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
            value: roomAccessPage
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func onlineModePanel(_ room: GameRoom) -> some View {
        let displayedMode = displayedGameMode(for: room)
        let accent = displayedMode == .questions ? SpyTheme.red : SpyTheme.amber
        let presentationSnapshot = lobbyPresentationSnapshot(for: room)

        return SpyLobbyPanel(accent: accent) {
            VStack(alignment: .leading, spacing: 14) {
                SpyLobbySectionHeader(
                    systemImage: "gearshape.fill",
                    title: localized(en: "GAME MODE", ru: "РЕЖИМ ИГРЫ", es: "MODO DE JUEGO", uk: "РЕЖИМ ГРИ")
                )

                HStack(spacing: 10) {
                    onlineModeOption(room, mode: .questions, symbol: "?")
                    onlineModeOption(room, mode: .associations, symbol: "💭")
                }
            }
        }
        .animation(
            remoteLobbyUpdateAnimation(for: room),
            value: presentationSnapshot
        )
    }

    private func onlineModeOption(_ room: GameRoom, mode: SpyGameMode, symbol: String) -> some View {
        let isSelected = displayedGameMode(for: room) == mode

        return SpyLobbyModeChoice(
            symbol: symbol,
            title: copy.modeTitle(mode),
            isSelected: isSelected,
            isEnabled: isHost(room),
            accessibilityIdentifier: "onlineRoom.mode.\(mode.rawValue)"
        ) {
            guard isHost(room), !isSelected else { return }
            HapticManager.shared.fire(.tabSelection)
            Task { await updateMode(room, mode: mode) }
        }
    }

    private func onlineSpySettingsPanel(_ room: GameRoom) -> some View {
        let spyCount = displayedSpyCount(for: room)
        let maximum = room.maximumLobbySpyCount
        let isMultiSpy = spyCount > 1
        let presentationSnapshot = lobbyPresentationSnapshot(for: room)

        return SpyLobbyPanel(accent: isMultiSpy ? SpyTheme.red : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SpyLobbySectionHeader(
                        systemImage: "person.crop.circle.badge.questionmark",
                        title: localized(en: "SPIES", ru: "ШПИОНЫ", es: "ESPIAS", uk: "ШПИГУНИ")
                    )
                    Spacer()
                    Text("\(spyCount)")
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundStyle(isMultiSpy ? SpyTheme.red : .white)
                        .contentTransition(.numericText())
                        .accessibilityHidden(true)
                }

                SpyWebSlider(
                    value: onlineSpyCountSliderValue(for: room),
                    range: 1...Double(maximum),
                    language: appState.language,
                    step: 1,
                    animatesProgrammaticChanges: !isHost(room),
                    onCommit: { committedValue in
                        guard isHost(room) else { return }
                        beginSpyCountUpdate(room, count: Int(committedValue.rounded()))
                    },
                    onCancel: {
                        isDraggingOnlineSpyCount = false
                        if !appState.hasOptimisticLobbySettingsChanges,
                           let currentRoom = appState.activeRoom {
                            selectedSpyCount = Double(currentRoom.lobbySpyCountValue)
                        }
                    },
                    onInteractionChanged: { isInteracting in
                        isDraggingOnlineSpyCount = isInteracting
                        if !isInteracting {
                            reconcileAuthoritativeLobbyStateAfterSliderInteraction()
                        }
                    },
                    accessibilityLabel: localized(
                        en: "Number of spies",
                        ru: "Количество шпионов",
                        es: "Numero de espias",
                        uk: "Кількість шпигунів"
                    ),
                    accessibilityIdentifier: "onlineRoom.spyCountSlider"
                )
                .disabled(!isHost(room) || maximum == 1)

                HStack {
                    Text("1")
                    Spacer()
                    Text("\(maximum)")
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
                .accessibilityHidden(true)

                Toggle(
                    isOn: Binding(
                        get: { displayedSpiesKnowEachOther(for: room) },
                        set: { newValue in
                            guard isHost(room) else { return }
                            updateSpiesKnowEachOther(room, enabled: newValue)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localized(
                            en: "SPIES KNOW EACH OTHER",
                            ru: "ШПИОНЫ ЗНАЮТ ДРУГ ДРУГА",
                            es: "LOS ESPIAS SE CONOCEN",
                            uk: "ШПИГУНИ ЗНАЮТЬ ОДИН ОДНОГО"
                        ))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        Text(localized(
                            en: "Off by default. Teammates appear only on a revealed spy card.",
                            ru: "По умолчанию выключено. Сообщники видны только на открытой карте шпиона.",
                            es: "Desactivado por defecto. Los aliados solo aparecen al revelar la carta.",
                            uk: "Типово вимкнено. Напарників видно лише на відкритій картці шпигуна."
                        ))
                        .font(.system(size: 9, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(SpyTheme.red)
                .disabled(!isHost(room))
                .accessibilityIdentifier("onlineRoom.spiesKnowEachOtherToggle")

                if isMultiSpy {
                    Text(localized(
                        en: "MULTI-SPY MATCH · UNRANKED",
                        ru: "НЕСКОЛЬКО ШПИОНОВ · БЕЗ РЕЙТИНГА",
                        es: "PARTIDA MULTIESPIA · SIN CLASIFICACION",
                        uk: "КІЛЬКА ШПИГУНІВ · БЕЗ РЕЙТИНГУ"
                    ))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.amber)
                }
            }
        }
        .animation(remoteLobbyUpdateAnimation(for: room), value: presentationSnapshot)
    }

    private func onlinePlayersPanel(_ room: GameRoom) -> some View {
        let missingPlayers = max(3 - room.playersList.count, 0)

        return SpyLobbyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                SpyLobbySectionHeader(
                    systemImage: "person.2.fill",
                    title: "\(localized(en: "PLAYERS", ru: "ИГРОКИ", es: "JUGADORES", uk: "ГРАВЦІ")) (\(room.playersList.count) / 3+)"
                )

                VStack(spacing: 8) {
                    ForEach(Array(room.playersList.enumerated()), id: \.element.id) { index, player in
                        onlinePlayerRow(player, index: index, room: room)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                if missingPlayers > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .black))
                        Text(copy.minimumOperatives(room.playersList.count))
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(0.02)
                            .spyFitted(lines: 2, scale: 0.62)
                        Spacer()
                    }
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .spyCutCard(cut: 8, fill: SpyTheme.red.opacity(0.05), stroke: SpyTheme.red.opacity(0.24))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: room.playersList.map(\.id))
    }

    private func onlinePlayerRow(_ player: Player, index: Int, room: GameRoom) -> some View {
        let isCurrentUser = player.email == appState.user?.email
        let isRoomHost = player.email == room.hostEmail
        let kickConfirmation = RoomKickPolicy.confirmation(
            for: player,
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )
        let kickPhase = roomKickCoordinator.phase(
            for: player,
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.78))
                .frame(width: 16)

            Text(player.avatar)
                .font(.system(size: 23))
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SpyTheme.strokeStrong.opacity(0.74), lineWidth: 1)
                }

            HStack(spacing: 8) {
                Text(player.name.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.56)

                Spacer(minLength: 4)

                if isRoomHost {
                    onlinePlayerBadge(copy.hostBadge, color: SpyTheme.red)
                } else if isCurrentUser {
                    onlinePlayerBadge(youLabel, color: SpyTheme.muted)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SpyTheme.strokeStrong.opacity(0.78), lineWidth: 1)
            }

            if kickConfirmation != nil {
                RoomKickButton(
                    phase: kickPhase,
                    accessibilityIdentifier: "onlineRoom.kick.\(roomPlayerAccessibilityKey(player.email))",
                    accessibilityLabel: roomKickAccessibilityLabel(
                        player: player,
                        phase: kickPhase
                    )
                ) {
                    requestRoomKick(player, room: room)
                }
            }
        }
    }

    private func onlinePlayerBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.06)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(color.opacity(0.07))
            .overlay(Rectangle().stroke(color.opacity(0.28), lineWidth: 1))
            .lineLimit(1)
    }

    private func roomKickAccessibilityLabel(
        player: Player,
        phase: RoomKickPhase
    ) -> String {
        switch phase {
        case .idle:
            localized(
                en: "Remove \(player.name) from room",
                ru: "Удалить \(player.name) из комнаты",
                es: "Expulsar a \(player.name) de la sala",
                uk: "Видалити \(player.name) з кімнати"
            )
        case .sending:
            localized(
                en: "Removing \(player.name)",
                ru: "Удаляем \(player.name)",
                es: "Expulsando a \(player.name)",
                uk: "Видаляємо \(player.name)"
            )
        case .failed:
            localized(
                en: "Retry removing \(player.name)",
                ru: "Повторить удаление \(player.name)",
                es: "Reintentar expulsar a \(player.name)",
                uk: "Повторити видалення \(player.name)"
            )
        }
    }

    private func roomPlayerAccessibilityKey(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }.reduce("") { $0 + String($1) }
    }

    private var onlineIntelPanel: some View {
        SpyLobbyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    SpyLobbySectionHeader(
                        systemImage: "paintpalette.fill",
                        title: localized(en: "THEME", ru: "ТЕМА", es: "TEMA", uk: "ТЕМА")
                    )
                    Spacer()
                    Text(localized(en: "AI INTEL", ru: "AI INTEL", es: "IA INTEL", uk: "AI-РОЗВІДКА"))
                        .font(.system(size: 10, weight: .black, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.62, alignment: .trailing)
                }

                roomThemeInput
                    .id(onlineThemeScrollTarget)

                roomThemeSuggestions

                if roomHasCustomTheme {
                    if !roomHasGeneratedTheme {
                        roomWordCountModeSelector
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    roomAnalyzeButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !roomHasCustomTheme {
                    roomPackSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if roomHasCustomTheme && roomHasGeneratedTheme {
                    Text(roomAIWarning)
                        .font(.system(size: 9, weight: .bold, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .lineSpacing(2)
                        .spyFitted(lines: 2, scale: 0.58)

                    roomWordsSlider
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    if roomThemeMaxWords < 200 {
                        roomExpandThemePoolButton
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if roomShouldShowPoolPreview {
                    roomPoolPreview
                }

                if roomGeneratedWords.count >= 2 && roomHasCustomTheme {
                    roomSaveAsWordPackButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.smooth(duration: 0.28), value: roomHasCustomTheme)
            .animation(.smooth(duration: 0.28), value: roomHasGeneratedTheme)
            .animation(.smooth(duration: 0.28), value: roomGeneratedPack)
        }
    }

    private func onlineGuestIntelPanel(_ room: GameRoom) -> some View {
        let presentationSnapshot = lobbyPresentationSnapshot(for: room)

        return SpyLobbyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                SpyLobbySectionHeader(
                    systemImage: "paintpalette.fill",
                    title: localized(en: "THEME", ru: "ТЕМА", es: "TEMA", uk: "ТЕМА")
                )
                if roomHasAuthoritativeLobbySelection(room) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((room.lobbySourceName?.nilIfBlank ?? room.lobbyTheme?.nilIfBlank ?? copy.waitingForHost).uppercased())
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        if let category = room.lobbyCategory?.nilIfBlank {
                            Text(category.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(SpyTheme.dim)
                                .contentTransition(.opacity)
                        }
                    }

                    roomPoolPreview(for: authoritativeRoomPoolSnapshot(from: room))
                } else {
                    HStack(spacing: 12) {
                        SpySpinner(size: 18, accent: SpyTheme.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(copy.waitingForHost)
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundStyle(SpyTheme.muted)
                            Text(copy.waitingForHostSignal)
                                .font(.system(size: 10, weight: .semibold, design: .default))
                                .foregroundStyle(SpyTheme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }
        }
        .animation(
            remoteLobbyUpdateAnimation(for: room),
            value: presentationSnapshot
        )
    }

    @ViewBuilder
    private func onlineControls(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            if isHost(room), room.playersList.count >= 3 {
                Button {
                    Task { await beginReadyCheck(room) }
                } label: {
                    SpyActionLabel(title: copy.readyCheckAction, systemImage: "checkmark.seal", tracking: 0.02, lines: 2)
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isStarting || !lobbySetupCanAdvance(room))
                .opacity(lobbySetupCanAdvance(room) ? 1 : 0.34)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("onlineRoom.readyCheck")
            } else {
                if !isHost(room) {
                    SpyLobbyPanel(accent: SpyTheme.muted, verticalPadding: 16) {
                        HStack(spacing: 12) {
                            SpySpinner(size: 18, accent: SpyTheme.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(copy.waitingForHost)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .foregroundStyle(SpyTheme.muted)
                                Text(copy.minimumOperatives(room.playersList.count))
                                    .font(.system(size: 9, weight: .semibold, design: .default))
                                    .foregroundStyle(SpyTheme.dim)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Button(role: .destructive) {
                Task { await leaveRoom(room) }
            } label: {
                SpyActionLabel(
                    title: isHost(room) ? closeRoomTitle : copy.leaveRoom,
                    systemImage: "chevron.left",
                    tracking: 0.02
                )
            }
            .buttonStyle(SpyButtonStyle(variant: .ghost))
            .accessibilityIdentifier("onlineRoom.leave")

            statusLine
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: room.playersList.count >= 3)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: userFacingStatus(status) ?? "")
    }

    private func onlineTimingPanel(_ room: GameRoom) -> some View {
        let displayedDuration = displayedDurationMinutes(for: room)
        let presentationSnapshot = lobbyPresentationSnapshot(for: room)

        return SpyLobbyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    SpyLobbySectionHeader(systemImage: "timer", title: copy.duration)
                    Spacer()
                    Text("\(Int(displayedDuration)) \(copy.minuteSuffix)")
                        .font(.system(size: 22, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.66, alignment: .trailing)
                        .contentTransition(.numericText())
                }

                SpyWebSlider(
                    value: onlineDurationSliderValue(for: room),
                    range: 1...15,
                    language: appState.language,
                    step: 1,
                    animatesProgrammaticChanges: !isHost(room),
                    onCommit: { committedValue in
                        guard isHost(room) else { return }
                        beginDurationUpdate(
                            room,
                            minutes: Int(committedValue.rounded())
                        )
                    },
                    onCancel: {
                        isDraggingOnlineDuration = false
                        if !appState.hasOptimisticLobbySettingsChanges,
                           let currentRoom = appState.activeRoom {
                            selectedDurationMinutes = Double(
                                max(1, min((currentRoom.gameDurationSeconds ?? 900) / 60, 15))
                            )
                        }
                    },
                    onInteractionChanged: { isInteracting in
                        isDraggingOnlineDuration = isInteracting
                        if !isInteracting {
                            reconcileAuthoritativeLobbyStateAfterSliderInteraction()
                        }
                    },
                    accessibilityIdentifier: "onlineRoom.durationSlider"
                )
                .disabled(!isHost(room))
            }
        }
        .animation(
            remoteLobbyUpdateAnimation(for: room),
            value: presentationSnapshot
        )
    }

    private func onlineRoomGlassCard<Content: View>(
        horizontalPadding: CGFloat = 20,
        verticalPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 20, y: 8)
    }

    private func onlineRoomCardTitle(
        systemImage: String,
        title: String,
        trailing: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .foregroundStyle(SpyTheme.dim)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(2.2)
        .foregroundStyle(.white.opacity(0.64))
    }

    private func roomSectionLabel(
        title: String,
        detail: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Rectangle()
                .fill(accent)
                .frame(width: 18, height: 2)
            Text(title)
                .foregroundStyle(.white.opacity(0.88))
            Spacer(minLength: 8)
            Text(detail)
                .foregroundStyle(accent)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.58)
        }
        .font(.system(size: 10, weight: .black, design: .monospaced))
        .tracking(0.07)
        .lineLimit(2)
        .padding(.top, 2)
    }

    private func missionSetupPanel(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            onlineRoomGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    onlineRoomCardTitle(
                        systemImage: "paintpalette",
                        title: roomThemeTitle,
                        trailing: allIncludedLabel
                    )

                    roomIntelSourceMenu

                    Button {
                        HapticManager.shared.fire(.tabSelection)
                        withAnimation(.smooth(duration: 0.24)) {
                            showsThemeBuilder.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SpyTheme.red)
                            Text(localized(en: "AI THEME BUILDER", ru: "AI-КОНСТРУКТОР ТЕМЫ", es: "CREADOR IA", uk: "AI-КОНСТРУКТОР ТЕМИ"))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1.4)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                                .minimumScaleFactor(0.64)
                            Spacer()
                            Image(systemName: showsThemeBuilder ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SpyTheme.dim)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.toggleThemeBuilder")

                    if showsThemeBuilder {
                        roomThemeBuilderCompact
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            onlineRoomGlassCard {
                roomDurationControl(room)
            }
        }
        .spyWebEntrance(delay: 0.10, duration: 0.45, y: 12)
    }

    private var roomIntelSourceMenu: some View {
        Menu {
            Button {
                selectRoomPack(nil)
                status = localized(en: "WORD PACK CLEARED", ru: "КОЛОДА НЕ ВЫБРАНА", es: "PACK NO SELECCIONADO", uk: "НАБІР СЛІВ НЕ ОБРАНО")
            } label: {
                Label(
                    localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado.", uk: "Не обрано."),
                    systemImage: "circle.dashed"
                )
            }

            ForEach(lobbyWordPacks) { pack in
                Button {
                    selectRoomPack(pack.id)
                    status = localized(en: "WORD PACK SELECTED", ru: "НАБОР СЛОВ ВЫБРАН", es: "PACK SELECCIONADO", uk: "НАБІР СЛІВ ОБРАНО")
                } label: {
                    Label(pack.name, systemImage: "shippingbox.fill")
                }
            }

            Button {
                withAnimation(.smooth(duration: 0.24)) {
                    showsThemeBuilder = true
                }
            } label: {
                Label(localized(en: "Build AI theme", ru: "Создать AI-тему", es: "Crear tema IA", uk: "Створити AI-тему"), systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedPackID == nil ? "circle.dashed" : "shippingbox.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SpyTheme.red)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.wordSource)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(SpyTheme.dim)
                    Text(selectedPackSummary)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SpyTheme.dim)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(isLoadingLobbyPacks)
        .accessibilityIdentifier("onlineRoom.intelSource")
    }

    private func roomDurationControl(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            onlineRoomCardTitle(
                systemImage: "timer",
                title: copy.duration,
                trailing: "\(Int(selectedDurationMinutes)) \(copy.minuteSuffix)"
            )

            HStack(spacing: 12) {
                durationStepButton(systemImage: "minus", enabled: selectedDurationMinutes > 1) {
                    beginDurationUpdate(room, minutes: Int(selectedDurationMinutes) - 1)
                }
                .accessibilityIdentifier("onlineRoom.durationDecrease")

                GeometryReader { proxy in
                    let fraction = (selectedDurationMinutes - 1) / 14
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 2)
                        Capsule()
                            .fill(SpyTheme.red)
                            .frame(width: proxy.size.width * fraction, height: 2)
                            .shadow(color: SpyTheme.red.opacity(0.55), radius: 5)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 36)

                durationStepButton(systemImage: "plus", enabled: selectedDurationMinutes < 15) {
                    beginDurationUpdate(room, minutes: Int(selectedDurationMinutes) + 1)
                }
                .accessibilityIdentifier("onlineRoom.durationIncrease")
            }

            HStack {
                Text("1 \(copy.minuteSuffix)")
                Spacer()
                Text("15 \(copy.minuteSuffix)")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(SpyTheme.dim.opacity(0.55))
        }
    }

    private func durationStepButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? .white.opacity(0.82) : SpyTheme.dim)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(enabled ? 0.05 : 0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(enabled ? Color.white.opacity(0.13) : Color.white.opacity(0.05), lineWidth: 1)
                }
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(!enabled)
    }

    private var roomThemeBuilderCompact: some View {
        VStack(alignment: .leading, spacing: 12) {
            roomThemeInput
            roomThemeSuggestions

            if roomHasCustomTheme && !roomHasGeneratedTheme {
                roomWordCountModeSelector
            }

            roomAnalyzeButton

            if roomHasGeneratedTheme, let generated = roomGeneratedPack {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(SpyTheme.green)
                    Text("\(generated.category.uppercased()) · \(roomGeneratedWords.count) \(copy.wordsSuffix)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                    Spacer()
                }
                .padding(10)
                .background(SpyTheme.green.opacity(0.06))
                .overlay(Rectangle().stroke(SpyTheme.green.opacity(0.24), lineWidth: 1))

                roomWordsSlider
                if roomShouldShowPoolPreview {
                    roomPoolPreview
                }
                roomExpandThemePoolButton
                roomSaveAsWordPackButton
            }
        }
    }

    private func guestMissionSummary(_ room: GameRoom) -> some View {
        onlineRoomGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                onlineRoomCardTitle(
                    systemImage: "doc.text",
                    title: localized(en: "MISSION BRIEF", ru: "ПАРАМЕТРЫ МИССИИ", es: "RESUMEN", uk: "ПАРАМЕТРИ МІСІЇ"),
                    trailing: copy.waitingForHost
                )
                HStack(spacing: 12) {
                    missionBriefValue(title: gameModeTitle, value: copy.modeTitle(room.gameModeValue), systemImage: "switch.2")
                    missionBriefValue(
                        title: copy.duration,
                        value: "\(max((room.gameDurationSeconds ?? 900) / 60, 1)) \(copy.minuteSuffix)",
                        systemImage: "timer"
                    )
                }
            }
        }
        .spyWebEntrance(delay: 0.10, duration: 0.45, y: 12)
    }

    private func missionBriefValue(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(SpyTheme.red)
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim)
            Text(value.uppercased())
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roomExitControl(_ room: GameRoom) -> some View {
        Button(role: .destructive) {
            Task { await leaveRoom(room) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left")
                Text(isHost(room) ? closeRoomTitle : copy.leaveRoom)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier("onlineRoom.leave")
    }

    private func waitingActionBar(_ room: GameRoom) -> some View {
        let actionMode = waitingStartActionMode(for: room)
        let actionTitle = waitingStartActionTitle(for: actionMode)
        let actionDetail = waitingStartActionDetail(for: actionMode, room: room)
        let usesAvailableAppearance = lobbyStartPrerequisitesAreMet(room)
        let canStart = lobbySetupCanAdvance(room)

        return SpyLobbyFooter {
            if isHost(room) {
                SpyLobbyActionRow {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        SpyLobbySecondaryActionLabel(
                            title: localized(en: "INVITE PLAYERS", ru: "ПРИГЛАСИТЬ ИГРОКОВ", es: "INVITAR JUGADORES", uk: "ЗАПРОСИТИ ГРАВЦІВ"),
                            systemImage: "person.badge.plus",
                            accessorySystemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(SpyLobbyFooterPressStyle())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(localized(en: "Invite players", ru: "Пригласить игроков", es: "Invitar jugadores", uk: "Запросити гравців"))
                    .accessibilityHint(localized(
                        en: "Opens code, QR, share, friends, and nearby radar options",
                        ru: "Открывает код, QR, отправку, друзей и поиск по радару",
                        es: "Abre codigo, QR, compartir, amigos y radar cercano",
                        uk: "Відкриває код, QR, надсилання, друзів і пошук через радар"
                    ))
                    .accessibilityIdentifier("onlineRoom.inviteMore")
                } trailing: {
                    Button {
                        Task { await start(room) }
                    } label: {
                        WaitingStartActionLabel(
                            mode: actionMode,
                            title: actionTitle,
                            detail: actionDetail,
                            usesAvailableAppearance: usesAvailableAppearance
                        )
                    }
                    .buttonStyle(SpyLobbyFooterPressStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(!canStart || isStarting)
                    .accessibilityLabel(actionTitle)
                    .accessibilityHint(actionDetail)
                    .accessibilityIdentifier("onlineRoom.startNow")
                }
            } else {
                HStack(spacing: 10) {
                    SpySpinner(size: 18, accent: SpyTheme.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(copy.waitingForHost)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(copy.minimumOperatives(room.playersList.count))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(SpyTheme.dim)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 58)
                .background(SpyTheme.card, in: CutCornerShape(cut: 9))
                .overlay(CutCornerShape(cut: 9).stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: canStart)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: isStarting)
    }

    private func webRoomCodePanel(_ room: GameRoom) -> some View {
        let inviteText = roomInviteText(room)

        return onlineRoomGlassCard(verticalPadding: 26) {
            VStack(spacing: 14) {
                Text(roomCodePlainLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(2.8)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))

                Button {
                    if isRoomCodeVisible {
                        HapticManager.shared.fire(.buttonPress)
                    } else {
                        HapticManager.shared.fire(.reveal)
                    }
                    withAnimation(.easeInOut(duration: 0.20)) {
                        isRoomCodeVisible.toggle()
                    }
                } label: {
                    ZStack {
                        if isRoomCodeVisible {
                            Text(room.code.uppercased())
                                .font(SpyTheme.brandFont(size: 52))
                                .tracking(9)
                                .foregroundStyle(SpyTheme.red)
                                .minimumScaleFactor(0.54)
                                .transition(.opacity)
                        } else {
                            Text("••••")
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .tracking(8)
                                .foregroundStyle(.white.opacity(0.76))
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .lineLimit(1)
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityLabel(localized(en: "Room code \(room.code)", ru: "Код комнаты \(room.code)", es: "Codigo de sala \(room.code)", uk: "Код кімнати \(room.code)"))

                Text(isRoomCodeVisible ? tapToHideRoomCode : tapToRevealRoomCode)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.7)
                    .foregroundStyle(SpyTheme.dim.opacity(0.48))

                HStack(spacing: 8) {
                    Button {
                        copyRoomCode(room)
                    } label: {
                        roomHeaderActionLabel(
                            title: copiedRoomCode ? roomCopiedTitle : roomCopyTitle,
                            systemImage: copiedRoomCode ? "checkmark" : "doc.on.doc",
                            accent: copiedRoomCode ? SpyTheme.green : .white.opacity(0.70)
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.copyCode")

                    ShareLink(item: inviteText) {
                        roomHeaderActionLabel(
                            title: localized(en: "SHARE", ru: "ОТПРАВИТЬ", es: "COMPARTIR", uk: "НАДІСЛАТИ"),
                            systemImage: "square.and.arrow.up",
                            accent: .white.opacity(0.70)
                        )
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        HapticManager.shared.fire(.buttonPress)
                    })
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.shareInvite")
                }
            }
        }
        .spyWebEntrance(delay: 0, duration: 0.45, y: 12)
    }

    private func roomAccessMenu(_ room: GameRoom) -> some View {
        Menu {
            Button {
                appState.presentedSheet = .roomQR(room)
            } label: {
                Label(localized(en: "Open QR", ru: "Открыть QR", es: "Abrir QR", uk: "Відкрити QR"), systemImage: "qrcode")
            }

            Button(role: .destructive) {
                Task { await leaveRoom(room) }
            } label: {
                Label(isHost(room) ? closeRoomTitle : copy.leaveRoom, systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(SpyTheme.muted)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("onlineRoom.accessMenu")
    }

    private func roomInviteText(_ room: GameRoom) -> String {
        localized(
            en: "Join my SpyClash room \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)",
            ru: "Присоединяйся к комнате SpyClash \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)",
            es: "Unete a mi sala SpyClash \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)",
            uk: "Приєднуйся до моєї кімнати SpyClash \(room.code.uppercased()): \(appState.client.roomJoinURL(code: room.code).absoluteString)"
        )
    }

    private func roomHeaderActionLabel(title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.58)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(accent.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func roomStageUtilityButton(
        title: String,
        systemImage: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.06)
                .foregroundStyle(accent)
                .spyFitted(lines: 2, scale: 0.60, alignment: .center)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.white.opacity(0.025))
                .overlay(Rectangle().stroke(accent.opacity(0.30), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private var hiddenRoomCodeDots: some View {
        HStack(spacing: 9) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index.isMultiple(of: 2) ? 0.82 : 0.52))
                    .frame(width: index.isMultiple(of: 3) ? 7 : 5, height: index.isMultiple(of: 3) ? 7 : 5)
                    .shadow(color: .white.opacity(0.35), radius: 5)
                    .offset(y: index.isMultiple(of: 2) ? -3 : 4)
            }
        }
    }

    private func webRoomQRPanel(_ room: GameRoom) -> some View {
        let payload = appState.client.roomJoinURL(code: room.code).absoluteString

        return onlineRoomGlassCard(verticalPadding: 24) {
            VStack(spacing: 16) {
                Text("// \(localized(en: "QR INVITATION", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR", uk: "QR-ЗАПРОШЕННЯ"))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2.8)
                    .foregroundStyle(SpyTheme.dim.opacity(0.70))

                Button {
                    appState.presentedSheet = .roomQR(room)
                } label: {
                    QRCodeImageView(payload: payload, cornerRadius: 2)
                        .frame(width: 204, height: 204)
                        .spyQRCodeFrame(cut: 8, inset: 7)
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityIdentifier("onlineRoom.openQR")
                .accessibilityLabel(localized(en: "Open large room QR", ru: "Открыть большой QR комнаты", es: "Abrir QR grande de la sala", uk: "Відкрити великий QR кімнати"))
            }
        }
        .spyWebEntrance(delay: 0.02, duration: 0.45, y: 12)
    }

    private func qrVisibleFace(payload: String) -> some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0, animatesEntrance: false) {
            VStack(spacing: 12) {
                QRCodeImageView(payload: payload, cornerRadius: 2)
                    .frame(width: 190, height: 190)
                    .spyQRCodeFrame(cut: 12, inset: 10)

                Text(webQRHint)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var qrHiddenFace: some View {
        SpyPanel(accent: SpyTheme.red, motionDelay: 0, animatesEntrance: false) {
            VStack(spacing: 10) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white.opacity(0.70))

                Text(qrHiddenTitle)
                    .font(.system(size: 13, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.muted)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)

                Text(tapToFlipQR)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                        }
            .frame(maxWidth: .infinity)
            .frame(height: 232)
            }
    }

    private func webWaitingRoomModePanel(_ room: GameRoom) -> some View {
        onlineRoomGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                onlineRoomCardTitle(systemImage: "gearshape", title: isHost(room) ? gameModeTitle : modeTitle)

                if isHost(room) {
                    HStack(spacing: 10) {
                        webModeButton(mode: .questions, selected: selectedGameMode == .questions) {
                            Task { await updateMode(room, mode: .questions) }
                        }
                        webModeButton(mode: .associations, selected: selectedGameMode == .associations) {
                            Task { await updateMode(room, mode: .associations) }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: room.gameModeValue == .questions ? "questionmark.bubble" : "bubble.left.and.bubble.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SpyTheme.red)
                        Text(copy.modeTitle(room.gameModeValue))
                            .font(SpyTheme.brandFont(size: 18))
                            .tracking(2)
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(scale: 0.58)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
            }
        }
        .spyWebEntrance(delay: 0.04, duration: 0.45, y: 12)
    }

    private func webModeButton(mode: SpyGameMode, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode == .questions ? "questionmark.bubble" : "bubble.left.and.bubble.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? .white.opacity(0.78) : SpyTheme.dim.opacity(0.72))

                Text(copy.modeTitle(mode))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .foregroundStyle(selected ? .white : SpyTheme.dim)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(selected ? SpyTheme.red : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? SpyTheme.red : Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(selected || isStarting)
        .accessibilityIdentifier("onlineRoom.mode.\(mode.rawValue)")
    }

    private func webPanelTitle(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .black))
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .default))
                .tracking(0.08)
                .spyFitted(lines: 2, scale: 0.68)
        }
        .foregroundStyle(SpyTheme.muted)
    }

    private func readyVotingRoom(_ room: GameRoom) -> some View {
        let isReady = currentUserIsReady(room)
        let readyCount = room.readyPlayers?.count ?? 0

        return VStack(alignment: .leading, spacing: 16) {
            roomCompactHeader(room)
            readyCheckPanel(room, isReady: isReady, readyCount: readyCount)
            readyRosterPanel(room)
            readyVotingControls(room)
            roomExitControl(room)
        }
    }

    private func readyBreadcrumb(_ room: GameRoom) -> some View {
        HStack(spacing: 8) {
            Text(localized(en: "HOME", ru: "ДОМ", es: "INICIO", uk: "ГОЛОВНА"))
                .foregroundStyle(SpyTheme.red)
            Text("//")
            Text(localized(en: "LOBBY", ru: "ЛОББИ", es: "SALA", uk: "ЛОБІ"))
            Text("//")
            Text(room.code.uppercased())
        }
        .font(.system(size: 10, weight: .black, design: .monospaced))
        .tracking(0.08)
        .foregroundStyle(SpyTheme.dim.opacity(0.58))
        .lineLimit(1)
        .minimumScaleFactor(0.74)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func rouletteRoom(_ room: GameRoom) -> some View {
        VStack(spacing: 18) {
            SpyPanel(accent: SpyTheme.red) {
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .stroke(SpyTheme.stroke, lineWidth: 1)
                            .frame(width: 230, height: 230)
                        Circle()
                            .trim(from: 0.08, to: 0.72)
                            .stroke(SpyTheme.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 230, height: 230)
                            .rotationEffect(.degrees(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: now)

                        VStack(spacing: 10) {
                            Text(rouletteTarget(room)?.avatar ?? "🕵️")
                                .font(.system(size: 58))
                            Text(rouletteTarget(room)?.name.uppercased() ?? copy.selecting)
                                .font(.system(size: 22, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                        }
                        .padding(28)
                    }
                    .frame(maxWidth: .infinity)

                    Text(copy.firstQuestionVector)
                        .font(.system(size: 10, weight: .bold, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.red)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                        .frame(maxWidth: 260)

                    Text(isHost(room) ? copy.armingFinalPayload : copy.waitingForHostSignal)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.muted)
                        .multilineTextAlignment(.center)
                        .spyFitted(lines: 2, scale: 0.72, alignment: .center)

                    statusLine
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 38)
        .task(id: "\(room.id)-\(room.rouletteTargetEmail ?? "")") {
            await completeRouletteIfNeeded(room)
        }
    }

    private func playingRoom(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if room.allRoleCardsRead {
                webActiveGamePhase(room)
            } else {
                webCardRevealPhase(room)
            }
        }
    }

    private func webActiveGamePhase(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            webPlayingHeader(room)
            webTimerStrip(room)

            if room.questionPhase == "results", !room.isVotingActive {
                votingPanel(room)
            } else {
                webTurnCard(room)
            }

            webActiveRoleCard(room)
            webEarlySpyGuessPanel(room)

            if !isTimeExpired(room) {
                if isCurrentUserSpectator(room), room.isVotingActive {
                    webSpectatorVotingPanel(room)
                } else if !isCurrentUserSpectator(room) {
                    webVoteRequestPanel(room)
                }
            }

            webAgentsStrip(room)

            if isCurrentUserSpectator(room) {
                webSpectatorBanner(room)
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private func webPlayingHeader(_ room: GameRoom) -> some View {
        HStack {
            Text("// \(localized(en: "PLAYING", ru: "ИГРА", es: "JUEGO", uk: "ГРА"))")
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.72)

            Spacer()

            roomActionsMenu(room)
        }
    }

    private func webTimerStrip(_ room: GameRoom) -> some View {
        let remaining = remainingSeconds(room)
        let urgent = remaining <= 60

        return HStack(spacing: 12) {
            Text(webTimeLeftTitle)
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.68)
                .layoutPriority(1)

            Spacer()

            Text(timeString(remaining))
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(urgent ? SpyTheme.red : SpyTheme.green)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(SpyTheme.dark, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    private func webAgentsStrip(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(webAgentsTitle) (\(room.activePlayers.count))")
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.72)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(room.playersList) { player in
                    let isOut = room.spectatorsList.contains(player.email)
                    let isAsker = player.email == room.currentAskerEmail
                    let isAnswerer = player.email == room.currentAnswererEmail
                    let isCurrent = player.email == appState.user?.email
                    HStack(spacing: 5) {
                        Text(isOut ? "👁" : player.avatar)
                            .font(.system(size: 16))
                        Text(compactPlayerName(player.name))
                            .font(.system(size: 10, weight: .bold, design: .default))
                            .foregroundStyle(isCurrent ? SpyTheme.green : (isOut ? SpyTheme.dim.opacity(0.45) : SpyTheme.muted))
                            .spyFitted(scale: 0.64)
                        if isCurrent {
                            Text(youLabel)
                                .font(.system(size: 8, weight: .black, design: .default))
                                .foregroundStyle(SpyTheme.green)
                                .spyFitted(scale: 0.58)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SpyTheme.control, in: Rectangle())
                    .overlay(Rectangle().stroke(isOut ? SpyTheme.red.opacity(0.28) : (isAsker || isAnswerer ? SpyTheme.red.opacity(0.38) : SpyTheme.stroke), lineWidth: 1))
                    .opacity(isOut ? 0.55 : 1)
                }
            }
        }
        .padding(12)
        .background(SpyTheme.dark, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.dim, edges: [.top, .leading])
        }
    }

    private func webActiveRoleCard(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            ZStack {
                if revealRole {
                    webRevealedRoleCard(
                        room,
                        isSpy: currentUserIsSpy(room),
                        isSpectator: isCurrentUserSpectator(room)
                    )
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else {
                    webHiddenRoleCard
                        .transition(.scale(scale: 1.03).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.80), value: revealRole)

            if revealRole {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        revealRole = false
                    }
                } label: {
                    SpyActionLabel(
                        title: localized(en: "HIDE CARD", ru: "СКРЫТЬ КАРТУ", es: "OCULTAR CARTA", uk: "ПРИХОВАТИ КАРТКУ"),
                        systemImage: "eye.slash.fill",
                        tracking: 0.02,
                        lines: 2
                    )
                }
                .buttonStyle(SpyButtonStyle(variant: .ghost))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func webSpectatorBanner(_ room: GameRoom) -> some View {
        let spies = room.spyPlayers

        return VStack(spacing: 7) {
            Text(copy.spectatorMode)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.68, alignment: .center)

            Text(spyTeamResult(spies))
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(SpyTheme.red)
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)

            Text(copy.wordResult(room.displayWord))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.06)
                .foregroundStyle(SpyTheme.dim.opacity(0.72))
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(SpyTheme.dark, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private func webTurnCard(_ room: GameRoom) -> some View {
        if room.gameModeValue == .associations {
            webAssociationTurnCard(room)
        } else {
            webQuestionTurnCard(room)
        }
    }

    private func webQuestionTurnCard(_ room: GameRoom) -> some View {
        let asker = player(for: room.currentAskerEmail, in: room)
        let answerer = player(for: room.currentAnswererEmail, in: room)

        return VStack(spacing: 14) {
            Text(webActivePairTitle)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.74, alignment: .center)

            HStack(spacing: 12) {
                webPairAgent(player: asker, label: copy.asker, color: SpyTheme.red)

                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(SpyTheme.red)
                    .symbolEffect(.pulse, options: .repeating)

                webPairAgent(player: answerer, label: copy.answer, color: .white)
            }

            Button {
                Task { await advance(room) }
            } label: {
                if isAdvancing {
                    SpySpinner(size: 20, accent: .white)
                } else {
                    SpyActionLabel(title: webNextPairTitle, systemImage: "forward.end.fill", tracking: 0.06)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: .outline))
            .disabled(isAdvancing || isCurrentUserSpectator(room))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(SpyTheme.card, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.red, edges: [.top, .leading])
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: SpyTheme.red, edges: [.bottom, .trailing])
        }
    }

    private func webAssociationTurnCard(_ room: GameRoom) -> some View {
        let speaker = player(for: room.currentAskerEmail, in: room)

        return VStack(spacing: 12) {
            Text(copy.associationDrum)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.74, alignment: .center)

            Text(speaker?.avatar ?? "🕵️")
                .font(.system(size: 56))

            Text(speaker?.name.uppercased() ?? copy.spinToStart)
                .font(.system(size: 22, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(SpyTheme.red)
                .spyFitted(scale: 0.58, alignment: .center)

            Text(copy.roundAssociation(room.roundNumber ?? 1))
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.62, alignment: .center)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(SpyTheme.card, in: Rectangle())
        .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: SpyTheme.red, edges: [.top, .leading])
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: SpyTheme.red, edges: [.bottom, .trailing])
        }
    }

    private func webPairAgent(player: Player?, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(player?.avatar ?? "🕵️")
                .font(.system(size: 40))

            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.10)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(scale: 0.72, alignment: .center)

            Text(player?.name.uppercased() ?? copy.pending)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(color)
                .spyFitted(scale: 0.54, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func webEarlySpyGuessPanel(_ room: GameRoom) -> some View {
        if currentUserIsSpy(room),
           revealRole,
           !isCurrentUserSpectator(room),
           !room.enabledWordPool.isEmpty,
           !isTimeExpired(room) {
            SpyPanel(accent: SpyTheme.red) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(webEarlyGuessTitle)
                        .font(SpyTheme.micro)
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.68)

                    Text(webEarlyGuessDescription)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(4)
                        .spyFitted(lines: 3, scale: 0.64)

                    Button {
                        showSpyGuess = true
                    } label: {
                        SpyActionLabel(title: webEarlyGuessButtonTitle, systemImage: "scope", tracking: 0.02, lines: 2)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(isSubmittingSpyGuess)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func webVoteRequestPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: room.isVotingActive ? SpyTheme.red : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                Text(webVoteTitle)
                    .font(SpyTheme.micro)
                    .tracking(0.02)
                    .foregroundStyle(room.isVotingActive ? SpyTheme.red : SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.68)

                if room.isVotingActive {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exclusionVoteRule(room))
                            .foregroundStyle(SpyTheme.red)
                        Text(exclusionVoteCancellationHint)
                            .foregroundStyle(SpyTheme.dim)
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .lineLimit(3)
                    .minimumScaleFactor(0.64)
                }

                if !room.isVotingActive {
                    Text(webVoteDescription(room))
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(4)
                        .spyFitted(lines: 3, scale: 0.62)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                        ForEach(room.activePlayers) { player in
                            voteRequestChip(player: player, requested: room.voteRequestsList.contains(player.email), current: player.email == appState.user?.email)
                        }
                    }

                    if hasCurrentUserRequestedVote(room) {
                        Text(webVoteRequestedTitle)
                            .font(.system(size: 11, weight: .black, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(SpyTheme.green)
                            .frame(maxWidth: .infinity)
                            .spyFitted(lines: 2, scale: 0.68, alignment: .center)
                    } else {
                        Button {
                            beginVoteRequest(room)
                        } label: {
                            if isRequestingVote {
                                SpySpinner(size: 20, accent: .white)
                            } else {
                                SpyActionLabel(title: webVoteRequestButtonTitle, systemImage: "megaphone.fill", tracking: 0.02, lines: 2)
                            }
                        }
                        .buttonStyle(SpyButtonStyle(variant: .outline))
                        .disabled(isRequestingVote)
                    }
                } else if let vote = myVote(in: room), let target = player(for: vote.votedForEmail, in: room) {
                    Text(copy.voteLocked(target.name))
                        .font(.system(size: 12, weight: .black, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.green)
                        .frame(maxWidth: .infinity)
                        .spyFitted(lines: 2, scale: 0.64, alignment: .center)
                } else {
                    Text(webVoteStartedTitle)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.text)
                        .lineSpacing(4)
                        .spyFitted(lines: 3, scale: 0.62)

                    VStack(spacing: 8) {
                        ForEach(votingCandidates(in: room)) { candidate in
                            Button {
                                beginDetectiveVote(room, targetEmail: candidate.email)
                            } label: {
                                voteCandidateRow(
                                    candidate,
                                    isPending: emailsMatch(
                                        pendingDetectiveVoteTargetEmail,
                                        candidate.email
                                    )
                                )
                            }
                            .buttonStyle(SpyButtonStyle(variant: .ghost))
                            .disabled(isCastingVote)
                        }
                    }
                }

                statusLine
            }
        }
    }

    private func webSpectatorVotingPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: SpyTheme.dim) {
            VStack(alignment: .leading, spacing: 12) {
                Text(webVotingInProgressTitle)
                    .font(SpyTheme.micro)
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.68)

                VStack(alignment: .leading, spacing: 4) {
                    Text(exclusionVoteRule(room))
                        .foregroundStyle(SpyTheme.red)
                    Text(exclusionVoteCancellationHint)
                        .foregroundStyle(SpyTheme.dim)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineLimit(3)
                .minimumScaleFactor(0.64)

                VStack(spacing: 8) {
                    ForEach(room.activePlayers) { player in
                        let votes = room.detectiveVotesList.filter { $0.votedForEmail == player.email }.count
                        HStack(spacing: 10) {
                            Text(player.avatar)
                                .font(.system(size: 19))
                                .frame(width: 30, height: 30)
                                .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 6))

                            Text(player.name.uppercased())
                                .font(.system(size: 12, weight: .black, design: .default))
                                .foregroundStyle(SpyTheme.muted)
                                .spyFitted(scale: 0.58)

                            Spacer()

                            if votes > 0 {
                                Text("▲ \(votes)")
                                    .font(.system(size: 11, weight: .black, design: .default))
                                    .foregroundStyle(SpyTheme.red)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(SpyTheme.control, in: CutCornerShape(cut: 9))
                        .overlay(
                            CutCornerShape(cut: 9)
                                .stroke(SpyTheme.stroke, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    private func voteRequestChip(player: Player, requested: Bool, current: Bool) -> some View {
        HStack(spacing: 5) {
            Text(requested ? "✓" : "·")
                .font(.system(size: 11, weight: .black, design: .default))
                .foregroundStyle(requested ? SpyTheme.green : SpyTheme.dim)

            Text(compactPlayerName(current ? youLabel : player.name))
                .font(.system(size: 10, weight: .black, design: .default))
                .foregroundStyle(requested ? SpyTheme.green : SpyTheme.dim)
                .spyFitted(scale: 0.58)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(requested ? SpyTheme.green.opacity(0.08) : SpyTheme.black.opacity(0.48), in: CutCornerShape(cut: 7))
        .overlay(
            CutCornerShape(cut: 7)
                .stroke(requested ? SpyTheme.green.opacity(0.28) : SpyTheme.stroke, lineWidth: 1)
        )
    }

    private func voteCandidateRow(_ candidate: Player, isPending: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(candidate.avatar)
                .font(.system(size: 21))
                .frame(width: 32, height: 32)

            Text(candidate.name.uppercased())
                .font(.system(size: 12, weight: .black, design: .default))
                .foregroundStyle(SpyTheme.text)
                .spyFitted(scale: 0.58)

            Spacer()

            if isPending {
                SpySpinner(size: 17, accent: SpyTheme.red)
            } else {
                Text(webVoteSpyQuestion)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func legacyPlayingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            if currentUserIsSpy(room), !room.enabledWordPool.isEmpty, !isTimeExpired(room) {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    showSpyGuess = true
                } label: {
                    SpyActionLabel(title: copy.guessWord, systemImage: "scope", tracking: 0.06)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isSubmittingSpyGuess || isCurrentUserSpectator(room))
            }

            Button {
                beginVoteRequest(room)
            } label: {
                if isRequestingVote {
                    SpySpinner(size: 20, accent: .white)
                } else {
                    SpyActionLabel(title: voteButtonTitle(room), systemImage: "checkmark.seal.fill", tracking: 0.02, lines: 2)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: room.isVotingActive ? .ghost : .outline))
            .disabled(isRequestingVote || hasCurrentUserRequestedVote(room) || isCurrentUserSpectator(room))

            statusLine
        }
    }

    private func webCardRevealPhase(_ room: GameRoom) -> some View {
        let email = appState.user?.email
        let isSpectator = email.map { room.spectatorsList.contains($0) } ?? false
        let isSpy = room.isSpy(email: email)
        let currentRead = currentUserHasReadCard(room)

        return VStack(spacing: 24) {
            Text(webCardPhaseTitle)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .frame(maxWidth: .infinity)
                .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                .padding(.top, 38)

            ZStack {
                if revealRole {
                    webRevealedRoleCard(room, isSpy: isSpy, isSpectator: isSpectator)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else {
                    webHiddenRoleCard
                        .transition(.scale(scale: 1.03).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.80), value: revealRole)

            if revealRole {
                if !currentRead {
                    Button {
                        Task { await markCardRead(room) }
                    } label: {
                        if isMarkingCardRead {
                            SpySpinner(size: 20, accent: .white)
                        } else {
                            Text(webReadyToPlayTitle)
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .tracking(0.08)
                                .spyFitted(lines: 2, scale: 0.52, alignment: .center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(isMarkingCardRead)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Text(webWaitingOthersTitle)
                        .font(.system(size: 11, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.green)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                        .transition(.opacity)
                }
            }

            webCardsReadPanel(room)

            statusLine
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var webHiddenRoleCard: some View {
        Button {
            HapticManager.shared.fire(.reveal)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                revealRole = true
            }
        } label: {
            VStack(spacing: 16) {
                Text("🃏")
                    .font(.system(size: 60))
                    .symbolEffect(.pulse, options: .repeating)

                Text(webTapToRevealRoleTitle)
                    .font(.system(size: 18, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .spyFitted(lines: 3, scale: 0.62, alignment: .center)

                Text(webDontShowOthersTitle)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))
                    .spyFitted(lines: 2, scale: 0.70, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .padding(.horizontal, 28)
            .background(SpyTheme.card, in: Rectangle())
            .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                cornerMark(color: SpyTheme.dim, edges: [.top, .leading])
            }
            .overlay(alignment: .bottomTrailing) {
                cornerMark(color: SpyTheme.dim, edges: [.bottom, .trailing])
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
    }

    private func webRevealedRoleCard(_ room: GameRoom, isSpy: Bool, isSpectator: Bool) -> some View {
        let accent = isSpectator ? SpyTheme.dim : (isSpy ? SpyTheme.red : SpyTheme.green)

        return VStack(spacing: 14) {
            Text(isSpy ? "🕵️" : "🔍")
                .font(.system(size: 52))

            Text(roleTitle(isSpy: isSpy, isSpectator: isSpectator))
                .font(.system(size: 24, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(accent)
                .spyFitted(lines: 2, scale: 0.58, alignment: .center)

            if isSpy || isSpectator {
                Text(roleSubtitle(isSpy: isSpy, isSpectator: isSpectator, room: room))
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
            } else {
                VStack(spacing: 8) {
                    Text(webSecretWordLabel)
                        .font(.system(size: 10, weight: .bold, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.dim.opacity(0.62))
                        .spyFitted(scale: 0.70, alignment: .center)

                    Text(room.displayWord?.uppercased() ?? copy.classified)
                        .font(.system(size: 40, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(lines: 2, scale: 0.44, alignment: .center)

                    Text("\(copy.categoryLabel.uppercased()): \(room.category?.uppercased() ?? copy.classicCategory)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.28)
                        .foregroundStyle(SpyTheme.dim.opacity(0.58))
                        .spyFitted(lines: 2, scale: 0.62, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background((isSpy ? SpyTheme.red : Color.white).opacity(isSpy ? 0.05 : 0.025), in: Rectangle())
        .overlay(Rectangle().stroke(accent.opacity(isSpy ? 0.35 : 0.22), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            cornerMark(color: accent, edges: [.top, .leading])
        }
        .overlay(alignment: .bottomTrailing) {
            cornerMark(color: accent, edges: [.bottom, .trailing])
        }
    }

    private func webCardsReadPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(webCardsReadTitle) \(room.activeCardsReadList.count)/\(room.activePlayers.count)")
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.70)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    ForEach(room.activePlayers) { player in
                        let isRead = room.cardsReadList.contains(player.email)
                        HStack(spacing: 6) {
                            Text(player.avatar)
                            Text(player.name.uppercased())
                                .spyFitted(scale: 0.58)
                            if isRead {
                                Text("✓")
                            }
                        }
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(0.04)
                        .foregroundStyle(isRead ? SpyTheme.green : SpyTheme.dim.opacity(0.62))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(isRead ? SpyTheme.green.opacity(0.06) : SpyTheme.black.opacity(0.42), in: Rectangle())
                        .overlay(Rectangle().stroke(isRead ? SpyTheme.green.opacity(0.25) : SpyTheme.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func cornerMark(color: Color, edges: Edge.Set) -> some View {
        ZStack {
            if edges.contains(.top) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if edges.contains(.bottom) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }

            if edges.contains(.leading) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if edges.contains(.trailing) {
                Rectangle()
                    .fill(color.opacity(0.92))
                    .frame(width: 1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func finishedRoom(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SpyPanel(accent: room.winner == "spy" ? SpyTheme.red : SpyTheme.green) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(copy.result)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker()
                    Text(room.winner == "spy" ? spyVictoryTitle(room) : copy.detectivesWin)
                        .font(.system(size: 34, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(room.winner == "spy" ? SpyTheme.red : SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.54)
                    Text(copy.wordResult(room.displayWord))
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.58)
                    if let spyGuess = FinishedRoomResultPolicy.wrongSpyGuess(in: room) {
                        Text(wrongSpyGuessResult(spyGuess))
                            .font(SpyTheme.micro)
                            .tracking(0.08)
                            .foregroundStyle(SpyTheme.amber)
                            .spyFitted(lines: 3, scale: 0.56)
                            .accessibilityIdentifier("onlineRoom.result.spyGuess")
                    }
                    if !room.spyPlayers.isEmpty {
                        Text(spyTeamResult(room.spyPlayers))
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(lines: 2, scale: 0.58)
                    }
                }
            }
            playersPanel(room)
            replayPanel(room)
            if FinishedRoomActionPolicy.showsIndependentLeaveRoom(
                hostEmail: room.hostEmail,
                currentUserEmail: appState.user?.email
            ) {
                Button {
                    Task { await leaveRoom(room) }
                } label: {
                    Label(copy.leaveRoom, systemImage: "house.fill")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .accessibilityIdentifier("onlineRoom.finished.leaveRoom")
            }
        }
    }

    private func wrongSpyGuessResult(_ guess: String) -> String {
        localized(
            en: "THE SPY GUESSED: \(guess.uppercased())",
            ru: "ШПИОН ДУМАЛ, ЧТО СЛОВО: \(guess.uppercased())",
            es: "EL ESPÍA PENSÓ QUE ERA: \(guess.uppercased())",
            uk: "ШПИГУН ДУМАВ, ЩО СЛОВО: \(guess.uppercased())"
        )
    }

    private func roomKeyPanel(_ room: GameRoom, showsMetrics: Bool = true) -> some View {
        SpyPanel(accent: room.normalizedStatus == "playing" ? SpyTheme.green : SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                            Text(roomBreadcrumb)
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                            .tracking(0.10)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(scale: 0.64)
                        Text(roomCodeLabel)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker(lines: 2)
                    }

                    Spacer()

                    roomActionsMenu(room)
                }

                Text(room.code)
                    .font(.system(size: 62, weight: .black, design: .monospaced))
                    .tracking(5.5)
                    .foregroundStyle(SpyTheme.red)
                    .minimumScaleFactor(0.46)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                Text(roomCodeShare)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if showsMetrics {
                    HStack(spacing: 10) {
                        metric(copy.activeMetric, "\(room.activePlayers.count)")
                        metric(copy.mode, copy.modeTitle(room.gameModeValue))
                        metric(copy.votesMetric, "\(room.activeVoteRequests.count)/\(room.voteThreshold)")
                    }
                }
            }
        }
    }

    private func roomActionsMenu(_ room: GameRoom) -> some View {
        Menu {
            Button {
                copyRoomCode(room)
            } label: {
                Label(copiedRoomCode ? roomCopiedTitle : roomCopyTitle, systemImage: copiedRoomCode ? "checkmark" : "doc.on.doc.fill")
            }

            Button {
                appState.presentedSheet = .roomQR(room)
            } label: {
                Label(localized(en: "QR INVITE", ru: "QR-ПРИГЛАШЕНИЕ", es: "INVITACIÓN QR", uk: "QR-ЗАПРОШЕННЯ"), systemImage: "qrcode")
            }

            if room.normalizedStatus == "ready_voting", isHost(room) {
                Button {
                    Task { await returnToWaiting(room) }
                } label: {
                    Label(copy.returnToLobby, systemImage: "arrow.uturn.left")
                }
                .disabled(isStarting)
            }

            Button(role: .destructive) {
                Task { await leaveRoom(room) }
            } label: {
                Label(isHost(room) ? closeRoomTitle : copy.leaveRoom, systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            HStack(spacing: 8) {
                roomStatePill(room)

                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(SpyTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(SpyTheme.dark)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .disabled(isStarting)
    }

    private func roomStatePill(_ room: GameRoom) -> some View {
        let isLive = room.normalizedStatus == "playing"
        let color = isLive ? SpyTheme.green : SpyTheme.red

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                Text(roomStateLabel(room))
                    .font(.system(size: 10, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(color)
                    .spyFitted(scale: 0.70)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(color.opacity(0.07))
        .overlay(Rectangle().stroke(color.opacity(0.22), lineWidth: 1))
    }

    private func roomCompactHeader(_ room: GameRoom) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(roomBreadcrumb)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.64)
                Text(room.code)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(SpyTheme.red)
            }

            Spacer()

            roomActionsMenu(room)
        }
        .padding(.vertical, 4)
    }

    private func readyCheckPanel(_ room: GameRoom, isReady: Bool, readyCount: Int) -> some View {
        SpyPanel(accent: SpyTheme.red) {
            VStack(spacing: 16) {
                Text(readyCheckingTitle)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.70, alignment: .center)

                Text(copy.areYouReady)
                    .font(.system(size: 20, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.62, alignment: .center)

                Button {
                    beginReadyToggle(room)
                } label: {
                    if isTogglingReady {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        Text(isReady
                            ? localized(en: "REMOVE READY", ru: "СНЯТЬ ГОТОВНОСТЬ", es: "QUITAR LISTO", uk: "ЗНЯТИ ГОТОВНІСТЬ")
                            : localized(en: "I'M READY", ru: "Я ГОТОВ", es: "ESTOY LISTO", uk: "Я ГОТОВИЙ"))
                            .font(.system(size: 13, weight: .black, design: .default))
                            .tracking(0.04)
                            .spyFitted(scale: 0.68, alignment: .center)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: isReady ? .red : .outline))
                .disabled(isTogglingReady)
                .accessibilityIdentifier("onlineRoom.toggleReady")

                Text("\(readyCount) / \(room.playersList.count) \(readyCountTitle)")
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim.opacity(0.72))
                    .spyFitted(scale: 0.70, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func readyRosterPanel(_ room: GameRoom) -> some View {
        let ready = Set(room.readyPlayers ?? [])

        return SpyPanel(accent: SpyTheme.muted) {
            VStack(alignment: .leading, spacing: 12) {
                Text(readyAgentsStatusTitle)
                    .font(.system(size: 10, weight: .bold, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.70)

                ForEach(room.playersList) { player in
                    readyPlayerRow(
                        player,
                        room: room,
                        isReady: ready.contains(player.email)
                    )
                }
            }
        }
    }

    private func readyPlayerRow(
        _ player: Player,
        room: GameRoom,
        isReady: Bool
    ) -> some View {
        let kickConfirmation = RoomKickPolicy.confirmation(
            for: player,
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )
        let kickPhase = roomKickCoordinator.phase(
            for: player,
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )

        return HStack(spacing: 12) {
            Text(player.avatar)
                .font(.system(size: 24))
                .frame(width: 34, height: 34)

            Text(player.name.uppercased())
                .font(.system(size: 12, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(.white.opacity(0.82))
                .spyFitted(scale: 0.56)

            Spacer()

            Text(isReady ? readyYesTitle : readyWaitingTitle)
                .font(.system(size: 10, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(isReady ? SpyTheme.green : SpyTheme.dim.opacity(0.50))
                .spyFitted(scale: 0.64, alignment: .trailing)

            if kickConfirmation != nil {
                RoomKickButton(
                    phase: kickPhase,
                    accessibilityIdentifier: "onlineRoom.kick.\(roomPlayerAccessibilityKey(player.email))",
                    accessibilityLabel: roomKickAccessibilityLabel(
                        player: player,
                        phase: kickPhase
                    )
                ) {
                    requestRoomKick(player, room: room)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(SpyTheme.dark, in: CutCornerShape(cut: 7))
        .overlay {
            CutCornerShape(cut: 7)
                .stroke(isReady ? SpyTheme.red.opacity(0.55) : SpyTheme.strokeStrong, lineWidth: 1)
        }
    }

    private func readyVotingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            if isHost(room) && allPlayersReady(room) {
                Button {
                    Task { await start(room) }
                } label: {
                    if isStarting {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        SpyActionLabel(title: copy.startGame, systemImage: "play.fill", tracking: 0.02)
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isStarting)
            }

            if isHost(room) {
                Button {
                    Task { await returnToWaiting(room) }
                } label: {
                    SpyActionLabel(title: copy.returnToLobby, systemImage: "arrow.uturn.left", tracking: 0.02)
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
                .disabled(isStarting)
                .accessibilityIdentifier("onlineRoom.returnToLobby")
            }

            statusLine
        }
    }

    private func lobbyConfigurationPanel(_ room: GameRoom) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if isHost(room) {
                webThemeSourcePanel
                webDurationPanel
            } else {
                SpyPanel(accent: SpyTheme.muted, motionDelay: 0.10) {
                    HStack(spacing: 12) {
                        SpySpinner(size: 22, accent: SpyTheme.red)

                        VStack(alignment: .leading, spacing: 5) {
                            webPanelTitle(systemImage: "hourglass", title: copy.waitingForHost)
                            Text(copy.waitingForHostSignal)
                                .font(.system(size: 12, weight: .semibold, design: .default))
                                .tracking(0.02)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 2, scale: 0.68)
                        }

                        Spacer()
                    }
                }
            }
        }
    }

    private var webThemeSourcePanel: some View {
        SpyPanel(accent: SpyTheme.muted, motionDelay: 0.10) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    webPanelTitle(systemImage: "paintpalette.fill", title: roomThemeTitle)
                    Spacer()
                    Text(allIncludedLabel)
                        .font(.system(size: 10, weight: .black, design: .default))
                        .tracking(0.08)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.62, alignment: .trailing)
                }

                roomThemeInput
                roomThemeSuggestions

                if roomHasCustomTheme && !roomHasGeneratedTheme {
                    roomWordCountModeSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                roomAnalyzeButton

                if !roomHasCustomTheme {
                    roomPackSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if roomHasCustomTheme && roomHasGeneratedTheme {
                    Text(roomAIWarning)
                        .font(.system(size: 9, weight: .bold, design: .default))
                        .tracking(0.02)
                        .foregroundStyle(SpyTheme.dim)
                        .lineSpacing(2)
                        .spyFitted(lines: 2, scale: 0.58)

                    roomWordsSlider
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    if roomThemeMaxWords < 200 {
                        roomExpandThemePoolButton
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                if roomShouldShowPoolPreview {
                    roomPoolPreview
                }

                if roomGeneratedWords.count >= 2 && roomHasCustomTheme {
                    roomSaveAsWordPackButton
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.smooth(duration: 0.26), value: roomHasCustomTheme)
            .animation(.smooth(duration: 0.26), value: roomHasGeneratedTheme)
            .animation(.smooth(duration: 0.26), value: roomGeneratedPack)
        }
    }

    private var roomThemeInput: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(focusedOnlineSetupField == .theme ? SpyTheme.red : SpyTheme.dim)
                .frame(width: 18)

            TextField("", text: roomThemeDraftBinding, prompt: Text(roomThemePlaceholder).foregroundStyle(SpyTheme.dim))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .font(SpyTheme.mono)
                .tracking(0.04)
                .foregroundStyle(.white)
                .tint(SpyTheme.red)
                .focused($focusedOnlineSetupField, equals: .theme)
                .onSubmit {
                    dismissOnlineSetupCapture()
                }
                .accessibilityIdentifier("onlineRoom.themeInput")

            if roomHasCustomTheme {
                Button {
                    withAnimation(.smooth(duration: 0.20)) {
                        setRoomThemeDraft("")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SpyTheme.dim)
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(SpyWebPressStyle())
                .spyHitTarget()
                .accessibilityLabel(localized(en: "Clear theme", ru: "Очистить тему", es: "Limpiar tema", uk: "Очистити тему"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 9))
        .overlay(
            CutCornerShape(cut: 9)
                .stroke(
                    focusedOnlineSetupField == .theme ? SpyTheme.red.opacity(0.86) : SpyTheme.inputBorder,
                    lineWidth: 1
                )
        )
        .shadow(color: focusedOnlineSetupField == .theme ? SpyTheme.red.opacity(0.12) : .clear, radius: 8)
        .animation(.smooth(duration: 0.18), value: focusedOnlineSetupField == .theme)
    }

    private var roomThemeSuggestions: some View {
        AIThemeSuggestionStrip(
            language: appState.language,
            selectedTheme: roomTheme,
            accessibilityIdentifier: "onlineRoom.themeSuggestions"
        ) { suggestion in
            selectOnlineThemeSuggestion(suggestion)
        }
    }

    private func selectOnlineThemeSuggestion(_ suggestion: String) {
        dismissOnlineSetupCapture()
        setRoomThemeDraft(suggestion)
    }

    private var roomWordCountModeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(RoomWordCountMode.allCases) { mode in
                    let isActive = roomWordCountMode == mode
                    Button {
                        withAnimation(.smooth(duration: 0.18)) {
                            roomWordCountMode = mode
                        }
                        scheduleLobbyStateSync(debounce: .milliseconds(120))
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: mode == .recommended ? "wand.and.stars" : "slider.horizontal.3")
                                .font(.system(size: 13, weight: .black))
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(roomWordCountModeTitle(mode))
                                    .font(.system(size: 10.5, weight: .black, design: .default))
                                    .tracking(0.02)
                                    .spyFitted(lines: 1, scale: 0.58)
                                Text(roomWordCountModeHint(mode))
                                    .font(.system(size: 9.5, weight: .bold, design: .default))
                                    .tracking(0.02)
                                    .foregroundStyle(isActive ? Color.white.opacity(0.70) : SpyTheme.dim)
                                    .spyFitted(lines: 1, scale: 0.58)
                            }

                            Spacer(minLength: 0)

                            if isActive {
                                Circle()
                                    .fill(SpyTheme.green)
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .foregroundStyle(isActive ? SpyTheme.red : SpyTheme.muted)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(isActive ? SpyTheme.red.opacity(0.10) : SpyTheme.dark.opacity(0.76), in: CutCornerShape(cut: 7))
                        .overlay(CutCornerShape(cut: 7).stroke(isActive ? SpyTheme.red.opacity(0.55) : SpyTheme.strokeStrong.opacity(0.78), lineWidth: 1))
                        .contentShape(CutCornerShape(cut: 7))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }

            if roomWordCountMode == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(roomCountLabel)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker()
                        Spacer()
                        Text("\(Int(roomCustomWordCount)) / 80")
                            .font(.system(size: 15, weight: .black, design: .default))
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(scale: 0.66, alignment: .trailing)
                    }

                    SpyWebSlider(
                        value: $roomCustomWordCount,
                        range: 10...80,
                        language: appState.language,
                        step: 1,
                        onCommit: { committedValue in
                            isDraggingOnlineWordCount = false
                            reconcileAuthoritativeLobbyStateAfterSliderInteraction()
                            roomCustomWordCount = committedValue
                            scheduleLobbyStateSync(debounce: .milliseconds(160))
                        },
                        onInteractionChanged: { isInteracting in
                            isDraggingOnlineWordCount = isInteracting
                            if !isInteracting {
                                reconcileAuthoritativeLobbyStateAfterSliderInteraction()
                            }
                        }
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(SpyTheme.dark.opacity(0.86), in: CutCornerShape(cut: 7))
                .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.strokeStrong.opacity(0.72), lineWidth: 1))
            }
        }
    }

    private var roomAnalyzeButton: some View {
        Button {
            dismissOnlineSetupCapture()
            Task {
                await generateRoomTheme(usingInitialTarget: !roomHasGeneratedTheme)
            }
        } label: {
            if roomThemeOperation == .generate {
                SpyLoadingLabel(title: roomThemeActionTitle, accent: .white)
                    .frame(height: 52)
            } else {
                SpyActionLabel(
                    title: roomThemeActionTitle,
                    systemImage: roomThemeActionIcon,
                    tracking: 0.02,
                    lines: 2
                )
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .disabled(!roomHasCustomTheme || isGeneratingRoomTheme)
        .opacity(roomHasCustomTheme ? 1 : 0.42)
    }

    private var roomPackSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lobbyPackLoadState == .idle || isLoadingLobbyPacks {
                HStack(spacing: 10) {
                    SpySpinner(size: 16, accent: SpyTheme.red)
                    Text(localized(en: "LOADING WORD PACKS", ru: "ЗАГРУЗКА КОЛОД", es: "CARGANDO PACKS", uk: "ЗАВАНТАЖЕННЯ НАБОРІВ СЛІВ"))
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(0.04)
                        .foregroundStyle(SpyTheme.dim)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 12)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
            } else if let roomPackLoadError {
                VStack(alignment: .leading, spacing: 9) {
                    Text(localized(en: "COULDN'T LOAD YOUR DECKS", ru: "НЕ УДАЛОСЬ ЗАГРУЗИТЬ КОЛОДЫ", es: "NO SE PUDIERON CARGAR LOS PACKS", uk: "НЕ ВДАЛОСЯ ЗАВАНТАЖИТИ НАБОРИ"))
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                    Text(roomPackLoadError)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .lineLimit(2)
                    Button {
                        Task { await loadLobbyWordPacks(force: true) }
                    } label: {
                        Label(
                            localized(en: "TRY AGAIN", ru: "ПОВТОРИТЬ", es: "REINTENTAR", uk: "ПОВТОРИТИ"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(SpyTheme.red.opacity(0.06), in: CutCornerShape(cut: 7))
                        .overlay(CutCornerShape(cut: 7).stroke(SpyTheme.red.opacity(0.38), lineWidth: 1))
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.retryWordPacks")
                }
                .padding(12)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.red.opacity(0.28), lineWidth: 1))
            } else if lobbyWordPacks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SpyTheme.dim)
                    Text(localized(
                        en: "You haven't created any decks.",
                        ru: "Вы не создавали своих колод.",
                        es: "No has creado ningun pack.",
                        uk: "Ви ще не створили жодного набору."
                    ))
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(SpyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .background(SpyTheme.dark, in: CutCornerShape(cut: 8))
                .overlay(CutCornerShape(cut: 8).stroke(SpyTheme.stroke, lineWidth: 1))
                .accessibilityIdentifier("onlineRoom.noSavedWordPacks")
            } else {
                Text("\(localized(en: "WORD PACKS", ru: "КОЛОДЫ", es: "PACKS", uk: "НАБОРИ СЛІВ")) \(lobbyWordPacks.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.62)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
                    roomPackOption(
                        id: nil,
                        title: localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado.", uk: "Не обрано."),
                        subtitle: nil,
                        accessibilityIdentifier: "onlineRoom.noPackSource"
                    ) {
                        selectRoomPack(nil)
                    }

                    ForEach(lobbyWordPacks) { pack in
                        roomPackOption(
                            id: pack.id,
                            title: pack.name,
                            subtitle: "\(pack.words?.roomCleanWords.count ?? 0)",
                        ) {
                            selectRoomPack(pack.id)
                        }
                    }
                }
            }
        }
        .disabled(isLoadingLobbyPacks)
        .opacity(isLoadingLobbyPacks ? 0.58 : 1)
    }

    private func roomPackOption(
        id: String?,
        title: String,
        subtitle: String?,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = selectedPackID == id

        return Button(action: action) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(0.02)
                    .spyFitted(lines: 2, scale: 0.68, alignment: .center)

                if let subtitle {
                    Text("(\(subtitle))")
                        .font(.system(size: 10, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.dim)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? SpyTheme.red : SpyTheme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(isSelected ? SpyTheme.red.opacity(0.06) : SpyTheme.dark)
            .overlay(Rectangle().stroke(isSelected ? SpyTheme.red.opacity(0.50) : SpyTheme.strokeStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SpyWebPressStyle())
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private var roomWordsSlider: some View {
        let maxWords = roomThemeMaxWords
        let selectedWords = min(Int(roomWordCount), activeRoomWords(roomGeneratedPack?.words ?? []).count)
        let lowerBound = Double(min(5, maxWords))
        let upperBound = Double(maxWords)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(roomWordsLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Spacer()
                Text("\(selectedWords) / \(maxWords)")
                    .font(.system(size: 16, weight: .black, design: .default))
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.66, alignment: .trailing)
            }

            Text(roomThemeMetaLabel(maxWords: maxWords))
                .font(.system(size: 9, weight: .bold, design: .default))
                .tracking(0.02)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.60)

            SpyWebSlider(
                value: $roomWordCount,
                range: lowerBound...upperBound,
                language: appState.language,
                step: 1,
                accent: SpyTheme.red,
                onCommit: { committedValue in
                    isDraggingOnlineWordCount = false
                    reconcileAuthoritativeLobbyStateAfterSliderInteraction()
                    roomWordCount = committedValue
                    scheduleLobbyStateSync(debounce: .milliseconds(120))
                },
                onInteractionChanged: { isInteracting in
                    isDraggingOnlineWordCount = isInteracting
                    if !isInteracting {
                        reconcileAuthoritativeLobbyStateAfterSliderInteraction()
                    }
                }
            )
            .disabled(lowerBound == upperBound)
        }
        .padding(12)
        .background(SpyTheme.panelDeep, in: CutCornerShape(cut: 8))
        .overlay(CutCornerShape(cut: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private var roomExpandThemePoolButton: some View {
        Button {
            Task { await pushRoomThemeMax() }
        } label: {
            if roomThemeOperation == .expand {
                SpyLoadingLabel(title: roomAddMoreWordsLabel, accent: SpyTheme.amber)
                    .frame(height: 50)
            } else {
                SpyActionLabel(
                    title: roomAddMoreWordsLabel,
                    systemImage: "plus.circle.fill",
                    fontSize: 10,
                    iconSize: 13,
                    tracking: 0.02,
                    lines: 2
                )
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .outline))
        .disabled(isGeneratingRoomTheme || roomThemeMaxWords >= 200)
        .accessibilityIdentifier("onlineRoom.addMoreThemeWords")
    }

    @ViewBuilder
    private var roomPoolPreview: some View {
        roomPoolPreview(for: roomPoolSnapshot)
    }

    @ViewBuilder
    private func roomPoolPreview(for snapshot: RoomPoolSnapshot?) -> some View {
        if let snapshot,
           LobbyPresentationPolicy.shouldShowPoolPreview(
               totalWordCount: snapshot.words.count
           ) {
            roomPoolPreviewCard(snapshot)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func roomPoolPreviewCard(_ snapshot: RoomPoolSnapshot) -> some View {
        let collapsedWordLimit = 8
        let compactWords = Array(snapshot.words.prefix(collapsedWordLimit))
        let additionalWords = Array(snapshot.words.dropFirst(collapsedWordLimit))
        let canToggleWordList = snapshot.words.count > collapsedWordLimit

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(roomPoolPreviewLabel)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker()
                    Text(snapshot.category.uppercased())
                        .font(.system(size: 18, weight: .black, design: .default))
                        .tracking(0.04)
                        .foregroundStyle(.white)
                        .spyFitted(lines: 2, scale: 0.56)
                        .contentTransition(.opacity)
                }

                Spacer()

                Text(snapshot.countLabel)
                    .font(SpyTheme.micro)
                    .tracking(0.10)
                    .foregroundStyle(SpyTheme.green)
                    .spyFitted(scale: 0.62, alignment: .trailing)
                    .contentTransition(.numericText())
            }

            roomPoolWordGrid(
                compactWords,
                disabledWordKeys: snapshot.disabledWordKeys
            )

            if showsAllRoomPoolWords {
                roomPoolWordGrid(
                    additionalWords,
                    disabledWordKeys: snapshot.disabledWordKeys
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Text(snapshot.source.uppercased())
                    .font(.system(size: 9, weight: .black, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(scale: 0.50)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(SpyTheme.dark)
                    .overlay(Rectangle().stroke(SpyTheme.stroke, lineWidth: 1))
                    .contentTransition(.opacity)

                Spacer()
            }

            if canToggleWordList {
                Button {
                    HapticManager.shared.fire(.tabSelection)
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        showsAllRoomPoolWords.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(showsAllRoomPoolWords ? roomShowLessWordsLabel : roomShowAllWordsLabel(snapshot.words.count))
                        Spacer(minLength: 8)
                        Image(systemName: showsAllRoomPoolWords ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .black))
                    }
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.02)
                    .foregroundStyle(SpyTheme.muted)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
                    .background(SpyTheme.panelDeep)
                    .overlay(Rectangle().stroke(SpyTheme.strokeStrong, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
                .accessibilityIdentifier("onlineRoom.toggleAllThemeWords")
            }
        }
        .padding(12)
        .background(SpyTheme.dark)
        .overlay(
            Rectangle()
                .stroke(SpyTheme.green.opacity(0.14), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(SpyTheme.green.opacity(0.32))
                .frame(width: 76, height: 1)
        }
        .accessibilityIdentifier("onlineRoom.poolPreview")
    }

    private func roomPoolWordGrid(
        _ words: [String],
        disabledWordKeys: Set<String>
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(words, id: \.self) { word in
                let isEnabled = !disabledWordKeys.contains(roomWordKey(word))

                Button {
                    guard let room = appState.activeRoom, isHost(room) else { return }
                    toggleRoomPoolWord(word)
                } label: {
                    Text(word.uppercased())
                        .font(.system(size: 10, weight: .black, design: .default))
                        .tracking(0.02)
                        .strikethrough(!isEnabled, color: SpyTheme.dim)
                        .foregroundStyle(isEnabled ? SpyTheme.bodyText : SpyTheme.dim.opacity(0.38))
                        .spyFitted(scale: 0.50, alignment: .center)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .background(isEnabled ? SpyTheme.control : SpyTheme.black)
                        .overlay(
                            Rectangle()
                                .stroke(isEnabled ? SpyTheme.stroke : SpyTheme.strokeDim, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(SpyWebPressStyle())
                .disabled(appState.activeRoom.map { !isHost($0) } ?? true)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .accessibilityLabel(word)
                .accessibilityValue(
                    isEnabled
                        ? localized(en: "In game", ru: "В игре", es: "En juego", uk: "У грі")
                        : localized(en: "Crossed out", ru: "Вычеркнуто", es: "Tachada", uk: "Викреслено")
                )
            }
        }
    }

    private var roomSaveAsWordPackButton: some View {
        Button {
            Task { await saveRoomThemePack() }
        } label: {
            if isSavingRoomThemePack {
                SpyLoadingLabel(title: roomSaveAsWordPackLabel, accent: SpyTheme.green)
                    .frame(height: 50)
            } else {
                SpyActionLabel(title: roomSaveAsWordPackLabel, systemImage: "tray.and.arrow.down.fill", fontSize: 10, iconSize: 13, tracking: 0.02, lines: 2)
            }
        }
        .buttonStyle(SpyButtonStyle(variant: .ghost))
        .disabled(isSavingRoomThemePack || roomGeneratedWords.count < 2)
    }

    private var webDurationPanel: some View {
        SpyPanel(accent: SpyTheme.muted, motionDelay: 0.15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    webPanelTitle(systemImage: "timer", title: copy.duration)
                    Spacer()
                    Text("\(Int(selectedDurationMinutes)) \(copy.minuteSuffix)")
                        .font(.system(size: 22, weight: .black, design: .default))
                        .foregroundStyle(SpyTheme.red)
                        .spyFitted(scale: 0.66, alignment: .trailing)
                }

                SpyWebSlider(
                    value: $selectedDurationMinutes,
                    range: 1...15,
                    language: appState.language,
                    step: 1
                )

                HStack {
                    Text("1 \(copy.minuteSuffix)")
                    Spacer()
                    Text("15 \(copy.minuteSuffix)")
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.52))
            }
        }
    }

    private func timerPanel(_ room: GameRoom) -> some View {
        let remaining = remainingSeconds(room)
        let expired = remaining == 0

        return SpyPanel(accent: expired ? SpyTheme.red : SpyTheme.green) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(copy.missionTimer)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker(lines: 2)
                    Spacer()
                    Text(expired ? copy.timeUp : copy.liveStatus)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(expired ? SpyTheme.red : SpyTheme.green)
                        .spyFitted(scale: 0.68, alignment: .trailing)
                }
                Text(timeString(remaining))
                    .font(.system(size: 40, weight: .black, design: .monospaced))
                    .tracking(0.12)
                    .foregroundStyle(expired ? SpyTheme.red : .white)
                    .contentTransition(.numericText())
                Text(expired ? spyVictoryTitle(room) : copy.timerHintLive)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyFitted(lines: 2, scale: 0.70)
            }
        }
    }

    private func rolePanel(_ room: GameRoom) -> some View {
        let email = appState.user?.email
        let isSpectator = email.map { room.spectatorsList.contains($0) } ?? false
        let isSpy = room.isSpy(email: email)

        return SpyPanel(accent: isSpectator ? SpyTheme.dim : (isSpy ? SpyTheme.red : SpyTheme.green)) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(copy.roleCard)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                    Button {
                        if revealRole {
                            HapticManager.shared.fire(.buttonPress)
                        } else {
                            HapticManager.shared.fire(.reveal)
                        }
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                            revealRole.toggle()
                        }
                    } label: {
                        Image(systemName: revealRole ? "eye.slash.fill" : "eye.fill")
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                    .frame(width: 58)
                    .contentShape(Rectangle())
                }

                ZStack {
                    if revealRole {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(roleTitle(isSpy: isSpy, isSpectator: isSpectator))
                                .font(.system(size: 30, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(isSpectator ? SpyTheme.dim : (isSpy ? SpyTheme.red : SpyTheme.green))
                                .spyFitted(lines: 2, scale: 0.58)
                            Text(roleSubtitle(isSpy: isSpy, isSpectator: isSpectator, room: room))
                                .font(SpyTheme.micro)
                                .tracking(0.12)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 3, scale: 0.66)
                            if !isSpy && !isSpectator {
                                Text(room.displayWord?.uppercased() ?? copy.classified)
                                    .font(.system(size: 38, weight: .black, design: .default))
                                    .tracking(0.04)
                                    .foregroundStyle(SpyTheme.red)
                                    .spyFitted(lines: 2, scale: 0.48)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(SpyTheme.red)
                                .symbolEffect(.pulse, options: .repeating)
                            Text(copy.tapEyeToReveal)
                                .font(SpyTheme.micro)
                                .tracking(0.12)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(lines: 2, scale: 0.70, alignment: .center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 132)
                        .transition(.scale(scale: 1.04).combined(with: .opacity))
                    }
                }
                .frame(minHeight: 148)
            }
        }
    }

    private func roleReadinessPanel(_ room: GameRoom) -> some View {
        let readCount = room.activeCardsReadList.count
        let total = max(room.activePlayers.count, 1)
        let progress = Double(readCount) / Double(total)
        let currentRead = currentUserHasReadCard(room)

        return SpyPanel(accent: currentRead ? SpyTheme.green : SpyTheme.amber) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                        Text(copy.cardCheck)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                        Text("\(readCount)/\(room.activePlayers.count)")
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(currentRead ? SpyTheme.green : SpyTheme.amber)
                }

                Text(currentRead ? copy.cardConfirmed : copy.readYourRole)
                    .font(.system(size: 26, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(currentRead ? SpyTheme.green : .white)
                    .spyFitted(lines: 2, scale: 0.62)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(SpyTheme.panelDeep)
                        Rectangle()
                            .fill(SpyTheme.red)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 6)
                .overlay(Rectangle().stroke(SpyTheme.stroke))

                ForEach(room.activePlayers) { player in
                    HStack(spacing: 10) {
                        Image(systemName: room.cardsReadList.contains(player.email) ? "checkmark.seal.fill" : "circle.dotted")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(room.cardsReadList.contains(player.email) ? SpyTheme.green : SpyTheme.dim)
                            .frame(width: 24)
                        Text(player.name.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(.white.opacity(0.86))
                            .spyFitted(scale: 0.58)
                        Spacer()
                        Text(room.cardsReadList.contains(player.email) ? copy.readyShort : copy.waitShort)
                            .font(.system(size: 10, weight: .black, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(room.cardsReadList.contains(player.email) ? SpyTheme.green : SpyTheme.dim)
                            .spyFitted(scale: 0.68, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }

                Text(copy.cardTimerHint)
                    .font(SpyTheme.mono)
                    .foregroundStyle(SpyTheme.muted)
                    .lineSpacing(3)

                Button {
                    Task { await markCardRead(room) }
                } label: {
                    if isMarkingCardRead {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        SpyActionLabel(
                            title: currentRead ? copy.waitingForTeam : copy.confirmCardRead,
                            systemImage: currentRead ? "hourglass" : "checkmark.seal.fill",
                            tracking: 0.02,
                            lines: 2
                        )
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: currentRead ? .ghost : .red))
                .disabled(currentRead || !revealRole || isMarkingCardRead)
            }
        }
    }

    @ViewBuilder
    private func turnPanel(_ room: GameRoom) -> some View {
        if room.gameModeValue == .associations {
            SpyPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(copy.associationDrum)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)

                    HStack(spacing: 12) {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(SpyTheme.red)
                            .symbolEffect(.pulse, options: .repeating)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(player(for: room.currentAskerEmail, in: room)?.name.uppercased() ?? copy.spinToStart)
                                .font(.system(size: 24, weight: .black, design: .default))
                                .tracking(0.04)
                                .foregroundStyle(.white)
                                .spyFitted(scale: 0.58)
                            Text(copy.roundAssociation(room.roundNumber ?? 1))
                                .font(SpyTheme.micro)
                                .tracking(0.12)
                                .foregroundStyle(SpyTheme.dim)
                                .spyFitted(scale: 0.68)
                        }
                        Spacer()
                    }
                }
            }
        } else {
            SpyPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(copy.questionVector)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    HStack(spacing: 12) {
                        turnAgent(title: copy.asker, player: player(for: room.currentAskerEmail, in: room), color: SpyTheme.red)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(SpyTheme.dim)
                        turnAgent(title: copy.answer, player: player(for: room.currentAnswererEmail, in: room), color: SpyTheme.green)
                    }
                }
            }
        }
    }

    private func votingPanel(_ room: GameRoom) -> some View {
        SpyPanel(accent: SpyTheme.red) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                        Text(copy.voteProtocol)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                    Text(
                        room.isVotingActive
                            ? "\(room.exclusionVoteThreshold)/\(room.activePlayers.count)"
                            : "\(room.activeVoteRequests.count)/\(room.voteThreshold)"
                    )
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.red)
                }

                Text(room.isVotingActive ? copy.whoIsSpy : copy.questionCycleComplete)
                    .font(.system(size: 27, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.58)

                if room.isVotingActive {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exclusionVoteRule(room))
                            .foregroundStyle(SpyTheme.red)
                        Text(exclusionVoteCancellationHint)
                            .foregroundStyle(SpyTheme.dim)
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .lineLimit(2)
                    .minimumScaleFactor(0.66)
                }

                if !room.isVotingActive {
                    Text(copy.requestVoteHint)
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                } else if isCurrentUserSpectator(room) {
                    Text(copy.spectatorVoteHint)
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                } else if let vote = myVote(in: room), let target = player(for: vote.votedForEmail, in: room) {
                        Text(copy.voteLocked(target.name))
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.68)
                } else {
                    ForEach(votingCandidates(in: room)) { candidate in
                        Button {
                            beginDetectiveVote(room, targetEmail: candidate.email)
                        } label: {
                            HStack {
                                Text(candidate.avatar)
                                    .font(.system(size: 22))
                                Text(candidate.name.uppercased())
                                    .font(.system(size: 11, weight: .bold, design: .default))
                                    .tracking(0.04)
                                    .spyFitted(scale: 0.68)
                                Spacer()
                                if emailsMatch(pendingDetectiveVoteTargetEmail, candidate.email) {
                                    SpySpinner(size: 17, accent: SpyTheme.red)
                                } else {
                                    Image(systemName: "scope")
                                }
                            }
                        }
                        .buttonStyle(SpyButtonStyle(variant: .ghost))
                        .disabled(isCastingVote)
                    }
                }
            }
        }
    }

    private func replayPanel(_ room: GameRoom) -> some View {
        let eligiblePlayers = room.replayEligiblePlayersList
        let eligibleEmails = Set(eligiblePlayers.map { normalizedEmailKey($0.email) })
        var votes = Set((room.readyPlayers ?? []).map(normalizedEmailKey))
        votes.formIntersection(eligibleEmails)
        let currentEmail = appState.user.map { normalizedEmailKey($0.email) }
        let currentIsEligible = currentEmail.map(eligibleEmails.contains) ?? false
        if isVotingReplay, let currentEmail, currentIsEligible {
            votes.insert(currentEmail)
        }
        let hasVoted = currentEmail.map(votes.contains) ?? false
        let total = eligiblePlayers.count
        let allVoted = !eligiblePlayers.isEmpty && eligibleEmails.isSubset(of: votes)
        let replayRequest = ReplayAutoStartPolicy.request(
            for: room,
            currentUserEmail: appState.user?.email
        )
        let autoStartFailed = replayRequest?.operationKey == replayAutoStartFailedOperationKey

        return SpyPanel(accent: allVoted ? SpyTheme.green : SpyTheme.amber) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                        Text(copy.playAgainEyebrow)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyFitted(scale: 0.70)
                    Spacer()
                    Text("\(votes.count)/\(total)")
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(allVoted ? SpyTheme.green : SpyTheme.amber)
                }

                Text(allVoted ? copy.teamReadyAnotherRun : copy.voteForNewGame)
                    .font(.system(size: 23, weight: .black, design: .default))
                    .tracking(0.04)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.58)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(eligiblePlayers) { player in
                        let accepted = votes.contains(normalizedEmailKey(player.email))
                        HStack(spacing: 5) {
                            Text(accepted ? "✓" : "·")
                            Text(player.name.uppercased())
                                .spyFitted(scale: 0.58)
                        }
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.02)
                        .foregroundStyle(accepted ? SpyTheme.green : SpyTheme.dim)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .background(accepted ? SpyTheme.green.opacity(0.16) : SpyTheme.black.opacity(0.72), in: CutCornerShape(cut: 6))
                        .overlay(CutCornerShape(cut: 6).stroke(accepted ? SpyTheme.green.opacity(0.58) : SpyTheme.stroke.opacity(0.95), lineWidth: 1))
                        .shadow(color: accepted ? SpyTheme.green.opacity(0.12) : .clear, radius: 10, y: 4)
                    }
                }

                if currentIsEligible, !hasVoted {
                    Button {
                        beginReplayVote(room)
                    } label: {
                        if isVotingReplay {
                            SpySpinner(size: 20, accent: .white)
                        } else {
                            Label(copy.voteForNewGame, systemImage: "arrow.clockwise")
                                .lineLimit(2)
                                .minimumScaleFactor(0.58)
                        }
                    }
                    .buttonStyle(SpyButtonStyle(variant: .red))
                    .disabled(isVotingReplay || isResettingRoom)
                    .accessibilityIdentifier("onlineRoom.voteReplay")
                } else if isVotingReplay {
                    HStack(spacing: 8) {
                        SpySpinner(size: 16, accent: SpyTheme.amber)
                        Text(localized(
                            en: "SAVING YOUR REPLAY VOTE",
                            ru: "СОХРАНЯЕМ ТВОЙ ГОЛОС ЗА РЕВАНШ",
                            es: "GUARDANDO TU VOTO DE REVANCHA",
                            uk: "ЗБЕРІГАЄМО ТВІЙ ГОЛОС ЗА РЕВАНШ"
                        ))
                    }
                    .font(SpyTheme.micro)
                    .tracking(0.08)
                    .foregroundStyle(SpyTheme.amber)
                    .spyFitted(lines: 2, scale: 0.60, alignment: .center)
                    .frame(maxWidth: .infinity, minHeight: 36)
                } else {
                    Text(copy.replayVoteLocked)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.green)
                        .spyFitted(lines: 2, scale: 0.62, alignment: .center)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }

                if isHost(room) {
                    Button {
                        if allVoted, let replayRequest {
                            scheduleReplayAutoStart(replayRequest, isExplicitRetry: true)
                        } else {
                            Task { await resetRoom(room) }
                        }
                    } label: {
                        if isResettingRoom || isStarting {
                            SpySpinner(size: 20, accent: .white)
                        } else {
                        Label(
                            allVoted
                                ? (autoStartFailed
                                    ? localized(en: "RETRY START", ru: "ПОВТОРИТЬ СТАРТ", es: "REINTENTAR INICIO", uk: "ПОВТОРИТИ СТАРТ")
                                    : copy.playAgain)
                                : copy.backToLobby,
                            systemImage: allVoted ? "play.fill" : "arrow.uturn.left"
                        )
                                .lineLimit(2)
                                .minimumScaleFactor(0.58)
                        }
                    }
                    .buttonStyle(SpyButtonStyle(variant: allVoted ? .red : .outline))
                    .disabled(isResettingRoom || isStarting || isVotingReplay)
                    .accessibilityIdentifier(allVoted ? "onlineRoom.startReplay" : "onlineRoom.resetReplay")
                } else if allVoted {
                    Text(copy.waitingHostResetLobby)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.muted)
                        .spyFitted(lines: 2, scale: 0.68)
                }
            }
        }
    }

    private func playersPanel(_ room: GameRoom) -> some View {
        let missingPlayers = max(3 - room.playersList.count, 0)

        return onlineRoomGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                onlineRoomCardTitle(
                    systemImage: "person.2",
                    title: localized(en: "PLAYERS", ru: "ИГРОКИ", es: "JUGADORES", uk: "ГРАВЦІ"),
                    trailing: "\(room.playersList.count) / 3+"
                )

                VStack(alignment: .leading, spacing: 8) {
                    if room.playersList.isEmpty {
                        Text(copy.waiting)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(SpyTheme.dim)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    } else {
                        ForEach(Array(room.playersList.enumerated()), id: \.element.id) { index, player in
                            playerRow(player, index: index, room: room)
                                .spyWebEntrance(
                                    delay: Double(index) * 0.04,
                                    duration: 0.36,
                                    x: -10,
                                    y: 0
                                )
                        }
                    }
                }

                if missingPlayers > 0 {
                    Text(copy.minimumOperatives(room.playersList.count))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SpyTheme.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(SpyTheme.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(SpyTheme.red.opacity(0.20), lineWidth: 1)
                        }
                }
            }
        }
        .spyWebEntrance(delay: 0.05, duration: 0.45, y: 12)
    }

    private func playerRow(_ player: Player, index: Int, room: GameRoom) -> some View {
        let isCurrentUser = player.email == appState.user?.email
        let isRoomHost = player.email == room.hostEmail

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SpyTheme.dim.opacity(0.58))
                .frame(width: 16)

            Text(player.avatar)
                .font(.system(size: 24))
                .frame(width: 30, height: 30)

            Text(player.name.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.58)

            Spacer(minLength: 8)

            if isRoomHost {
                Text(copy.hostBadge)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(SpyTheme.red)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(SpyTheme.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(SpyTheme.red.opacity(0.26), lineWidth: 1)
                    }
            } else if isCurrentUser {
                Text(youLabel)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(SpyTheme.dim)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(Color.white.opacity(isCurrentUser ? 0.045 : 0.026), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isCurrentUser ? 0.10 : 0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func webWaitingRoomActions(_ room: GameRoom) -> some View {
        VStack(spacing: 10) {
            if isHost(room) {
                if room.playersList.count < 3 {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        webWaitingActionLabel(
                            title: localized(en: "INVITE OPERATIVES", ru: "ПРИГЛАСИТЬ ИГРОКОВ", es: "INVITAR AGENTES", uk: "ЗАПРОСИТИ ГРАВЦІВ"),
                            systemImage: "person.badge.plus",
                            filled: false
                        )
                    }
                    .buttonStyle(SpyWebPressStyle())
                    .accessibilityIdentifier("onlineRoom.inviteMore")
                } else {
                    HStack(spacing: 10) {
                        Button {
                            Task { await beginReadyCheck(room) }
                        } label: {
                            webWaitingActionLabel(
                                title: copy.readyCheckAction,
                                systemImage: "checkmark.seal",
                                filled: false
                            )
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .disabled(isStarting)
                        .accessibilityIdentifier("onlineRoom.readyCheck")

                        Button {
                            Task { await start(room) }
                        } label: {
                            webWaitingActionLabel(
                                title: isStarting
                                    ? localized(en: "STARTING", ru: "ЗАПУСК", es: "INICIANDO", uk: "ЗАПУСК")
                                    : copy.startNow,
                                systemImage: "play.fill",
                                filled: true
                            )
                        }
                        .buttonStyle(SpyWebPressStyle())
                        .disabled(isStarting)
                        .accessibilityIdentifier("onlineRoom.startNow")
                    }
                }
            } else {
                onlineRoomGlassCard(verticalPadding: 16) {
                    HStack(spacing: 10) {
                        SpySpinner(size: 16, accent: SpyTheme.red)
                        Text(copy.waitingForHost)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.58))
                        Spacer()
                    }
                }
            }

            statusLine
        }
        .spyWebEntrance(delay: 0.18, duration: 0.45, y: 12)
    }

    private func webWaitingActionLabel(title: String, systemImage: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .lineLimit(2)
                .minimumScaleFactor(0.58)
        }
        .foregroundStyle(filled ? Color.white : SpyTheme.red)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(filled ? SpyTheme.red : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SpyTheme.red.opacity(filled ? 1 : 0.62), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func waitingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            if isHost(room) {
                if room.playersList.count < 3 {
                    Button {
                        HapticManager.shared.fire(.buttonPress)
                        appState.presentedSheet = .roomQR(room)
                    } label: {
                        SpyPrimaryCommandLabel(
                            title: localized(en: "INVITE OPERATIVES", ru: "ПРИГЛАСИТЬ ОПЕРАТИВНИКОВ", es: "INVITAR AGENTES", uk: "ЗАПРОСИТИ ОПЕРАТИВНИКІВ"),
                            detail: copy.minimumOperatives(room.playersList.count),
                            systemImage: "person.badge.plus"
                        )
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .accessibilityIdentifier("onlineRoom.inviteMore")
                } else {
                    Button {
                        Task { await start(room) }
                    } label: {
                        if isStarting {
                            SpyPrimaryCommandLabel(
                                title: localized(en: "ARMING MISSION", ru: "ЗАПУСК МИССИИ", es: "INICIANDO MISION", uk: "ЗАПУСК МІСІЇ"),
                                detail: copy.minimumOperatives(room.playersList.count),
                                systemImage: "antenna.radiowaves.left.and.right"
                            )
                        } else {
                            SpyPrimaryCommandLabel(
                                title: copy.startNow,
                                detail: localized(en: "BEGIN IMMEDIATELY", ru: "НАЧАТЬ НЕМЕДЛЕННО", es: "COMENZAR AHORA", uk: "ПОЧАТИ НЕГАЙНО"),
                                systemImage: "play.fill"
                            )
                        }
                    }
                    .buttonStyle(SpyPrimaryCommandStyle())
                    .disabled(isStarting)
                    .accessibilityIdentifier("onlineRoom.startNow")

                    Button {
                        Task { await beginReadyCheck(room) }
                    } label: {
                        SpyActionLabel(title: copy.readyCheckAction, systemImage: "checkmark.seal", tracking: 0.02, lines: 2)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .outline))
                    .disabled(isStarting)
                    .accessibilityIdentifier("onlineRoom.readyCheck")
                }
            } else {
                HStack(spacing: 12) {
                    SpySpinner(size: 22, accent: SpyTheme.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.waitingForHost)
                            .font(.system(size: 12, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(.white)
                            .spyFitted(scale: 0.68)
                        Text(copy.minimumOperatives(room.playersList.count))
                            .font(.system(size: 10, weight: .bold, design: .default))
                            .tracking(0.02)
                            .foregroundStyle(SpyTheme.dim)
                            .spyFitted(lines: 2, scale: 0.62)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SpyTheme.strokeDim).frame(height: 1)
                }
            }

            statusLine
        }
        .spyWebEntrance(delay: 0.20, duration: 0.45, y: 16)
    }

    private func preTimerControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            statusLine
        }
    }

    private func playingControls(_ room: GameRoom) -> some View {
        VStack(spacing: 12) {
            if currentUserIsSpy(room), !room.enabledWordPool.isEmpty, !isTimeExpired(room) {
                Button {
                    HapticManager.shared.fire(.buttonPress)
                    showSpyGuess = true
                } label: {
                    SpyActionLabel(title: copy.guessWord, systemImage: "scope", tracking: 0.02)
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isSubmittingSpyGuess || isCurrentUserSpectator(room))
            }

            if !room.isVotingActive && room.questionPhase != "results" {
                Button {
                    Task { await advance(room) }
                } label: {
                    if isAdvancing {
                        SpySpinner(size: 20, accent: .white)
                    } else {
                        SpyActionLabel(
                            title: room.gameModeValue == .associations ? copy.nextAssociation : copy.nextQuestion,
                            systemImage: "forward.end.fill",
                            tracking: 0.02,
                            lines: 2
                        )
                    }
                }
                .buttonStyle(SpyButtonStyle(variant: .red))
                .disabled(isAdvancing || isCurrentUserSpectator(room))
            }

            Button {
                beginVoteRequest(room)
            } label: {
                if isRequestingVote {
                    SpySpinner(size: 20, accent: .white)
                } else {
                        SpyActionLabel(title: voteButtonTitle(room), systemImage: "checkmark.seal.fill", tracking: 0.02, lines: 2)
                }
            }
            .buttonStyle(SpyButtonStyle(variant: room.isVotingActive ? .ghost : .outline))
            .disabled(isRequestingVote || hasCurrentUserRequestedVote(room) || isCurrentUserSpectator(room))

            statusLine
        }
    }

    private var statusLine: some View {
        EmptyView()
    }

    private func publishGameToast(_ rawStatus: String) {
        guard !rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard status == rawStatus,
                  let message = userFacingStatus(rawStatus) else { return }
            appState.showToast(message, kind: toastKind(for: rawStatus))
            status = ""
        }
    }

    private func publishRoomThemeError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            await Task.yield()
            guard roomThemeError == message else { return }
            appState.showToast(trimmed, kind: .error)
            roomThemeError = ""
        }
    }

    private func toastKind(for rawStatus: String) -> AppToastKind {
        let upper = rawStatus.uppercased()
        let errorMarkers = [
            "ERROR", "FAILED", "COULDN'T", "UNABLE", "EXPIRED", "TRACEBACK", "[401]",
            "ОШИБ", "НЕ УДАЛ", "ИСТЕКЛ", "NO SE PUDO", "ERROR DE",
            "ПОМИЛ", "НЕ ВДАЛ", "ЗАВЕРШИЛ"
        ]
        if errorMarkers.contains(where: upper.contains) {
            return .error
        }

        let warningMarkers = [
            "SELECT A DECK", "NEED AT LEAST", "CHOOSE", "ВЫБЕРИ", "НУЖНО МИНИМУМ", "ELIGE",
            "ОБЕРИ", "ПОТРІБНО МІНІМУМ"
        ]
        if warningMarkers.contains(where: upper.contains) {
            return .warning
        }

        let successMarkers = [
            "READY", "SAVED", "SELECTED", "CLEARED", "SYNCED", "LOCKED", "SENT", "RESTORED", "EXPANDED",
            "ГОТОВ", "СОХРАН", "ВЫБРАН", "НЕ ВЫБРАН", "СИНХРОНИЗ", "ОТПРАВ", "ВОССТАНОВ", "РАСШИРЕН",
            "LISTO", "GUARDADO", "SELECCIONADO", "SINCRONIZADO", "ENVIADO", "RESTAURADO", "AMPLIADO",
            "ГОТОВ", "ЗБЕРЕЖ", "ОБРАН", "СИНХРОНІЗ", "НАДІСЛ", "ВІДНОВ", "РОЗШИР"
        ]
        if isPositiveStatus(rawStatus) || successMarkers.contains(where: upper.contains) {
            return .success
        }

        return .info
    }

    private func userFacingStatus(_ rawStatus: String) -> String? {
        let trimmed = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let upper = trimmed.uppercased()
        if upper.contains("AUTHENTICATION") || upper.contains("[401]") {
            return localized(en: "SESSION EXPIRED. LOG IN AGAIN", ru: "СЕССИЯ ИСТЕКЛА. ВОЙДИ СНОВА", es: "SESION EXPIRADA. INICIA SESION", uk: "СЕСІЯ ЗАВЕРШИЛАСЯ. УВІЙДИ ЗНОВУ")
        }
        if upper.contains("HTTP") || upper.contains("TRACEBACK") || upper.contains("REQUEST_ID") {
            return localized(en: "SERVER SYNC FAILED. TRY AGAIN", ru: "СИНХРОНИЗАЦИЯ НЕ УДАЛАСЬ. ПОВТОРИ", es: "ERROR DE SINCRONIZACION", uk: "СИНХРОНІЗАЦІЯ ІЗ СЕРВЕРОМ НЕ ВДАЛАСЯ. ПОВТОРИ")
        }
        return trimmed.count > 72 ? "\(trimmed.prefix(69))..." : trimmed
    }

    private func isPositiveStatus(_ status: String) -> Bool {
        [
            copy.modeSynced,
            durationSyncedStatus,
            copy.readyCheckSent,
            copy.lobbyRestored,
            copy.roomSynced,
            copy.readyRemoved,
            copy.readyLocked,
            copy.replayVoteLocked,
            copy.rouletteArmed,
            copy.gameReady,
            copy.associationSpun,
            copy.questionSent,
            roomCopiedTitle,
            copy.cardConfirmedStatus,
            copy.voteRequestedStatus,
            copy.voteLockedStatus,
            copy.spyGuessLocked
        ].contains(status)
    }

    private var emptyRoom: some View {
        SpyPanel {
            VStack(spacing: 16) {
                Image(systemName: "scope")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(SpyTheme.red)
                Text(copy.noActiveRoom)
                    .font(.system(size: 24, weight: .black, design: .default))
                    .tracking(0.04)
                    .spyFitted(lines: 2, scale: 0.58, alignment: .center)
                Button {
                    appState.selectedTab = .home
                } label: {
                    Label(copy.openHome, systemImage: "house.fill")
                }
                .buttonStyle(SpyButtonStyle(variant: .outline))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 80)
    }

    private var roomBreadcrumb: String {
        localized(en: "HOME / LOBBY", ru: "ДОМ / ЛОББИ", es: "INICIO / SALA", uk: "ГОЛОВНА / ЛОБІ")
    }

    private var roomCodeLabel: String {
        localized(en: "// ROOM CODE", ru: "// КОД КОМНАТЫ", es: "// CODIGO", uk: "// КОД КІМНАТИ")
    }

    private var roomCodePlainLabel: String {
        localized(en: "ROOM CODE", ru: "КОД КОМНАТЫ", es: "CODIGO", uk: "КОД КІМНАТИ")
    }

    private var roomCodeShare: String {
        localized(en: "Share the code with your team or open the QR invite.", ru: "Передай код команде или открой QR-приглашение.", es: "Comparte el codigo o abre el QR.", uk: "Передай код команді або відкрий QR-запрошення.")
    }

    private var roomCopyTitle: String {
        localized(en: "COPY", ru: "КОПИРОВАТЬ", es: "COPIAR", uk: "СКОПІЮВАТИ")
    }

    private var roomCopiedTitle: String {
        localized(en: "COPIED", ru: "СКОПИРОВАНО", es: "COPIADO", uk: "СКОПІЙОВАНО")
    }

    private var tapToHideRoomCode: String {
        localized(en: "TAP TO HIDE", ru: "ТАП ЧТОБЫ СКРЫТЬ", es: "TOCA PARA OCULTAR", uk: "НАТИСНИ, ЩОБ ПРИХОВАТИ")
    }

    private var tapToRevealRoomCode: String {
        localized(en: "TAP TO REVEAL", ru: "ТАП ЧТОБЫ ПОКАЗАТЬ", es: "TOCA PARA MOSTRAR", uk: "НАТИСНИ, ЩОБ ПОКАЗАТИ")
    }

    private var webQRHint: String {
        localized(en: "TAP TO FLIP", ru: "ТАП ЧТОБЫ ПЕРЕВЕРНУТЬ", es: "TOCA PARA GIRAR", uk: "НАТИСНИ, ЩОБ ПЕРЕВЕРНУТИ")
    }

    private var qrHiddenTitle: String {
        localized(en: "QR HIDDEN", ru: "QR СКРЫТ", es: "QR OCULTO", uk: "QR ПРИХОВАНО")
    }

    private var tapToFlipQR: String {
        localized(en: "TAP TO FLIP", ru: "ТАП ЧТОБЫ ПЕРЕВЕРНУТЬ", es: "TOCA PARA GIRAR", uk: "НАТИСНИ, ЩОБ ПЕРЕВЕРНУТИ")
    }

    private var gameModeTitle: String {
        localized(en: "GAME MODE", ru: "РЕЖИМ ИГРЫ", es: "MODO DE JUEGO", uk: "РЕЖИМ ГРИ")
    }

    private var modeTitle: String {
        localized(en: "MODE", ru: "РЕЖИМ", es: "MODO", uk: "РЕЖИМ")
    }

    private var agentsLabel: String {
        localized(en: "// AGENTS", ru: "// АГЕНТЫ", es: "// AGENTES", uk: "// АГЕНТИ")
    }

    private var readyCheckingTitle: String {
        localized(en: "READY CHECK", ru: "ПРОВЕРКА", es: "CHECK", uk: "ПЕРЕВІРКА ГОТОВНОСТІ")
    }

    private var readyYesTitle: String {
        localized(en: "YES", ru: "ДА", es: "SI", uk: "ТАК")
    }

    private var readyNoTitle: String {
        localized(en: "NO", ru: "НЕТ", es: "NO", uk: "НІ")
    }

    private var readyWaitingTitle: String {
        localized(en: "WAITING", ru: "ЖДЕМ", es: "ESPERA", uk: "ЧЕКАЄМО")
    }

    private var readyCountTitle: String {
        localized(en: "READY", ru: "ГОТОВЫ", es: "LISTOS", uk: "ГОТОВІ")
    }

    private var readyAgentsStatusTitle: String {
        localized(en: "AGENTS STATUS", ru: "СТАТУС АГЕНТОВ", es: "ESTADO AGENTES", uk: "СТАТУС АГЕНТІВ")
    }

    private var webCardPhaseTitle: String {
        localized(en: "// CARD REVEAL PHASE", ru: "// ФАЗА ОТКРЫТИЯ КАРТ", es: "// FASE DE CARTAS", uk: "// ФАЗА ВІДКРИТТЯ КАРТОК")
    }

    private var webTapToRevealRoleTitle: String {
        localized(en: "TAP TO REVEAL ROLE", ru: "НАЖМИ, ЧТОБЫ ОТКРЫТЬ РОЛЬ", es: "TOCA PARA REVELAR ROL", uk: "НАТИСНИ, ЩОБ ВІДКРИТИ РОЛЬ")
    }

    private var webDontShowOthersTitle: String {
        localized(en: "DON'T SHOW OTHERS", ru: "НЕ ПОКАЗЫВАЙ ДРУГИМ", es: "NO LO MUESTRES", uk: "НЕ ПОКАЗУЙ ІНШИМ")
    }

    private var webReadyToPlayTitle: String {
        localized(en: "✓ READ, READY TO PLAY", ru: "✓ ПРОЧИТАЛ, ГОТОВ ИГРАТЬ", es: "✓ LEIDO, LISTO", uk: "✓ ПРОЧИТАНО, ГОТОВИЙ ГРАТИ")
    }

    private var webWaitingOthersTitle: String {
        localized(en: "✓ You're ready. Waiting for others...", ru: "✓ Ты готов. Ждем остальных...", es: "✓ Listo. Esperando...", uk: "✓ Ти готовий. Чекаємо на інших...")
    }

    private var webCardsReadTitle: String {
        localized(en: "// CARDS READ", ru: "// КАРТЫ ПРОЧИТАНЫ", es: "// CARTAS LEIDAS", uk: "// КАРТКИ ПРОЧИТАНО")
    }

    private var webSecretWordLabel: String {
        localized(en: "SECRET WORD", ru: "СЕКРЕТНОЕ СЛОВО", es: "PALABRA SECRETA", uk: "СЕКРЕТНЕ СЛОВО")
    }

    private var webTimeLeftTitle: String {
        localized(en: "// TIME REMAINING", ru: "// ОСТАЛОСЬ ВРЕМЕНИ", es: "// TIEMPO RESTANTE", uk: "// ЧАСУ ЗАЛИШИЛОСЯ")
    }

    private var webAgentsTitle: String {
        localized(en: "// AGENTS", ru: "// АГЕНТЫ", es: "// AGENTES", uk: "// АГЕНТИ")
    }

    private var webActivePairTitle: String {
        localized(en: "ACTIVE PAIR", ru: "АКТИВНАЯ ПАРА", es: "PAREJA ACTIVA", uk: "АКТИВНА ПАРА")
    }

    private var webNextPairTitle: String {
        localized(en: "NEXT PAIR", ru: "СЛЕДУЮЩАЯ ПАРА", es: "SIGUIENTE PAREJA", uk: "НАСТУПНА ПАРА")
    }

    private var webEarlyGuessTitle: String {
        localized(en: "// EARLY GUESS", ru: "// ДОСРОЧНОЕ УГАДЫВАНИЕ", es: "// PISTA TEMPRANA", uk: "// ДОСТРОКОВА ЗДОГАДКА")
    }

    private var webEarlyGuessDescription: String {
        localized(
            en: "Think you know the secret word? Guess early. Correct answer wins the game.",
            ru: "Думаешь, что знаешь секретное слово? Угадай досрочно. Верный ответ выигрывает игру.",
            es: "Crees saber la palabra secreta? Adivina antes. Respuesta correcta gana.",
            uk: "Думаєш, що знаєш секретне слово? Вгадай достроково. Правильна відповідь приносить перемогу."
        )
    }

    private var webEarlyGuessButtonTitle: String {
        localized(en: "GUESS WORD EARLY", ru: "УГАДАТЬ СЛОВО ДОСРОЧНО", es: "ADIVINAR ANTES", uk: "ВГАДАТИ СЛОВО ДОСТРОКОВО")
    }

    private var webVoteTitle: String {
        localized(en: "// VOTE FOR SPY", ru: "// ГОЛОСОВАНИЕ ЗА ШПИОНА", es: "// VOTAR AL ESPIA", uk: "// ГОЛОСУВАННЯ ЗА ШПИГУНА")
    }

    private var webVoteDescriptionLead: String {
        localized(en: "Want to start a vote?", ru: "Хочешь начать голосование?", es: "Quieres iniciar votacion?", uk: "Хочеш почати голосування?")
    }

    private var webVoteAgreementSuffix: String {
        localized(en: "players must agree.", ru: "игроков должны согласиться.", es: "jugadores deben aceptar.", uk: "гравців мають погодитися.")
    }

    private var webVoteRequestButtonTitle: String {
        localized(en: "VOTE TO START", ru: "ХОЧУ ГОЛОСОВАТЬ", es: "VOTAR PARA INICIAR", uk: "ХОЧУ ГОЛОСУВАТИ")
    }

    private var webVoteRequestedTitle: String {
        localized(en: "✓ You voted to start", ru: "✓ Ты проголосовал за начало", es: "✓ Votaste para iniciar", uk: "✓ Ти проголосував за початок")
    }

    private var webVoteStartedTitle: String {
        localized(
            en: "Voting started. Who do you vote as the spy?",
            ru: "Голосование началось. За кого голосуешь как за шпиона?",
            es: "La votacion empezo. A quien marcas como espia?",
            uk: "Голосування почалося. Кого вважаєш шпигуном?"
        )
    }

    private var webVotingInProgressTitle: String {
        localized(en: "// VOTING IN PROGRESS", ru: "// ГОЛОСОВАНИЕ ИДЕТ", es: "// VOTACION EN CURSO", uk: "// ГОЛОСУВАННЯ ТРИВАЄ")
    }

    private var webVoteSpyQuestion: String {
        localized(en: "SPY?", ru: "ШПИОН?", es: "ESPIA?", uk: "ШПИГУН?")
    }

    private func webVoteDescription(_ room: GameRoom) -> String {
        "\(webVoteDescriptionLead) \(room.activeVoteRequests.count)/\(room.voteThreshold) \(webVoteAgreementSuffix)"
    }

    private var youLabel: String {
        localized(en: "YOU", ru: "ТЫ", es: "TU", uk: "ТИ")
    }

    private var closeRoomTitle: String {
        localized(en: "CLOSE", ru: "ЗАКРЫТЬ", es: "CERRAR", uk: "ЗАКРИТИ")
    }

    private var durationSyncedStatus: String {
        localized(en: "DURATION SYNCED", ru: "ДЛИТЕЛЬНОСТЬ СОХРАНЕНА", es: "DURACION GUARDADA", uk: "ТРИВАЛІСТЬ ЗБЕРЕЖЕНО")
    }

    private var selectedPackSummary: String {
        switch roomWordSource {
        case .none:
            if lobbyPackLoadState == .loaded, lobbyWordPacks.isEmpty {
                return localized(
                    en: "You haven't created any decks.",
                    ru: "Вы не создавали своих колод.",
                    es: "No has creado ningun pack.",
                    uk: "Ви ще не створили жодного набору."
                )
            }
            return localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado.", uk: "Не обрано.")

        case .generated:
            guard let roomGeneratedPack else {
                return localized(en: "Not generated yet.", ru: "Ещё не сгенерировано.", es: "Aun no generado.", uk: "Ще не згенеровано.")
            }
            return copy.selectedPackSummary(
                name: roomGeneratedPack.category.nilIfBlank ?? roomTheme.nilIfBlank ?? customCategoryFallback,
                words: roomGeneratedWords.count
            )

        case let .saved(id):
            guard let pack = lobbyWordPacks.first(where: { $0.id == id }) else {
                return localized(en: "Not selected.", ru: "Не выбрано.", es: "No seleccionado.", uk: "Не обрано.")
            }
            return copy.selectedPackSummary(name: pack.name, words: pack.words?.roomCleanWords.count ?? 0)
        }
    }

    private var roomHasCustomTheme: Bool {
        roomTheme.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil
    }

    private var roomHasGeneratedTheme: Bool {
        (roomGeneratedPack?.words.roomCleanWords.count ?? 0) >= 2
    }

    private var isGeneratingRoomTheme: Bool {
        roomThemeOperation != nil
    }

    private func onlineDurationSliderValue(for room: GameRoom) -> Binding<Double> {
        Binding(
            get: { displayedDurationMinutes(for: room) },
            set: { newValue in
                guard isHost(room) else { return }
                selectedDurationMinutes = newValue
            }
        )
    }

    private func onlineSpyCountSliderValue(for room: GameRoom) -> Binding<Double> {
        Binding(
            get: { Double(displayedSpyCount(for: room)) },
            set: { newValue in
                guard isHost(room) else { return }
                selectedSpyCount = Double(
                    min(max(Int(newValue.rounded()), 1), room.maximumLobbySpyCount)
                )
            }
        )
    }

    private var roomThemeDraftBinding: Binding<String> {
        Binding(
            get: { roomTheme },
            set: { setRoomThemeDraft($0) }
        )
    }

    private var roomThemeSelectionIsReady: Bool {
        if !appState.hasOptimisticLobbySettingsChanges,
           let room = appState.activeRoom,
           roomHasAuthoritativeLobbySelection(room) {
            let enabledCount = (room.lobbyWordPool ?? []).filter(\.enabled).count
            let selectedCount = min(max(room.lobbyWordCount ?? enabledCount, 0), enabledCount)
            return selectedCount >= 2
        }

        if roomHasCustomTheme {
            return roomWordSource == .generated && roomGeneratedWords.count >= 2
        }

        switch roomWordSource {
        case .none:
            return false
        case .generated:
            return roomGeneratedWords.count >= 2
        case let .saved(id):
            guard lobbyPackLoadState == .loaded else { return false }
            let words = lobbyWordPacks.first(where: { $0.id == id })?.words?.roomCleanWords ?? []
            return activeRoomWords(words).count >= 2
        }
    }

    private func lobbyStateIsServerConfirmed(for room: GameRoom) -> Bool {
        guard configuredRoomID == room.id else { return false }
        return LobbyStartGate.isServerConfirmed(
            roomRevision: room.lobbyRevision,
            authoritativeState: appState.authoritativeLobbyStatePayload(from: room),
            localState: currentLobbyStatePayload(for: room),
            hasOptimisticChanges: appState.hasOptimisticLobbySettingsChanges,
            hasSyncFailure: appState.lobbySettingsSyncFailure != nil,
            isEditingLobbySlider: isEditingLobbySlider
        )
    }

    private func lobbySetupCanAdvance(_ room: GameRoom) -> Bool {
        lobbyStartPrerequisitesAreMet(room) &&
            lobbyStateIsServerConfirmed(for: room) &&
            !waitingStartActionMode(for: room).blocksStart
    }

    private func lobbyStartPrerequisitesAreMet(_ room: GameRoom) -> Bool {
        LobbyStartGate.hasPrerequisites(
            playerCount: room.playersList.count,
            isThemeSelectionReady: roomThemeSelectionIsReady,
            isGeneratingRoomTheme: isGeneratingRoomTheme
        )
    }

    private func roomStartActionDetail(_ room: GameRoom) -> String {
        if room.playersList.count < 3 {
            return copy.minimumOperatives(room.playersList.count)
        }
        if isGeneratingRoomTheme {
            return localized(en: "GENERATING WORDS", ru: "ГЕНЕРАЦИЯ СЛОВ", es: "GENERANDO PALABRAS", uk: "ГЕНЕРАЦІЯ СЛІВ")
        }
        if !roomThemeSelectionIsReady {
            switch roomWordSource {
            case .none:
                return localized(
                    en: "SELECT DECK / THEME",
                    ru: "ВЫБЕРИ КОЛОДУ / ТЕМУ",
                    es: "ELIGE PACK / TEMA",
                    uk: "ОБЕРИ НАБІР / ТЕМУ"
                )
            case .generated:
                return localized(en: "GENERATE WORDS FIRST", ru: "СНАЧАЛА СГЕНЕРИРУЙ СЛОВА", es: "GENERA PALABRAS PRIMERO", uk: "СПОЧАТКУ ЗГЕНЕРУЙ СЛОВА")
            case .saved:
                return localized(en: "THIS DECK NEEDS MORE WORDS", ru: "В КОЛОДЕ НЕДОСТАТОЧНО СЛОВ", es: "ESTE PACK NECESITA MAS PALABRAS", uk: "У НАБОРІ ЗАМАЛО СЛІВ")
            }
        }
        if !lobbyStateIsServerConfirmed(for: room) {
            return localized(
                en: "WAITING FOR SERVER CONFIRMATION",
                ru: "ЖДЁМ ПОДТВЕРЖДЕНИЕ СЕРВЕРА",
                es: "ESPERANDO CONFIRMACION DEL SERVIDOR",
                uk: "ЧЕКАЄМО НА ПІДТВЕРДЖЕННЯ СЕРВЕРА"
            )
        }
        return localized(en: "START NOW", ru: "НАЧАТЬ СРАЗУ", es: "INICIAR AHORA", uk: "ПОЧАТИ ЗАРАЗ")
    }

    private var roomThemeMaxWords: Int {
        max(roomGeneratedPack?.words.roomCleanWords.count ?? 0, 2)
    }

    private var roomShouldShowPoolPreview: Bool {
        guard let snapshot = roomPoolSnapshot else { return false }
        return LobbyPresentationPolicy.shouldShowPoolPreview(
            totalWordCount: snapshot.words.count
        )
    }

    private func roomWordKey(_ word: String) -> String {
        RoomWordPoolFilter.key(word)
    }

    private func activeRoomWords(_ words: [String]) -> [String] {
        RoomWordPoolFilter.activeWords(words, excluding: disabledRoomPoolWordKeys)
    }

    private func toggleRoomPoolWord(_ word: String) {
        let key = roomWordKey(word)
        if disabledRoomPoolWordKeys.contains(key) {
            disabledRoomPoolWordKeys.remove(key)
        } else {
            disabledRoomPoolWordKeys.insert(key)
        }
        HapticManager.shared.fire(.tabSelection)
        scheduleLobbyStateSync(debounce: .milliseconds(90))
    }

    private var roomGeneratedWords: [String] {
        Array(activeRoomWords(roomGeneratedPack?.words ?? []).prefix(Int(max(roomWordCount, 1))))
    }

    private var lobbyWordPacksForStart: [WordPack] {
        if !appState.hasOptimisticLobbySettingsChanges,
           let room = appState.activeRoom,
           roomHasAuthoritativeLobbySelection(room) {
            let enabled = (room.lobbyWordPool ?? [])
                .filter(\.enabled)
                .map(\.word)
                .roomCleanWords
            let selected = Array(enabled.prefix(max(room.lobbyWordCount ?? enabled.count, 0)))
            let id = room.lobbySourcePackID?.nilIfBlank ?? "authoritative-lobby"
            let name = room.lobbySourceName?.nilIfBlank
                ?? room.lobbyCategory?.nilIfBlank
                ?? room.lobbyTheme?.nilIfBlank
                ?? lobbyNameFallback
            let pack = WordPack(
                id: id,
                name: name,
                category: room.lobbyCategory?.nilIfBlank ?? name,
                words: selected,
                ownerEmail: appState.user?.email,
                isPublic: false
            )
            return [pack] + lobbyWordPacks.filter { $0.id != id }
        }

        if roomWordSource == .generated, let pack = generatedRoomWordPack {
            return [pack] + lobbyWordPacks.filter { $0.id != pack.id }
        }

        if case let .saved(id) = roomWordSource,
           var pack = lobbyWordPacks.first(where: { $0.id == id }) {
            pack.words = activeRoomWords(pack.words ?? [])
            return [pack] + lobbyWordPacks.filter { $0.id != id }
        }

        if let room = appState.activeRoom,
           roomHasAuthoritativeLobbySelection(room) {
            let enabled = (room.lobbyWordPool ?? [])
                .filter(\.enabled)
                .map(\.word)
                .roomCleanWords
            let selected = Array(enabled.prefix(max(room.lobbyWordCount ?? enabled.count, 0)))
            let id = room.lobbySourcePackID?.nilIfBlank ?? "authoritative-lobby"
            let name = room.lobbySourceName?.nilIfBlank
                ?? room.lobbyCategory?.nilIfBlank
                ?? room.lobbyTheme?.nilIfBlank
                ?? lobbyNameFallback
            let pack = WordPack(
                id: id,
                name: name,
                category: room.lobbyCategory?.nilIfBlank ?? name,
                words: selected,
                ownerEmail: appState.user?.email,
                isPublic: false
            )
            return [pack] + lobbyWordPacks.filter { $0.id != id }
        }

        return lobbyWordPacks
    }

    private var generatedRoomWordPack: WordPack? {
        guard let roomGeneratedPack else { return nil }
        let words = roomGeneratedWords
        guard words.count >= 2 else { return nil }
        let name = roomGeneratedPack.name?.nilIfBlank
            ?? roomGeneratedPack.category.nilIfBlank
            ?? roomTheme.nilIfBlank
            ?? customNameFallback
        return WordPack(
            id: "generated",
            name: name,
            category: roomGeneratedPack.category.nilIfBlank ?? name,
            words: words,
            ownerEmail: appState.user?.email,
            isPublic: false
        )
    }

    private var roomPoolSnapshot: RoomPoolSnapshot? {
        if roomWordSource == .generated, let roomGeneratedPack {
            let words = roomGeneratedPack.words.roomCleanWords
            let inGameCount = min(max(Int(roomWordCount), 0), activeRoomWords(words).count)
            let source = roomGeneratedLobbySource == .manual
                ? localized(en: "MANUAL", ru: "ВРУЧНУЮ", es: "MANUAL", uk: "ВРУЧНУ")
                : localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO", uk: "ЗГЕНЕРОВАНО AI")
            return RoomPoolSnapshot(
                category: roomGeneratedPack.category.nilIfBlank ?? roomTheme.nilIfBlank ?? customCategoryFallback,
                source: source,
                words: words,
                disabledWordKeys: disabledRoomPoolWordKeys,
                countLabel: localized(
                    en: "\(inGameCount)/\(words.count) IN GAME",
                    ru: "\(inGameCount)/\(words.count) В ИГРЕ",
                    es: "\(inGameCount)/\(words.count) EN JUEGO",
                    uk: "\(inGameCount)/\(words.count) У ГРІ"
                )
            )
        }

        if let room = appState.activeRoom,
           isHost(room),
           (appState.hasOptimisticLobbySettingsChanges || !roomHasAuthoritativeLobbySelection(room)),
           case let .saved(id) = roomWordSource,
           let pack = lobbyWordPacks.first(where: { $0.id == id }) {
            let words = pack.words?.roomCleanWords ?? []
            let inGameCount = activeRoomWords(words).count
            return RoomPoolSnapshot(
                category: pack.category?.nilIfBlank ?? pack.name,
                source: localized(en: "WORD PACK", ru: "WORDPACK", es: "WORDPACK", uk: "НАБІР СЛІВ"),
                words: words,
                disabledWordKeys: disabledRoomPoolWordKeys,
                countLabel: localized(
                    en: "\(inGameCount)/\(words.count) IN GAME",
                    ru: "\(inGameCount)/\(words.count) В ИГРЕ",
                    es: "\(inGameCount)/\(words.count) EN JUEGO",
                    uk: "\(inGameCount)/\(words.count) У ГРІ"
                )
            )
        }

        if let room = appState.activeRoom,
           roomHasAuthoritativeLobbySelection(room) {
            return authoritativeRoomPoolSnapshot(from: room)
        }

        return nil
    }

    private func authoritativeRoomPoolSnapshot(from room: GameRoom) -> RoomPoolSnapshot {
        let entries = room.lobbyWordPool ?? []
        let words = entries.map(\.word).roomCleanWords
        let enabledCount = entries.filter(\.enabled).count
        let selectedCount = min(max(room.lobbyWordCount ?? enabledCount, 0), enabledCount)
        let source: String
        switch LobbyWordSource(rawValue: room.lobbyWordSource ?? "none") ?? .none {
        case .ai:
            source = localized(en: "AI GENERATED", ru: "AI ГЕНЕРАЦИЯ", es: "IA GENERADO", uk: "ЗГЕНЕРОВАНО AI")
        case .saved:
            source = localized(en: "WORD PACK", ru: "WORDPACK", es: "WORDPACK", uk: "НАБІР СЛІВ")
        case .manual:
            source = localized(en: "MANUAL", ru: "ВРУЧНУЮ", es: "MANUAL", uk: "ВРУЧНУ")
        case .none:
            source = copy.waitingForHost
        }
        return RoomPoolSnapshot(
            category: room.lobbyCategory?.nilIfBlank
                ?? room.lobbySourceName?.nilIfBlank
                ?? room.lobbyTheme?.nilIfBlank
                ?? customCategoryFallback,
            source: source,
            words: words,
            disabledWordKeys: Set(
                entries.filter { !$0.enabled }.map { roomWordKey($0.word) }
            ),
            countLabel: localized(
                en: "\(selectedCount)/\(words.count) IN GAME",
                ru: "\(selectedCount)/\(words.count) В ИГРЕ",
                es: "\(selectedCount)/\(words.count) EN JUEGO",
                uk: "\(selectedCount)/\(words.count) У ГРІ"
            )
        )
    }

    private var roomThemeTitle: String {
        localized(en: "THEME / WORD PACK", ru: "ТЕМА / НАБОР СЛОВ", es: "TEMA / PACK", uk: "ТЕМА / НАБІР СЛІВ")
    }

    private var allIncludedLabel: String {
        localized(en: "ALL INCLUDED", ru: "ВСЁ ДОСТУПНО", es: "TODO INCLUIDO", uk: "УСЕ ДОСТУПНО")
    }

    private var roomThemePlaceholder: String {
        localized(en: "European countries, hero archetypes...", ru: "Страны Европы, архетипы героев...", es: "Países de Europa, arquetipos heroicos...", uk: "Країни Європи, архетипи героїв...")
    }

    private var roomCountLabel: String {
        localized(en: "// WORDS TO CREATE", ru: "// СОЗДАТЬ СЛОВ", es: "// PALABRAS A CREAR", uk: "// СЛІВ ДЛЯ СТВОРЕННЯ")
    }

    private var roomWordsLabel: String {
        localized(en: "WORDS IN GAME", ru: "СЛОВ В ИГРЕ", es: "PALABRAS EN JUEGO", uk: "СЛІВ У ГРІ")
    }

    private var roomAIWarning: String {
        localized(
            en: "AI can make mistakes. Check the words before playing.",
            ru: "AI может ошибаться. Проверь слова перед игрой.",
            es: "La IA puede equivocarse. Revisa las palabras antes de jugar.",
            uk: "AI може помилятися. Перевір слова перед грою."
        )
    }

    private var roomPoolPreviewLabel: String {
        localized(en: "// POOL PREVIEW", ru: "// ПРЕВЬЮ ПУЛА", es: "// PREVIEW BANCO", uk: "// ПЕРЕГЛЯД ПУЛУ")
    }

    private var roomAddMoreWordsLabel: String {
        if roomThemeMaxWords >= 200 {
            return localized(en: "WORD POOL MAXED", ru: "ДОСТИГНУТ МАКСИМУМ", es: "BANCO AL MAXIMO", uk: "ДОСЯГНУТО МАКСИМУМУ ПУЛУ")
        }
        return localized(en: "EXPAND POOL · +50", ru: "РАСШИРИТЬ ПУЛ · +50", es: "AMPLIAR BANCO · +50", uk: "РОЗШИРИТИ ПУЛ · +50")
    }

    private func roomShowAllWordsLabel(_ count: Int) -> String {
        localized(
            en: "SHOW ALL · \(count)",
            ru: "ПОКАЗАТЬ ВСЕ · \(count)",
            es: "MOSTRAR TODO · \(count)",
            uk: "ПОКАЗАТИ ВСІ · \(count)"
        )
    }

    private var roomShowLessWordsLabel: String {
        localized(en: "SHOW LESS", ru: "ПОКАЗАТЬ МЕНЬШЕ", es: "MOSTRAR MENOS", uk: "ПОКАЗАТИ МЕНШЕ")
    }

    private var roomSaveAsWordPackLabel: String {
        localized(en: "SAVE AS WORDPACK", ru: "СОХРАНИТЬ КАК WORDPACK", es: "GUARDAR WORDPACK", uk: "ЗБЕРЕГТИ ЯК НАБІР СЛІВ")
    }

    private var roomThemeActionTitle: String {
        if roomHasGeneratedTheme {
            return localized(en: "REGENERATE", ru: "СГЕНЕРИРОВАТЬ ЗАНОВО", es: "REGENERAR", uk: "ЗГЕНЕРУВАТИ ЗНОВУ")
        }
        return localized(en: "GENERATE WORDS", ru: "СГЕНЕРИРОВАТЬ СЛОВА", es: "GENERAR PALABRAS", uk: "ЗГЕНЕРУВАТИ СЛОВА")
    }

    private var roomThemeActionIcon: String {
        if roomHasGeneratedTheme { return "arrow.clockwise" }
        return "sparkles"
    }

    private func roomWordCountModeTitle(_ mode: RoomWordCountMode) -> String {
        switch mode {
        case .recommended:
            localized(en: "RECOMMENDED", ru: "РЕКОМЕНДОВАНО", es: "RECOMENDADO", uk: "РЕКОМЕНДОВАНО")
        case .custom:
            localized(en: "CUSTOM", ru: "СВОЙ ВЫБОР", es: "CUSTOM", uk: "ВЛАСНИЙ ВИБІР")
        }
    }

    private func roomWordCountModeHint(_ mode: RoomWordCountMode) -> String {
        switch mode {
        case .recommended:
            if WordPackRecommendedCountPolicy.isCountriesTheme(roomTheme) {
                localized(en: "Up to 100 words", ru: "До 100 слов", es: "Hasta 100 palabras", uk: "До 100 слів")
            } else {
                localized(en: "30 words", ru: "30 слов", es: "30 palabras", uk: "30 слів")
            }
        case .custom:
            localized(
                en: "\(Int(roomCustomWordCount)) words",
                ru: "\(Int(roomCustomWordCount)) слов",
                es: "\(Int(roomCustomWordCount)) palabras",
                uk: "\(Int(roomCustomWordCount)) слів"
            )
        }
    }

    private func roomThemeMetaLabel(maxWords: Int) -> String {
        return localized(
            en: "AI POOL · \(maxWords) AVAILABLE",
            ru: "AI-ПУЛ · \(maxWords) ДОСТУПНО",
            es: "BANCO IA · \(maxWords) DISPONIBLES",
            uk: "AI-ПУЛ · ДОСТУПНО \(maxWords)"
        )
    }

    private func configTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker(lines: 2)
            Text(value)
                .font(.system(size: 15, weight: .black, design: .default))
                .tracking(value.count > 10 ? 0.0 : 0.08)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .spyCutCard(cut: 8, fill: SpyTheme.panelDeep, stroke: SpyTheme.stroke)
    }

    private func setupMenuLabel(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpyTheme.red)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SpyTheme.micro)
                        .tracking(0.12)
                        .foregroundStyle(SpyTheme.dim)
                        .spyKicker(lines: 2)
                    Text(isLoadingLobbyPacks ? copy.syncingWordPacks : value)
                    .font(.system(size: 11, weight: .bold, design: .default))
                    .tracking(0.02)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(SpyTheme.dim)
        }
        .padding(12)
        .spyCutCard(cut: 8, fill: SpyTheme.panelDeep, stroke: SpyTheme.stroke)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.dim)
                    .spyKicker()
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .font(SpyTheme.micro)
                    .tracking(0.12)
                    .foregroundStyle(SpyTheme.red)
                    .spyFitted(scale: 0.66, alignment: .trailing)
            }
            SpyWebSlider(
                value: value,
                range: range,
                language: appState.language,
                step: 1
            )
        }
    }

    private func turnAgent(title: String, player: Player?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SpyTheme.micro)
                .tracking(0.12)
                .foregroundStyle(SpyTheme.dim)
                .spyKicker()
            Text(player?.name.uppercased() ?? copy.pending)
                .font(.system(size: 18, weight: .black, design: .default))
                .tracking(0.04)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SpyTheme.panelDeep)
        .overlay(Rectangle().stroke(SpyTheme.stroke))
    }

    private func inlineBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .black, design: .default))
            .tracking(0.02)
            .foregroundStyle(color)
            .spyFitted(scale: 0.66, alignment: .center)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(color.opacity(0.08))
            .overlay(Rectangle().stroke(color.opacity(0.35)))
    }

    private func copyRoomCode(_ room: GameRoom) {
        UIPasteboard.general.string = room.code
        copiedRoomCode = true
        status = roomCopiedTitle
        HapticManager.shared.fire(.notification(.success))

        Task {
            try? await Task.sleep(for: .milliseconds(2800))
            await MainActor.run {
                copiedRoomCode = false
            }
        }
    }

    private var customCategoryFallback: String {
        localized(
            en: "CUSTOM",
            ru: "СВОЯ ТЕМА",
            es: "PERSONALIZADO",
            uk: "ВЛАСНА ТЕМА"
        )
    }

    private var customNameFallback: String {
        localized(
            en: "Custom",
            ru: "Своя тема",
            es: "Personalizado",
            uk: "Власна тема"
        )
    }

    private var lobbyNameFallback: String {
        localized(en: "Lobby", ru: "Лобби", es: "Sala", uk: "Лобі")
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch appState.language {
        case .ru:
            ru
        case .es:
            es
        case .uk:
            uk
        default:
            en
        }
    }

    private func exclusionVoteRule(_ room: GameRoom) -> String {
        localized(
            en: "Exclusion requires \(room.exclusionVoteThreshold) of \(room.activePlayers.count) votes for one suspect.",
            ru: "Для исключения нужно \(room.exclusionVoteThreshold) из \(room.activePlayers.count) голосов за одного игрока.",
            es: "La exclusion requiere \(room.exclusionVoteThreshold) de \(room.activePlayers.count) votos por un sospechoso.",
            uk: "Для виключення потрібно \(room.exclusionVoteThreshold) із \(room.activePlayers.count) голосів за одного підозрюваного."
        )
    }

    private var exclusionVoteCancellationHint: String {
        localized(
            en: "The server cancels the vote as soon as that result becomes impossible.",
            ru: "Сервер отменит голосование, как только такой результат станет невозможен.",
            es: "El servidor cancela la votacion en cuanto ese resultado sea imposible.",
            uk: "Сервер скасує голосування, щойно такий результат стане неможливим."
        )
    }

    private var detectiveVoteCancelledStatus: String {
        localized(
            en: "VOTE CANCELLED — THE REQUIRED RESULT IS NO LONGER POSSIBLE",
            ru: "ГОЛОСОВАНИЕ ОТМЕНЕНО — НУЖНЫЙ РЕЗУЛЬТАТ УЖЕ НЕВОЗМОЖЕН",
            es: "VOTACION CANCELADA — EL RESULTADO REQUERIDO YA NO ES POSIBLE",
            uk: "ГОЛОСУВАННЯ СКАСОВАНО — ПОТРІБНИЙ РЕЗУЛЬТАТ УЖЕ НЕМОЖЛИВИЙ"
        )
    }

    private var detectiveVoteSyncDelayedStatus: String {
        localized(
            en: "VOTE RESULT SYNC IS DELAYED",
            ru: "СИНХРОНИЗАЦИЯ ИТОГА ГОЛОСОВАНИЯ ЗАДЕРЖИВАЕТСЯ",
            es: "LA SINCRONIZACION DEL RESULTADO DE LA VOTACION SE RETRASA",
            uk: "СИНХРОНІЗАЦІЯ РЕЗУЛЬТАТУ ГОЛОСУВАННЯ ЗАТРИМУЄТЬСЯ"
        )
    }

    private func player(for email: String?, in room: GameRoom) -> Player? {
        guard let email else { return nil }
        return room.playersList.first { $0.email == email }
    }

    private func spyTeamResult(_ spies: [Player]) -> String {
        guard !spies.isEmpty else { return copy.spyResult(copy.pending) }
        if spies.count == 1 {
            return copy.spyResult(spies[0].name)
        }
        let names = spies.map { $0.name.uppercased() }.joined(separator: ", ")
        return "\(localized(en: "SPIES", ru: "ШПИОНЫ", es: "ESPIAS", uk: "ШПИГУНИ")): \(names)"
    }

    private func spyVictoryTitle(_ room: GameRoom) -> String {
        guard room.lobbySpyCountValue > 1 else { return copy.spyWins }
        return localized(
            en: "SPIES WIN",
            ru: "ШПИОНЫ ПОБЕДИЛИ",
            es: "GANAN LOS ESPIAS",
            uk: "ШПИГУНИ ПЕРЕМОГЛИ"
        )
    }

    private func votingCandidates(in room: GameRoom) -> [Player] {
        let eliminated = Set((room.eliminatedEmails ?? []).map { $0.lowercased() })
        return room.activePlayers.filter { player in
            !eliminated.contains(player.email.lowercased()) &&
                !emailsMatch(player.email, appState.user?.email)
        }
    }

    private func compactPlayerName(_ name: String) -> String {
        let uppercased = name.uppercased()
        guard uppercased.count > 7 else { return uppercased }
        return "\(uppercased.prefix(6))…"
    }

    private func rouletteTarget(_ room: GameRoom) -> Player? {
        player(for: room.rouletteTargetEmail ?? room.currentAskerEmail, in: room)
    }

    private func isHost(_ room: GameRoom) -> Bool {
        room.hostEmail == appState.user?.email
    }

    private func currentUserIsReady(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return (room.readyPlayers ?? []).contains(email)
    }

    private func currentUserIsSpy(_ room: GameRoom) -> Bool {
        room.isSpy(email: appState.user?.email)
    }

    private func allPlayersReady(_ room: GameRoom) -> Bool {
        let ready = Set((room.readyPlayers ?? []).map(normalizedEmailKey))
        let eligiblePlayers = room.replayEligiblePlayersList
        return eligiblePlayers.count >= 3 && eligiblePlayers.allSatisfy {
            ready.contains(normalizedEmailKey($0.email))
        }
    }

    private func isCurrentUserSpectator(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return room.spectatorsList.contains(email)
    }

    private func hasCurrentUserRequestedVote(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return room.voteRequestsList.contains { emailsMatch($0, email) }
    }

    private func myVote(in room: GameRoom) -> VoteRecord? {
        guard let email = appState.user?.email else { return nil }
        return room.detectiveVotesList.first { $0.voterEmail == email }
    }

    private func currentUserHasReadCard(_ room: GameRoom) -> Bool {
        guard let email = appState.user?.email else { return false }
        return room.cardsReadList.contains(email)
    }

    private func roomStateLabel(_ room: GameRoom) -> String {
        if room.normalizedStatus == "playing" && !room.allRoleCardsRead { return copy.dealing }
        if room.isGamePaused { return localized(en: "PAUSED", ru: "ПАУЗА", es: "PAUSA", uk: "ПАУЗА") }
        if room.isVotingActive { return copy.voting }
        if room.questionPhase == "results" { return copy.results }
        return copy.statusLabel(room.normalizedStatus)
    }

    private func voteButtonTitle(_ room: GameRoom) -> String {
        if hasCurrentUserRequestedVote(room) { return copy.voteRequestedStatus }
        if room.isVotingActive { return copy.votingOpen }
        return copy.requestVote(room.activeVoteRequests.count, threshold: room.voteThreshold)
    }

    private func roleTitle(isSpy: Bool, isSpectator: Bool) -> String {
        if isSpectator { return copy.spectatorMode }
        return isSpy ? copy.youAreSpy : copy.youAreDetective
    }

    private func roleSubtitle(isSpy: Bool, isSpectator: Bool, room: GameRoom) -> String {
        if isSpectator { return copy.spectatorSubtitle }
        if isSpy { return copy.categorySubtitle(room.category) }
        return copy.secretWord
    }

    private func remainingSeconds(_ room: GameRoom) -> Int {
        let timer = OnlineTimerSnapshot(room: room, now: now)
        return timer.hasDeadline
            ? timer.displayedSeconds
            : max(room.gameDurationSeconds ?? 0, 0)
    }

    private func isTimeExpired(_ room: GameRoom) -> Bool {
        OnlineTimerSnapshot(room: room, now: now).isExpired
    }

    private func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func timeString(_ seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        let remainder = max(seconds, 0) % 60
        return "\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    private func setRoomThemeDraft(_ currentTheme: String) {
        let previousTheme = roomTheme
        guard previousTheme != currentTheme else { return }
        roomTheme = currentTheme
        roomGeneratedLobbySource = .ai
        updateRoomThemeDraft(from: previousTheme, to: currentTheme)
        scheduleLobbyStateSync(debounce: .milliseconds(260))
    }

    private func updateRoomThemeDraft(from previousTheme: String, to currentTheme: String) {
        let previousValue = previousTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentValue = currentTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previousValue != currentValue else { return }

        let previouslyHadTheme = previousValue.nilIfBlank != nil
        let hasTheme = currentValue.nilIfBlank != nil

        if !previouslyHadTheme, hasTheme {
            roomThemeFallbackSource = roomWordSource == .generated ? .none : roomWordSource
        }

        roomGeneratedPack = nil
        roomThemeError = ""
        showsAllRoomPoolWords = false
        disabledRoomPoolWordKeys.removeAll()

        if hasTheme {
            roomWordSource = .generated
        } else if previouslyHadTheme {
            roomWordSource = resolvedRoomFallbackSource
            roomThemeFallbackSource = .none
        }
    }

    private func selectRoomPack(_ id: String?) {
        let source = id.map(RoomWordSource.saved) ?? .none
        roomThemeFallbackSource = roomHasCustomTheme ? source : .none
        roomWordSource = source
        roomTheme = ""
        roomGeneratedPack = nil
        roomThemeError = ""
        showsAllRoomPoolWords = false
        disabledRoomPoolWordKeys.removeAll()
        scheduleLobbyStateSync(debounce: .milliseconds(80))
    }

    private var resolvedRoomFallbackSource: RoomWordSource {
        guard case let .saved(id) = roomThemeFallbackSource else { return .none }
        return lobbyWordPacks.contains(where: { $0.id == id }) ? .saved(id) : .none
    }

    private func generateRoomTheme(usingInitialTarget: Bool) async {
        let theme = roomTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let operationRoom = appState.activeRoom,
              isHost(operationRoom),
              operationRoom.normalizedStatus == "waiting",
              !theme.isEmpty,
              roomThemeOperation == nil else { return }
        let operationRoomID = operationRoom.id
        let requestID = UUID()

        let targetCount: Int
        if usingInitialTarget {
            targetCount = roomWordCountMode == .custom
                ? Int(roomCustomWordCount)
                : WordPackRecommendedCountPolicy.requestCount(for: theme)
        } else {
            targetCount = roomThemeMaxWords
        }

        roomThemeOperation = .generate
        roomThemeError = ""
        defer { roomThemeOperation = nil }

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                generated = GeneratedWordPack(
                    name: "\(theme) Kit",
                    category: theme,
                    words: (1...max(targetCount, 5)).map { "\(theme) \($0)" },
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
            } else {
                _ = try await appState.confirmedLobbyRoom(
                    roomID: operationRoomID,
                    allowedStatuses: ["waiting"]
                )
                guard let currentRoom = appState.activeRoom,
                      currentRoom.id == operationRoomID,
                      isHost(currentRoom),
                      currentRoom.normalizedStatus == "waiting",
                      roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }
                generated = try await appState.client.generateWordPack(
                    theme: theme,
                    count: max(targetCount, 5),
                    requestID: requestID,
                    preferFresh: !usingInitialTarget
                )
            }
            guard let currentRoom = appState.activeRoom,
                  currentRoom.id == operationRoomID,
                  isHost(currentRoom),
                  currentRoom.normalizedStatus == "waiting",
                  roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }

            let words = generated.words.roomCleanWords
            guard words.count >= 2 else {
                roomThemeError = localized(
                    en: "Couldn't recognize this theme. Try another.",
                    ru: "Не удалось распознать тему. Попробуй другую.",
                    es: "No se pudo reconocer el tema. Prueba otro.",
                    uk: "Не вдалося розпізнати цю тему. Спробуй іншу."
                )
                HapticManager.shared.fire(.notification(.warning))
                return
            }

            let cleanGenerated = GeneratedWordPack(
                name: generated.name,
                category: generated.category.nilIfBlank ?? theme,
                words: words,
                aiLimit: generated.aiLimit,
                aiGenerationsToday: generated.aiGenerationsToday,
                aiRemaining: generated.aiRemaining
            )
            roomGeneratedPack = cleanGenerated
            roomGeneratedLobbySource = .ai
            disabledRoomPoolWordKeys.removeAll()
            if usingInitialTarget {
                let selectedCount = roomWordCountMode == .custom
                    ? min(words.count, Int(roomCustomWordCount))
                    : WordPackRecommendedCountPolicy.selectedCount(
                        for: theme,
                        availableCount: words.count
                    )
                roomWordCount = Double(selectedCount)
            } else {
                roomWordCount = Double(min(max(Int(roomWordCount), 2), words.count))
            }
            roomWordSource = .generated
            showsAllRoomPoolWords = false
            scheduleLobbyStateSync(debounce: .milliseconds(80))
            status = localized(en: "AI WORD POOL READY", ru: "AI-ПУЛ СЛОВ ГОТОВ", es: "BANCO IA LISTO", uk: "AI-ПУЛ СЛІВ ГОТОВИЙ")
            HapticManager.shared.fire(.milestone)
        } catch {
            guard appState.activeRoom?.id == operationRoomID,
                  roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }
            roomThemeError = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func pushRoomThemeMax() async {
        let theme = roomTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPack = roomGeneratedPack
        let current = currentPack?.words.roomCleanWords ?? []
        let selectedWordCount = Int(roomWordCount)
        let wasUsingEntirePool = selectedWordCount >= current.count
        guard let operationRoom = appState.activeRoom,
              isHost(operationRoom),
              operationRoom.normalizedStatus == "waiting",
              !theme.isEmpty,
              current.count >= 2,
              roomThemeOperation == nil else { return }
        let operationRoomID = operationRoom.id
        let requestID = UUID()

        let additionalCount = min(50, 200 - current.count)
        roomThemeOperation = .expand
        roomThemeError = ""
        defer { roomThemeOperation = nil }

        do {
            let generated: GeneratedWordPack
            if appState.shouldUsePreviewData {
                generated = GeneratedWordPack(
                    name: "\(theme) Kit",
                    category: theme,
                    words: (1...additionalCount).map { "\(theme) \(current.count + $0)" },
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
            } else {
                _ = try await appState.confirmedLobbyRoom(
                    roomID: operationRoomID,
                    allowedStatuses: ["waiting"]
                )
                guard let currentRoom = appState.activeRoom,
                      currentRoom.id == operationRoomID,
                      isHost(currentRoom),
                      currentRoom.normalizedStatus == "waiting",
                      roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }
                generated = try await appState.client.generateWordPack(
                    theme: theme,
                    count: additionalCount,
                    requestID: requestID,
                    excluding: current,
                    preferFresh: false
                )
            }
            guard let currentRoom = appState.activeRoom,
                  currentRoom.id == operationRoomID,
                  isHost(currentRoom),
                  currentRoom.normalizedStatus == "waiting",
                  roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }

            var seen = Set(current.map { $0.lowercased() })
            let additions = generated.words.roomCleanWords.filter { seen.insert($0.lowercased()).inserted }
            let merged = Array((current + additions).prefix(200))
            guard merged.count > current.count else {
                roomThemeError = localized(
                    en: "Couldn't find more unique words.",
                    ru: "Больше уникальных слов найти не удалось.",
                    es: "No se encontraron mas palabras unicas.",
                    uk: "Не вдалося знайти більше унікальних слів."
                )
                HapticManager.shared.fire(.notification(.warning))
                return
            }

            roomGeneratedPack = GeneratedWordPack(
                name: generated.name ?? currentPack?.name,
                category: generated.category.nilIfBlank ?? currentPack?.category ?? theme,
                words: merged,
                aiLimit: generated.aiLimit,
                aiGenerationsToday: generated.aiGenerationsToday,
                aiRemaining: generated.aiRemaining
            )
            roomGeneratedLobbySource = .ai
            disabledRoomPoolWordKeys = disabledRoomPoolWordKeys.filter { key in
                merged.contains { roomWordKey($0) == key }
            }
            let nextSelectedCount = if roomWordCountMode == .recommended {
                WordPackRecommendedCountPolicy.selectedCount(
                    for: theme,
                    availableCount: merged.count
                )
            } else if wasUsingEntirePool {
                merged.count
            } else {
                min(merged.count, max(selectedWordCount, 2))
            }
            roomWordCount = Double(nextSelectedCount)
            roomWordSource = .generated
            showsAllRoomPoolWords = false
            scheduleLobbyStateSync(debounce: .milliseconds(80))
            status = localized(en: "AI WORD POOL EXPANDED", ru: "AI-ПУЛ СЛОВ РАСШИРЕН", es: "BANCO IA AMPLIADO", uk: "AI-ПУЛ СЛІВ РОЗШИРЕНО")
            HapticManager.shared.fire(.milestone)
        } catch {
            guard appState.activeRoom?.id == operationRoomID,
                  roomTheme.trimmingCharacters(in: .whitespacesAndNewlines) == theme else { return }
            roomThemeError = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func saveRoomThemePack() async {
        guard let email = appState.user?.email else { return }
        guard let roomGeneratedPack else { return }
        let words = activeRoomWords(roomGeneratedPack.words)
        guard words.count >= 2 else { return }
        let name = roomGeneratedPack.name?.nilIfBlank
            ?? roomGeneratedPack.category.nilIfBlank
            ?? roomTheme.nilIfBlank
            ?? customNameFallback
        let pack = WordPack(
            id: "generated",
            name: name,
            category: roomGeneratedPack.category.nilIfBlank ?? name,
            words: words,
            ownerEmail: email,
            isPublic: false
        )

        isSavingRoomThemePack = true
        defer { isSavingRoomThemePack = false }

        if appState.shouldUsePreviewData {
            let previewPack = WordPack(
                id: "preview-saved-\(UUID().uuidString)",
                name: pack.name,
                category: pack.category,
                words: pack.words,
                ownerEmail: email,
                isPublic: false
            )
            lobbyWordPacks.append(previewPack)
            lobbyPackLoadState = .loaded
            status = localized(en: "WORDPACK SAVED", ru: "WORDPACK СОХРАНЕН", es: "WORDPACK GUARDADO", uk: "НАБІР СЛІВ ЗБЕРЕЖЕНО")
            HapticManager.shared.fire(.milestone)
            return
        }

        do {
            let saved = try await appState.client.createWordPack(
                name: pack.name,
                category: pack.category ?? pack.name,
                words: pack.words ?? [],
                ownerEmail: email
            )
            lobbyWordPacks.append(saved)
            lobbyWordPacks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lobbyPackLoadState = .loaded
            appState.markWordPacksChanged()
            status = localized(en: "WORDPACK SAVED", ru: "WORDPACK СОХРАНЕН", es: "WORDPACK GUARDADO", uk: "НАБІР СЛІВ ЗБЕРЕЖЕНО")
            HapticManager.shared.fire(.milestone)
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func roomHasAuthoritativeLobbySelection(_ room: GameRoom) -> Bool {
        let source = LobbyWordSource(rawValue: room.lobbyWordSource ?? "none") ?? .none
        return source != .none ||
            !(room.lobbyWordPool ?? []).isEmpty ||
            room.lobbyTheme?.nilIfBlank != nil
    }

    private func applyAuthoritativeLobbyState(from room: GameRoom, force: Bool = false) {
        let revision = max(room.lobbyRevision ?? 0, 0)
        let authoritativeState = appState.authoritativeLobbyStatePayload(from: room)
        let currentState = authoritativeState.map { _ in
            currentLobbyStatePayload(for: room)
        }
        let isEditingLobbySlider = LobbyPresentationPolicy.shouldDeferAuthoritativeUpdate(
            isDraggingDuration: isDraggingOnlineDuration,
            isDraggingWordCount: isDraggingOnlineWordCount,
            isDraggingSpyCount: isDraggingOnlineSpyCount
        )
        let hasProtectedOptimisticChanges = isHost(room) &&
            appState.hasOptimisticLobbySettingsChanges
        let hasLegacyPresentationChange = revision == 0 && (
            selectedGameMode != room.gameModeValue ||
                Int(selectedDurationMinutes) != max(1, min((room.gameDurationSeconds ?? 900) / 60, 15))
        )
        switch LobbyPresentationPolicy.authoritativeUpdateDisposition(
            appliedRevision: appliedLobbyRevision,
            incomingRevision: revision,
            currentState: currentState,
            authoritativeState: authoritativeState,
            isEditingLobbySlider: isEditingLobbySlider,
            hasOptimisticChanges: hasProtectedOptimisticChanges,
            force: force,
            hasLegacyPresentationChange: hasLegacyPresentationChange
        ) {
        case .deferUpdate:
            deferredLobbyUpdate.record(force: force)
            return
        case .ignore:
            deferredLobbyUpdate.clear()
            return
        case .apply:
            break
        }

        selectedGameMode = room.gameModeValue
        selectedDurationMinutes = Double(max(1, min((room.gameDurationSeconds ?? 900) / 60, 15)))
        selectedSpyCount = Double(min(room.lobbySpyCountValue, room.maximumLobbySpyCount))
        selectedSpiesKnowEachOther = room.spiesKnowEachOther ?? false

        guard let authoritativeState else {
            appliedLobbyRevision = max(appliedLobbyRevision, revision)
            deferredLobbyUpdate.clear()
            return
        }

        let currentLobbyState = currentLobbyStatePayload(for: room)
        let currentPoolIdentity = LobbyPoolIdentity(state: currentLobbyState)
        let incomingPoolIdentity = LobbyPoolIdentity(state: authoritativeState)
        let shouldResetExpandedPool = LobbyPresentationPolicy.shouldResetExpandedPool(
            current: currentPoolIdentity,
            incoming: incomingPoolIdentity,
            currentWordKeys: Set(
                currentLobbyState.lobbyWordPool.map { roomWordKey($0.word) }
            ),
            incomingWordKeys: Set(
                authoritativeState.lobbyWordPool.map { roomWordKey($0.word) }
            )
        )
        let source = authoritativeState.lobbyWordSource
        let entries = authoritativeState.lobbyWordPool
        let words = entries.map(\.word).roomCleanWords
        roomTheme = authoritativeState.lobbyTheme ?? ""
        roomWordCountMode = authoritativeState.lobbyWordCountMode == .custom
            ? .custom
            : .recommended
        let authoritativeCount = max(min(authoritativeState.lobbyWordCount, 200), 0)
        let normalizedRecommendedCount = LobbyRecommendedCountMigrationPolicy.normalizedCount(
            for: roomTheme,
            authoritativeCount: authoritativeCount,
            availableCount: entries.filter(\.enabled).count
        )
        let shouldApplyRecommendedCountPolicy = roomWordCountMode == .recommended
            && LobbyRecommendedCountMigrationPolicy.applies(to: source)
        let shouldPersistRecommendedCountNormalization = shouldApplyRecommendedCountPolicy
            && LobbyRecommendedCountMigrationPolicy.requiresServerSync(
                authoritativeCount: authoritativeCount,
                normalizedCount: normalizedRecommendedCount
            )
            && isHost(room)
            && room.normalizedStatus == "waiting"
        roomWordCount = if shouldApplyRecommendedCountPolicy {
            Double(normalizedRecommendedCount)
        } else {
            Double(authoritativeCount)
        }
        if roomWordCountMode == .custom {
            roomCustomWordCount = Double(max(min(authoritativeCount, 80), 10))
        }
        disabledRoomPoolWordKeys = Set(
            entries.filter { !$0.enabled }.map { roomWordKey($0.word) }
        )
        if shouldResetExpandedPool, isHost(room) {
            showsAllRoomPoolWords = false
        }
        roomThemeFallbackSource = .none

        switch source {
        case .ai, .manual:
            roomWordSource = .generated
            roomGeneratedLobbySource = source
            roomGeneratedPack = words.isEmpty
                ? nil
                : GeneratedWordPack(
                    name: authoritativeState.lobbySourceName,
                    category: authoritativeState.lobbyCategory?.nilIfBlank
                        ?? authoritativeState.lobbyTheme?.nilIfBlank
                        ?? customCategoryFallback,
                    words: words,
                    aiLimit: nil,
                    aiGenerationsToday: nil
                )
        case .saved:
            roomWordSource = .saved(
                authoritativeState.lobbySourcePackID?.nilIfBlank ?? "remote:\(room.id)"
            )
            roomGeneratedLobbySource = .ai
            roomGeneratedPack = nil
        case .none:
            roomWordSource = .none
            roomGeneratedLobbySource = .ai
            roomGeneratedPack = nil
        }

        appliedLobbyRevision = revision
        deferredLobbyUpdate.clear()
        if shouldPersistRecommendedCountNormalization {
            scheduleLobbyStateSync(debounce: .milliseconds(80))
        }
    }

    private func reconcileAuthoritativeLobbyStateAfterSliderInteraction() {
        guard !isDraggingOnlineDuration,
              !isDraggingOnlineWordCount,
              !isDraggingOnlineSpyCount,
              !appState.hasOptimisticLobbySettingsChanges,
              let room = appState.activeRoom else { return }
        let force = deferredLobbyUpdate.requiresForce ||
            appState.lobbySettingsSyncFailure != nil
        applyAuthoritativeLobbyState(
            from: room,
            force: force
        )
    }

    private func currentLobbyStatePayload(for room: GameRoom) -> LobbyStatePayload {
        let source: LobbyWordSource
        let sourcePackID: String?
        let sourceName: String?
        let category: String?
        let rawWords: [String]

        switch roomWordSource {
        case .none:
            source = .none
            sourcePackID = nil
            sourceName = nil
            category = roomTheme.nilIfBlank
            rawWords = []
        case .generated:
            source = roomGeneratedLobbySource == .manual ? .manual : .ai
            sourcePackID = nil
            sourceName = roomGeneratedPack?.name?.nilIfBlank
                ?? roomGeneratedPack?.category.nilIfBlank
                ?? roomTheme.nilIfBlank
            category = roomGeneratedPack?.category.nilIfBlank ?? roomTheme.nilIfBlank
            rawWords = LobbyDraftPoolPolicy.generatedPayloadWords(
                localWords: roomGeneratedPack?.words,
                priorAuthoritativeWords: (room.lobbyWordPool ?? []).map(\.word)
            ).roomCleanWords
        case let .saved(id):
            source = .saved
            sourcePackID = id.hasPrefix("remote:") ? room.lobbySourcePackID : id
            let pack = lobbyWordPacks.first(where: { $0.id == id })
            sourceName = pack?.name.nilIfBlank ?? room.lobbySourceName?.nilIfBlank
            category = pack?.category?.nilIfBlank ?? room.lobbyCategory?.nilIfBlank
            rawWords = pack?.words?.roomCleanWords
                ?? (room.lobbyWordPool ?? []).map(\.word).roomCleanWords
        }

        var existingIDsByWordKey: [String: String] = [:]
        for entry in room.lobbyWordPool ?? [] {
            if let id = entry.serverID?.nilIfBlank {
                existingIDsByWordKey[roomWordKey(entry.word)] = id
            }
        }
        let pool = Array(rawWords.prefix(200)).map { word in
            LobbyWordPoolEntry(
                id: existingIDsByWordKey[roomWordKey(word)],
                word: word,
                enabled: !disabledRoomPoolWordKeys.contains(roomWordKey(word))
            )
        }
        let enabledCount = pool.filter(\.enabled).count
        let selectedCount: Int
        switch source {
        case .ai, .manual:
            selectedCount = pool.isEmpty && roomWordCountMode == .custom
                ? Int(roomCustomWordCount)
                : min(max(Int(roomWordCount), 0), enabledCount)
        case .saved:
            selectedCount = enabledCount
        case .none:
            selectedCount = roomWordCountMode == .custom ? Int(roomCustomWordCount) : 0
        }

        return LobbyStatePayload(
            gameMode: selectedGameMode,
            gameDurationSeconds: max(60, min(Int(selectedDurationMinutes.rounded()) * 60, 900)),
            spyCount: min(max(Int(selectedSpyCount.rounded()), 1), room.maximumLobbySpyCount),
            spiesKnowEachOther: selectedSpiesKnowEachOther,
            lobbyWordSource: source,
            lobbySourcePackID: sourcePackID,
            lobbySourceName: sourceName,
            lobbyTheme: roomTheme.nilIfBlank,
            lobbyCategory: category,
            lobbyWordCount: max(0, min(selectedCount, 200)),
            lobbyWordCountMode: roomWordCountMode == .custom ? .custom : .recommended,
            lobbyWordPool: pool
        )
    }

    private func scheduleLobbyStateSync(debounce: Duration = .milliseconds(160)) {
        guard let room = appState.activeRoom,
              isHost(room),
              room.normalizedStatus == "waiting" else { return }

        let state = currentLobbyStatePayload(for: room)
        appState.enqueueLobbySettings(
            roomID: room.id,
            state: state,
            confirmedState: appState.authoritativeLobbyStatePayload(from: room),
            debounce: debounce
        )
    }

    private func configureLobby(_ room: GameRoom) async {
        if configuredRoomID != room.id {
            appliedLobbyRevision = -1
            configuredRoomID = room.id
            selectedGameMode = room.gameModeValue
            selectedDurationMinutes = Double(max((room.gameDurationSeconds ?? 900) / 60, 1))
            selectedSpyCount = Double(min(room.lobbySpyCountValue, room.maximumLobbySpyCount))
            selectedSpiesKnowEachOther = room.spiesKnowEachOther ?? false
            roomAccessPage = RoomAccessPagePolicy.roomCode
            roomFriendsDirectory.deactivate()
            roomFriendsLoadAttempt = 0
            isRoomCodeVisible = false
            isRoomQRVisible = false
            roomThemeFallbackSource = .none
            roomWordSource = .none
            roomTheme = ""
            roomGeneratedPack = nil
            roomGeneratedLobbySource = .ai
            roomThemeError = ""
            roomWordCount = 25
            roomCustomWordCount = 25
            roomWordCountMode = .recommended
            showsAllRoomPoolWords = false
            disabledRoomPoolWordKeys.removeAll()
            pendingStartPlan = nil
            rouletteCompletionKey = nil
            isDraggingOnlineDuration = false
            isDraggingOnlineWordCount = false
            deferredLobbyUpdate.clear()
            applyAuthoritativeLobbyState(from: room, force: true)
        }

        consumeRoomFriendsNavigationRequestIfNeeded()

        if appState.shouldUsePreviewData {
            lobbyWordPacks = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-no-wordpacks")
                ? []
                : WordPack.previewPacks
            lobbyPackLoadState = .loaded
            return
        }

        await loadLobbyWordPacks()
    }

    private func consumeRoomFriendsNavigationRequestIfNeeded() {
        guard let room = appState.activeRoom,
              configuredRoomID == room.id,
              appearedRoomMissionPanelID == room.id,
              appState.consumeRoomFriendsNavigationRequest(for: room) else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            roomAccessPage = RoomAccessPagePolicy.friends
        }
    }

    private func loadLobbyWordPacks(force: Bool = false) async {
        if appState.shouldUsePreviewData {
            lobbyWordPacks = ProcessInfo.processInfo.arguments.contains("--spyclash-preview-no-wordpacks")
                ? []
                : WordPack.previewPacks
            lobbyPackLoadState = .loaded
            return
        }

        guard force || lobbyPackLoadState != .loaded else { return }
        guard let email = appState.user?.email else {
            lobbyPackLoadState = .failed(localized(
                en: "Sign in again to load your decks.",
                ru: "Войдите снова, чтобы загрузить колоды.",
                es: "Inicia sesion de nuevo para cargar tus packs.",
                uk: "Увійди знову, щоб завантажити свої набори слів."
            ))
            return
        }

        let requestRoomID = appState.activeRoom?.id
        let payloadBeforeReload = appState.activeRoom.flatMap { room -> LobbyStatePayload? in
            guard isHost(room), room.normalizedStatus == "waiting" else { return nil }
            return currentLobbyStatePayload(for: room)
        }
        lobbyPackLoadState = .loading
        do {
            let loadedPacks = try await appState.client.wordPacks(ownerEmail: email)
            guard appState.activeRoom?.id == requestRoomID else { return }
            lobbyWordPacks = loadedPacks
            let mayValidateSelectedPack = appState.activeRoom.map {
                isHost($0) && $0.normalizedStatus == "waiting"
            } ?? false
            if mayValidateSelectedPack,
               case let .saved(id) = roomWordSource,
               !lobbyWordPacks.contains(where: { $0.id == id }) {
                roomWordSource = .none
                showsAllRoomPoolWords = false
                disabledRoomPoolWordKeys.removeAll()
            } else if mayValidateSelectedPack,
                      case let .saved(id) = roomWordSource,
                      let selectedPack = lobbyWordPacks.first(where: { $0.id == id }) {
                let availableKeys = Set((selectedPack.words ?? []).roomCleanWords.map(roomWordKey))
                disabledRoomPoolWordKeys.formIntersection(availableKeys)
            }
            lobbyPackLoadState = .loaded
            if let room = appState.activeRoom,
               let payloadBeforeReload,
               !currentLobbyStatePayload(for: room)
                .equivalentForLobbySync(to: payloadBeforeReload) {
                scheduleLobbyStateSync(debounce: .milliseconds(80))
            }
        } catch {
            lobbyPackLoadState = .failed(error.localizedDescription)
        }
    }

    private func updateMode(_ room: GameRoom, mode: SpyGameMode) async {
        guard let currentRoom = appState.activeRoom,
              currentRoom.id == room.id,
              isHost(currentRoom),
              currentRoom.normalizedStatus == "waiting" else { return }
        selectedGameMode = mode
        appState.enqueueLobbyGameMode(roomID: currentRoom.id, mode: mode)
        await Task.yield()
    }

    private func beginDurationUpdate(_ room: GameRoom, minutes: Int) {
        let clampedMinutes = max(1, min(minutes, 15))
        guard let currentRoom = appState.activeRoom,
              currentRoom.id == room.id,
              isHost(currentRoom),
              currentRoom.normalizedStatus == "waiting" else { return }

        isDraggingOnlineDuration = false
        reconcileAuthoritativeLobbyStateAfterSliderInteraction()
        selectedDurationMinutes = Double(clampedMinutes)
        scheduleLobbyStateSync(debounce: .milliseconds(140))
    }

    private func beginSpyCountUpdate(_ room: GameRoom, count: Int) {
        guard let currentRoom = appState.activeRoom,
              currentRoom.id == room.id,
              isHost(currentRoom),
              currentRoom.normalizedStatus == "waiting" else { return }

        isDraggingOnlineSpyCount = false
        let clampedCount = min(max(count, 1), currentRoom.maximumLobbySpyCount)
        selectedSpyCount = Double(clampedCount)
        scheduleLobbyStateSync(debounce: .milliseconds(90))
        reconcileAuthoritativeLobbyStateAfterSliderInteraction()
    }

    private func updateSpiesKnowEachOther(_ room: GameRoom, enabled: Bool) {
        guard let currentRoom = appState.activeRoom,
              currentRoom.id == room.id,
              isHost(currentRoom),
              currentRoom.normalizedStatus == "waiting" else { return }
        selectedSpiesKnowEachOther = enabled
        scheduleLobbyStateSync(debounce: .milliseconds(90))
        HapticManager.shared.fire(.tabSelection)
    }

    private func reconcileSpyCountForRosterChange() {
        guard let room = appState.activeRoom,
              room.normalizedStatus == "waiting",
              isHost(room) else { return }
        let maximum = room.maximumLobbySpyCount
        selectedSpyCount = Double(min(room.lobbySpyCountValue, maximum))
    }

    private func beginReadyCheck(_ room: GameRoom) async {
        guard let currentRoom = appState.activeRoom,
              currentRoom.id == room.id,
              isHost(currentRoom),
              currentRoom.normalizedStatus == "waiting",
              !isStarting,
              lobbySetupCanAdvance(currentRoom) else { return }
        let operationUserID = appState.user?.id
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "ready_voting")
            status = copy.readyCheckSent
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let updatedRoom = try await appState.client.beginReadyCheck(room: currentRoom)
            guard appState.user?.id == operationUserID,
                  appState.activeRoom?.id == currentRoom.id else { return }
            appState.activeRoom = updatedRoom
            status = copy.readyCheckSent
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func beginReadyToggle(_ room: GameRoom) {
        guard !isTogglingReady,
              room.normalizedStatus == "ready_voting",
              appState.user != nil else { return }
        isTogglingReady = true
        HapticManager.shared.fire(.buttonPress)
        Task { await toggleReady(room) }
    }

    private func beginActiveLobbyReturnVote(_ room: GameRoom) {
        guard let request = activeLobbyReturnVoteState.begin(
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email,
            requestID: UUID()
        ) else { return }
        Task { await performActiveLobbyReturnVote(request, room: room) }
    }

    private func performActiveLobbyReturnVote(
        _ request: ActiveLobbyReturnRequest,
        room: GameRoom
    ) async {
        do {
            let candidate: GameRoom
            if appState.shouldUsePreviewData {
                await Task.yield()
                candidate = previewActiveLobbyReturnCandidate(
                    room: room,
                    request: request
                )
            } else {
                candidate = try await appState.client.voteReturnToLobby(
                    room: room,
                    vote: request.targetVote
                )
            }

            guard adoptActiveLobbyReturnCandidate(candidate, request: request) else {
                if !appState.shouldUsePreviewData,
                   await recoverActiveLobbyReturnVote(request) {
                    return
                }
                guard failActiveLobbyReturnVote(request) else { return }
                status = localized(
                    en: "RETURN VOTE WAS NOT CONFIRMED — TAP TO RETRY",
                    ru: "ГОЛОС ЗА ВОЗВРАТ НЕ ПОДТВЕРЖДЁН — ПОВТОРИ",
                    es: "EL VOTO DE REGRESO NO SE CONFIRMÓ — REINTENTA",
                    uk: "ГОЛОС ЗА ПОВЕРНЕННЯ НЕ ПІДТВЕРДЖЕНО — ПОВТОРИ"
                )
                HapticManager.shared.fire(.notification(.error))
                return
            }
        } catch {
            if RequestCancellationPolicy.isCancellation(error) {
                activeLobbyReturnVoteState.finish(request)
                return
            }
            if await recoverActiveLobbyReturnVote(request) {
                return
            }
            guard failActiveLobbyReturnVote(request) else { return }
            status = localized(
                en: "RETURN VOTE FAILED — TAP TO RETRY",
                ru: "НЕ УДАЛОСЬ ОТПРАВИТЬ ГОЛОС — ПОВТОРИ",
                es: "FALLÓ EL VOTO DE REGRESO — REINTENTA",
                uk: "НЕ ВДАЛОСЯ НАДІСЛАТИ ГОЛОС — ПОВТОРИ"
            )
            HapticManager.shared.fire(.notification(.error))
        }
    }

    @discardableResult
    private func adoptActiveLobbyReturnCandidate(
        _ candidate: GameRoom,
        request: ActiveLobbyReturnRequest
    ) -> Bool {
        guard activeLobbyReturnVoteState.isPending(request),
              let currentRoom = appState.activeRoom,
              ActiveLobbyReturnPolicy.canAdopt(
                  candidate: candidate,
                  over: currentRoom,
                  request: request,
                  accountUserID: appState.user?.id,
                  currentUserEmail: appState.user?.email
              ),
              activeLobbyReturnVoteState.finish(request) else { return false }
        appState.activeRoom = candidate
        status = request.targetVote
            ? localized(
                en: "RETURN VOTE RECORDED",
                ru: "ГОЛОС ЗА ВОЗВРАТ ПРИНЯТ",
                es: "VOTO DE REGRESO REGISTRADO",
                uk: "ГОЛОС ЗА ПОВЕРНЕННЯ ПРИЙНЯТО"
            )
            : localized(
                en: "RETURN VOTE CANCELLED",
                ru: "ГОЛОС ЗА ВОЗВРАТ ОТМЕНЁН",
                es: "VOTO DE REGRESO CANCELADO",
                uk: "ГОЛОС ЗА ПОВЕРНЕННЯ СКАСОВАНО"
            )
        HapticManager.shared.fire(.notification(.success))
        return true
    }

    private func recoverActiveLobbyReturnVote(
        _ request: ActiveLobbyReturnRequest
    ) async -> Bool {
        guard activeLobbyReturnVoteState.isPending(request),
              let currentRoom = appState.activeRoom,
              request.scope.matches(currentRoom),
              let refreshed = try? await appState.client.refreshRoom(id: request.scope.roomID),
              !Task.isCancelled else { return false }
        return adoptActiveLobbyReturnCandidate(refreshed, request: request)
    }

    @discardableResult
    private func failActiveLobbyReturnVote(
        _ request: ActiveLobbyReturnRequest
    ) -> Bool {
        guard let currentRoom = appState.activeRoom else { return false }
        return activeLobbyReturnVoteState.fail(
            request,
            currentRoom: currentRoom,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )
    }

    private func previewActiveLobbyReturnCandidate(
        room: GameRoom,
        request: ActiveLobbyReturnRequest
    ) -> GameRoom {
        var candidate = room
        var votes = room.readyPlayers ?? []
        votes.removeAll {
            RoomKickPolicy.normalizedEmail($0) == request.actorEmail.lowercased()
        }
        if request.targetVote {
            votes.append(request.actorEmail)
        }

        let eligible = ActiveLobbyReturnPolicy.eligiblePlayerEmailKeys(in: room)
        let voteKeys = Set(votes.compactMap(RoomKickPolicy.normalizedEmail))
        if request.targetVote, !eligible.isEmpty, eligible.isSubset(of: voteKeys) {
            candidate.status = "waiting"
            candidate.readyPlayers = []
            candidate.matchID = nil
            candidate.introStartedAt = nil
            candidate.gameStartedAt = nil
            candidate.gamePausedAt = nil
            candidate.gamePausedTotalSeconds = 0
            candidate.spyEmail = nil
            candidate.spyEmails = []
            candidate.revealedSpyEmails = []
            candidate.secretWord = nil
            candidate.word = nil
            candidate.category = nil
            candidate.cardsRead = []
            candidate.voteRequests = []
            candidate.detectiveVotes = []
            candidate.spyGuess = nil
        } else {
            candidate.readyPlayers = votes
        }
        candidate.roomRevision = (room.roomRevision ?? room.lobbyRevision ?? 0) + 1
        return candidate
    }

    private func requestRoomKick(_ player: Player, room: GameRoom) {
        guard let confirmation = RoomKickPolicy.confirmation(
            for: player,
            room: room,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        ) else { return }
        roomKickConfirmation = confirmation
        HapticManager.shared.fire(.buttonPress)
    }

    private func confirmRoomKick(_ confirmation: RoomKickConfirmation) {
        roomKickConfirmation = nil
        guard let room = appState.activeRoom,
              let request = roomKickCoordinator.begin(
                  confirmation: confirmation,
                  room: room,
                  accountUserID: appState.user?.id,
                  currentUserEmail: appState.user?.email,
                  requestID: UUID()
              ) else { return }
        HapticManager.shared.fire(.notification(.warning))
        Task { await performRoomKick(request, room: room) }
    }

    private func performRoomKick(
        _ request: RoomKickRequest,
        room: GameRoom
    ) async {
        do {
            let candidate: GameRoom
            if appState.shouldUsePreviewData {
                await Task.yield()
                var previewRoom = room
                previewRoom.players = room.playersList.filter {
                    !RoomKickPolicy.matchesTarget($0, request: request)
                }
                previewRoom.status = "waiting"
                previewRoom.readyPlayers = []
                previewRoom.roomRevision = (room.roomRevision ?? room.lobbyRevision ?? 0) + 1
                candidate = previewRoom
            } else {
                candidate = try await appState.client.kickPlayer(
                    room: room,
                    targetUserID: request.targetUserID,
                    targetEmail: request.targetEmail
                )
            }

            guard adoptRoomKickCandidate(candidate, request: request) else {
                if !appState.shouldUsePreviewData,
                   await recoverRoomKick(request) {
                    return
                }
                guard failRoomKick(request) else { return }
                status = localized(
                    en: "REMOVE OPERATIVE WAS NOT CONFIRMED — RETRY",
                    ru: "УДАЛЕНИЕ ИГРОКА НЕ ПОДТВЕРЖДЕНО — ПОВТОРИ",
                    es: "LA EXPULSIÓN NO SE CONFIRMÓ — REINTENTA",
                    uk: "ВИДАЛЕННЯ ГРАВЦЯ НЕ ПІДТВЕРДЖЕНО — ПОВТОРИ"
                )
                HapticManager.shared.fire(.notification(.error))
                return
            }
        } catch {
            if RequestCancellationPolicy.isCancellation(error) {
                roomKickCoordinator.finish(request)
                return
            }
            if await recoverRoomKick(request) {
                return
            }
            guard failRoomKick(request) else { return }
            status = localized(
                en: "REMOVE OPERATIVE FAILED — RETRY",
                ru: "НЕ УДАЛОСЬ УДАЛИТЬ ИГРОКА — ПОВТОРИ",
                es: "NO SE PUDO EXPULSAR — REINTENTA",
                uk: "НЕ ВДАЛОСЯ ВИДАЛИТИ ГРАВЦЯ — ПОВТОРИ"
            )
            HapticManager.shared.fire(.notification(.error))
        }
    }

    @discardableResult
    private func adoptRoomKickCandidate(
        _ candidate: GameRoom,
        request: RoomKickRequest,
        recovered: Bool = false
    ) -> Bool {
        guard roomKickCoordinator.isPending(request),
              let currentRoom = appState.activeRoom else { return false }
        let canAdopt = recovered
            ? RoomKickPolicy.canAdoptRecoveredSnapshot(
                candidate: candidate,
                over: currentRoom,
                request: request,
                accountUserID: appState.user?.id,
                currentUserEmail: appState.user?.email
            )
            : RoomKickPolicy.canAdopt(
                candidate: candidate,
                over: currentRoom,
                request: request,
                accountUserID: appState.user?.id,
                currentUserEmail: appState.user?.email
            )
        guard canAdopt, roomKickCoordinator.finish(request) else { return false }
        appState.activeRoom = candidate
        status = localized(
            en: "OPERATIVE REMOVED",
            ru: "ИГРОК УДАЛЁН",
            es: "OPERATIVO EXPULSADO",
            uk: "ГРАВЦЯ ВИДАЛЕНО"
        )
        HapticManager.shared.fire(.notification(.success))
        return true
    }

    private func recoverRoomKick(_ request: RoomKickRequest) async -> Bool {
        guard roomKickCoordinator.isPending(request),
              let currentRoom = appState.activeRoom,
              request.scope.matches(
                  room: currentRoom,
                  accountUserID: appState.user?.id,
                  currentUserEmail: appState.user?.email
              ),
              let refreshed = try? await appState.client.refreshRoom(
                  id: request.scope.roomID,
                  timeoutInterval: RoomActionTransportPolicy.timeoutInterval(for: "get_room"),
                  allowsTypedConflictRetry: false
              ),
              !Task.isCancelled else { return false }
        return adoptRoomKickCandidate(
            refreshed,
            request: request,
            recovered: true
        )
    }

    @discardableResult
    private func failRoomKick(_ request: RoomKickRequest) -> Bool {
        guard let currentRoom = appState.activeRoom else { return false }
        return roomKickCoordinator.fail(
            request,
            currentRoom: currentRoom,
            accountUserID: appState.user?.id,
            currentUserEmail: appState.user?.email
        )
    }

    private func beginReplayVote(_ room: GameRoom) {
        guard !isVotingReplay,
              !isResettingRoom,
              ["finished", "ended"].contains(room.normalizedStatus),
              let currentEmail = appState.user?.email,
              room.replayEligiblePlayersList.contains(where: {
                  normalizedEmailKey($0.email) == normalizedEmailKey(currentEmail)
              }),
              !(room.readyPlayers ?? []).contains(where: { emailsMatch($0, currentEmail) }) else { return }
        isVotingReplay = true
        HapticManager.shared.fire(.buttonPress)
        Task { await voteReplay(room) }
    }

    private func beginVoteRequest(_ room: GameRoom, firesHaptic: Bool = true) {
        guard canCurrentUserRequestVote(room) else { return }
        isRequestingVote = true
        if firesHaptic {
            HapticManager.shared.fire(.buttonPress)
        }
        Task { await requestVote(room) }
    }

    private func beginDetectiveVote(
        _ room: GameRoom,
        targetEmail: String,
        firesHaptic: Bool = true
    ) {
        guard canCurrentUserCastVote(room) else { return }
        isCastingVote = true
        pendingDetectiveVoteTargetEmail = targetEmail
        if firesHaptic {
            HapticManager.shared.fire(.milestone)
        }
        Task { await castVote(room, targetEmail: targetEmail) }
    }

    private func toggleReady(_ room: GameRoom) async {
        defer { isTogglingReady = false }
        guard let user = appState.user else { return }
        let wasReady = currentUserIsReady(room)
        if appState.shouldUsePreviewData {
            var previewRoom = room
            var ready = Set(room.readyPlayers ?? [])
            if wasReady {
                ready.remove(user.email)
                status = copy.readyRemoved
            } else {
                ready.insert(user.email)
                status = copy.readyLocked
            }
            previewRoom.readyPlayers = Array(ready)
            appState.activeRoom = previewRoom
            HapticManager.shared.fire(
                .notification(.success)
            )
            return
        }
        do {
            appState.activeRoom = try await appState.client.toggleReady(room: room, user: user)
            status = wasReady ? copy.readyRemoved : copy.readyLocked
            HapticManager.shared.fire(
                .notification(.success)
            )
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func returnToWaiting(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "waiting")
            status = copy.lobbyRestored
            HapticManager.shared.fire(.buttonPress)
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            appState.activeRoom = try await appState.client.returnToWaiting(room: room)
            status = copy.lobbyRestored
            HapticManager.shared.fire(.buttonPress)
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func voteReplay(_ room: GameRoom) async {
        defer { isVotingReplay = false }
        guard let user = appState.user else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            var votes = Set(room.readyPlayers ?? [])
            votes.insert(user.email)
            previewRoom.readyPlayers = Array(votes)
            appState.activeRoom = previewRoom
            status = copy.replayVoteLocked
            HapticManager.shared.fire(.notification(.success))
            if let request = ReplayAutoStartPolicy.request(
                for: previewRoom,
                currentUserEmail: user.email
            ) {
                scheduleReplayAutoStart(request)
            }
            return
        }

        do {
            let updated = try await appState.client.votePlayAgain(room: room, user: user)
            guard appState.user?.id == user.id,
                  appState.activeRoom?.id == room.id else { return }
            appState.activeRoom = updated
            status = copy.replayVoteLocked
            HapticManager.shared.fire(.notification(.success))

            if let request = ReplayAutoStartPolicy.request(
                for: updated,
                currentUserEmail: user.email
            ) {
                scheduleReplayAutoStart(request)
            }
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func resetRoom(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "waiting")
            pendingStartPlan = nil
            rouletteCompletionKey = nil
            revealRole = false
            showSpyGuess = false
            status = copy.lobbyRestored
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isResettingRoom = true
        defer { isResettingRoom = false }

        do {
            appState.activeRoom = try await appState.client.returnFinishedRoomToLobby(room: room)
            selectedGameMode = appState.activeRoom?.gameModeValue ?? selectedGameMode
            selectedDurationMinutes = Double(max((appState.activeRoom?.gameDurationSeconds ?? 900) / 60, 1))
            pendingStartPlan = nil
            rouletteCompletionKey = nil
            revealRole = false
            showSpyGuess = false
            status = copy.lobbyRestored
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func scheduleReplayAutoStart(
        _ request: ReplayAutoStartRequest,
        isExplicitRetry: Bool = false
    ) {
        var coordinator = replayAutoStartCoordinator
        let didSchedule = isExplicitRetry
            ? coordinator.retry(request)
            : coordinator.observe(request)
        guard didSchedule else { return }

        replayAutoStartCoordinator = coordinator
        replayAutoStartFailedOperationKey = nil
        isResettingRoom = true
        isStarting = true
        if isExplicitRetry {
            HapticManager.shared.fire(.buttonPress)
        }
    }

    private func performReplayAutoStart(_ request: ReplayAutoStartRequest) async {
        defer {
            var coordinator = replayAutoStartCoordinator
            coordinator.finish(request)
            replayAutoStartCoordinator = coordinator
            isResettingRoom = false
            isStarting = false
        }

        guard let user = appState.user,
              let initialRoom = appState.activeRoom,
              initialRoom.id == request.roomID else { return }

        if appState.shouldUsePreviewData {
            var previewRoom = initialRoom
            previewRoom.status = "roulette"
            previewRoom.matchID = nil
            previewRoom.winner = nil
            previewRoom.readyPlayers = []
            previewRoom.cardsRead = []
            previewRoom.voteRequests = []
            previewRoom.detectiveVotes = []
            previewRoom.spyGuess = nil
            previewRoom.rouletteTargetEmail = previewRoom.playersList.randomElement()?.email
            previewRoom.introStartedAt = ISO8601DateFormatter().string(from: Date())
            previewRoom.gameStartedAt = nil
            appState.activeRoom = previewRoom
            replayAutoStartFailedOperationKey = nil
            pendingStartPlan = nil
            rouletteCompletionKey = nil
            revealRole = false
            showSpyGuess = false
            status = copy.rouletteArmed
            HapticManager.shared.fire(.notification(.success))
            return
        }

        do {
            var authoritativeRoom = initialRoom
            switch ReplayAutoStartPolicy.disposition(
                of: authoritativeRoom,
                for: request,
                currentUserEmail: user.email
            ) {
            case .resetRequired:
                authoritativeRoom = try await resetReplayRoomForAutoStart(
                    authoritativeRoom,
                    request: request,
                    userEmail: user.email
                )
            case .armRequired, .alreadyStarted:
                break
            case .invalid:
                throw CancellationError()
            }

            try Task.checkCancellation()
            authoritativeRoom = try adoptReplayAutoStartCandidate(
                authoritativeRoom,
                request: request,
                userEmail: user.email
            )

            switch ReplayAutoStartPolicy.disposition(
                of: authoritativeRoom,
                for: request,
                currentUserEmail: user.email
            ) {
            case .alreadyStarted:
                break
            case .armRequired:
                isResettingRoom = false
                selectedGameMode = authoritativeRoom.gameModeValue
                selectedDurationMinutes = Double(
                    max((authoritativeRoom.gameDurationSeconds ?? 900) / 60, 1)
                )
                applyAuthoritativeLobbyState(from: authoritativeRoom, force: true)
                authoritativeRoom = try await armReplayRoomAfterReset(
                    authoritativeRoom,
                    request: request,
                    userEmail: user.email
                )
                try Task.checkCancellation()
                authoritativeRoom = try adoptReplayAutoStartCandidate(
                    authoritativeRoom,
                    request: request,
                    userEmail: user.email
                )
                guard ReplayAutoStartPolicy.disposition(
                    of: authoritativeRoom,
                    for: request,
                    currentUserEmail: user.email
                ) == .alreadyStarted else {
                    throw Base44Error(
                        message: "Replay start did not reach roulette.",
                        statusCode: 409
                    )
                }
            case .resetRequired, .invalid:
                throw Base44Error(
                    message: "Replay reset did not reach the lobby.",
                    statusCode: 409
                )
            }

            replayAutoStartFailedOperationKey = nil
            rouletteCompletionKey = nil
            revealRole = false
            showSpyGuess = false
            status = copy.rouletteArmed
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard !Task.isCancelled,
                  !RequestCancellationPolicy.isCancellation(error) else { return }
            replayAutoStartFailedOperationKey = request.operationKey
            status = localized(
                en: "REPLAY AUTO-START FAILED — TAP START AGAIN TO RETRY",
                ru: "АВТОСТАРТ РЕВАНША НЕ УДАЛСЯ — НАЖМИ СТАРТ ЕЩЁ РАЗ",
                es: "FALLO EL INICIO AUTOMATICO — TOCA INICIAR PARA REINTENTAR",
                uk: "АВТОСТАРТ РЕВАНШУ НЕ ВДАВСЯ — НАТИСНИ СТАРТ ЩЕ РАЗ"
            )
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func resetReplayRoomForAutoStart(
        _ room: GameRoom,
        request: ReplayAutoStartRequest,
        userEmail: String
    ) async throws -> GameRoom {
        do {
            return try await appState.client.resetRoomForReplay(room: room)
        } catch {
            guard !RequestCancellationPolicy.isCancellation(error) else { throw error }
            if let currentRoom = appState.activeRoom {
                let currentDisposition = ReplayAutoStartPolicy.disposition(
                    of: currentRoom,
                    for: request,
                    currentUserEmail: userEmail
                )
                if currentDisposition == .armRequired || currentDisposition == .alreadyStarted {
                    return currentRoom
                }
            }
            if let refreshed = try? await appState.client.refreshRoom(id: request.roomID) {
                let disposition = ReplayAutoStartPolicy.disposition(
                    of: refreshed,
                    for: request,
                    currentUserEmail: userEmail
                )
                if disposition == .armRequired || disposition == .alreadyStarted {
                    return refreshed
                }
            }
            throw error
        }
    }

    private func armReplayRoomAfterReset(
        _ room: GameRoom,
        request: ReplayAutoStartRequest,
        userEmail: String
    ) async throws -> GameRoom {
        do {
            let confirmedRoom = try await appState.confirmedLobbyRoom(roomID: room.id)
            guard roomThemeSelectionIsReady, !isGeneratingRoomTheme else {
                throw Base44Error(
                    message: localized(
                        en: "The saved replay word source is unavailable.",
                        ru: "Сохранённый источник слов для реванша недоступен.",
                        es: "La fuente de palabras guardada no esta disponible.",
                        uk: "Збережене джерело слів для реваншу недоступне."
                    ),
                    statusCode: 409
                )
            }
            let plan = try appState.client.makeGameStartPlan(
                room: confirmedRoom,
                wordPacks: lobbyWordPacksForStart,
                selectedPackID: selectedPackID,
                gameMode: confirmedRoom.gameModeValue,
                durationSeconds: confirmedRoom.gameDurationSeconds ?? 900,
                forcedAskerEmail: nil
            )
            pendingStartPlan = plan
            return try await appState.client.armRoulette(room: confirmedRoom, plan: plan)
        } catch {
            guard !RequestCancellationPolicy.isCancellation(error) else { throw error }
            if let currentRoom = appState.activeRoom,
               ReplayAutoStartPolicy.disposition(
                   of: currentRoom,
                   for: request,
                   currentUserEmail: userEmail
               ) == .alreadyStarted {
                return currentRoom
            }
            if let refreshed = try? await appState.client.refreshRoom(id: request.roomID),
               ReplayAutoStartPolicy.disposition(
                   of: refreshed,
                   for: request,
                   currentUserEmail: userEmail
               ) == .alreadyStarted {
                return refreshed
            }
            throw error
        }
    }

    private func adoptReplayAutoStartCandidate(
        _ candidate: GameRoom,
        request: ReplayAutoStartRequest,
        userEmail: String
    ) throws -> GameRoom {
        guard appState.user?.email == userEmail,
              let currentRoom = appState.activeRoom,
              currentRoom.id == request.roomID else { throw CancellationError() }

        if ReplayAutoStartPolicy.canAdopt(
            candidate,
            over: currentRoom,
            for: request,
            currentUserEmail: userEmail
        ) {
            appState.activeRoom = candidate
            return candidate
        }

        let currentDisposition = ReplayAutoStartPolicy.disposition(
            of: currentRoom,
            for: request,
            currentUserEmail: userEmail
        )
        if currentDisposition == .armRequired || currentDisposition == .alreadyStarted {
            return currentRoom
        }
        throw CancellationError()
    }

    private func start(_ room: GameRoom) async {
        guard !isStarting else { return }
        guard appState.user?.email != nil else { return }
        guard !waitingStartActionMode(for: room).blocksStart else { return }
        guard lobbyStateIsServerConfirmed(for: room) else {
            status = localized(
                en: "WAIT FOR LOBBY SETTINGS TO BE SAVED ON THE SERVER",
                ru: "ДОЖДИСЬ СОХРАНЕНИЯ НАСТРОЕК ЛОББИ НА СЕРВЕРЕ",
                es: "ESPERA A QUE LOS AJUSTES SE GUARDEN EN EL SERVIDOR",
                uk: "ЗАЧЕКАЙ, ДОКИ НАЛАШТУВАННЯ ЛОБІ ЗБЕРЕЖУТЬСЯ НА СЕРВЕРІ"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }
        guard !appState.hasOptimisticLobbySettingsChanges else { return }
        guard roomThemeSelectionIsReady, !isGeneratingRoomTheme else {
            status = localized(
                en: "SELECT A DECK OR GENERATE THE THEME WORDS BEFORE STARTING",
                ru: "ПЕРЕД СТАРТОМ ВЫБЕРИ КОЛОДУ ИЛИ СГЕНЕРИРУЙ СЛОВА ТЕМЫ",
                es: "ELIGE UN PACK O GENERA LAS PALABRAS ANTES DE EMPEZAR",
                uk: "ПЕРЕД ПОЧАТКОМ ОБЕРИ НАБІР АБО ЗГЕНЕРУЙ СЛОВА ТЕМИ"
            )
            HapticManager.shared.fire(.notification(.warning))
            return
        }
        if appState.shouldUsePreviewData {
            appState.activeRoom = GameRoom.previewRoom(status: "roulette")
            status = copy.rouletteArmed
            revealRole = false
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let confirmedRoom = try await appState.confirmedLobbyRoom(
                roomID: room.id
            )
            guard roomThemeSelectionIsReady, let selectedPackID else {
                throw Base44Error(
                    message: localized(
                        en: "Select a deck or create a theme first.",
                        ru: "Сначала выбери колоду или создай тему.",
                        es: "Elige un pack o crea un tema primero.",
                        uk: "Спочатку обери набір слів або створи тему."
                    ),
                    statusCode: nil
                )
            }
            let packs = lobbyWordPacksForStart
            let plan = try appState.client.makeGameStartPlan(
                room: confirmedRoom,
                wordPacks: packs,
                selectedPackID: selectedPackID,
                gameMode: selectedGameMode,
                durationSeconds: Int(selectedDurationMinutes * 60),
                forcedAskerEmail: confirmedRoom.rouletteTargetEmail
            )
            pendingStartPlan = plan
            let operationUserID = appState.user?.id
            let armedRoom = try await appState.client.armRoulette(
                room: confirmedRoom,
                plan: plan
            )
            guard appState.user?.id == operationUserID,
                  appState.activeRoom?.id == confirmedRoom.id else {
                pendingStartPlan = nil
                return
            }
            appState.activeRoom = armedRoom
            status = copy.rouletteArmed
            revealRole = false
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func completeRouletteIfNeeded(_ room: GameRoom) async {
        if appState.shouldUsePreviewData {
            try? await Task.sleep(for: .seconds(8))
            guard appState.activeRoom?.normalizedStatus == "roulette" else { return }
            appState.activeRoom = GameRoom.previewRoom(status: "cards-last")
            status = copy.gameReady
            return
        }
        guard room.normalizedStatus == "roulette",
              let userEmail = appState.user?.email,
              room.playersList.contains(where: { $0.email == userEmail }) else { return }
        let key = "\(room.id)-\(room.introStartedAt ?? room.rouletteTargetEmail ?? "")"
        guard rouletteCompletionKey != key else { return }
        rouletteCompletionKey = key

        isStarting = true
        defer { isStarting = false }

        do {
            let elapsed = room.introStartedAt
                .flatMap(parseDate)
                .map { max(Date().timeIntervalSince($0), 0) } ?? 0
            let delay = max(8.2 - elapsed, 0)
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            let currentRoom = (try? await appState.client.refreshRoom(id: room.id)) ?? room
            guard currentRoom.normalizedStatus == "roulette" else { return }

            appState.activeRoom = try await appState.client.completeGameStart(room: currentRoom)
            pendingStartPlan = nil
            status = copy.gameReady
            revealRole = false
            HapticManager.shared.fire(.milestone)
        } catch {
            if RequestCancellationPolicy.isCancellation(error) {
                if appState.activeRoom?.id == room.id,
                   appState.activeRoom?.normalizedStatus == "roulette" {
                    rouletteCompletionKey = nil
                }
                return
            }
            rouletteCompletionKey = nil
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func advance(_ room: GameRoom) async {
        guard !room.isGamePaused, !isTimeExpired(room) else { return }
        if appState.shouldUsePreviewData {
            status = room.gameModeValue == .associations ? copy.associationSpun : copy.questionSent
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isAdvancing = true
        defer { isAdvancing = false }
        do {
            if room.gameModeValue == .associations {
                appState.activeRoom = try await appState.client.advanceAssociation(room: room)
                status = copy.associationSpun
            } else {
                appState.activeRoom = try await appState.client.advanceQuestion(room: room)
                status = copy.questionSent
            }
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func performOnlineRoundCommand(_ command: OnlineRoundCommand, room: GameRoom) async {
        guard !isAdvancing, !room.isGamePaused, !isTimeExpired(room) else { return }
        if appState.shouldUsePreviewData {
            applyPreviewRoundCommand(command, room: room)
            HapticManager.shared.fire(.notification(.success))
            return
        }

        isAdvancing = true
        defer { isAdvancing = false }

        do {
            let currentCommand = room.onlineRoundCommand(
                for: appState.user?.email,
                isHost: isHost(room),
                isTransitioning: false
            )
            guard currentCommand == command else {
                return
            }

            switch command {
            case .markAnswerHeard:
                appState.activeRoom = try await appState.client.markAnswerHeard(room: room)
            case .continueRound:
                appState.activeRoom = try await appState.client.continueRound(room: room)
            case .startAssociation:
                appState.activeRoom = try await appState.client.startAssociation(room: room)
            case .advanceAssociation:
                appState.activeRoom = try await appState.client.advanceAssociation(room: room)
            }
            if command != .markAnswerHeard {
                status = onlineRoundSuccessStatus(command)
            }
            HapticManager.shared.fire(.notification(.success))
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func advanceQuestionAfterCountdown(_ room: GameRoom) async {
        guard !isAdvancing, !room.isGamePaused, !isTimeExpired(room) else { return }
        if appState.shouldUsePreviewData {
            guard let previewRoom = OnlineQuestionPreviewRoundPolicy.transition(
                .markAnswerHeard,
                room: room
            ) else { return }
            appState.activeRoom = previewRoom
            return
        }

        isAdvancing = true
        defer { isAdvancing = false }

        do {
            guard room.onlineRoundPhase == .countdown,
                  emailsMatch(room.currentAskerEmail, appState.user?.email) else {
                return
            }
            appState.activeRoom = try await appState.client.advanceQuestion(room: room)
            HapticManager.shared.fire(.notification(.success))
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func stopAssociationSpinAfterAnimation(_ room: GameRoom) async {
        guard !isAdvancing, !room.isGamePaused, !isTimeExpired(room) else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            var state = previewRoom.associationRoundState
            state.spinning = false
            previewRoom.currentAnswer = state.encodedValue
            appState.activeRoom = previewRoom
            return
        }

        isAdvancing = true
        defer { isAdvancing = false }

        do {
            guard let currentRoom = appState.activeRoom,
                  currentRoom.id == room.id,
                  currentRoom.canStopAssociationSpin(
                    for: appState.user?.email,
                    isHost: isHost(currentRoom)
                  ) else {
                return
            }
            appState.activeRoom = try await appState.client.stopAssociationSpin(room: currentRoom)
        } catch is CancellationError {
            return
        } catch {
            // Ranked active clients provide the bounded fallback sequence. A
            // failed automatic settlement must not create a local retry storm.
            return
        }
    }

    private func applyPreviewRoundCommand(_ command: OnlineRoundCommand, room: GameRoom) {
        var previewRoom = room
        switch command {
        case .markAnswerHeard:
            guard let transition = OnlineQuestionPreviewRoundPolicy.transition(
                command,
                room: room
            ) else { return }
            previewRoom = transition
        case .continueRound:
            if room.gameModeValue == .questions {
                guard let transition = OnlineQuestionPreviewRoundPolicy.transition(
                    command,
                    room: room
                ) else { return }
                previewRoom = transition
            } else {
                previewRoom.questionPhase = "asking"
                previewRoom.countdownStartedAt = nil
                previewRoom.roundNumber = (previewRoom.roundNumber ?? 1) + 1
                previewRoom.questionsInRound = 0
                previewRoom.currentAnswer = ""
                previewRoom.currentAnswerFeedback = nil
                previewRoom.playerFeedback = []
            }
        case .startAssociation:
            previewRoom.currentAskerEmail = previewRoom.activePlayers.first?.email
            previewRoom.currentAnswer = AssociationRoundState(spoken: [], spinning: true).encodedValue
            previewRoom.questionPhase = "asking"
        case .advanceAssociation:
            var state = previewRoom.associationRoundState
            if let currentSpeaker = previewRoom.currentAskerEmail,
               !state.spoken.contains(currentSpeaker) {
                state.spoken.append(currentSpeaker)
            }
            let remaining = previewRoom.activePlayers.filter { !state.spoken.contains($0.email) }
            if remaining.isEmpty {
                state.spoken = []
                previewRoom.roundNumber = (previewRoom.roundNumber ?? 1) + 1
            }
            previewRoom.currentAskerEmail = (remaining.first ?? previewRoom.activePlayers.first)?.email
            state.spinning = true
            previewRoom.currentAnswer = state.encodedValue
        }
        appState.activeRoom = previewRoom
        if command != .markAnswerHeard {
            status = onlineRoundSuccessStatus(command)
        }
    }

    private func onlineRoundSuccessStatus(_ command: OnlineRoundCommand) -> String {
        switch command {
        case .markAnswerHeard:
            localized(en: "ANSWER CONFIRMED", ru: "ОТВЕТ ПОДТВЕРЖДЕН", es: "RESPUESTA CONFIRMADA", uk: "ВІДПОВІДЬ ПІДТВЕРДЖЕНО")
        case .continueRound:
            localized(en: "NEXT ROUND READY", ru: "НОВЫЙ РАУНД ГОТОВ", es: "NUEVA RONDA LISTA", uk: "НАСТУПНИЙ РАУНД ГОТОВИЙ")
        case .startAssociation, .advanceAssociation:
            copy.associationSpun
        }
    }

    private func emailsMatch(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }
        return left.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(right.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func normalizedEmailKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func markCardRead(_ room: GameRoom) async {
        guard let user = appState.user else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            var cardsRead = previewRoom.cardsReadList
            if !cardsRead.contains(user.email) {
                cardsRead.append(user.email)
            }
            previewRoom.cardsRead = cardsRead
            if previewRoom.allRoleCardsRead {
                previewRoom.gameStartedAt = ISO8601DateFormatter().string(from: Date())
                previewRoom.gamePausedAt = nil
                previewRoom.gamePausedTotalSeconds = 0
            }
            appState.activeRoom = previewRoom
            revealRole = false
            status = copy.cardConfirmedStatus
            HapticManager.shared.fire(.notification(.success))
            return
        }
        isMarkingCardRead = true
        defer { isMarkingCardRead = false }
        do {
            appState.activeRoom = try await appState.client.markRoleCardRead(room: room, user: user)
            revealRole = false
            status = copy.cardConfirmedStatus
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func toggleGamePause(_ room: GameRoom) async {
        guard isHost(room), room.gameStartedAt != nil, !isTogglingGamePause else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            if room.isGamePaused {
                if let pausedAt = room.gamePausedAt.flatMap(parseDate) {
                    let additionalPause = max(Int(Date().timeIntervalSince(pausedAt)), 0)
                    previewRoom.gamePausedTotalSeconds = max(room.gamePausedTotalSeconds ?? 0, 0) + additionalPause
                }
                previewRoom.gamePausedAt = nil
            } else {
                previewRoom.gamePausedAt = ISO8601DateFormatter().string(from: Date())
            }
            appState.activeRoom = previewRoom
            HapticManager.shared.fire(.buttonPress)
            return
        }

        isTogglingGamePause = true
        defer { isTogglingGamePause = false }
        do {
            let updatedRoom: GameRoom
            if room.isGamePaused {
                updatedRoom = try await appState.client.resumeGame(room: room)
            } else {
                updatedRoom = try await appState.client.pauseGame(room: room)
            }
            appState.activeRoom = updatedRoom
            HapticManager.shared.fire(.notification(.success))
        } catch {
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func finalizeExpiredRoomIfNeeded(_ room: GameRoom) async {
        guard let scope = OnlineRoomMatchScope(room: room),
              ExpiredRoomFinalizationRetryPolicy.canAttempt(
                  scope: scope,
                  room: room,
                  now: Date()
              ) else { return }

        if appState.shouldUsePreviewData {
            var previewRoom = room
            previewRoom.status = "finished"
            previewRoom.winner = "spy"
            previewRoom.questionPhase = nil
            guard let currentRoom = appState.activeRoom,
                  OnlineAuthoritativeRoomPolicy.canAdopt(
                      candidate: previewRoom,
                      over: currentRoom,
                      scope: scope
                  ) else { return }
            showSpyGuess = false
            appState.activeRoom = previewRoom
            HapticManager.shared.fire(.notification(.success))
            return
        }

        var failedAttempt = 0
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                return
            }

            guard let currentRoom = appState.activeRoom,
                  ExpiredRoomFinalizationRetryPolicy.canAttempt(
                      scope: scope,
                      room: currentRoom,
                      now: Date()
                  ) else { return }

            let actionFailure: Error
            var shouldRefresh = true
            do {
                let updated = try await appState.client.finalizeExpiredRoom(room: currentRoom)
                guard !Task.isCancelled,
                      let activeRoom = appState.activeRoom else { return }
                switch ExpiredRoomFinalizationRetryPolicy.disposition(
                    for: updated,
                    over: activeRoom,
                    scope: scope,
                    now: Date()
                ) {
                case .adopt:
                    appState.activeRoom = updated
                    guard ExpiredRoomFinalizationRetryPolicy.canAttempt(
                        scope: scope,
                        room: updated,
                        now: Date()
                    ) else { return }
                case .retryCurrent:
                    shouldRefresh = false
                case .stop:
                    return
                }
                actionFailure = Base44Error(
                    message: "The terminal room state is still pending.",
                    statusCode: 409,
                    code: "terminal_reconciliation_pending",
                    retryable: true
                )
            } catch {
                guard !Task.isCancelled,
                      !RequestCancellationPolicy.isCancellation(error) else { return }
                actionFailure = error
            }

            if shouldRefresh {
                do {
                    if let refreshed = try await appState.client.refreshRoom(id: scope.roomID) {
                        guard !Task.isCancelled,
                              let activeRoom = appState.activeRoom else { return }
                        switch ExpiredRoomFinalizationRetryPolicy.disposition(
                            for: refreshed,
                            over: activeRoom,
                            scope: scope,
                            now: Date()
                        ) {
                        case .adopt:
                            appState.activeRoom = refreshed
                            guard ExpiredRoomFinalizationRetryPolicy.canAttempt(
                                scope: scope,
                                room: refreshed,
                                now: Date()
                            ) else { return }
                        case .retryCurrent:
                            break
                        case .stop:
                            return
                        }
                    } else {
                        guard let activeRoom = appState.activeRoom,
                              ExpiredRoomFinalizationRetryPolicy.canAttempt(
                                  scope: scope,
                                  room: activeRoom,
                                  now: Date()
                              ) else { return }
                    }
                } catch {
                    guard !Task.isCancelled,
                          !RequestCancellationPolicy.isCancellation(error) else { return }
                    if ExpiredRoomFinalizationRetryPolicy.isRetryable(actionFailure) {
                        guard ExpiredRoomFinalizationRetryPolicy.isRetryable(error) else {
                            presentExpiredRoomFinalizationFailure(error)
                            return
                        }
                    }
                }
            }

            guard ExpiredRoomFinalizationRetryPolicy.isRetryable(actionFailure) else {
                presentExpiredRoomFinalizationFailure(actionFailure)
                return
            }
            if failedAttempt == ExpiredRoomFinalizationRetryPolicy.warningAfterFailedAttempts {
                presentExpiredRoomFinalizationDelay()
            }
            let delay = ExpiredRoomFinalizationRetryPolicy.delayMilliseconds(
                afterFailedAttempt: failedAttempt
            )
            failedAttempt += 1
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
        }
    }

    private func presentExpiredRoomFinalizationFailure(_ error: Error) {
        appState.showToast(
            userFacingStatus(error.localizedDescription) ?? error.localizedDescription,
            kind: .error
        )
        HapticManager.shared.fire(.notification(.error))
    }

    private func presentExpiredRoomFinalizationDelay() {
        appState.showToast(
            localized(
                en: "RESULT SYNC IS DELAYED. KEEP THE ROOM OPEN",
                ru: "СИНХРОНИЗАЦИЯ РЕЗУЛЬТАТА ЗАДЕРЖИВАЕТСЯ. НЕ ЗАКРЫВАЙ КОМНАТУ",
                es: "LA SINCRONIZACION DEL RESULTADO SE RETRASA. MANTEN LA SALA ABIERTA",
                uk: "СИНХРОНІЗАЦІЯ РЕЗУЛЬТАТУ ЗАТРИМУЄТЬСЯ. НЕ ЗАКРИВАЙ КІМНАТУ"
            ),
            kind: .warning
        )
        HapticManager.shared.fire(.notification(.warning))
    }

    private func presentDetectiveVoteCancellationIfNeeded() async {
        guard let room = appState.activeRoom,
              let event = DetectiveVoteCancellationEvent(room: room),
              let timing = DetectiveVoteCancellationPresentationPolicy.timing(
                  for: event,
                  now: Date(),
                  handledEventIDs: handledDetectiveVoteCancellationEventIDs
              ) else { return }

        if timing.startDelay > 0 {
            do {
                try await Task.sleep(for: .seconds(timing.startDelay))
            } catch {
                return
            }
        }

        guard !Task.isCancelled,
              let currentRoom = appState.activeRoom,
              let currentEvent = DetectiveVoteCancellationEvent(room: currentRoom),
              currentEvent.id == event.id,
              let currentTiming = DetectiveVoteCancellationPresentationPolicy.timing(
                  for: currentEvent,
                  now: Date(),
                  handledEventIDs: handledDetectiveVoteCancellationEventIDs
              ) else { return }

        handledDetectiveVoteCancellationEventIDs.insert(event.id)
        showSpyGuess = false
        detectiveVoteCancellationPresentation = currentEvent
        HapticManager.shared.fire(.notification(.warning))
        UIAccessibility.post(
            notification: .announcement,
            argument: DetectiveVoteCancellationCopy
                .localized(languageCode: appState.language.rawValue)
                .accessibilityAnnouncement
        )

        defer {
            if detectiveVoteCancellationPresentation?.id == event.id {
                detectiveVoteCancellationPresentation = nil
            }
        }

        let remainingDuration = currentTiming.endAt.timeIntervalSince(Date())
        guard remainingDuration > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(remainingDuration))
        } catch {
            return
        }
    }

    private func presentLegacyDetectiveVoteCancellationFeedbackIfNeeded(
        authoritative room: GameRoom
    ) {
        guard DetectiveVoteCancellationEvent(room: room) == nil else { return }
        appState.showToast(detectiveVoteCancelledStatus, kind: .warning)
        HapticManager.shared.fire(.notification(.warning))
    }

    private func requestVote(_ room: GameRoom) async {
        defer { isRequestingVote = false }
        guard detectiveVoteCancellationPresentation == nil,
              !room.isGamePaused,
              !isTimeExpired(room) else { return }
        guard let user = appState.user,
              let requestScope = OnlineRoomMatchScope(room: room) else { return }
        if appState.shouldUsePreviewData {
            var previewRoom = room
            if !previewRoom.voteRequestsList.contains(where: { emailsMatch($0, user.email) }) {
                previewRoom.voteRequests = previewRoom.voteRequestsList + [user.email]
            }
            appState.activeRoom = previewRoom
            HapticManager.shared.fire(.notification(.success))
            return
        }
        do {
            let updated = try await appState.client.requestVote(room: room, user: user)
            guard appState.user?.id == user.id,
                  let currentRoom = appState.activeRoom,
                  requestScope.matches(currentRoom) else { return }
            if OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: updated,
                over: currentRoom,
                scope: requestScope
            ) {
                appState.activeRoom = updated
            }
            guard appState.activeRoom?.voteRequestsList.contains(where: {
                emailsMatch($0, user.email)
            }) == true else { return }
            HapticManager.shared.fire(.notification(.success))
        } catch {
            guard !Task.isCancelled,
                  !RequestCancellationPolicy.isCancellation(error) else { return }
            if UncertainRoomMutationRecoveryPolicy.shouldRefreshAfterFailure(error) {
                await reconcileUncertainVoteRequest(
                    scope: requestScope,
                    actor: user
                )
                return
            }
            status = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func reconcileUncertainVoteRequest(
        scope: OnlineRoomMatchScope,
        actor: SpyUser
    ) async {
        guard !Task.isCancelled,
              appState.user?.id == actor.id,
              let activeRoom = appState.activeRoom,
              scope.matches(activeRoom) else { return }

        let refreshed: GameRoom?
        do {
            refreshed = try await appState.client.refreshRoom(
                id: scope.roomID,
                timeoutInterval: RoomActionTransportPolicy.timeoutInterval(for: "get_room"),
                allowsTypedConflictRetry: false
            )
        } catch {
            return
        }

        guard !Task.isCancelled,
              appState.user?.id == actor.id,
              let currentRoom = appState.activeRoom,
              scope.matches(currentRoom) else { return }
        switch UncertainRoomMutationRecoveryPolicy.refreshDisposition(
            candidate: refreshed,
            over: currentRoom,
            scope: scope
        ) {
        case .adopt:
            guard let refreshed else { return }
            appState.activeRoom = refreshed
        case .retainCurrent:
            break
        case .reject:
            return
        }

        guard let authoritativeRoom = appState.activeRoom,
              UncertainRoomMutationRecoveryPolicy.confirmsVoteRequest(
                  in: authoritativeRoom,
                  scope: scope,
                  actorEmail: actor.email
              ) else {
            // The write outcome is still uncertain. Realtime and the scoped
            // polling loop remain authoritative; never replay the mutation.
            return
        }
        HapticManager.shared.fire(.notification(.success))
    }

    private func castVote(_ room: GameRoom, targetEmail: String) async {
        defer {
            isCastingVote = false
            pendingDetectiveVoteTargetEmail = nil
        }
        guard detectiveVoteCancellationPresentation == nil,
              !room.isGamePaused,
              !isTimeExpired(room) else { return }
        guard let user = appState.user else { return }
        guard let castScope = DetectiveVoteCastScope(
            room: room,
            actorEmail: user.email,
            targetEmail: targetEmail
        ) else { return }
        if appState.shouldUsePreviewData {
            status = copy.voteLockedStatus
            HapticManager.shared.fire(.notification(.success))
            return
        }
        let recoveryStartedAt = Date()
        func elapsedRecoveryMilliseconds() -> Int {
            max(Int(Date().timeIntervalSince(recoveryStartedAt) * 1_000), 0)
        }

        var retry = 0
        while true {
            guard !Task.isCancelled,
                  castScope.matchesActor(appState.user?.email),
                  let activeRoom = appState.activeRoom,
                  castScope.room.matches(activeRoom) else { return }
            let remainingRequestBudget = DetectiveVoteConflictRecoveryPolicy
                .remainingBudgetMilliseconds(
                    elapsedMilliseconds: elapsedRecoveryMilliseconds()
                )
            if retry > 0, remainingRequestBudget == 0 {
                presentDetectiveVoteSyncDelayed()
                return
            }

            switch DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: room,
                authoritative: activeRoom,
                cast: castScope,
                now: Date()
            ) {
            case .persisted, .cancelled:
                applyDetectiveVoteResponse(
                    previous: room,
                    authoritative: activeRoom,
                    scope: castScope.room
                )
                return
            case .superseded, .ejected, .finished, .deadline:
                return
            case .reject:
                return
            case .retry:
                break
            }

            do {
                let updated = try await appState.client.castDetectiveVote(
                    room: room,
                    user: user,
                    targetEmail: castScope.targetEmail,
                    expectedVoteRoundID: castScope.voteRoundID,
                    timeoutInterval: retry == 0
                        ? nil
                        : Double(remainingRequestBudget) / 1_000
                )
                guard !Task.isCancelled,
                      let currentRoom = appState.activeRoom,
                      OnlineAuthoritativeRoomPolicy.canAdopt(
                          candidate: updated,
                          over: currentRoom,
                          scope: castScope.room
                      ) else { return }

                switch DetectiveVoteDirectSuccessPolicy.disposition(
                    previous: room,
                    authoritative: updated,
                    cast: castScope,
                    now: Date()
                ) {
                case .recorded, .cancelled:
                    applyDetectiveVoteResponse(
                        previous: room,
                        authoritative: updated,
                        scope: castScope.room
                    )
                    return
                case .adoptSilently:
                    guard let latestRoom = appState.activeRoom,
                          OnlineAuthoritativeRoomPolicy.canAdopt(
                              candidate: updated,
                              over: latestRoom,
                              scope: castScope.room
                          ) else { return }
                    appState.activeRoom = updated
                    return
                case .reconcile:
                    guard let latestRoom = appState.activeRoom,
                          OnlineAuthoritativeRoomPolicy.canAdopt(
                              candidate: updated,
                              over: latestRoom,
                              scope: castScope.room
                          ) else { return }
                    appState.activeRoom = updated
                    let remainingReconciliationBudget = DetectiveVoteConflictRecoveryPolicy
                        .remainingBudgetMilliseconds(
                            elapsedMilliseconds: elapsedRecoveryMilliseconds()
                        )
                    guard remainingReconciliationBudget > 0 else {
                        presentDetectiveVoteSyncDelayed()
                        return
                    }
                    switch await reconcileDetectiveVoteConflict(
                        previous: room,
                        cast: castScope,
                        refreshAfterReject: true,
                        refreshTimeoutInterval:
                            Double(remainingReconciliationBudget) / 1_000
                    ) {
                    case .resolved, .stop:
                        return
                    case .failed(let refreshError):
                        presentDetectiveVoteFailure(refreshError)
                        return
                    case .rejected:
                        presentDetectiveVoteSyncDelayed()
                        return
                    case .retry:
                        guard let delay = DetectiveVoteConflictRecoveryPolicy
                            .delayMilliseconds(
                                beforeRetry: retry,
                                elapsedMilliseconds: elapsedRecoveryMilliseconds()
                            ) else {
                            presentDetectiveVoteSyncDelayed()
                            return
                        }
                        retry += 1
                        do {
                            try await Task.sleep(for: .milliseconds(delay))
                        } catch {
                            return
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled,
                      !RequestCancellationPolicy.isCancellation(error) else { return }
                if UncertainRoomMutationRecoveryPolicy.shouldRefreshAfterFailure(error) {
                    switch await reconcileDetectiveVoteConflict(
                        previous: room,
                        cast: castScope,
                        forceAuthoritativeRefresh: true,
                        refreshTimeoutInterval:
                            RoomActionTransportPolicy.timeoutInterval(for: "get_room")
                    ) {
                    case .resolved, .stop:
                        return
                    case .retry, .rejected, .failed:
                        // The transport may have lost only the response. Do not
                        // cast again; realtime/polling will settle the result.
                        presentDetectiveVoteSyncDelayed()
                        return
                    }
                }
                if DetectiveVoteRoundChangedPolicy.shouldReconcile(
                    action: "cast_detective_vote",
                    error: error
                ) {
                    await reconcileChangedDetectiveVoteRound(
                        previous: room,
                        cast: castScope
                    )
                    return
                }
                if DetectiveVoteResponsePolicy.shouldReconcileInactiveVote(error) {
                    await reconcileInactiveDetectiveVote(
                        previous: room,
                        cast: castScope
                    )
                    return
                }
                guard DetectiveVoteConflictRecoveryPolicy.isRecoverableConflict(error) else {
                    presentDetectiveVoteFailure(error)
                    return
                }

                let remainingReconciliationBudget = DetectiveVoteConflictRecoveryPolicy
                    .remainingBudgetMilliseconds(
                        elapsedMilliseconds: elapsedRecoveryMilliseconds()
                    )
                guard remainingReconciliationBudget > 0 else {
                    presentDetectiveVoteSyncDelayed()
                    return
                }

                switch await reconcileDetectiveVoteConflict(
                    previous: room,
                    cast: castScope,
                    refreshTimeoutInterval:
                        Double(remainingReconciliationBudget) / 1_000
                ) {
                case .resolved, .stop:
                    return
                case .failed(let refreshError):
                    presentDetectiveVoteFailure(refreshError)
                    return
                case .rejected:
                    presentDetectiveVoteSyncDelayed()
                    return
                case .retry:
                    guard let delay = DetectiveVoteConflictRecoveryPolicy
                        .delayMilliseconds(
                            beforeRetry: retry,
                            elapsedMilliseconds: elapsedRecoveryMilliseconds()
                        ) else {
                        presentDetectiveVoteSyncDelayed()
                        return
                    }
                    retry += 1
                    do {
                        try await Task.sleep(for: .milliseconds(delay))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func reconcileChangedDetectiveVoteRound(
        previous: GameRoom,
        cast: DetectiveVoteCastScope
    ) async {
        guard !Task.isCancelled,
              cast.matchesActor(appState.user?.email),
              let activeRoom = appState.activeRoom,
              cast.room.matches(activeRoom) else { return }
        do {
            guard let refreshed = try await appState.client.refreshRoom(id: cast.room.roomID) else {
                return
            }
            guard !Task.isCancelled,
                  cast.matchesActor(appState.user?.email),
                  let currentRoom = appState.activeRoom,
                  cast.room.matches(currentRoom) else { return }

            let authoritative: GameRoom
            if OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: refreshed,
                over: currentRoom,
                scope: cast.room
            ) {
                authoritative = refreshed
            } else if cast.room.matches(refreshed) {
                authoritative = currentRoom
            } else {
                return
            }

            guard let latestRoom = appState.activeRoom,
                  OnlineAuthoritativeRoomPolicy.canAdopt(
                      candidate: authoritative,
                      over: latestRoom,
                      scope: cast.room
                  ) else { return }
            let feedback = DetectiveVoteRoundChangedPolicy.feedback(
                previous: previous,
                authoritative: authoritative
            )
            appState.activeRoom = authoritative
            if feedback == .cancelled {
                presentLegacyDetectiveVoteCancellationFeedbackIfNeeded(
                    authoritative: authoritative
                )
            }
        } catch {
            return
        }
    }

    private func reconcileDetectiveVoteConflict(
        previous: GameRoom,
        cast: DetectiveVoteCastScope,
        refreshAfterReject: Bool = false,
        forceAuthoritativeRefresh: Bool = false,
        refreshTimeoutInterval: TimeInterval? = nil
    ) async -> DetectiveVoteConflictReconciliationOutcome {
        guard !Task.isCancelled,
              cast.matchesActor(appState.user?.email),
              let activeRoom = appState.activeRoom,
              cast.room.matches(activeRoom) else { return .stop }
        if !forceAuthoritativeRefresh {
            switch DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: activeRoom,
                cast: cast,
                now: Date()
            ) {
            case .persisted, .cancelled:
                applyDetectiveVoteResponse(
                    previous: previous,
                    authoritative: activeRoom,
                    scope: cast.room
                )
                return .resolved
            case .superseded, .ejected, .finished, .deadline:
                return .resolved
            case .reject:
                guard refreshAfterReject else { return .stop }
            case .retry:
                break
            }
        }
        do {
            guard let refreshed = try await appState.client.refreshRoom(
                id: cast.room.roomID,
                timeoutInterval: refreshTimeoutInterval,
                allowsTypedConflictRetry: refreshTimeoutInterval == nil
            ) else {
                return .retry
            }
            guard !Task.isCancelled,
                  cast.matchesActor(appState.user?.email),
                  let currentRoom = appState.activeRoom,
                  cast.room.matches(currentRoom) else { return .stop }
            guard cast.room.matches(refreshed) else { return .rejected }
            if cast.hasChangedVoteRound(currentRoom) {
                return .stop
            }
            if cast.hasChangedVoteRound(refreshed) {
                guard OnlineAuthoritativeRoomPolicy.canAdopt(
                    candidate: refreshed,
                    over: currentRoom,
                    scope: cast.room
                ) else { return .stop }
                appState.activeRoom = refreshed
                return .resolved
            }

            let authoritative: GameRoom
            if OnlineAuthoritativeRoomPolicy.canAdopt(
                candidate: refreshed,
                over: currentRoom,
                scope: cast.room
            ) {
                authoritative = refreshed
            } else if cast.room.matches(refreshed) {
                authoritative = currentRoom
            } else {
                return .rejected
            }

            switch DetectiveVoteConflictRecoveryPolicy.resolution(
                previous: previous,
                authoritative: authoritative,
                cast: cast,
                now: Date()
            ) {
            case .persisted, .cancelled:
                applyDetectiveVoteResponse(
                    previous: previous,
                    authoritative: authoritative,
                    scope: cast.room
                )
                return .resolved
            case .superseded, .ejected, .finished, .deadline:
                guard let latestRoom = appState.activeRoom,
                      OnlineAuthoritativeRoomPolicy.canAdopt(
                          candidate: authoritative,
                          over: latestRoom,
                          scope: cast.room
                      ) else { return .stop }
                appState.activeRoom = authoritative
                return .resolved
            case .retry:
                guard let latestRoom = appState.activeRoom,
                      OnlineAuthoritativeRoomPolicy.canAdopt(
                          candidate: authoritative,
                          over: latestRoom,
                          scope: cast.room
                      ) else { return .stop }
                appState.activeRoom = authoritative
                return .retry
            case .reject:
                return .rejected
            }
        } catch {
            guard !Task.isCancelled,
                  !RequestCancellationPolicy.isCancellation(error) else { return .stop }
            return LobbySyncRetryPolicy.isRetryable(error) ? .retry : .failed(error)
        }
    }

    private func reconcileInactiveDetectiveVote(
        previous: GameRoom,
        cast: DetectiveVoteCastScope
    ) async {
        switch await reconcileDetectiveVoteConflict(previous: previous, cast: cast) {
        case .retry, .rejected, .failed:
            appState.showToast(detectiveVoteSyncDelayedStatus, kind: .warning)
            HapticManager.shared.fire(.notification(.warning))
        case .resolved, .stop:
            return
        }
    }

    private func presentDetectiveVoteFailure(_ error: Error) {
        status = error.localizedDescription.uppercased()
        HapticManager.shared.fire(.notification(.error))
    }

    private func presentDetectiveVoteSyncDelayed() {
        appState.showToast(detectiveVoteSyncDelayedStatus, kind: .warning)
        HapticManager.shared.fire(.notification(.warning))
    }

    private func applyDetectiveVoteResponse(
        previous: GameRoom,
        authoritative: GameRoom,
        scope: OnlineRoomMatchScope
    ) {
        guard let currentRoom = appState.activeRoom,
              OnlineAuthoritativeRoomPolicy.canAdopt(
                  candidate: authoritative,
                  over: currentRoom,
                  scope: scope
              ) else { return }
        let transition = DetectiveVoteResponsePolicy.classify(
            previous: previous,
            authoritative: authoritative
        )
        appState.activeRoom = authoritative
        switch transition {
        case .recorded:
            status = copy.voteLockedStatus
            HapticManager.shared.fire(.notification(.success))
        case .cancelled:
            presentLegacyDetectiveVoteCancellationFeedbackIfNeeded(
                authoritative: authoritative
            )
        }
    }

    private func submitSpyGuess(_ room: GameRoom, word: String) async throws {
        guard detectiveVoteCancellationPresentation == nil,
              !room.isGamePaused,
              !isTimeExpired(room) else {
            throw Base44Error(
                message: localized(
                    en: "The guessing window has closed.",
                    ru: "Окно для выбора слова уже закрыто.",
                    es: "La ventana para adivinar ya se cerro.",
                    uk: "Час для вибору слова вже минув."
                ),
                statusCode: 409
            )
        }
        guard let user = appState.user,
              let scope = SpyGuessSubmissionScope(room: room, guess: word) else {
            throw Base44Error(
                message: localized(
                    en: "Unable to submit that word. Try again.",
                    ru: "Не удалось отправить это слово. Попробуй ещё раз.",
                    es: "No se pudo enviar esa palabra. Intentalo de nuevo.",
                    uk: "Не вдалося надіслати це слово. Спробуй ще раз."
                ),
                statusCode: 400
            )
        }
        guard !isSubmittingSpyGuess else {
            throw Base44Error(
                message: localized(
                    en: "That guess is already being submitted.",
                    ru: "Этот вариант уже отправляется.",
                    es: "Esa respuesta ya se esta enviando.",
                    uk: "Цей варіант уже надсилається."
                ),
                statusCode: 409
            )
        }
        if appState.shouldUsePreviewData {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "--spyclash-preview-slow-spy-guess"
            ) {
                try await Task.sleep(for: .seconds(10))
            }
#endif
            var previewRoom = room
            previewRoom.spyGuess = word.trimmingCharacters(in: .whitespacesAndNewlines)
            previewRoom.status = "finished"
            previewRoom.winner = previewRoom.displayWord.map {
                $0.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } == true ? "spy" : "detectives"
            appState.activeRoom = previewRoom
            status = copy.spyGuessLocked
            return
        }
        isSubmittingSpyGuess = true
        defer { isSubmittingSpyGuess = false }

        let updated: GameRoom
        do {
            updated = try await appState.client.submitSpyGuess(
                room: room,
                user: user,
                guess: word
            )
        } catch {
            guard !RequestCancellationPolicy.isCancellation(error) else { throw error }
            if try await recoverCommittedSpyGuess(scope) {
                status = copy.spyGuessLocked
                return
            }
            throw error
        }

        if adoptCommittedSpyGuessCandidate(updated, scope: scope) {
            status = copy.spyGuessLocked
            return
        }
        if try await recoverCommittedSpyGuess(scope) {
            status = copy.spyGuessLocked
            return
        }

        throw Base44Error(
            message: localized(
                en: "The result is still syncing. Tap retry to confirm your guess.",
                ru: "Результат ещё синхронизируется. Нажми повтор, чтобы подтвердить выбор.",
                es: "El resultado sigue sincronizandose. Toca reintentar para confirmar.",
                uk: "Результат ще синхронізується. Натисни повтор, щоб підтвердити вибір."
            ),
            statusCode: 503,
            code: "spy_guess_commit_unconfirmed",
            retryable: true
        )
    }

    private func recoverCommittedSpyGuess(_ scope: SpyGuessSubmissionScope) async throws -> Bool {
        try Task.checkCancellation()
        if let currentRoom = appState.activeRoom,
           scope.confirmsCommit(in: currentRoom) {
            return true
        }
        guard let refreshed = try? await appState.client.refreshRoom(id: scope.room.roomID) else {
            try Task.checkCancellation()
            return false
        }
        try Task.checkCancellation()
        return adoptCommittedSpyGuessCandidate(refreshed, scope: scope)
    }

    private func adoptCommittedSpyGuessCandidate(
        _ candidate: GameRoom,
        scope: SpyGuessSubmissionScope
    ) -> Bool {
        guard let currentRoom = appState.activeRoom,
              scope.room.matches(currentRoom) else { return false }
        if scope.confirmsCommit(in: currentRoom) {
            return true
        }
        guard OnlineAuthoritativeRoomPolicy.canAdopt(
            candidate: candidate,
            over: currentRoom,
            scope: scope.room
        ) else { return false }
        appState.activeRoom = candidate
        return scope.confirmsCommit(in: candidate)
    }

    private func leaveRoom(_ room: GameRoom) async {
        appState.leaveRoomImmediately(room)
        HapticManager.shared.fire(.buttonPress)
        status = ""
        revealRole = false
    }

}

private struct PreparedRoomQRCode: @unchecked Sendable {
    let payload: String
    let image: UIImage
}

private struct RoomQRFlipFace: @MainActor AnimatableModifier {
    var progress: Double
    let isBack: Bool
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let angle = isBack
            ? -180 + (clampedProgress * 180)
            : clampedProgress * 180
        let faceOpacity = reduceMotion
            ? (isBack ? clampedProgress : 1 - clampedProgress)
            : (isBack
                ? (clampedProgress >= 0.5 ? 1.0 : 0.0)
                : (clampedProgress < 0.5 ? 1.0 : 0.0))

        content
            .opacity(faceOpacity)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.72
            )
    }
}

private struct RoomQRFlipSheen: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let normalizedProgress = min(max((progress + 1.12) / 2.24, 0), 1)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.035),
                            SpyTheme.red.opacity(0.18),
                            Color.white.opacity(0.075),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 84, height: proxy.size.height + 28)
                .rotationEffect(.degrees(11))
                .blur(radius: 3)
                .offset(
                    x: -110 + (normalizedProgress * (proxy.size.width + 220)),
                    y: -14
                )
                .blendMode(.screen)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RoomQRScanBeam: View {
    @SpyReduceMotion private var reduceMotion
    let isActive: Bool
    @State private var beamAtEnd = false

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            SpyTheme.red.opacity(0.12),
                            SpyTheme.red.opacity(0.68),
                            SpyTheme.red.opacity(0.12),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .shadow(color: SpyTheme.red.opacity(0.62), radius: 7)
                .offset(y: beamAtEnd ? (proxy.size.height / 2) + 14 : -(proxy.size.height / 2) - 14)
        }
        .mask {
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(isActive ? 1 : 0.34)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isActive) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                beamAtEnd = false
            }

            guard isActive, !reduceMotion else { return }
            await Task.yield()

            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                beamAtEnd = true
            }
        }
    }
}

private struct RoomCodeSpoilerField: View {
    @SpyReduceMotion private var reduceMotion
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isActive)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                for index in 0..<80 {
                    let seed = Double(index)
                    let column = CGFloat(index % 20)
                    let row = CGFloat(index / 20)
                    let xJitter = CGFloat((sin(seed * 2.41) + 1) * 0.26)
                    let yJitter = CGFloat((cos(seed * 1.73) + 1) * 0.22)
                    let xUnit = (column + 0.22 + xJitter) / 20
                    let yUnit = (row + 0.28 + yJitter) / 4
                    let speed = 0.72 + (seed.truncatingRemainder(dividingBy: 9.0) * 0.07)
                    let phase = seed * 1.71
                    let driftX = CGFloat(sin((time * speed) + phase) * (5 + seed.truncatingRemainder(dividingBy: 8.0)))
                    let driftY = CGFloat(cos((time * speed * 0.72) + phase) * (3 + seed.truncatingRemainder(dividingBy: 5.0)))
                    let diameter = CGFloat(2.6 + seed.truncatingRemainder(dividingBy: 3.0))
                    let pulse = 0.58 + (sin((time * 1.35) + phase) + 1) * 0.18
                    let rect = CGRect(
                        x: (xUnit * max(size.width - diameter, 0)) + driftX,
                        y: (yUnit * max(size.height - diameter, 0)) + driftY,
                        width: diameter,
                        height: diameter
                    )

                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(min(max(pulse, 0.34), 0.94)))
                    )
                }
            }
        }
        .mask {
            LinearGradient(
                colors: [.clear, .white, .white, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .shadow(color: .white.opacity(0.34), radius: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WaitingStartActionLabel: View {
    @SpyReduceMotion private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let mode: WaitingStartActionMode
    let title: String
    let detail: String
    let usesAvailableAppearance: Bool

    var body: some View {
        ZStack {
            replacementContent
        }
        .frame(maxWidth: .infinity, minHeight: actionMinimumHeight)
        .contentShape(CutCornerShape(cut: 9))
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: mode
        )
        .accessibilityElement(children: .ignore)
    }

    @ViewBuilder
    private var replacementContent: some View {
        switch mode {
        case .action:
            actionContent
                .transition(replacementTransition)

        case .syncing:
            statusContent(
                accent: SpyTheme.red,
                systemImage: nil,
                showsSpinner: true
            )
            .transition(replacementTransition)

        case .serverConfirmed:
            statusContent(
                accent: SpyTheme.green,
                systemImage: "checkmark.circle.fill",
                showsSpinner: false
            )
            .transition(replacementTransition)

        case .failed:
            statusContent(
                accent: SpyTheme.amber,
                systemImage: "exclamationmark.triangle.fill",
                showsSpinner: false
            )
            .transition(replacementTransition)
        }
    }

    private var actionContent: some View {
        SpyLobbyPrimaryActionLabel(
            title: title,
            detail: detail,
            systemImage: "play.fill",
            isAvailable: usesAvailableAppearance
        )
    }

    private func statusContent(
        accent: Color,
        systemImage: String?,
        showsSpinner: Bool
    ) -> some View {
        let displayedAccent = usesAvailableAppearance ? accent : SpyTheme.dim

        return HStack(spacing: 9) {
            Group {
                if showsSpinner {
                    SpySpinner(size: 14, accent: displayedAccent)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(displayedAccent)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)

            textContent(
                titleColor: Color.white.opacity(usesAvailableAppearance ? 0.94 : 0.40),
                detailColor: usesAvailableAppearance
                    ? Color.white.opacity(0.58)
                    : SpyTheme.dim.opacity(0.72),
                titleSize: dynamicTypeSize.isAccessibilitySize ? 11 : 8.4
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: actionMinimumHeight)
        .background(
            LinearGradient(
                colors: [
                    displayedAccent.opacity(usesAvailableAppearance ? 0.16 : 0.055),
                    Color.white.opacity(usesAvailableAppearance ? 0.025 : 0.012)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: CutCornerShape(cut: 9)
        )
        .overlay(
            CutCornerShape(cut: 9)
                .stroke(displayedAccent.opacity(usesAvailableAppearance ? 0.58 : 0.22), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            CornerStroke(
                color: displayedAccent.opacity(usesAvailableAppearance ? 0.84 : 0.30)
            )
                .frame(width: 14, height: 14)
        }
        .shadow(
            color: usesAvailableAppearance ? accent.opacity(0.12) : .clear,
            radius: 12,
            y: 4
        )
    }

    private func textContent(
        titleColor: Color,
        detailColor: Color,
        titleSize: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: titleSize, weight: .black, design: .monospaced))
                .foregroundStyle(titleColor)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.78 : 0.52)
                .contentTransition(.opacity)

            Text(detail)
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 8.5 : 7, weight: .bold, design: .monospaced))
                .foregroundStyle(detailColor)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.76 : 0.50)
                .contentTransition(.opacity)
        }
    }

    private var replacementTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
    }

    private var actionMinimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 72 : 58
    }
}

private enum RoomWordSource: Equatable {
    case none
    case generated
    case saved(String)
}

private enum RoomPackLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private enum OnlineSetupField: Hashable {
    case theme
}

private enum OnlineSetupPanel: Hashable {
    case mission
    case mode
    case roles
    case timing
    case players
    case intel
    case controls
}

/// Erases each large setup panel at a stable boundary. On physical iOS 26.4,
/// nesting all six concrete panel types inside the former generic helper could
/// recurse through Swift metadata instantiation and overflow the main stack.
private struct OnlineSetupSlotView: View {
    let content: AnyView
    let dimmed: Bool

    var body: some View {
        content
            .modifier(SpyLobbySetupFocusEffect(dimmed: dimmed))
    }
}

private enum RoomWordCountMode: String, CaseIterable, Identifiable {
    case recommended
    case custom

    var id: String { rawValue }
}

private enum RoomThemeOperation {
    case generate
    case expand
}

enum LobbyDraftPoolPolicy {
    /// A missing local pack means the current theme draft invalidated its pool.
    /// The room snapshot can still contain words from a saved pack or an older
    /// theme, so reusing it here would relabel stale words as the new AI draft.
    static func generatedPayloadWords(
        localWords: [String]?,
        priorAuthoritativeWords _: [String]
    ) -> [String] {
        localWords ?? []
    }
}

enum RoomWordPoolFilter {
    static func canonicalWord(_ rawValue: String) -> String {
        rawValue
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func key(_ rawValue: String) -> String {
        canonicalWord(rawValue)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func activeWords(_ words: [String], excluding disabledKeys: Set<String>) -> [String] {
        var seen = Set<String>()
        return words.compactMap { rawValue in
            let word = canonicalWord(rawValue)
            guard !word.isEmpty else { return nil }
            let normalizedKey = key(word)
            guard seen.insert(normalizedKey).inserted,
                  !disabledKeys.contains(normalizedKey) else { return nil }
            return word
        }
    }
}

private struct RoomPoolSnapshot: Equatable {
    let category: String
    let source: String
    let words: [String]
    let disabledWordKeys: Set<String>
    let countLabel: String
}

private extension Array where Element == String {
    var roomCleanWords: [String] {
        var seen = Set<String>()
        return compactMap { raw in
            let word = RoomWordPoolFilter.canonicalWord(raw)
            guard !word.isEmpty else { return nil }
            let key = RoomWordPoolFilter.key(word)
            guard seen.insert(key).inserted else { return nil }
            return word
        }
    }
}

private struct SpyGuessSheet: View {
    let room: GameRoom
    let isSubmitting: Bool
    let copy: GameCopy
    let language: AppLanguage
    let onGuess: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var submissionPhase = SpyGuessSubmissionPhase.idle
    @State private var submissionTask: Task<Void, Never>?

    private var words: [WordPoolEntry] {
        room.enabledWordPool.sorted {
            $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending
        }
    }

    private var blocksInteraction: Bool {
        isSubmitting || submissionPhase.blocksInteraction
    }

    var body: some View {
        ZStack {
            SpyTheme.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(copy.spyGuessEyebrow)
                            .font(SpyTheme.micro)
                            .tracking(0.12)
                            .foregroundStyle(SpyTheme.dim)
                            .spyKicker()
                        Text(submissionPhase.submittingWord == nil ? copy.chooseWord : copy.spyGuessLocked)
                            .font(.system(size: 28, weight: .black, design: .default))
                            .tracking(0.04)
                            .foregroundStyle(SpyTheme.red)
                            .spyFitted(lines: 2, scale: 0.58)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(SpyButtonStyle(variant: .ghost))
                    .frame(width: 54)
                    .disabled(blocksInteraction)
                }

                if let submittingWord = submissionPhase.submittingWord {
                    submissionAcknowledgement(for: submittingWord)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    Text(copy.spyGuessHint)
                        .font(SpyTheme.mono)
                        .foregroundStyle(SpyTheme.muted)
                        .lineSpacing(3)

                    if let failedWord = submissionPhase.failedWord {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(localized(
                                en: "YOUR GUESS WAS NOT CONFIRMED. NOTHING CHANGED — TRY AGAIN.",
                                ru: "ВЫБОР НЕ ПОДТВЕРЖДЁН. НИЧЕГО НЕ ИЗМЕНИЛОСЬ — ПОПРОБУЙ ЕЩЁ РАЗ.",
                                es: "NO SE CONFIRMO TU RESPUESTA. NADA CAMBIO — INTENTALO DE NUEVO.",
                                uk: "ВИБІР НЕ ПІДТВЕРДЖЕНО. НІЧОГО НЕ ЗМІНИЛОСЯ — СПРОБУЙ ЩЕ РАЗ."
                            ))
                            .font(SpyTheme.micro)
                            .tracking(0.06)
                            .foregroundStyle(SpyTheme.amber)
                            .spyFitted(lines: 3, scale: 0.58)

                            Button {
                                beginSubmission(failedWord)
                            } label: {
                                Label(
                                    localized(
                                        en: "RETRY \(failedWord.uppercased())",
                                        ru: "ПОВТОРИТЬ: \(failedWord.uppercased())",
                                        es: "REINTENTAR: \(failedWord.uppercased())",
                                        uk: "ПОВТОРИТИ: \(failedWord.uppercased())"
                                    ),
                                    systemImage: "arrow.clockwise"
                                )
                                .lineLimit(2)
                                .minimumScaleFactor(0.56)
                            }
                            .buttonStyle(SpyButtonStyle(variant: .outline))
                            .accessibilityIdentifier("onlineRoom.spyGuess.retry")
                        }
                        .padding(12)
                        .background(SpyTheme.amber.opacity(0.08), in: CutCornerShape(cut: 8))
                        .overlay(
                            CutCornerShape(cut: 8)
                                .stroke(SpyTheme.amber.opacity(0.46), lineWidth: 1)
                        )
                    }

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(words) { entry in
                                Button {
                                    beginSubmission(entry.word)
                                } label: {
                                    HStack {
                                        Text(entry.word.uppercased())
                                            .font(.system(size: 11, weight: .bold, design: .default))
                                            .tracking(0.04)
                                            .foregroundStyle(.white)
                                            .spyFitted(lines: 2, scale: 0.54)
                                        Spacer()
                                        if submissionPhase.failedWord == entry.word {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(SpyTheme.amber)
                                        } else {
                                            Image(systemName: "scope")
                                                .foregroundStyle(SpyTheme.red)
                                        }
                                    }
                                }
                                .buttonStyle(SpyButtonStyle(variant: .ghost))
                                .disabled(blocksInteraction)
                                .accessibilityIdentifier("onlineRoom.spyGuess.word.\(entry.id)")
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .padding(20)
        }
        .interactiveDismissDisabled(blocksInteraction)
        .animation(.easeOut(duration: 0.16), value: submissionPhase)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
        }
    }

    private func submissionAcknowledgement(for word: String) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(SpyTheme.red.opacity(0.14))
                    .frame(width: 92, height: 92)
                Circle()
                    .stroke(SpyTheme.red.opacity(0.5), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: "lock.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(SpyTheme.red)
            }

            VStack(spacing: 8) {
                Text(word.uppercased())
                    .font(.system(size: 24, weight: .black, design: .default))
                    .tracking(0.05)
                    .foregroundStyle(.white)
                    .spyFitted(lines: 2, scale: 0.56)
                    .accessibilityIdentifier("onlineRoom.spyGuess.syncing.word")

                Text(localized(
                    en: "YOUR GUESS IS LOCKED ON THIS DEVICE",
                    ru: "ВЫБОР ЗАФИКСИРОВАН НА ЭТОМ УСТРОЙСТВЕ",
                    es: "TU RESPUESTA QUEDO BLOQUEADA EN ESTE DISPOSITIVO",
                    uk: "ВИБІР ЗАФІКСОВАНО НА ЦЬОМУ ПРИСТРОЇ"
                ))
                .font(SpyTheme.micro)
                .tracking(0.06)
                .foregroundStyle(SpyTheme.muted)
                .multilineTextAlignment(.center)
                .spyFitted(lines: 2, scale: 0.58)
            }

            HStack(spacing: 10) {
                SpySpinner(size: 18, accent: SpyTheme.red)
                Text(localized(
                    en: "CONFIRMING THE RESULT WITH THE SERVER...",
                    ru: "ПОДТВЕРЖДАЕМ РЕЗУЛЬТАТ НА СЕРВЕРЕ...",
                    es: "CONFIRMANDO EL RESULTADO CON EL SERVIDOR...",
                    uk: "ПІДТВЕРДЖУЄМО РЕЗУЛЬТАТ НА СЕРВЕРІ..."
                ))
                .font(SpyTheme.micro)
                .tracking(0.04)
                .foregroundStyle(SpyTheme.dim)
                .spyFitted(lines: 2, scale: 0.56)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(SpyTheme.red.opacity(0.07), in: CutCornerShape(cut: 8))
            .overlay(
                CutCornerShape(cut: 8)
                    .stroke(SpyTheme.red.opacity(0.35), lineWidth: 1)
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onlineRoom.spyGuess.syncing")
    }

    private func beginSubmission(_ word: String) {
        guard let pending = SpyGuessSubmissionPhase.begin(
            word: word,
            from: submissionPhase
        ) else { return }
        submissionPhase = pending
        HapticManager.shared.fire(.buttonPress)

        submissionTask?.cancel()
        submissionTask = Task { @MainActor in
            // Let SwiftUI commit the locked acknowledgement before any network
            // work starts, so the first tap always has visible feedback.
            await Task.yield()
            do {
                try await onGuess(word)
                submissionTask = nil
                HapticManager.shared.fire(.notification(.success))
                dismiss()
            } catch {
                guard !RequestCancellationPolicy.isCancellation(error) else {
                    submissionTask = nil
                    submissionPhase = .idle
                    return
                }
                submissionTask = nil
                submissionPhase = submissionPhase.failing()
                HapticManager.shared.fire(.notification(.error))
            }
        }
    }

    private func localized(en: String, ru: String, es: String, uk: String) -> String {
        switch language {
        case .en: en
        case .ru: ru
        case .es: es
        case .uk: uk
        }
    }
}
