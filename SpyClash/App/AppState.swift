import AuthenticationServices
import Foundation
import Observation
import UIKit

enum AppleAuthStage: Int, CaseIterable, Identifiable {
    case verifyingIdentity
    case establishingSession
    case synchronizingProfile
    case accessGranted

    var id: Int { rawValue }

    var progressPercent: Int {
        switch self {
        case .verifyingIdentity: 22
        case .establishingSession: 58
        case .synchronizingProfile: 84
        case .accessGranted: 100
        }
    }

    var progress: Double {
        Double(progressPercent) / 100
    }
}

enum StandardAuthCinematicStage: Equatable {
    case preparing
    case placing(Int)
    case assembled
    case accessGranted

    var placedCount: Int {
        switch self {
        case .preparing:
            0
        case .placing(let piece):
            piece
        case .assembled, .accessGranted:
            4
        }
    }
}

enum AuthHomeRevealPhase: Equatable {
    case idle
    case covered
    case revealing
}

private enum ProviderAuthCinematic: Equatable {
    case apple
    case standard
}

private enum ActiveRoomRestoreOutcome: Equatable {
    case restored
    case noActiveRoom
    case retryLater
}

enum RadarInvitePolicySyncState: Equatable {
    case localOnly
    case syncing
    case synced
    case pendingRetry
}

enum RoomSyncOperation: Equatable {
    case creatingRoom
    case joiningRoom
    case closingRoom
    case leavingRoom
    case updatingMode(SpyGameMode)
    case updatingDuration(minutes: Int)

    func title(for language: AppLanguage) -> String {
        switch (self, language) {
        case (.creatingRoom, .ru): "СОЗДАНИЕ КОМНАТЫ"
        case (.creatingRoom, .es): "CREANDO SALA"
        case (.creatingRoom, .uk): "СТВОРЕННЯ КІМНАТИ"
        case (.creatingRoom, _): "CREATING ROOM"
        case (.joiningRoom, .ru): "ПОДКЛЮЧЕНИЕ К КОМНАТЕ"
        case (.joiningRoom, .es): "CONECTANDO A LA SALA"
        case (.joiningRoom, .uk): "ПІДКЛЮЧЕННЯ ДО КІМНАТИ"
        case (.joiningRoom, _): "JOINING ROOM"
        case (.closingRoom, .ru): "ЗАКРЫТИЕ КОМНАТЫ"
        case (.closingRoom, .es): "CERRANDO SALA"
        case (.closingRoom, .uk): "ЗАКРИТТЯ КІМНАТИ"
        case (.closingRoom, _): "CLOSING ROOM"
        case (.leavingRoom, .ru): "ВЫХОД ИЗ КОМНАТЫ"
        case (.leavingRoom, .es): "SALIENDO DE LA SALA"
        case (.leavingRoom, .uk): "ВИХІД ІЗ КІМНАТИ"
        case (.leavingRoom, _): "LEAVING ROOM"
        case (.updatingMode, .ru): "СИНХРОНИЗАЦИЯ РЕЖИМА"
        case (.updatingMode, .es): "SINCRONIZANDO MODO"
        case (.updatingMode, .uk): "СИНХРОНІЗАЦІЯ РЕЖИМУ"
        case (.updatingMode, _): "SYNCING GAME MODE"
        case (.updatingDuration, .ru): "СИНХРОНИЗАЦИЯ ВРЕМЕНИ"
        case (.updatingDuration, .es): "SINCRONIZANDO TIEMPO"
        case (.updatingDuration, .uk): "СИНХРОНІЗАЦІЯ ТРИВАЛОСТІ"
        case (.updatingDuration, _): "SYNCING DURATION"
        }
    }

    func detail(for language: AppLanguage) -> String {
        switch self {
        case .creatingRoom:
            return switch language {
            case .ru: "Подготавливаем защищённую игровую сессию. Пожалуйста, подождите."
            case .es: "Preparando una sesion segura. Espera un momento."
            case .uk: "Готуємо захищену ігрову сесію. Зачекай, будь ласка."
            default: "Preparing a secure game session. Please wait."
            }
        case .joiningRoom:
            return switch language {
            case .ru: "Подключаемся и синхронизируем состояние комнаты. Пожалуйста, подождите."
            case .es: "Conectando y sincronizando el estado de la sala. Espera un momento."
            case .uk: "Підключаємося та синхронізуємо стан кімнати. Зачекай, будь ласка."
            default: "Connecting and synchronizing room state. Please wait."
            }
        case .closingRoom:
            return switch language {
            case .ru: "Закрываем сессию для всех игроков. Пожалуйста, подождите."
            case .es: "Cerrando la sesion para todos los jugadores. Espera un momento."
            case .uk: "Закриваємо сесію для всіх гравців. Зачекай, будь ласка."
            default: "Closing the session for every player. Please wait."
            }
        case .leavingRoom:
            return switch language {
            case .ru: "Синхронизируем выход из комнаты. Пожалуйста, подождите."
            case .es: "Sincronizando tu salida de la sala. Espera un momento."
            case .uk: "Синхронізуємо твій вихід із кімнати. Зачекай, будь ласка."
            default: "Synchronizing your exit from the room. Please wait."
            }
        case .updatingMode(let mode):
            let modeTitle: String
            switch (mode, language) {
            case (.questions, .ru): modeTitle = "«Вопросы»"
            case (.associations, .ru): modeTitle = "«Ассоциации»"
            case (.questions, .es): modeTitle = "Preguntas"
            case (.associations, .es): modeTitle = "Asociaciones"
            case (.questions, .uk): modeTitle = "«Запитання»"
            case (.associations, .uk): modeTitle = "«Асоціації»"
            case (.questions, _): modeTitle = "Questions"
            case (.associations, _): modeTitle = "Associations"
            }
            switch language {
            case .ru: return "Переключаем комнату на режим \(modeTitle). Пожалуйста, подождите."
            case .es: return "Cambiando la sala al modo \(modeTitle). Espera un momento."
            case .uk: return "Перемикаємо кімнату в режим \(modeTitle). Зачекай, будь ласка."
            default: return "Switching the room to \(modeTitle) mode. Please wait."
            }
        case .updatingDuration(let minutes):
            return switch language {
            case .ru: "Устанавливаем длительность игры: \(minutes) мин. Пожалуйста, подождите."
            case .es: "Ajustando la duracion a \(minutes) min. Espera un momento."
            case .uk: "Установлюємо тривалість гри: \(minutes) хв. Зачекай, будь ласка."
            default: "Setting game duration to \(minutes) min. Please wait."
            }
        }
    }
}

enum RoomConnectionState: Equatable {
    case synced
    case reconnecting
}

struct RoomRefreshFailureTracker {
    private(set) var consecutiveFailures = 0
    private(set) var hasAnnouncedInterruption = false

    mutating func recordFailure(threshold: Int = 3) -> Bool {
        if consecutiveFailures < Int.max {
            consecutiveFailures += 1
        }
        guard consecutiveFailures >= max(threshold, 1),
              !hasAnnouncedInterruption else {
            return false
        }
        hasAnnouncedInterruption = true
        return true
    }

    mutating func recordSuccess() -> Bool {
        let shouldAnnounceRecovery = hasAnnouncedInterruption
        consecutiveFailures = 0
        hasAnnouncedInterruption = false
        return shouldAnnounceRecovery
    }
}

struct FinishedMatchCompetitiveStatsExpectation: Hashable {
    let minimumGamesPlayed: Int

    init(minimumGamesPlayed: Int) {
        self.minimumGamesPlayed = minimumGamesPlayed
    }

    init?(room: GameRoom, user: SpyUser) {
        let accountEmail = user.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard room.normalizedStatus == "finished",
              room.lobbySpyCountValue == 1,
              room.spyEmailsList.count == 1,
              !accountEmail.isEmpty,
              room.playersList.contains(where: {
                  $0.email
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == accountEmail
              }) else { return nil }

        let winner = room.winner?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard winner == "spy" || winner == "detectives" else { return nil }

        let baselineGames = max(0, user.gamesPlayed ?? 0)
        minimumGamesPlayed = baselineGames + 1
    }

    func isSatisfied(by user: SpyUser) -> Bool {
        max(0, user.gamesPlayed ?? 0) >= minimumGamesPlayed
    }
}

struct FinishedMatchProfileRefreshKey: Hashable {
    let userID: String
    let matchID: String
}

struct FinishedMatchProfileRefreshRequest: Hashable {
    let userID: String
    let matchID: String
    let expectedCompetitiveStats: FinishedMatchCompetitiveStatsExpectation

    var key: FinishedMatchProfileRefreshKey {
        FinishedMatchProfileRefreshKey(userID: userID, matchID: matchID)
    }
}

struct FinishedMatchProfileRefreshPolicy {
    static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(350),
        .milliseconds(900)
    ]

    private(set) var inFlight = Set<FinishedMatchProfileRefreshKey>()
    private(set) var completed = Set<FinishedMatchProfileRefreshKey>()
    private var cachedRequests: [
        FinishedMatchProfileRefreshKey: FinishedMatchProfileRefreshRequest
    ] = [:]

    mutating func request(
        room: GameRoom?,
        user: SpyUser?
    ) -> FinishedMatchProfileRefreshRequest? {
        guard let room,
              room.normalizedStatus == "finished",
              let matchID = room.matchID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank,
              let user,
              let userID = user.id
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank else { return nil }
        let key = FinishedMatchProfileRefreshKey(
            userID: userID,
            matchID: matchID
        )
        guard !completed.contains(key), !inFlight.contains(key) else {
            return nil
        }
        if let cachedRequest = cachedRequests[key] {
            inFlight.insert(key)
            return cachedRequest
        }
        guard let expectedCompetitiveStats = FinishedMatchCompetitiveStatsExpectation(
            room: room,
            user: user
        ) else { return nil }
        let request = FinishedMatchProfileRefreshRequest(
            userID: userID,
            matchID: matchID,
            expectedCompetitiveStats: expectedCompetitiveStats
        )
        cachedRequests[key] = request
        inFlight.insert(key)
        return request
    }

    mutating func finish(
        _ request: FinishedMatchProfileRefreshRequest,
        adopted: Bool
    ) {
        inFlight.remove(request.key)
        if adopted {
            completed.insert(request.key)
        }
    }

    static func hasExpectedIdentity(
        refreshedUserID: String,
        expectedUserID: String,
        currentUserID: String?
    ) -> Bool {
        refreshedUserID == expectedUserID && currentUserID == expectedUserID
    }

    static func canAdopt(
        refreshedUser: SpyUser,
        request: FinishedMatchProfileRefreshRequest,
        currentUserID: String?
    ) -> Bool {
        hasExpectedIdentity(
            refreshedUserID: refreshedUser.id,
            expectedUserID: request.userID,
            currentUserID: currentUserID
        ) && request.expectedCompetitiveStats.isSatisfied(by: refreshedUser)
    }
}

enum RoomRefreshDisposition: Equatable {
    case stop
    case discardAndContinue
    case apply
    case close
}

enum RoomRefreshFailureDisposition: Equatable {
    case retry
    case close
}

enum GameRoomRealtimeSignalDisposition: Equatable {
    case ignore
    case applyLobbyMode(GameRoomRealtimeLobbyModeProjection)
    case refresh(forceCatchUp: Bool)
    case close
}

enum GameRoomRealtimeSignalPolicy {
    static func disposition(
        signal: GameRoomRealtimeSignal,
        activeRoomID: String?,
        activeRoomStatus: String? = nil,
        currentRoomRevision: Int?,
        currentLobbyRevision: Int = 0,
        subscriptionGenerationIsCurrent: Bool = true
    ) -> GameRoomRealtimeSignalDisposition {
        guard subscriptionGenerationIsCurrent,
              signal.roomID == activeRoomID else { return .ignore }

        if signal.state == "closed" {
            if let signalRoomRevision = signal.roomRevision {
                // The first revisioned close after a legacy room migration is
                // authoritative even when the unrelated lobby counter is much
                // larger than the new room counter.
                guard let currentRoomRevision else { return .close }
                return signalRoomRevision >= max(currentRoomRevision, 0)
                    ? .close
                    : .ignore
            }
            return signal.lobbyRevision >= max(currentLobbyRevision, 0)
                ? .close
                : .ignore
        }

        guard let signalRoomRevision = signal.roomRevision else {
            return .refresh(forceCatchUp: true)
        }
        guard let currentRoomRevision else {
            // Never compare the fresh room-revision domain to a legacy lobby
            // revision. One mediated read establishes the migration baseline.
            return .refresh(forceCatchUp: true)
        }
        if let projection = signal.lobbyModeProjection,
           activeRoomStatus == "waiting",
           signalRoomRevision == max(currentRoomRevision, 0) + 1,
           signal.lobbyRevision == max(currentLobbyRevision, 0) {
            return .applyLobbyMode(projection)
        }
        return signalRoomRevision > max(currentRoomRevision, 0)
            ? .refresh(forceCatchUp: false)
            : .ignore
    }
}

enum GameRoomRealtimeLobbyModeApplier {
    static func applying(
        signal: GameRoomRealtimeSignal,
        projection: GameRoomRealtimeLobbyModeProjection,
        to room: GameRoom
    ) -> GameRoom {
        var updated = room
        updated.gameMode = projection.gameMode.rawValue
        updated.lobbyRevision = signal.lobbyRevision
        updated.roomRevision = signal.roomRevision
        return updated
    }
}

struct GameRoomRealtimeProjectionLatency: Equatable {
    let commitToReceiveMilliseconds: Int?
    let emitToReceiveMilliseconds: Int?

    static func measure(
        projection: GameRoomRealtimeLobbyModeProjection,
        receivedAt: Date
    ) -> GameRoomRealtimeProjectionLatency {
        GameRoomRealtimeProjectionLatency(
            commitToReceiveMilliseconds: milliseconds(
                from: projection.committedAt,
                to: receivedAt
            ),
            emitToReceiveMilliseconds: milliseconds(
                from: projection.emittedAt,
                to: receivedAt
            )
        )
    }

    private static func milliseconds(from raw: String?, to receivedAt: Date) -> Int? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else { return nil }
        return Int((receivedAt.timeIntervalSince(date) * 1_000).rounded())
    }
}

enum GameRoomRealtimeRefreshRetryPolicy {
    static let retryDelaysMilliseconds = [150, 350, 800]

    static func delayMilliseconds(afterFailedAttempt attempt: Int) -> Int? {
        guard retryDelaysMilliseconds.indices.contains(attempt) else { return nil }
        return retryDelaysMilliseconds[attempt]
    }
}

struct ClosedRoomRevisionFence: Equatable {
    private struct Marker: Equatable {
        let closedRoomRevision: Int?
        let closedLobbyRevision: Int?
        let closedMembershipID: String
        var reopenedMembershipID: String?
        var reopenedRoomRevision: Int?
        var reopenedLobbyRevision: Int?

        var hasKnownClosedRevision: Bool {
            closedRoomRevision != nil || closedLobbyRevision != nil
        }
    }

    private var markersByAccountAndRoom: [String: Marker] = [:]

    mutating func record(
        userID: String?,
        roomID: String,
        roomRevision: Int?,
        lobbyRevision: Int?,
        membershipID: String?
    ) {
        guard let key = key(userID: userID, roomID: roomID) else { return }
        let normalizedMembershipID = membershipID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedRoomRevision = roomRevision.map { max($0, 0) }
        let normalizedLobbyRevision = lobbyRevision.map { max($0, 0) }
        let prior = markersByAccountAndRoom[key]
        let closedRoomRevision: Int?
        let closedLobbyRevision: Int?
        if normalizedRoomRevision == nil, normalizedLobbyRevision == nil {
            closedRoomRevision = nil
            closedLobbyRevision = nil
        } else if let normalizedRoomRevision {
            closedRoomRevision = max(
                normalizedRoomRevision,
                prior?.closedRoomRevision ?? 0
            )
            closedLobbyRevision = normalizedLobbyRevision
        } else if prior?.closedRoomRevision != nil {
            // A legacy observation cannot downgrade an already revisioned
            // close marker to the unrelated lobby counter.
            closedRoomRevision = prior?.closedRoomRevision
            closedLobbyRevision = prior?.closedLobbyRevision
        } else {
            closedRoomRevision = nil
            closedLobbyRevision = normalizedLobbyRevision.map {
                max($0, prior?.closedLobbyRevision ?? 0)
            }
        }
        markersByAccountAndRoom[key] = Marker(
            // Both nil revisions mean a 404/nil authoritative read. Preserve
            // that as an unknown terminal boundary; guessing from the local
            // room could admit a response that still predates close.
            closedRoomRevision: closedRoomRevision,
            closedLobbyRevision: closedLobbyRevision,
            closedMembershipID: normalizedMembershipID,
            reopenedMembershipID: nil,
            reopenedRoomRevision: nil,
            reopenedLobbyRevision: nil
        )
    }

    func permits(
        userID: String?,
        roomID: String,
        roomRevision: Int?,
        lobbyRevision: Int?,
        membershipID: String?
    ) -> Bool {
        guard let key = key(userID: userID, roomID: roomID),
              let marker = markersByAccountAndRoom[key] else {
            return true
        }
        if let reopenedMembershipID = marker.reopenedMembershipID {
            let candidateMembershipID = membershipID?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !candidateMembershipID.isEmpty &&
                candidateMembershipID == reopenedMembershipID &&
                RoomPollPolicy.acceptsSnapshot(
                    currentRoomRevision: marker.reopenedRoomRevision,
                    currentLobbyRevision: marker.reopenedLobbyRevision,
                    fetchedRoomRevision: roomRevision,
                    fetchedLobbyRevision: lobbyRevision
                )
        }
        guard marker.hasKnownClosedRevision else { return false }
        // A close/kick signal is authoritative for this account's exact room
        // generation. Only an explicit later rejoin, which commits a strictly
        // newer room revision, may make that room adoptable again.
        return RoomPollPolicy.isSnapshotNewer(
            currentRoomRevision: marker.closedRoomRevision,
            currentLobbyRevision: marker.closedLobbyRevision,
            fetchedRoomRevision: roomRevision,
            fetchedLobbyRevision: lobbyRevision
        )
    }

    mutating func authorizeExplicitRejoin(
        userID: String?,
        roomID: String,
        roomRevision: Int?,
        lobbyRevision: Int?,
        membershipID: String?
    ) -> Bool {
        guard let key = key(userID: userID, roomID: roomID),
              var marker = markersByAccountAndRoom[key] else {
            return true
        }
        let candidateMembershipID = membershipID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidateMembershipID.isEmpty,
              marker.closedMembershipID.isEmpty ||
                candidateMembershipID != marker.closedMembershipID,
              !marker.hasKnownClosedRevision || RoomPollPolicy.isSnapshotNewer(
                  currentRoomRevision: marker.closedRoomRevision,
                  currentLobbyRevision: marker.closedLobbyRevision,
                  fetchedRoomRevision: roomRevision,
                  fetchedLobbyRevision: lobbyRevision
              ) else {
            return false
        }
        // Keep a generation fence after reopening. Removing the marker would
        // let an older pre-close response arrive after the explicit join and
        // replace the newly joined membership.
        marker.reopenedMembershipID = candidateMembershipID
        marker.reopenedRoomRevision = roomRevision.map { max($0, 0) }
        marker.reopenedLobbyRevision = lobbyRevision.map { max($0, 0) }
        markersByAccountAndRoom[key] = marker
        return true
    }

    private func key(userID: String?, roomID: String) -> String? {
        let normalizedUserID = userID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedRoomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUserID.isEmpty, !normalizedRoomID.isEmpty else { return nil }
        return "\(normalizedUserID)\u{1F}\(normalizedRoomID)"
    }
}

enum ActiveRoomSnapshotAdmissionPolicy {
    static func fallbackAfterRejectingCandidate(
        previousRoom: GameRoom?,
        previousRoomIsPermitted: Bool
    ) -> GameRoom? {
        previousRoomIsPermitted ? previousRoom : nil
    }
}

enum DismissedRoomExitMode: String, Equatable {
    case leave
    case close

    static func resolve(room: GameRoom, currentUserEmail: String?) -> Self {
        let host = room.hostEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let currentUser = currentUserEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return host?.isEmpty == false && host == currentUser ? .close : .leave
    }
}

enum DismissedRoomExitFailureDisposition: Equatable {
    case retry
    case stop
    case leaveThenStop
}

enum DismissedRoomExitRetryPolicy {
    static let leaveRetryDelaysMilliseconds = [250, 750]
    static let closeRetryDelaysMilliseconds = [1_000, 2_000, 4_000, 8_000]

    static func delayMilliseconds(
        afterFailedAttempt attempt: Int,
        mode: DismissedRoomExitMode
    ) -> Int? {
        guard attempt >= 0 else { return nil }
        switch mode {
        case .leave:
            guard leaveRetryDelaysMilliseconds.indices.contains(attempt) else { return nil }
            return leaveRetryDelaysMilliseconds[attempt]
        case .close:
            return closeRetryDelaysMilliseconds[
                min(attempt, closeRetryDelaysMilliseconds.count - 1)
            ]
        }
    }

    static func failureDisposition(
        for error: Error,
        mode: DismissedRoomExitMode
    ) -> DismissedRoomExitFailureDisposition {
        guard let base44Error = error as? Base44Error,
              let statusCode = base44Error.statusCode else { return .retry }
        if statusCode == 409,
           base44Error.code == "room_exit_membership_conflict" {
            return .stop
        }
        if statusCode == 403, mode == .close { return .leaveThenStop }
        if (400...499).contains(statusCode),
           ![408, 409, 429].contains(statusCode) {
            return .stop
        }
        return .retry
    }

    @MainActor
    static func run(
        mode: DismissedRoomExitMode,
        shouldContinue: () -> Bool,
        operation: () async throws -> Void,
        leaveFallback: (() async -> Void)? = nil,
        sleep: (Int) async throws -> Void
    ) async {
        var failedAttempts = 0
        while shouldContinue(), !Task.isCancelled {
            do {
                try await operation()
                return
            } catch is CancellationError {
                return
            } catch {
                switch failureDisposition(for: error, mode: mode) {
                case .stop:
                    return
                case .leaveThenStop:
                    await leaveFallback?()
                    return
                case .retry:
                    break
                }
                guard let delay = delayMilliseconds(
                    afterFailedAttempt: failedAttempts,
                    mode: mode
                ) else { return }
                failedAttempts += 1
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
            }
        }
    }
}

enum RoomPollPolicy {
    static let backgroundWakeCheckSeconds = 2.0

    static func acceptsSnapshot(
        currentRoomRevision: Int?,
        currentLobbyRevision: Int?,
        fetchedRoomRevision: Int?,
        fetchedLobbyRevision: Int?
    ) -> Bool {
        switch (currentRoomRevision, fetchedRoomRevision) {
        case let (current?, fetched?):
            return max(fetched, 0) >= max(current, 0)
        case (nil, .some):
            // The first room-revisioned response establishes the new revision
            // domain. Its value is unrelated to the legacy lobby counter.
            return true
        case (.some, nil):
            // Never regress a migrated client to an unversioned snapshot.
            return false
        case (nil, nil):
            return max(fetchedLobbyRevision ?? 0, 0) >=
                max(currentLobbyRevision ?? 0, 0)
        }
    }

    static func isSnapshotNewer(
        currentRoomRevision: Int?,
        currentLobbyRevision: Int?,
        fetchedRoomRevision: Int?,
        fetchedLobbyRevision: Int?
    ) -> Bool {
        switch (currentRoomRevision, fetchedRoomRevision) {
        case let (current?, fetched?):
            return max(fetched, 0) > max(current, 0)
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (nil, nil):
            return max(fetchedLobbyRevision ?? 0, 0) >
                max(currentLobbyRevision ?? 0, 0)
        }
    }

    static func disposition(
        monitoredRoomID: String,
        activeRoomID: String?,
        isCancelled: Bool,
        hasActiveOperation: Bool,
        didRoomSyncRevisionChange: Bool = false,
        isLatestRefreshRequest: Bool = true,
        fetchedRoomExists: Bool
    ) -> RoomRefreshDisposition {
        guard !isCancelled, activeRoomID == monitoredRoomID else { return .stop }
        guard !hasActiveOperation,
              !didRoomSyncRevisionChange,
              isLatestRefreshRequest else {
            return .discardAndContinue
        }
        return fetchedRoomExists ? .apply : .close
    }

    static func delaySeconds(
        roomStatus: String?,
        consecutiveFailures: Int,
        isApplicationActive: Bool
    ) -> Double {
        guard isApplicationActive else { return 30 }

        let status = roomStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let baseDelay = ["ready_voting", "roulette", "playing"].contains(status ?? "")
            ? 2.0
            : 4.0
        let cappedFailures = min(max(consecutiveFailures, 0), 2)
        return min(baseDelay * pow(2, Double(cappedFailures)), 8)
    }

    static func failureDisposition(for error: Error) -> RoomRefreshFailureDisposition {
        guard let error = error as? Base44Error,
              error.isRoomAccessRevoked else { return .retry }
        return .close
    }
}

struct LobbyLatestWinsIntent: Equatable {
    let mutationID: UUID
    let roomID: String
    let state: LobbyStatePayload
    let retryCount: Int
}

struct LobbyLatestWinsRequest: Equatable {
    let intent: LobbyLatestWinsIntent
    let expectedRevision: Int
}

struct LobbyLatestWinsState: Equatable {
    private(set) var confirmedRevision = 0
    private(set) var pendingIntent: LobbyLatestWinsIntent?
    private(set) var inFlightRequest: LobbyLatestWinsRequest?
    private(set) var lastServerConfirmedMutationID: UUID?

    var hasOptimisticChanges: Bool {
        pendingIntent != nil || inFlightRequest != nil
    }

    var hasPendingIntent: Bool {
        pendingIntent != nil
    }

    func latestStateMatches(roomID: String, state: LobbyStatePayload) -> Bool {
        if let pendingIntent {
            return pendingIntent.roomID == roomID && pendingIntent.state == state
        }
        if let inFlightRequest {
            return inFlightRequest.intent.roomID == roomID && inFlightRequest.intent.state == state
        }
        return false
    }

    mutating func reset(confirmedRevision: Int) {
        self.confirmedRevision = max(confirmedRevision, 0)
        pendingIntent = nil
        inFlightRequest = nil
        lastServerConfirmedMutationID = nil
    }

    mutating func reconcile(confirmedRevision: Int) {
        self.confirmedRevision = max(self.confirmedRevision, confirmedRevision)
    }

    mutating func enqueue(
        roomID: String,
        state: LobbyStatePayload,
        mutationID: UUID = UUID()
    ) {
        pendingIntent = LobbyLatestWinsIntent(
            mutationID: mutationID,
            roomID: roomID,
            state: state,
            retryCount: 0
        )
    }

    /// Rewrites only the mode of queued full-state mutations after the
    /// dedicated mode endpoint commits. An older request already on the wire
    /// cannot be changed, so a correction is queued behind it without dropping
    /// its duration/deck edits.
    @discardableResult
    mutating func rebaseGameMode(
        roomID: String,
        mode: SpyGameMode,
        fallbackState: LobbyStatePayload? = nil,
        forceCorrection: Bool = false,
        mutationID: UUID = UUID()
    ) -> Bool {
        if let pendingIntent, pendingIntent.roomID == roomID {
            let rebased = pendingIntent.state.replacingGameMode(with: mode)
            guard rebased != pendingIntent.state else { return false }
            self.pendingIntent = LobbyLatestWinsIntent(
                // The server binds one mutation id to one payload fingerprint.
                // A rebased retry is a new mutation, not another attempt of the
                // old payload whose response may have been lost.
                mutationID: mutationID,
                roomID: pendingIntent.roomID,
                state: rebased,
                retryCount: 0
            )
            return true
        }

        if let inFlightRequest,
           inFlightRequest.intent.roomID == roomID,
           inFlightRequest.intent.state.gameMode != mode {
            pendingIntent = LobbyLatestWinsIntent(
                mutationID: mutationID,
                roomID: roomID,
                state: inFlightRequest.intent.state.replacingGameMode(with: mode),
                retryCount: 0
            )
            return true
        }

        guard forceCorrection,
              let fallbackState,
              fallbackState.gameMode != mode else { return false }
        pendingIntent = LobbyLatestWinsIntent(
            mutationID: mutationID,
            roomID: roomID,
            state: fallbackState.replacingGameMode(with: mode),
            retryCount: 0
        )
        return true
    }

    @discardableResult
    mutating func enqueueLatest(
        roomID: String,
        state: LobbyStatePayload,
        confirmedState: LobbyStatePayload?,
        mutationID: UUID = UUID()
    ) -> Bool {
        if let pendingIntent,
           pendingIntent.roomID == roomID,
           pendingIntent.state.equivalentForLobbySync(to: state) {
            return false
        }

        if let inFlightRequest,
           inFlightRequest.intent.roomID == roomID,
           inFlightRequest.intent.state.equivalentForLobbySync(to: state) {
            pendingIntent = nil
            return false
        }

        if inFlightRequest == nil,
           let confirmedState,
           confirmedState.equivalentForLobbySync(to: state) {
            pendingIntent = nil
            return false
        }

        pendingIntent = LobbyLatestWinsIntent(
            mutationID: mutationID,
            roomID: roomID,
            state: state,
            retryCount: 0
        )
        return true
    }

    mutating func beginNext() -> LobbyLatestWinsRequest? {
        guard inFlightRequest == nil, let intent = pendingIntent else { return nil }
        pendingIntent = nil
        let request = LobbyLatestWinsRequest(
            intent: intent,
            expectedRevision: confirmedRevision
        )
        inFlightRequest = request
        return request
    }

    @discardableResult
    mutating func finish(
        _ request: LobbyLatestWinsRequest,
        confirmedRevision: Int
    ) -> Bool {
        guard inFlightRequest == request else { return false }
        inFlightRequest = nil
        guard confirmedRevision > request.expectedRevision else { return false }
        reconcile(confirmedRevision: confirmedRevision)
        lastServerConfirmedMutationID = request.intent.mutationID
        return pendingIntent == nil
    }

    @discardableResult
    mutating func recordRecoveredServerConfirmation(
        _ request: LobbyLatestWinsRequest,
        confirmedRevision: Int
    ) -> Bool {
        guard !hasOptimisticChanges,
              confirmedRevision > request.expectedRevision else { return false }
        reconcile(confirmedRevision: confirmedRevision)
        lastServerConfirmedMutationID = request.intent.mutationID
        return true
    }

    @discardableResult
    mutating func fail(
        _ request: LobbyLatestWinsRequest,
        retry: Bool,
        maximumRetries: Int = 2
    ) -> Bool {
        guard inFlightRequest == request else { return false }
        inFlightRequest = nil
        guard retry,
              request.intent.retryCount < maximumRetries,
              pendingIntent == nil else { return false }
        pendingIntent = LobbyLatestWinsIntent(
            mutationID: request.intent.mutationID,
            roomID: request.intent.roomID,
            state: request.intent.state,
            retryCount: request.intent.retryCount + 1
        )
        return true
    }
}

struct LobbyModeLatestWinsIntent: Equatable {
    let requestID: UUID
    let roomID: String
    let mode: SpyGameMode
    let retryCount: Int
}

struct LobbyModeLatestWinsState: Equatable {
    private(set) var pendingIntent: LobbyModeLatestWinsIntent?
    private(set) var inFlightIntent: LobbyModeLatestWinsIntent?

    var hasOptimisticChanges: Bool {
        pendingIntent != nil || inFlightIntent != nil
    }

    mutating func reset() {
        pendingIntent = nil
        inFlightIntent = nil
    }

    @discardableResult
    mutating func enqueueLatest(
        roomID: String,
        mode: SpyGameMode,
        confirmedMode: SpyGameMode,
        requestID: UUID = UUID()
    ) -> Bool {
        if inFlightIntent?.roomID == roomID,
           inFlightIntent?.mode == mode {
            pendingIntent = nil
            return false
        }
        if inFlightIntent == nil, confirmedMode == mode {
            pendingIntent = nil
            return false
        }
        if pendingIntent?.roomID == roomID, pendingIntent?.mode == mode {
            return false
        }
        pendingIntent = LobbyModeLatestWinsIntent(
            requestID: requestID,
            roomID: roomID,
            mode: mode,
            retryCount: 0
        )
        return true
    }

    mutating func beginNext() -> LobbyModeLatestWinsIntent? {
        guard inFlightIntent == nil, let pendingIntent else { return nil }
        self.pendingIntent = nil
        inFlightIntent = pendingIntent
        return pendingIntent
    }

    @discardableResult
    mutating func finish(_ intent: LobbyModeLatestWinsIntent) -> Bool {
        guard inFlightIntent == intent else { return false }
        inFlightIntent = nil
        return pendingIntent == nil
    }

    @discardableResult
    mutating func fail(
        _ intent: LobbyModeLatestWinsIntent,
        retry: Bool,
        maximumRetries: Int = 2
    ) -> Bool {
        guard inFlightIntent == intent else { return false }
        inFlightIntent = nil
        guard retry,
              intent.retryCount < maximumRetries,
              pendingIntent == nil else { return false }
        pendingIntent = LobbyModeLatestWinsIntent(
            requestID: intent.requestID,
            roomID: intent.roomID,
            mode: intent.mode,
            retryCount: intent.retryCount + 1
        )
        return true
    }
}

private struct LobbyModeProtection: Equatable {
    let roomID: String
    let mode: SpyGameMode
}

extension LobbyStatePayload {
    func replacingGameMode(with mode: SpyGameMode) -> LobbyStatePayload {
        var copy = self
        copy.gameMode = mode
        return copy
    }

    func equivalentForLobbySync(to other: LobbyStatePayload) -> Bool {
        gameMode == other.gameMode &&
            gameDurationSeconds == other.gameDurationSeconds &&
            spyCount == other.spyCount &&
            spiesKnowEachOther == other.spiesKnowEachOther &&
            lobbyWordSource == other.lobbyWordSource &&
            canonicalLobbyText(lobbySourcePackID) == canonicalLobbyText(other.lobbySourcePackID) &&
            canonicalLobbyText(lobbySourceName) == canonicalLobbyText(other.lobbySourceName) &&
            canonicalLobbyText(lobbyTheme) == canonicalLobbyText(other.lobbyTheme) &&
            canonicalLobbyText(lobbyCategory) == canonicalLobbyText(other.lobbyCategory) &&
            lobbyWordCount == other.lobbyWordCount &&
            lobbyWordCountMode == other.lobbyWordCountMode &&
            lobbyWordPool.count == other.lobbyWordPool.count &&
            zip(lobbyWordPool, other.lobbyWordPool).allSatisfy { lhs, rhs in
                canonicalLobbyWordKey(lhs.word) == canonicalLobbyWordKey(rhs.word) &&
                    lhs.enabled == rhs.enabled
            }
    }

    private func canonicalLobbyText(_ value: String?) -> String {
        (value ?? "")
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonicalLobbyWordKey(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

private struct LobbySettingsSyncScope: Equatable {
    let userID: String
    let roomID: String
}

enum LobbySyncRetryPolicy {
    static func isRevisionConflict(_ error: Error) -> Bool {
        guard let base44Error = error as? Base44Error,
              base44Error.statusCode == 409 else { return false }
        return base44Error.code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "lobby_revision_conflict"
    }

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let base44Error = error as? Base44Error {
            if base44Error.retryable { return true }
            guard let statusCode = base44Error.statusCode else { return false }
            return [408, 425, 429].contains(statusCode) || (500...599).contains(statusCode)
        }
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
}

enum AppToastKind: Equatable {
    case success
    case warning
    case error
    case info
}

struct AppToastNotice: Identifiable, Equatable {
    let id: UUID
    let kind: AppToastKind
    let title: String
    let detail: String
    let systemImage: String
    let avatar: String?
}

enum SpyClashCustomRoute: Equatable {
    case notifications(scope: NotificationInboxScope, itemID: String?)
    case community
    case match(roomID: String)
    case join(code: String)
    case resetPassword(token: String)
    case authenticationCallback
    case unsupported

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "spyclash" else { return nil }

        let host = url.host?.lowercased() ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch host {
        case "notifications":
            let scopeQuery = query.first(where: { $0.name == "scope" })
            let scopeValue = scopeQuery?.value?.lowercased()
            let scope = scopeValue.flatMap(NotificationInboxScope.init(rawValue:)) ?? .global
            let itemQuery = query.first(where: { ["item_id", "id"].contains($0.name) })
            let itemID = itemQuery?.value?.nilIfBlank
            return .notifications(scope: scope, itemID: itemID)

        case "community":
            return .community

        case "match":
            guard let roomID = url.pathComponents
                .first(where: { $0 != "/" && !$0.isEmpty })?
                .nilIfBlank else {
                return .unsupported
            }
            return .match(roomID: roomID)

        case "game":
            let roomQuery = query.first(where: { $0.name == "room_id" })
            guard let roomID = roomQuery?.value?.nilIfBlank else {
                return .unsupported
            }
            return .match(roomID: roomID)

        case "join", "room":
            guard let code = SpyLinkParser.roomCodeIfPresent(from: url.absoluteString) else {
                return .unsupported
            }
            return .join(code: code)

        case "auth":
            return .authenticationCallback

        default:
            if let token = ResetPasswordLinkParser.tokenIfPresent(from: url.absoluteString) {
                return .resetPassword(token: token)
            }
            // Never feed an unknown custom-scheme host into SpyLinkParser:
            // legacy fallback parsing can otherwise mistake hosts such as
            // `rooms` for a valid room code.
            return .unsupported
        }
    }
}

@MainActor
@Observable
final class AppState: NSObject {
    let client: Base44Client
    let notificationInbox: NotificationInboxStore
    let gameRoomRealtime: GameRoomRealtimeService
    let radarNearby: RadarNearbyService
    var user: SpyUser? {
        didSet {
            let previousUserID = oldValue?.id
            let accountChanged = previousUserID != user?.id
            if accountChanged {
                onboardingSyncTask?.cancel()
                onboardingSyncTask = nil
                onboardingSyncUserID = nil
                postAuthActiveRoomRestoreTask?.cancel()
                postAuthActiveRoomRestoreTask = nil
                postAuthActiveRoomRestoreUserID = nil
                finishedMatchProfileRefreshTasks.values.forEach { $0.cancel() }
                finishedMatchProfileRefreshTasks.removeAll()
                finishedMatchProfileRefreshPolicy = FinishedMatchProfileRefreshPolicy()
            }
            if let user {
                OnboardingProgressStore.reconcileRemoteState(for: user)
            }
            reconcileRadarInvitePolicy(for: user, accountChanged: accountChanged)
            radarNearby.setActiveRoom(activeRoom)
            // `user` can be reassigned after a same-account token rotation.
            // Reconcile before the account-change early return so the socket
            // never keeps authenticating with the previous token.
            reconcileGameRoomRealtimeSubscription()
            reconcileLobbySettingsSyncScope(from: activeRoom, to: activeRoom)
            guard accountChanged else { return }
            PushNotificationCoordinator.shared.accountDidChange(
                isSignedIn: user != nil && client.hasSessionToken
            )
            notificationInbox.bindAccount(user?.id)
            synchronizeLiveActivitiesForAccountChange(previousUserID: previousUserID)
            queuePendingOnboardingSyncIfNeeded()
        }
    }
    var isRestoring = true
    var isBusy = false
    private(set) var isApplicationActive = false
    private(set) var isAppleAuthorizationPending = false
    var authPhase: AuthPhase = .email
    var authError: String? {
        didSet {
            guard authError != oldValue, let authError else { return }
            showToast(authError, kind: .error)
        }
    }
    var authNotice: String? {
        didSet {
            guard authNotice != oldValue, let authNotice else { return }
            showToast(authNotice, kind: .success)
        }
    }
    var accountDeletionManualRevocationNotice: String?
    var appleAuthStage: AppleAuthStage?
    var standardAuthCinematicStage: StandardAuthCinematicStage?
    var authHomeRevealPhase: AuthHomeRevealPhase = .idle
    var onboardingLaunchMessage: String?
    private(set) var isFinishingOnboarding = false
    private(set) var radarInvitePolicySyncState: RadarInvitePolicySyncState = .localOnly
    private(set) var radarActivationRevision = 0
    var selectedTab: AppTab = .home {
        didSet {
            if selectedTab != .home {
                isHomeLandingPresentationRequested = false
            }
        }
    }
    var shellRoute: AppShellRoute = .main
    var homeRootRequestID = 0
    private(set) var isHomeLandingPresentationRequested = false
    var notificationFocusItemID: String?
    var notificationFocusRequestID = 0
    var localSetupRequestID = 0
    private(set) var roomFriendsNavigationRequest: RoomFriendsNavigationRequest?
    private(set) var wordPacksRevision = 0
    var activeRoom: GameRoom? {
        didSet {
            #if DEBUG
            let shouldHonorDismissedRoom = !isUIPreviewMode
            #else
            let shouldHonorDismissedRoom = true
            #endif
            if shouldHonorDismissedRoom,
               let candidateRoom = activeRoom,
               !isActiveRoomSnapshotPermitted(candidateRoom) {
                let previousRoomIsPermitted = oldValue.map {
                    isActiveRoomSnapshotPermitted($0)
                } ?? false
                // Reject only the stale candidate. After an explicit rejoin,
                // a delayed response from the old membership must not evict
                // the valid new session that is already active.
                activeRoom = ActiveRoomSnapshotAdmissionPolicy
                    .fallbackAfterRejectingCandidate(
                        previousRoom: oldValue,
                        previousRoomIsPermitted: previousRoomIsPermitted
                    )
            }
            if activeRoom == nil {
                isHomeLandingPresentationRequested = false
            }
            if let request = roomFriendsNavigationRequest,
               !RoomFriendsNavigationPolicy.shouldRetain(
                   request,
                   activeRoomID: activeRoom?.id,
                   activeRoomStatus: activeRoom?.normalizedStatus
               ) {
                roomFriendsNavigationRequest = nil
            }
            reconcileLobbySettingsSyncScope(from: oldValue, to: activeRoom)
            if oldValue?.id != activeRoom?.id {
                roomConnectionState = .synced
                reconcileGameRoomRealtimeSubscription()
            } else {
                lobbySettingsSyncState.reconcile(
                    confirmedRevision: activeRoom?.lobbyRevision ?? 0
                )
            }
            persistActiveRoomReference(activeRoom)
            radarNearby.setActiveRoom(activeRoom)
            handleRoomPresenceChange(from: oldValue, to: activeRoom)
            synchronizeMatchLiveActivity(previousRoom: oldValue, room: activeRoom)
            scheduleFinishedMatchProfileRefreshIfNeeded(for: activeRoom)
        }
    }
    var isShellChromeSuppressed = false
    private(set) var roomSyncOperation: RoomSyncOperation?
    private(set) var roomSyncRevision = 0
    private(set) var roomConnectionState: RoomConnectionState = .synced
    private(set) var lobbySettingsSyncState = LobbyLatestWinsState()
    private(set) var lobbyModeSyncState = LobbyModeLatestWinsState()
    private(set) var lobbySettingsSyncFailure: String?
    private(set) var lobbySettingsSyncRoomID: String?
    private(set) var lobbySettingsRollbackEpoch = 0
    var presentedSheet: AppSheet?
    var roomQRTarget: RoomQRTarget = .web
    var language: AppLanguage = .stored {
        didSet {
            PushNotificationCoordinator.shared.updatePreferredLocale(language.rawValue)
            guard language != oldValue else { return }
            synchronizeMatchLiveActivity(previousRoom: nil, room: activeRoom)
        }
    }
    var pendingJoinCode: String?
    var deepLinkStatus: String? {
        didSet {
            guard deepLinkStatus != oldValue, let deepLinkStatus else { return }
            showToast(deepLinkStatus, kind: Self.deepLinkToastKind(deepLinkStatus))
        }
    }
    var isJoiningDeepLink = false
    private(set) var toastNotices: [AppToastNotice] = []
#if DEBUG
    var isUIPreviewMode = false
#endif

    private var webAuthSession: ASWebAuthenticationSession?
    private let appleSignInCoordinator = AppleSignInCoordinator()
    @ObservationIgnored private var standardAuthTimelineTask: Task<Void, Never>?
    @ObservationIgnored private var standardAuthRunID: UUID?
    @ObservationIgnored private var onboardingSyncTask: Task<Void, Never>?
    @ObservationIgnored private var onboardingSyncUserID: String?
    @ObservationIgnored private var postAuthActiveRoomRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var postAuthActiveRoomRestoreUserID: String?
    @ObservationIgnored private var authHomeRevealAnimationID: UUID?
    @ObservationIgnored private var authHomeRevealRestartTask: Task<Void, Never>?
    @ObservationIgnored private var authHomeRevealRestartID: UUID?
    @ObservationIgnored private var activationResumeTask: Task<Void, Never>?
    @ObservationIgnored private var activeRoomActivationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var roomRefreshRequestRevision = 0
    @ObservationIgnored private var closedRoomRevisionFence = ClosedRoomRevisionFence()
    @ObservationIgnored private var lobbySettingsSyncWorker: Task<Void, Never>?
    @ObservationIgnored private var lobbySettingsSyncGeneration = UUID()
    @ObservationIgnored private var lobbySettingsSyncRunID: UUID?
    @ObservationIgnored private var lobbySettingsSyncScope: LobbySettingsSyncScope?
    @ObservationIgnored private var lobbySettingsSyncUserID: String?
    @ObservationIgnored private var lobbyModeSyncWorker: Task<Void, Never>?
    @ObservationIgnored private var lobbyModeSyncRunID: UUID?
    @ObservationIgnored private var lobbyModeProtection: LobbyModeProtection?
    @ObservationIgnored private var gameRoomRealtimeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingGameRoomRealtimeRevision = 0
    @ObservationIgnored private var gameRoomRealtimeCatchUpRequested = false
    @ObservationIgnored private var gameRoomRealtimeGeneration = UUID()
    @ObservationIgnored private var finishedMatchProfileRefreshPolicy =
        FinishedMatchProfileRefreshPolicy()
    @ObservationIgnored private var finishedMatchProfileRefreshTasks:
        [FinishedMatchProfileRefreshRequest: Task<Void, Never>] = [:]
    @ObservationIgnored private var radarInvitePolicySyncTask: Task<Void, Never>?
    @ObservationIgnored private var radarInvitePolicySyncRunID: UUID?
    private var pendingRadarInvitePolicy: RadarInvitePolicy?
    private var radarInvitePolicySyncOwnerUserID: String?
    @ObservationIgnored private var liveActivitySyncTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityPushTokenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var liveActivityStateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var liveActivityPushToStartTokenTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityLifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMatchRoomID: String?
    @ObservationIgnored private var pendingNotificationRouteGeneration: UInt64 = 0
    @ObservationIgnored private var deferredActiveGameRetryGeneration: UInt64?
    @ObservationIgnored private var isConsumingPendingRoutes = false
    @ObservationIgnored private var pendingNotificationRoute: SpyNotificationRoute? {
        didSet {
            pendingNotificationRouteGeneration &+= 1
            deferredActiveGameRetryGeneration = nil
        }
    }
    private(set) var authPresentationRequestID = 0
    @ObservationIgnored private var isOpeningPendingMatch = false
    @ObservationIgnored private var dismissedRoomExitAttemptGeneration: UUID?
    @ObservationIgnored private var dismissedRoomExitTask: Task<Void, Never>?
    private static let activeRoomIDStorageKey = "spyclash.activeRoomID"
    private static let dismissedRoomIDStorageKey = "spyclash.dismissedRoomID"
    private static let dismissedRoomOwnerStorageKey = "spyclash.dismissedRoomOwnerID"
    private static let dismissedRoomExitModeStorageKey = "spyclash.dismissedRoomExitMode"
    private static let dismissedRoomExitRevisionStorageKey = "spyclash.dismissedRoomExitRevision"
    private static let dismissedRoomExitMembershipStorageKey = "spyclash.dismissedRoomExitMembership"
    private static let dismissedRoomCodeStorageKey = "spyclash.dismissedRoomCode"

    override init() {
        let client = Base44Client()
        let radarNearby = RadarNearbyService()
        self.client = client
        self.notificationInbox = NotificationInboxStore(client: client)
        self.gameRoomRealtime = GameRoomRealtimeService()
        self.radarNearby = radarNearby
        super.init()

        gameRoomRealtime.onSignal = { [weak self] signal, generation in
            self?.handleGameRoomRealtimeSignal(signal, serviceGeneration: generation)
        }
        gameRoomRealtime.onCatchUp = { [weak self] in
            self?.handleGameRoomRealtimeCatchUp()
        }
        radarNearby.onAutomaticInvitation = { [weak self] invitation in
            self?.handleAutomaticRadarInvitation(invitation)
        }
        PushNotificationCoordinator.shared.configure(
            client: client,
            routeHandler: { [weak self] route in
                self?.handleNotificationRoute(route)
            },
            inboxInvalidationHandler: { [weak self] in
                self?.refreshNotificationInboxAfterPush()
            }
        )
    }

    var shouldUsePreviewData: Bool {
#if DEBUG
        isUIPreviewMode
#else
        false
#endif
    }

    @discardableResult
    func beginRoomSync(_ operation: RoomSyncOperation) -> Bool {
        guard roomSyncOperation == nil else { return false }
        roomSyncOperation = operation
        roomSyncRevision &+= 1
        return true
    }

    func endRoomSync(_ operation: RoomSyncOperation) {
        guard roomSyncOperation == operation else { return }
        roomSyncOperation = nil
        roomSyncRevision &+= 1
        if gameRoomRealtimeCatchUpRequested ||
            pendingGameRoomRealtimeRevision >
            (activeRoom?.roomRevision ?? activeRoom?.lobbyRevision ?? 0) {
            scheduleGameRoomRealtimeRefresh()
        }
    }

    func leaveRoomImmediately(_ room: GameRoom) {
        cancelDismissedRoomExitAttempt()
        // Local-first leave/close is terminal for the membership generation
        // visible on this device. Its exact server revision is not known yet,
        // so require an explicit rejoin with a different membership before any
        // same-room response can become active again.
        closedRoomRevisionFence.record(
            userID: user?.id,
            roomID: room.id,
            roomRevision: nil,
            lobbyRevision: nil,
            membershipID: room.viewerMembershipID
        )
        if let ownerID = user?.id {
            UserDefaults.standard.set(room.id, forKey: Self.dismissedRoomIDStorageKey)
            UserDefaults.standard.set(ownerID, forKey: Self.dismissedRoomOwnerStorageKey)
            UserDefaults.standard.set(
                room.code.uppercased(),
                forKey: Self.dismissedRoomCodeStorageKey
            )
            let exitMode = DismissedRoomExitMode.resolve(
                room: room,
                currentUserEmail: user?.email
            )
            UserDefaults.standard.set(
                exitMode.rawValue,
                forKey: Self.dismissedRoomExitModeStorageKey
            )
            UserDefaults.standard.set(
                RoomExitRevisionPolicy.expectedRevision(
                    roomRevision: room.roomRevision
                ),
                forKey: Self.dismissedRoomExitRevisionStorageKey
            )
            UserDefaults.standard.set(
                room.viewerMembershipID,
                forKey: Self.dismissedRoomExitMembershipStorageKey
            )
        }

        roomSyncOperation = nil
        roomSyncRevision &+= 1
        _ = nextRoomRefreshRequestRevision()
        activeRoom = nil
        selectedTab = .home

#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        retryDismissedRoomExitIfNeeded()
    }

    func allowRoomActivation(_ roomID: String) {
        guard isDismissedRoom(roomID) else { return }
        UserDefaults.standard.removeObject(forKey: Self.dismissedRoomIDStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.dismissedRoomOwnerStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.dismissedRoomExitModeStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.dismissedRoomExitRevisionStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.dismissedRoomExitMembershipStorageKey)
        UserDefaults.standard.removeObject(forKey: Self.dismissedRoomCodeStorageKey)
        cancelDismissedRoomExitAttempt()
    }

    func confirmExplicitRoomActivation(_ room: GameRoom) throws {
        guard closedRoomRevisionFence.authorizeExplicitRejoin(
            userID: user?.id,
            roomID: room.id,
            roomRevision: room.roomRevision,
            lobbyRevision: room.lobbyRevision ?? 0,
            membershipID: room.viewerMembershipID
        ) else {
            throw Base44Error(
                message: "The room rejoin generation could not be confirmed. Try again.",
                statusCode: 409,
                code: "room_rejoin_generation_unconfirmed",
                retryable: true
            )
        }
        allowRoomActivation(room.id)
    }

    func joinRoomSnapshotForExplicitActivation(
        code rawCode: String,
        user: SpyUser
    ) async throws -> GameRoom {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let dismissedCode = UserDefaults.standard
            .string(forKey: Self.dismissedRoomCodeStorageKey)?
            .uppercased()
        let expectedMembershipID = dismissedCode == code
            ? UserDefaults.standard.string(
                forKey: Self.dismissedRoomExitMembershipStorageKey
            )
            : nil
        return try await client.join(
            code: code,
            user: user,
            expectedMembershipID: expectedMembershipID
        )
    }

    private func cancelDismissedRoomExitAttempt() {
        dismissedRoomExitTask?.cancel()
        dismissedRoomExitTask = nil
        dismissedRoomExitAttemptGeneration = nil
    }

    private func isDismissedRoom(_ roomID: String) -> Bool {
        guard let ownerID = user?.id,
              UserDefaults.standard.string(forKey: Self.dismissedRoomOwnerStorageKey) == ownerID else {
            return false
        }
        return UserDefaults.standard.string(forKey: Self.dismissedRoomIDStorageKey) == roomID
    }

    private func isActiveRoomSnapshotPermitted(_ room: GameRoom) -> Bool {
        !isDismissedRoom(room.id) &&
            closedRoomRevisionFence.permits(
                userID: user?.id,
                roomID: room.id,
                roomRevision: room.roomRevision,
                lobbyRevision: room.lobbyRevision ?? 0,
                membershipID: room.viewerMembershipID
            )
    }

    private func retryDismissedRoomExitIfNeeded() {
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        guard let roomID = UserDefaults.standard
            .string(forKey: Self.dismissedRoomIDStorageKey),
              isDismissedRoom(roomID),
              dismissedRoomExitAttemptGeneration == nil else { return }
        let exitMode = UserDefaults.standard
            .string(forKey: Self.dismissedRoomExitModeStorageKey)
            .flatMap { DismissedRoomExitMode(rawValue: $0) } ?? .leave
        let expectedRevision = UserDefaults.standard
            .object(forKey: Self.dismissedRoomExitRevisionStorageKey)
            .flatMap { ($0 as? NSNumber)?.intValue }
        let expectedMembershipID = UserDefaults.standard
            .string(forKey: Self.dismissedRoomExitMembershipStorageKey)
        let attemptGeneration = UUID()
        dismissedRoomExitAttemptGeneration = attemptGeneration
        dismissedRoomExitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await DismissedRoomExitRetryPolicy.run(
                mode: exitMode,
                shouldContinue: {
                    self.dismissedRoomExitAttemptGeneration == attemptGeneration &&
                        self.isDismissedRoom(roomID)
                },
                operation: {
                    switch exitMode {
                    case .leave:
                        try await self.client.leaveRoom(
                            roomID: roomID,
                            expectedRevision: expectedRevision,
                            expectedMembershipID: expectedMembershipID
                        )
                    case .close:
                        try await self.client.closeRoom(
                            roomID: roomID,
                            expectedRevision: expectedRevision,
                            expectedMembershipID: expectedMembershipID
                        )
                    }
                },
                leaveFallback: exitMode == .close ? {
                    // Authority can legitimately move before this local-first
                    // cleanup reaches the server. Stop close retries and make
                    // one bounded membership cleanup as the former host.
                    try? await self.client.leaveRoom(
                        roomID: roomID,
                        expectedRevision: expectedRevision,
                        expectedMembershipID: expectedMembershipID
                    )
                } : nil,
                sleep: { delay in
                    try await Task.sleep(for: .milliseconds(delay))
                }
            )
            if self.dismissedRoomExitAttemptGeneration == attemptGeneration {
                self.dismissedRoomExitAttemptGeneration = nil
                self.dismissedRoomExitTask = nil
            }
        }
    }

    func enqueueLobbySettings(
        roomID: String,
        state: LobbyStatePayload,
        confirmedState: LobbyStatePayload?,
        debounce: Duration
    ) {
        guard let scope = lobbySettingsSyncScope,
              scope.roomID == roomID,
              scope.userID == user?.id,
              let room = activeRoom,
              room.id == roomID,
              room.normalizedStatus == "waiting",
              room.hostEmail == user?.email else { return }

        // Until a dedicated mode request is acknowledged, unrelated full-state
        // edits carry the last authoritative mode, not the optimistic button
        // value. The queue is rebased immediately after the mode commit.
        let queuedState = lobbyModeSyncState.hasOptimisticChanges
            ? state.replacingGameMode(with: room.gameModeValue)
            : state
        let queuedConfirmedState = confirmedState.map {
            lobbyModeSyncState.hasOptimisticChanges
                ? $0.replacingGameMode(with: room.gameModeValue)
                : $0
        }
        lobbySettingsSyncState.reconcile(
            confirmedRevision: room.lobbyRevision ?? 0
        )
        _ = lobbySettingsSyncState.enqueueLatest(
            roomID: roomID,
            state: queuedState,
            confirmedState: queuedConfirmedState
        )
        lobbySettingsSyncFailure = nil
        if lobbySettingsSyncState.hasPendingIntent {
            startLobbySettingsWorker(debounce: debounce)
        }
    }

    func enqueueLobbyGameMode(roomID: String, mode: SpyGameMode) {
        guard let scope = lobbySettingsSyncScope,
              scope.roomID == roomID,
              scope.userID == user?.id,
              let room = activeRoom,
              room.id == roomID,
              room.normalizedStatus == "waiting",
              room.hostEmail == user?.email else { return }

        _ = lobbyModeSyncState.enqueueLatest(
            roomID: roomID,
            mode: mode,
            confirmedMode: room.gameModeValue
        )
        lobbySettingsSyncFailure = nil
        if lobbyModeSyncState.pendingIntent != nil {
            startLobbyModeWorker()
        }
    }

    var hasOptimisticLobbySettingsChanges: Bool {
        lobbySettingsSyncState.hasOptimisticChanges ||
            lobbyModeSyncState.hasOptimisticChanges
    }

    func hasUnconfirmedLobbySettings(for roomID: String) -> Bool {
        lobbySettingsSyncRoomID == roomID &&
            hasOptimisticLobbySettingsChanges
    }

    func confirmedLobbyRoom(
        roomID: String,
        allowedStatuses: Set<String> = ["waiting", "ready_voting"]
    ) async throws -> GameRoom {
        for _ in 0..<8 {
            guard activeRoom?.id == roomID,
                  activeRoom?.hostEmail == user?.email else {
                throw Base44Error(message: "Lobby room changed.", statusCode: 409)
            }
            if let worker = lobbySettingsSyncWorker {
                await worker.value
                continue
            }
            if let worker = lobbyModeSyncWorker {
                await worker.value
                continue
            }
            if lobbySettingsSyncState.hasPendingIntent {
                startLobbySettingsWorker(debounce: .zero)
                continue
            }
            if lobbyModeSyncState.pendingIntent != nil {
                startLobbyModeWorker()
                continue
            }
            break
        }

        if let lobbySettingsSyncFailure {
            throw Base44Error(message: lobbySettingsSyncFailure)
        }
        guard let room = activeRoom,
              room.id == roomID,
              room.hostEmail == user?.email,
              allowedStatuses.contains(room.normalizedStatus),
              !hasOptimisticLobbySettingsChanges else {
            throw Base44Error(
                message: "Lobby settings are still synchronizing.",
                statusCode: 409
            )
        }
        return room
    }

    func authoritativeLobbyStatePayload(from room: GameRoom) -> LobbyStatePayload? {
        guard (room.lobbySchemaVersion ?? 0) >= 1 || (room.lobbyRevision ?? 0) > 0 else {
            return nil
        }
        return LobbyStatePayload(
            gameMode: room.gameModeValue,
            gameDurationSeconds: max(60, min(room.gameDurationSeconds ?? 900, 900)),
            spyCount: room.lobbySpyCountValue,
            spiesKnowEachOther: room.spiesKnowEachOther ?? false,
            lobbyWordSource: LobbyWordSource(rawValue: room.lobbyWordSource ?? "none") ?? .none,
            lobbySourcePackID: room.lobbySourcePackID?.nilIfBlank,
            lobbySourceName: room.lobbySourceName?.nilIfBlank,
            lobbyTheme: room.lobbyTheme?.nilIfBlank,
            lobbyCategory: room.lobbyCategory?.nilIfBlank,
            lobbyWordCount: max(0, min(room.lobbyWordCount ?? 0, 200)),
            lobbyWordCountMode: LobbyWordCountMode(
                rawValue: room.lobbyWordCountMode ?? "recommended"
            ) ?? .recommended,
            lobbyWordPool: (room.lobbyWordPool ?? []).map {
                LobbyWordPoolEntry(
                    id: $0.serverID,
                    word: $0.word,
                    enabled: $0.enabled
                )
            }
        )
    }

    private func reconcileLobbySettingsSyncScope(
        from previousRoom: GameRoom?,
        to room: GameRoom?
    ) {
        let desiredScope: LobbySettingsSyncScope?
        if let user,
           let room,
           room.normalizedStatus == "waiting",
           room.hostEmail == user.email {
            desiredScope = LobbySettingsSyncScope(
                userID: user.id,
                roomID: room.id
            )
        } else {
            desiredScope = nil
        }

        let contextChanged = lobbySettingsSyncUserID != user?.id ||
            lobbySettingsSyncRoomID != room?.id
        guard contextChanged || desiredScope != lobbySettingsSyncScope else {
            lobbySettingsSyncState.reconcile(
                confirmedRevision: room?.lobbyRevision ?? 0
            )
            return
        }

        lobbySettingsSyncGeneration = UUID()
        lobbySettingsSyncWorker?.cancel()
        lobbySettingsSyncWorker = nil
        lobbySettingsSyncRunID = nil
        lobbyModeSyncWorker?.cancel()
        lobbyModeSyncWorker = nil
        lobbyModeSyncRunID = nil
        lobbyModeProtection = nil
        lobbySettingsSyncScope = desiredScope
        lobbySettingsSyncUserID = user?.id
        lobbySettingsSyncRoomID = room?.id
        lobbySettingsSyncState.reset(
            confirmedRevision: room?.lobbyRevision ?? 0
        )
        lobbyModeSyncState.reset()
        lobbySettingsSyncFailure = nil
        lobbySettingsRollbackEpoch &+= 1
    }

    private func startLobbyModeWorker() {
        guard lobbyModeSyncWorker == nil,
              lobbyModeSyncState.pendingIntent != nil,
              let scope = lobbySettingsSyncScope else { return }

        let generation = lobbySettingsSyncGeneration
        let runID = UUID()
        lobbyModeSyncRunID = runID
        lobbyModeSyncWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLobbyModeWorker(
                scope: scope,
                generation: generation,
                runID: runID
            )
        }
    }

    private func runLobbyModeWorker(
        scope: LobbySettingsSyncScope,
        generation: UUID,
        runID: UUID
    ) async {
        defer {
            finishLobbyModeWorker(
                scope: scope,
                generation: generation,
                runID: runID
            )
        }

        while !Task.isCancelled,
              lobbyModeWorkerIsCurrent(
                  scope: scope,
                  generation: generation,
                  runID: runID
              ),
              let intent = lobbyModeSyncState.beginNext() {
            guard let room = activeRoom,
                  room.id == scope.roomID,
                  room.normalizedStatus == "waiting",
                  room.hostEmail == user?.email else {
                _ = lobbyModeSyncState.fail(intent, retry: false)
                lobbySettingsRollbackEpoch &+= 1
                return
            }

#if DEBUG
            if shouldUsePreviewData {
                var previewRoom = room
                previewRoom.gameMode = intent.mode.rawValue
                previewRoom.roomRevision = (room.roomRevision ?? 0) + 1
                _ = lobbyModeSyncState.finish(intent)
                recordCommittedLobbyMode(
                    intent.mode,
                    room: previewRoom,
                    scope: scope
                )
                continue
            }
#endif

            do {
                let updatedRoom = try await client.updateGameMode(
                    room: room,
                    mode: intent.mode
                )
                guard lobbyModeWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ),
                      updatedRoom.id == scope.roomID,
                      updatedRoom.normalizedStatus == "waiting",
                      updatedRoom.gameModeValue == intent.mode,
                      RoomPollPolicy.acceptsSnapshot(
                          currentRoomRevision: room.roomRevision,
                          currentLobbyRevision: room.lobbyRevision,
                          fetchedRoomRevision: updatedRoom.roomRevision,
                          fetchedLobbyRevision: updatedRoom.lobbyRevision
                      ) else {
                    throw Base44Error(
                        message: "Game mode update was not confirmed.",
                        statusCode: 502,
                        retryable: true
                    )
                }

                _ = lobbyModeSyncState.finish(intent)
                recordCommittedLobbyMode(
                    intent.mode,
                    room: updatedRoom,
                    scope: scope
                )
                lobbySettingsSyncFailure = nil
            } catch is CancellationError {
                _ = lobbyModeSyncState.fail(intent, retry: false)
                return
            } catch {
                guard lobbyModeWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ) else { return }

                let retryable = LobbySyncRetryPolicy.isRetryable(error) ||
                    LobbySyncRetryPolicy.isRevisionConflict(error)
                let willRetry = lobbyModeSyncState.fail(intent, retry: retryable)
                if willRetry {
                    do {
                        try await Task.sleep(
                            for: intent.retryCount == 0
                                ? .milliseconds(120)
                                : .milliseconds(300)
                        )
                    } catch {
                        return
                    }
                    continue
                }

                if let projected = activeRoom,
                   projected.id == scope.roomID,
                   projected.normalizedStatus == "waiting",
                   projected.gameModeValue == intent.mode,
                   RoomPollPolicy.isSnapshotNewer(
                       currentRoomRevision: room.roomRevision,
                       currentLobbyRevision: room.lobbyRevision,
                       fetchedRoomRevision: projected.roomRevision,
                       fetchedLobbyRevision: projected.lobbyRevision
                   ) {
                    // The personal realtime projection is itself an
                    // authoritative post-commit receipt even if the initiator's
                    // HTTP response was lost.
                    recordCommittedLobbyMode(
                        intent.mode,
                        room: projected,
                        scope: scope
                    )
                    lobbySettingsSyncFailure = nil
                    continue
                }

                if let refreshed = try? await client.refreshRoom(id: scope.roomID),
                   lobbyModeWorkerIsCurrent(
                       scope: scope,
                       generation: generation,
                       runID: runID
                   ),
                   refreshed.normalizedStatus == "waiting",
                   refreshed.gameModeValue == intent.mode {
                    recordCommittedLobbyMode(
                        intent.mode,
                        room: refreshed,
                        scope: scope
                    )
                    lobbySettingsSyncFailure = nil
                    continue
                }

                if lobbyModeSyncState.pendingIntent == nil {
                    if !lobbySettingsSyncState.hasOptimisticChanges {
                        lobbyModeProtection = nil
                    }
                    lobbySettingsSyncFailure = error.localizedDescription
                    lobbySettingsRollbackEpoch &+= 1
                    if let refreshed = try? await client.refreshRoom(id: scope.roomID),
                       lobbyModeWorkerIsCurrent(
                           scope: scope,
                           generation: generation,
                           runID: runID
                       ),
                       RoomPollPolicy.acceptsSnapshot(
                           currentRoomRevision: activeRoom?.roomRevision,
                           currentLobbyRevision: activeRoom?.lobbyRevision,
                           fetchedRoomRevision: refreshed.roomRevision,
                           fetchedLobbyRevision: refreshed.lobbyRevision
                       ) {
                        if lobbyModeProtection?.roomID == scope.roomID {
                            adoptLobbyMutationRoom(refreshed)
                        } else {
                            activeRoom = refreshed
                        }
                    }
                }
            }
        }
    }

    private func recordCommittedLobbyMode(
        _ mode: SpyGameMode,
        room committedRoom: GameRoom,
        scope: LobbySettingsSyncScope
    ) {
        guard activeRoom?.id == scope.roomID else { return }
        let activeBeforeCommit = activeRoom
        let fullStateCommittedAfterMode = RoomPollPolicy.isSnapshotNewer(
            currentRoomRevision: committedRoom.roomRevision,
            currentLobbyRevision: committedRoom.lobbyRevision,
            fetchedRoomRevision: activeBeforeCommit?.roomRevision,
            fetchedLobbyRevision: activeBeforeCommit?.lobbyRevision
        ) &&
            activeBeforeCommit?.gameModeValue != mode
        let fallbackState = activeBeforeCommit.flatMap {
            authoritativeLobbyStatePayload(from: $0)
        }

        _ = lobbySettingsSyncState.rebaseGameMode(
            roomID: scope.roomID,
            mode: mode,
            fallbackState: fallbackState,
            forceCorrection: fullStateCommittedAfterMode
        )
        lobbyModeProtection = lobbySettingsSyncState.hasOptimisticChanges
            ? LobbyModeProtection(roomID: scope.roomID, mode: mode)
            : nil
        adoptLobbyMutationRoom(committedRoom)

        if lobbySettingsSyncState.hasPendingIntent {
            startLobbySettingsWorker(debounce: .zero)
        }
    }

    private func adoptLobbyMutationRoom(_ incomingRoom: GameRoom) {
        guard let currentRoom = activeRoom,
              incomingRoom.id == currentRoom.id else { return }
        let protection = lobbyModeProtection.flatMap {
            $0.roomID == incomingRoom.id ? $0 : nil
        }

        if RoomPollPolicy.acceptsSnapshot(
            currentRoomRevision: currentRoom.roomRevision,
            currentLobbyRevision: currentRoom.lobbyRevision,
            fetchedRoomRevision: incomingRoom.roomRevision,
            fetchedLobbyRevision: incomingRoom.lobbyRevision
        ) {
            let authoritativeIncomingMode = incomingRoom.gameModeValue
            var adopted = incomingRoom
            if let protection {
                adopted.gameMode = protection.mode.rawValue
            }
            activeRoom = adopted
            if authoritativeIncomingMode == protection?.mode,
               !lobbySettingsSyncState.hasOptimisticChanges {
                lobbyModeProtection = nil
            }
        } else if let protection, currentRoom.gameModeValue != protection.mode {
            var protectedCurrent = currentRoom
            protectedCurrent.gameMode = protection.mode.rawValue
            activeRoom = protectedCurrent
        }
    }

    private func finishLobbyModeWorker(
        scope: LobbySettingsSyncScope,
        generation: UUID,
        runID: UUID
    ) {
        guard lobbySettingsSyncScope == scope,
              lobbySettingsSyncGeneration == generation,
              lobbyModeSyncRunID == runID else { return }
        lobbyModeSyncWorker = nil
        lobbyModeSyncRunID = nil
        if lobbyModeSyncState.pendingIntent != nil {
            startLobbyModeWorker()
        }
    }

    private func lobbyModeWorkerIsCurrent(
        scope: LobbySettingsSyncScope,
        generation: UUID,
        runID: UUID
    ) -> Bool {
        lobbySettingsSyncScope == scope &&
            lobbySettingsSyncGeneration == generation &&
            lobbyModeSyncRunID == runID &&
            user?.id == scope.userID &&
            activeRoom?.id == scope.roomID &&
            activeRoom?.normalizedStatus == "waiting" &&
            activeRoom?.hostEmail == user?.email
    }

    private func startLobbySettingsWorker(debounce: Duration) {
        guard lobbySettingsSyncWorker == nil,
              lobbySettingsSyncState.hasPendingIntent,
              let scope = lobbySettingsSyncScope else { return }

        let generation = lobbySettingsSyncGeneration
        let runID = UUID()
        lobbySettingsSyncRunID = runID
        lobbySettingsSyncWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounce)
            } catch {
                self.finishLobbySettingsWorker(
                    scope: scope,
                    generation: generation,
                    runID: runID
                )
                return
            }
            await self.runLobbySettingsWorker(
                scope: scope,
                generation: generation,
                runID: runID
            )
        }
    }

    private func runLobbySettingsWorker(
        scope: LobbySettingsSyncScope,
        generation: UUID,
        runID: UUID
    ) async {
        defer {
            finishLobbySettingsWorker(
                scope: scope,
                generation: generation,
                runID: runID
            )
        }

        while !Task.isCancelled,
              lobbySettingsWorkerIsCurrent(
                  scope: scope,
                  generation: generation,
                  runID: runID
              ),
              let request = lobbySettingsSyncState.beginNext() {
            guard let room = activeRoom,
                  room.id == scope.roomID,
                  room.normalizedStatus == "waiting",
                  room.hostEmail == user?.email else {
                _ = lobbySettingsSyncState.fail(request, retry: false)
                lobbySettingsRollbackEpoch &+= 1
                return
            }

#if DEBUG
            if shouldUsePreviewData {
                var previewRoom = room
                applyLobbyPayload(
                    request.intent.state,
                    to: &previewRoom,
                    revision: request.expectedRevision + 1
                )
                _ = lobbySettingsSyncState.finish(
                    request,
                    confirmedRevision: request.expectedRevision + 1
                )
                guard lobbySettingsWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ) else { return }
                adoptLobbyMutationRoom(previewRoom)
                lobbySettingsSyncFailure = nil
                continue
            }
#endif

            do {
                let updatedRoom = try await client.updateLobbyState(
                    room: room,
                    mutationID: request.intent.mutationID.uuidString.lowercased(),
                    expectedRevision: request.expectedRevision,
                    state: request.intent.state
                )
                guard lobbySettingsWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ),
                      updatedRoom.id == scope.roomID,
                      let updatedRevision = updatedRoom.lobbyRevision,
                      updatedRevision > request.expectedRevision else {
                    throw Base44Error(
                        message: "Lobby update was not confirmed.",
                        statusCode: 502,
                        retryable: true
                    )
                }

                _ = lobbySettingsSyncState.finish(
                    request,
                    confirmedRevision: updatedRevision
                )
                guard lobbySettingsWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ) else { return }
                adoptLobbyMutationRoom(updatedRoom)
                lobbySettingsSyncFailure = nil
            } catch is CancellationError {
                _ = lobbySettingsSyncState.fail(request, retry: false)
                return
            } catch {
                guard lobbySettingsWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ) else { return }

                let base44Error = error as? Base44Error
                let shouldRefresh = base44Error?.statusCode == 409
                let retryable = LobbySyncRetryPolicy.isRevisionConflict(error) ||
                    LobbySyncRetryPolicy.isRetryable(error)
                let willRetry = lobbySettingsSyncState.fail(
                    request,
                    retry: retryable
                )

                if shouldRefresh,
                   let refreshed = try? await client.refreshRoom(id: scope.roomID),
                   lobbySettingsWorkerIsCurrent(
                       scope: scope,
                       generation: generation,
                       runID: runID
                   ) {
                    lobbySettingsSyncState.reconcile(
                        confirmedRevision: refreshed.lobbyRevision ?? 0
                    )
                    if RoomPollPolicy.acceptsSnapshot(
                        currentRoomRevision: activeRoom?.roomRevision,
                        currentLobbyRevision: activeRoom?.lobbyRevision,
                        fetchedRoomRevision: refreshed.roomRevision,
                        fetchedLobbyRevision: refreshed.lobbyRevision
                    ) {
                        adoptLobbyMutationRoom(refreshed)
                    }
                }

                guard lobbySettingsWorkerIsCurrent(
                    scope: scope,
                    generation: generation,
                    runID: runID
                ) else { return }

                if willRetry {
                    do {
                        let retryCount = request.intent.retryCount + 1
                        try await Task.sleep(
                            for: retryCount == 1 ? .milliseconds(180) : .milliseconds(450)
                        )
                    } catch {
                        return
                    }
                    continue
                }

                if retryable,
                   !lobbySettingsSyncState.hasOptimisticChanges,
                   let reconciled = try? await client.refreshRoom(id: scope.roomID),
                   lobbySettingsWorkerIsCurrent(
                       scope: scope,
                       generation: generation,
                       runID: runID
                   ) {
                    let wasCommitted = (reconciled.lobbyRevision ?? 0) > request.expectedRevision &&
                        authoritativeLobbyStatePayload(from: reconciled)?
                            .equivalentForLobbySync(to: request.intent.state) == true
                    lobbySettingsSyncState.reconcile(
                        confirmedRevision: reconciled.lobbyRevision ?? 0
                    )
                    if RoomPollPolicy.acceptsSnapshot(
                        currentRoomRevision: activeRoom?.roomRevision,
                        currentLobbyRevision: activeRoom?.lobbyRevision,
                        fetchedRoomRevision: reconciled.roomRevision,
                        fetchedLobbyRevision: reconciled.lobbyRevision
                    ) {
                        adoptLobbyMutationRoom(reconciled)
                    }
                    if wasCommitted {
                        _ = lobbySettingsSyncState.recordRecoveredServerConfirmation(
                            request,
                            confirmedRevision: reconciled.lobbyRevision ?? 0
                        )
                        lobbySettingsSyncFailure = nil
                        continue
                    }
                }

                if !lobbySettingsSyncState.hasOptimisticChanges {
                    if lobbyModeProtection?.roomID == scope.roomID {
                        lobbyModeProtection = nil
                        if let authoritative = try? await client.refreshRoom(id: scope.roomID),
                           lobbySettingsWorkerIsCurrent(
                               scope: scope,
                               generation: generation,
                               runID: runID
                           ),
                           RoomPollPolicy.acceptsSnapshot(
                               currentRoomRevision: activeRoom?.roomRevision,
                               currentLobbyRevision: activeRoom?.lobbyRevision,
                               fetchedRoomRevision: authoritative.roomRevision,
                               fetchedLobbyRevision: authoritative.lobbyRevision
                           ) {
                            activeRoom = authoritative
                        }
                    }
                    if base44Error?.isSpyCountInvalidForPlayerCount == true {
                        lobbySettingsSyncFailure = switch language {
                        case .en: "THE SPY COUNT WAS REDUCED FOR THE CURRENT ROSTER"
                        case .es: "SE REDUJO EL NUMERO DE ESPIAS PARA LOS JUGADORES ACTUALES"
                        case .ru: "КОЛИЧЕСТВО ШПИОНОВ УМЕНЬШЕНО ПОД ТЕКУЩИЙ СОСТАВ"
                        case .uk: "КІЛЬКІСТЬ ШПИГУНІВ ЗМЕНШЕНО ДЛЯ ПОТОЧНОГО СКЛАДУ"
                        }
                    } else if base44Error?.isClientUpdateRequired == true {
                        lobbySettingsSyncFailure = switch language {
                        case .en: "UPDATE SPYCLASH TO USE MULTI-SPY ROOMS"
                        case .es: "ACTUALIZA SPYCLASH PARA USAR SALAS MULTIESPIA"
                        case .ru: "ОБНОВИ SPYCLASH ДЛЯ КОМНАТ С НЕСКОЛЬКИМИ ШПИОНАМИ"
                        case .uk: "ОНОВИ SPYCLASH ДЛЯ КІМНАТ ІЗ КІЛЬКОМА ШПИГУНАМИ"
                        }
                    } else {
                        lobbySettingsSyncFailure = error.localizedDescription
                    }
                    lobbySettingsRollbackEpoch &+= 1
                }
            }
        }
    }

    private func finishLobbySettingsWorker(
        scope: LobbySettingsSyncScope,
        generation: UUID,
        runID: UUID
    ) {
        guard lobbySettingsSyncScope == scope,
              lobbySettingsSyncGeneration == generation,
              lobbySettingsSyncRunID == runID else { return }
        lobbySettingsSyncWorker = nil
        lobbySettingsSyncRunID = nil
        if lobbySettingsSyncState.hasPendingIntent {
            startLobbySettingsWorker(debounce: .milliseconds(90))
        }
    }

    private func lobbySettingsWorkerIsCurrent(
        scope: LobbySettingsSyncScope,
        generation: UUID,
        runID: UUID
    ) -> Bool {
        lobbySettingsSyncScope == scope &&
            lobbySettingsSyncGeneration == generation &&
            lobbySettingsSyncRunID == runID &&
            user?.id == scope.userID &&
            activeRoom?.id == scope.roomID &&
            activeRoom?.normalizedStatus == "waiting" &&
            activeRoom?.hostEmail == user?.email
    }

    private func applyLobbyPayload(
        _ payload: LobbyStatePayload,
        to room: inout GameRoom,
        revision: Int
    ) {
        room.gameMode = payload.gameMode.rawValue
        room.gameDurationSeconds = payload.gameDurationSeconds
        room.lobbySpyCount = payload.spyCount
        room.spiesKnowEachOther = payload.spiesKnowEachOther
        room.lobbySchemaVersion = 2
        room.lobbyRevision = revision
        room.lobbyWordSource = payload.lobbyWordSource.rawValue
        room.lobbySourcePackID = payload.lobbySourcePackID
        room.lobbySourceName = payload.lobbySourceName
        room.lobbyTheme = payload.lobbyTheme
        room.lobbyCategory = payload.lobbyCategory
        room.lobbyWordCount = payload.lobbyWordCount
        room.lobbyWordCountMode = payload.lobbyWordCountMode.rawValue
        room.lobbyWordPool = payload.lobbyWordPool
    }

    private func nextRoomRefreshRequestRevision() -> Int {
        roomRefreshRequestRevision &+= 1
        return roomRefreshRequestRevision
    }

    func showToast(
        _ message: String,
        kind: AppToastKind,
        detail: String? = nil,
        systemImage: String? = nil,
        avatar: String? = nil,
        duration: Duration = .milliseconds(2_800)
    ) {
        let title = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let notice = AppToastNotice(
            id: UUID(),
            kind: kind,
            title: title,
            detail: detail ?? toastDetail(for: kind),
            systemImage: systemImage ?? toastSystemImage(for: kind),
            avatar: avatar
        )

        toastNotices.append(notice)
        if toastNotices.count > 3 {
            toastNotices.removeFirst(toastNotices.count - 3)
        }

        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.dismissToast(notice.id)
        }
    }

    func dismissToast(_ id: UUID) {
        toastNotices.removeAll { $0.id == id }
    }

    func monitorActiveRoom(_ roomID: String) async {
#if DEBUG
        if shouldUsePreviewData {
            return
        }
#endif

        var failureTracker = RoomRefreshFailureTracker()

        while !Task.isCancelled, activeRoom?.id == roomID {
            if roomSyncOperation == nil {
                let refreshRevision = roomSyncRevision
                let refreshRequestRevision = nextRoomRefreshRequestRevision()
                do {
                    let refreshedRoom = try await client.refreshRoom(id: roomID)
                    switch RoomPollPolicy.disposition(
                        monitoredRoomID: roomID,
                        activeRoomID: activeRoom?.id,
                        isCancelled: Task.isCancelled,
                        hasActiveOperation: roomSyncOperation != nil,
                        didRoomSyncRevisionChange: roomSyncRevision != refreshRevision,
                        isLatestRefreshRequest: roomRefreshRequestRevision == refreshRequestRevision,
                        fetchedRoomExists: refreshedRoom != nil
                    ) {
                    case .stop:
                        return
                    case .discardAndContinue:
                        break
                    case .apply:
                        guard let refreshedRoom else { break }
                        if RoomPollPolicy.acceptsSnapshot(
                            currentRoomRevision: activeRoom?.roomRevision,
                            currentLobbyRevision: activeRoom?.lobbyRevision,
                            fetchedRoomRevision: refreshedRoom.roomRevision,
                            fetchedLobbyRevision: refreshedRoom.lobbyRevision
                        ) {
                            activeRoom = refreshedRoom
                        }
                        if failureTracker.recordSuccess() {
                            markRoomSyncRecoveredIfNeeded()
                        }
                    case .close:
                        closeActiveRoomAfterRefresh(roomID: roomID)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, activeRoom?.id == roomID else { return }
                    guard roomSyncOperation == nil,
                          roomSyncRevision == refreshRevision,
                          roomRefreshRequestRevision == refreshRequestRevision else { continue }
                    if RoomPollPolicy.failureDisposition(for: error) == .close {
                        closeActiveRoomAfterRefresh(roomID: roomID)
                        return
                    }
                    if failureTracker.recordFailure(),
                       activeRoom?.id == roomID,
                       roomConnectionState != .reconnecting {
                        roomConnectionState = .reconnecting
                        showToast(
                            roomSyncInterruptedToastMessage,
                            kind: .warning,
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                }
            }

            do {
                let delay = RoomPollPolicy.delaySeconds(
                    roomStatus: activeRoom?.normalizedStatus,
                    consecutiveFailures: failureTracker.consecutiveFailures,
                    isApplicationActive: isApplicationActive
                )
                if isApplicationActive {
                    try await Task.sleep(for: .seconds(delay))
                } else {
                    // Preserve a 30-second background request cadence while
                    // checking the lifecycle often enough that foregrounding
                    // cannot inherit the remainder of that long sleep.
                    var remainingBackgroundDelay = delay
                    while remainingBackgroundDelay > 0,
                          !Task.isCancelled,
                          activeRoom?.id == roomID,
                          !isApplicationActive {
                        let chunk = min(
                            remainingBackgroundDelay,
                            RoomPollPolicy.backgroundWakeCheckSeconds
                        )
                        try await Task.sleep(for: .seconds(chunk))
                        remainingBackgroundDelay -= chunk
                    }
                }
            } catch {
                return
            }
        }
    }

    func refreshActiveRoomOnActivation() {
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        guard user != nil,
              roomSyncOperation == nil,
              !isAuthTransitionActive else { return }
        if case .activeGame? = pendingNotificationRoute {
            // The deferred-route resolver owns this lookup under the black
            // curtain and must remain the only writer for that intent.
            return
        }
        retryDismissedRoomExitIfNeeded()

        let preferredRoomID = activeRoom?.id ?? UserDefaults.standard
            .string(forKey: Self.activeRoomIDStorageKey)?
            .nilIfBlank
        let pendingRouteGeneration = pendingNotificationRouteGeneration

        activeRoomActivationRefreshTask?.cancel()
        activeRoomActivationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let refreshRevision = self.roomSyncRevision
            let refreshRequestRevision = self.nextRoomRefreshRequestRevision()

            var refreshedRoom: GameRoom?
            if let preferredRoomID {
                refreshedRoom = try? await self.client.refreshRoom(id: preferredRoomID)
            }
            let activeStatuses: Set<String> = [
                "waiting",
                "ready_voting",
                "roulette",
                "playing"
            ]
            let preferredRoomIsUsable = refreshedRoom.map {
                activeStatuses.contains($0.normalizedStatus)
                    && !self.isDismissedRoom($0.id)
                    && $0.containsPlayer(email: self.user?.email)
            } ?? false
            if !preferredRoomIsUsable {
                do {
                    refreshedRoom = try await self.client.activeRoom(preferredRoomID: preferredRoomID)
                } catch {
                    // A network failure is not evidence that the room closed.
                    // The existing monitor will continue its bounded retries.
                    return
                }
            }

            guard !Task.isCancelled,
                  self.roomSyncOperation == nil,
                  self.roomSyncRevision == refreshRevision,
                  self.roomRefreshRequestRevision == refreshRequestRevision,
                  self.pendingNotificationRouteGeneration == pendingRouteGeneration else { return }

            if let candidate = refreshedRoom,
               candidate.normalizedStatus == "waiting",
               candidate.containsPlayer(email: self.user?.email),
               let user = self.user {
                do {
                    refreshedRoom = try await self.client.resumeWaitingRoom(candidate, user: user)
                } catch {
                    // Do not expose a pre-upgrade waiting-room snapshot. A later
                    // activation or the room monitor can safely retry the
                    // idempotent membership/capability refresh.
                    return
                }
            }

            guard !Task.isCancelled,
                  self.roomSyncOperation == nil,
                  self.roomSyncRevision == refreshRevision,
                  self.roomRefreshRequestRevision == refreshRequestRevision,
                  self.pendingNotificationRouteGeneration == pendingRouteGeneration else { return }

            if let refreshedRoom,
               !self.isDismissedRoom(refreshedRoom.id),
               activeStatuses.contains(refreshedRoom.normalizedStatus),
               refreshedRoom.containsPlayer(email: self.user?.email) {
                if self.activeRoom?.id != refreshedRoom.id || RoomPollPolicy.acceptsSnapshot(
                    currentRoomRevision: self.activeRoom?.roomRevision,
                    currentLobbyRevision: self.activeRoom?.lobbyRevision,
                    fetchedRoomRevision: refreshedRoom.roomRevision,
                    fetchedLobbyRevision: refreshedRoom.lobbyRevision
                ) {
                    self.activeRoom = refreshedRoom
                }
                self.selectedTab = .game
                self.markRoomSyncRecoveredIfNeeded()
            } else if let currentRoomID = self.activeRoom?.id,
                      currentRoomID == preferredRoomID {
                self.closeActiveRoomAfterRefresh(roomID: currentRoomID)
            }
        }
    }

    private func markRoomSyncRecoveredIfNeeded() {
        guard roomConnectionState == .reconnecting else { return }
        roomConnectionState = .synced
        showToast(
            roomSyncRecoveredToastMessage,
            kind: .success,
            systemImage: "checkmark.icloud.fill"
        )
    }

    private func closeActiveRoomAfterRefresh(
        roomID: String,
        authoritativeRoomRevision: Int? = nil,
        authoritativeLobbyRevision: Int? = nil
    ) {
        guard let closingRoom = activeRoom, closingRoom.id == roomID else { return }
        let closingRoomRevision = authoritativeRoomRevision.map {
            max($0, closingRoom.roomRevision ?? 0)
        }
        let closingLobbyRevision: Int?
        if authoritativeRoomRevision != nil {
            closingLobbyRevision = authoritativeLobbyRevision.map { max($0, 0) }
        } else {
            closingLobbyRevision = authoritativeLobbyRevision.map {
                max($0, closingRoom.lobbyRevision ?? 0)
            }
        }
        closedRoomRevisionFence.record(
            userID: user?.id,
            roomID: roomID,
            roomRevision: closingRoomRevision,
            lobbyRevision: closingLobbyRevision,
            membershipID: closingRoom.viewerMembershipID
        )
        // Invalidate every read generation before clearing the room. Requests
        // already in flight can still complete, but the revision fence in the
        // activeRoom setter rejects their pre-close snapshots.
        activeRoomActivationRefreshTask?.cancel()
        activeRoomActivationRefreshTask = nil
        gameRoomRealtimeRefreshTask?.cancel()
        gameRoomRealtimeRefreshTask = nil
        roomSyncRevision &+= 1
        _ = nextRoomRefreshRequestRevision()
        activeRoom = nil
        if selectedTab == .game {
            selectedTab = .home
        }
        showToast(
            roomClosedToastMessage,
            kind: .warning,
            systemImage: "rectangle.portrait.and.arrow.right"
        )
    }

    private func handleRoomPresenceChange(from previous: GameRoom?, to current: GameRoom?) {
        guard let previous,
              let current,
              previous.id == current.id else { return }

        let currentUserID = user?.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let previousIDs = Set(previous.playersList.map(normalizedPlayerID))
        let currentIDs = Set(current.playersList.map(normalizedPlayerID))
        let joined = current.playersList.filter { player in
            let id = normalizedPlayerID(player)
            return id != currentUserID && !previousIDs.contains(id)
        }
        let left = previous.playersList.filter { player in
            let id = normalizedPlayerID(player)
            return id != currentUserID && !currentIDs.contains(id)
        }

        guard !joined.isEmpty || !left.isEmpty else { return }

        if !joined.isEmpty {
            showPresenceToast(for: joined, joined: true)
        }
        if !left.isEmpty {
            showPresenceToast(for: left, joined: false)
        }
        HapticManager.shared.fire(.navigation)
    }

    private func scheduleFinishedMatchProfileRefreshIfNeeded(for room: GameRoom?) {
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        guard let request = finishedMatchProfileRefreshPolicy.request(
            room: room,
            user: user
        ) else { return }

        finishedMatchProfileRefreshTasks[request] = Task { @MainActor [weak self] in
            guard let self else { return }
            var adopted = false
            defer {
                self.finishedMatchProfileRefreshPolicy.finish(request, adopted: adopted)
                self.finishedMatchProfileRefreshTasks[request] = nil
            }
            let retryDelays = FinishedMatchProfileRefreshPolicy.retryDelays

            for (attempt, retryDelay) in retryDelays.enumerated() {
                guard !Task.isCancelled,
                      self.user?.id == request.userID else { return }
                if retryDelay != .zero {
                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        return
                    }
                }
                do {
                    let refreshed = try await self.client.currentUser()
                    guard FinishedMatchProfileRefreshPolicy.hasExpectedIdentity(
                        refreshedUserID: refreshed.id,
                        expectedUserID: request.userID,
                        currentUserID: self.user?.id
                    ) else { return }
                    guard FinishedMatchProfileRefreshPolicy.canAdopt(
                        refreshedUser: refreshed,
                        request: request,
                        currentUserID: self.user?.id
                    ) else {
                        continue
                    }
                    adopted = true
                    self.user = refreshed
                    return
                } catch {
                    guard attempt < retryDelays.count - 1,
                          LobbySyncRetryPolicy.isRetryable(error) else { return }
                }
            }
        }
    }

    private func showPresenceToast(for players: [Player], joined: Bool) {
        let isSinglePlayer = players.count == 1
        let title = isSinglePlayer
            ? (players.first?.name.uppercased() ?? presencePlayersTitle(players.count))
            : presencePlayersTitle(players.count)

        showToast(
            title,
            kind: joined ? .success : .error,
            detail: presenceDetail(joined: joined, isPlural: !isSinglePlayer),
            systemImage: joined ? "person.badge.plus.fill" : "person.badge.minus.fill",
            avatar: isSinglePlayer ? players.first?.avatar : nil,
            duration: .milliseconds(2_400)
        )
    }

    private func normalizedPlayerID(_ player: Player) -> String {
        player.email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func presencePlayersTitle(_ count: Int) -> String {
        switch language {
        case .ru: "ИГРОКОВ: \(count)"
        case .es: "\(count) JUGADORES"
        case .uk: "ГРАВЦІВ: \(count)"
        default: "\(count) PLAYERS"
        }
    }

    private func presenceDetail(joined: Bool, isPlural: Bool) -> String {
        switch (joined, isPlural, language) {
        case (true, false, .ru): "ВОШЁЛ"
        case (true, true, .ru): "ВОШЛИ"
        case (false, false, .ru): "ВЫШЕЛ"
        case (false, true, .ru): "ВЫШЛИ"
        case (true, false, .es): "ENTRÓ"
        case (true, true, .es): "ENTRARON"
        case (false, false, .es): "SALIÓ"
        case (false, true, .es): "SALIERON"
        case (true, false, .uk): "ПРИЄДНАВСЯ"
        case (true, true, .uk): "ПРИЄДНАЛИСЯ"
        case (false, false, .uk): "ВИЙШОВ"
        case (false, true, .uk): "ВИЙШЛИ"
        case (true, false, _): "JOINED"
        case (true, true, _): "JOINED"
        case (false, false, _): "LEFT"
        case (false, true, _): "LEFT"
        }
    }

    private func toastDetail(for kind: AppToastKind) -> String {
        switch (kind, language) {
        case (.success, .ru): "ГОТОВО"
        case (.warning, .ru), (.info, .ru): "ВНИМАНИЕ"
        case (.error, .ru): "ОШИБКА"
        case (.success, .es): "LISTO"
        case (.warning, .es), (.info, .es): "ATENCIÓN"
        case (.error, .es): "ERROR"
        case (.success, .uk): "ГОТОВО"
        case (.warning, .uk), (.info, .uk): "УВАГА"
        case (.error, .uk): "ПОМИЛКА"
        case (.success, _): "SUCCESS"
        case (.warning, _), (.info, _): "ATTENTION"
        case (.error, _): "ERROR"
        }
    }

    private func toastSystemImage(for kind: AppToastKind) -> String {
        switch kind {
        case .success: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    private static func deepLinkToastKind(_ message: String) -> AppToastKind {
        let upper = message.uppercased()
        let errorMarkers = ["ERROR", "FAILED", "NOT FOUND", "COULD NOT", "НЕ УДАЛ", "НЕ НАЙД", "NO SE PUDO", "НЕ ВДАЛ", "НЕ ЗНАЙД"]
        if errorMarkers.contains(where: upper.contains) {
            return .error
        }
        if upper.contains("READY") || upper.contains("ГОТОВ") || upper.contains("LISTA") || upper.contains("ПІДКЛЮЧЕНО") {
            return .success
        }
        return .warning
    }

    private var roomClosedToastMessage: String {
        switch language {
        case .ru: "ХОСТ ЗАКРЫЛ КОМНАТУ"
        case .es: "EL HOST CERRÓ LA SALA"
        case .uk: "ХОСТ ЗАКРИВ КІМНАТУ"
        default: "ROOM CLOSED BY HOST"
        }
    }

    private var roomSyncInterruptedToastMessage: String {
        switch language {
        case .ru: "СВЯЗЬ С КОМНАТОЙ ПРЕРВАНА — ПЕРЕПОДКЛЮЧАЕМСЯ"
        case .es: "CONEXIÓN INTERRUMPIDA — RECONECTANDO"
        case .uk: "ЗВ’ЯЗОК ІЗ КІМНАТОЮ ПЕРЕРВАНО — ПЕРЕПІДКЛЮЧАЄМОСЯ"
        default: "ROOM SYNC INTERRUPTED — RECONNECTING"
        }
    }

    private var roomSyncRecoveredToastMessage: String {
        switch language {
        case .ru: "СИНХРОНИЗАЦИЯ КОМНАТЫ ВОССТАНОВЛЕНА"
        case .es: "SINCRONIZACIÓN DE SALA RESTAURADA"
        case .uk: "СИНХРОНІЗАЦІЮ КІМНАТИ ВІДНОВЛЕНО"
        default: "ROOM SYNC RESTORED"
        }
    }

#if DEBUG
    private func scheduleToastPreviewIfRequested(roomID: String?) {
        let arguments = ProcessInfo.processInfo.arguments

        guard arguments.contains("--spyclash-preview-room-presence-events") else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self,
                  let roomID,
                  var joinedRoom = self.activeRoom,
                  joinedRoom.id == roomID else { return }
            let previewPlayer = Player(
                email: "signal.echo@spyclash.local",
                name: "Signal Echo",
                avatar: "🛰️"
            )
            if !joinedRoom.playersList.contains(where: { $0.email == previewPlayer.email }) {
                joinedRoom.players = joinedRoom.playersList + [previewPlayer]
                self.activeRoom = joinedRoom
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in
                guard let self,
                      var leftRoom = self.activeRoom,
                      leftRoom.id == roomID else { return }
                leftRoom.players = leftRoom.playersList.filter { $0.email != previewPlayer.email }
                self.activeRoom = leftRoom
            }
        }
    }
#endif

    var hasActiveAuthCinematic: Bool {
        appleAuthStage != nil || standardAuthCinematicStage != nil
    }

    var requiresOnboarding: Bool {
        guard let user else { return false }
        return OnboardingProgressStore.shouldPresentOnboarding(for: user)
    }

    var isAuthTransitionActive: Bool {
        hasActiveAuthCinematic || requiresOnboarding || authHomeRevealPhase != .idle
    }

    func restoreSession() async {
        isRestoring = true
        var shouldSynchronizeLiveActivity = true

#if DEBUG
        if activateUIPreviewModeIfRequested() {
            return
        }
#endif

        if let token = KeychainStore.readToken() {
            client.setToken(token)
        }

        do {
            user = try await client.currentUser()
            reconcileLanguagePreference(with: user?.language)
            retryDismissedRoomExitIfNeeded()
            await restoreActiveRoomIfPossible()
        } catch is CancellationError {
            // A newer authentication attempt replaced this restore. Its own
            // account transition owns notification and ActivityKit cleanup.
            shouldSynchronizeLiveActivity = false
        } catch let error as Base44Error where error.statusCode == 401 {
            // A confirmed credential rejection must also clean up ActivityKit
            // when user was already nil on a cold launch (so user.didSet does
            // not observe an account transition).
            shouldSynchronizeLiveActivity = false
            PushNotificationCoordinator.shared.accountDidChange(isSignedIn: false)
            cancelLiveActivityPushTokenObservers()
            cancelLiveActivityStateObservers()
            cancelLiveActivityPushToStartTokenObserver()
            cancelLiveActivityLifecycleObserver()
            await SpyClashMatchLiveActivityController.shared.endAll()
            client.clearToken()
            KeychainStore.clearToken()
            user = nil
            clearStoredActiveRoom()
        } catch {
            // A temporary transport/server failure is not proof that the
            // account was revoked. Preserve the token and any remotely driven
            // Live Activity so the next activation can recover.
            shouldSynchronizeLiveActivity = false
#if DEBUG
            print("Session restore deferred: \(error.localizedDescription)")
#endif
        }

        isRestoring = false
        if shouldSynchronizeLiveActivity {
            synchronizeMatchLiveActivity(previousRoom: nil, room: activeRoom)
        }
        await consumePendingRoutesIfPossible()
    }

    func login(email: String, password: String) async {
        await performAuth {
            let response = try await self.client.login(email: email, password: password)
            KeychainStore.saveToken(response.accessToken)
            await self.beginStandardAuthCinematic(
                with: response.user,
                startDelay: .milliseconds(650)
            )
        }
    }

    func register(email: String, password: String) async {
        await performAuth {
            try await self.client.register(email: email, password: password)
            self.authPhase = .otp(email: email)
            HapticManager.shared.fire(.notification(.success))
        }
    }

    func verify(email: String, code: String) async {
        await performAuth {
            try? await self.client.autoRegisterUser(email: email)
            let response = try await self.client.verify(email: email, code: code)
            if let token = response.accessToken, let verifiedUser = response.user {
                self.client.setToken(token)
                KeychainStore.saveToken(token)
                await self.beginStandardAuthCinematic(
                    with: verifiedUser,
                    startDelay: .milliseconds(650)
                )
            } else {
                self.authPhase = .password(email: email)
                HapticManager.shared.fire(.notification(.success))
            }
        }
    }

    func requestPasswordReset(email: String) async {
        await performAuth {
            try await self.client.requestPasswordReset(email: email)
            self.authPhase = .resetEmailSent(email: email)
            self.authNotice = self.language.auth.recoveryLinkNotice
            HapticManager.shared.fire(.notification(.success))
        }
    }

    func resetPassword(token: String, newPassword: String) async {
        await performAuth {
            try await self.client.resetPassword(token: token, newPassword: newPassword)
            self.authPhase = .email
            self.authNotice = self.language.auth.passphraseUpdatedNotice
            HapticManager.shared.fire(.notification(.success))
        }
    }

    func loginWithGoogle() async {
        guard let callback = URL(string: "spyclash://auth") else { return }
        await loginWithWebProvider(
            url: client.googleLoginURL(callbackURL: callback),
            providerName: "Google",
            missingTokenMessage: language.auth.googleMissingToken
        )
    }

    func configureAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard !isBusy else { return }
        authError = nil
        authNotice = nil

        do {
            try appleSignInCoordinator.configure(request)
            isAppleAuthorizationPending = true
            isBusy = true
        } catch {
            authError = error.localizedDescription
            HapticManager.shared.fire(.notification(.error))
        }
    }

    func completeAppleSignIn(
        _ result: Result<ASAuthorization, any Error>
    ) async {
        let animationStartedAt = ContinuousClock.now
        authHomeRevealPhase = .idle

        defer {
            isAppleAuthorizationPending = false
            isBusy = false
        }

        do {
            let credential = try appleSignInCoordinator.credential(from: result)
            isAppleAuthorizationPending = false

            guard let credential else {
                appleAuthStage = nil
                authHomeRevealPhase = .idle
                return
            }

            appleAuthStage = .verifyingIdentity
            let nativeSession = try await client.appleNativeAccessToken(for: credential) { [weak self] phase in
                switch phase {
                case .verifyingIdentity:
                    self?.appleAuthStage = .verifyingIdentity
                case .establishingSession:
                    self?.appleAuthStage = .establishingSession
                }
            }
            appleAuthStage = .synchronizingProfile
            try await acceptProviderToken(
                nativeSession.accessToken,
                cinematic: .apple,
                appleBindingTicket: nativeSession.bindingTicket
            )

            let assemblyElapsed = animationStartedAt.duration(to: .now)
            let assemblyDuration = Duration.milliseconds(3_100)
            if assemblyElapsed < assemblyDuration {
                try? await Task.sleep(for: assemblyDuration - assemblyElapsed)
            }

            appleAuthStage = .accessGranted
            // The auth timeline already owns its completion surge.
            HapticManager.shared.fire(.notification(.success))

            let totalElapsed = animationStartedAt.duration(to: .now)
            let remainingToFourSeconds = Duration.seconds(4) - totalElapsed
            let completionHold = max(remainingToFourSeconds, .milliseconds(850))
            try? await Task.sleep(for: completionHold)

            await revealHomeAfterAppleAuth()
        } catch {
            appleAuthStage = nil
            authHomeRevealPhase = .idle
            authError = error.localizedDescription
            HapticManager.shared.fire(.notification(.error))
        }
    }

    func cancelAppleSignInRequest() {
        guard isAppleAuthorizationPending else { return }
        appleSignInCoordinator.cancelPendingRequest()
        isAppleAuthorizationPending = false
        appleAuthStage = nil
        authHomeRevealPhase = .idle
        isBusy = false
    }

    private func loginWithWebProvider(
        url: URL,
        providerName: String,
        missingTokenMessage: String
    ) async {
        guard !isBusy else { return }
        isBusy = true
        authError = nil
        authNotice = nil
        defer { isBusy = false }

        await completeWebProviderLogin(
            url: url,
            providerName: providerName,
            missingTokenMessage: missingTokenMessage
        )
    }

    private func completeWebProviderLogin(
        url: URL,
        providerName: String,
        missingTokenMessage: String
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "spyclash") { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume()
                        return
                    }

                    self.webAuthSession = nil
                    if let error {
                        self.authError = (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                            ? nil
                            : error.localizedDescription
                        if self.authError != nil {
                            HapticManager.shared.fire(.notification(.error))
                        }
                        continuation.resume()
                        return
                    }

                    guard let token = callbackURL?.queryItems["access_token"] else {
                        self.authError = missingTokenMessage
                        HapticManager.shared.fire(.notification(.error))
                        continuation.resume()
                        return
                    }

                    do {
                        try await self.acceptProviderToken(token, cinematic: .standard)
                    } catch {
                        self.authError = error.localizedDescription
                        HapticManager.shared.fire(.notification(.error))
                    }
                    continuation.resume()
                }
            }

            session.presentationContextProvider = self
            // Keep the broker transaction cookie inside one clean Google
            // authorization session. A persistent session can retain or lose
            // a stale host cookie across app upgrades, which makes the secure
            // callback binding fail with `invalid_state` before we receive the
            // custom-scheme callback.
            session.prefersEphemeralWebBrowserSession = true
            webAuthSession = session
            if !session.start() {
                webAuthSession = nil
                authError = "Unable to start \(providerName) sign-in."
                HapticManager.shared.fire(.notification(.error))
                continuation.resume()
            }
        }
    }

    private func acceptProviderToken(
        _ token: String,
        cinematic: ProviderAuthCinematic,
        appleBindingTicket: String? = nil
    ) async throws {
        client.setToken(token)
        do {
            let authenticatedUser = try await client.autoRegisterUser(
                appleBindingTicket: appleBindingTicket
            )
            KeychainStore.saveToken(token)
            reconcileLanguagePreference(with: authenticatedUser.language)
            if cinematic == .standard {
                await beginStandardAuthCinematic(
                    with: authenticatedUser,
                    startDelay: .milliseconds(650)
                )
            } else {
                user = authenticatedUser
            }
#if DEBUG
            // A direct UI preview must stop owning routing once a real
            // provider login succeeds. Otherwise its launch argument keeps
            // forcing Welcome/Auth even though the authenticated user exists.
            isUIPreviewMode = false
#endif
            if cinematic == .apple {
                startPostAuthActiveRoomRestoreIfNeeded()
            }

        } catch {
            client.clearToken()
            KeychainStore.clearToken()
            throw error
        }
    }

    private func beginStandardAuthCinematic(
        with authenticatedUser: SpyUser,
        startDelay: Duration
    ) async {
        standardAuthTimelineTask?.cancel()

        let runID = UUID()
        standardAuthRunID = runID
        authHomeRevealPhase = .idle

        // This state must be committed before `user`. RootView and AuthView use
        // it to keep the login sheet physically alive for the whole cinematic.
        standardAuthCinematicStage = .preparing
        reconcileLanguagePreference(with: authenticatedUser.language)
        user = authenticatedUser
        startPostAuthActiveRoomRestoreIfNeeded()

        let timeline = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runStandardAuthTimeline(runID: runID, startDelay: startDelay)
        }
        standardAuthTimelineTask = timeline
        await timeline.value

        if standardAuthRunID == runID || standardAuthRunID == nil {
            standardAuthTimelineTask = nil
        }
    }

    private func runStandardAuthTimeline(
        runID: UUID,
        startDelay: Duration
    ) async {
        do {
            // Google needs enough time for ASWebAuthenticationSession to clear;
            // email only uses one render pass so piece 1 is never born assembled.
            try await Task.sleep(for: startDelay)
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }

        standardAuthCinematicStage = .placing(1)

        for piece in 1...4 {
            do {
                // Each placement owns a fresh full second. Do not reuse an
                // absolute launch deadline: after background/resume, overdue
                // deadlines would collapse several pieces into one frame.
                try await Task.sleep(for: .seconds(1))
            } catch {
                clearStandardAuthCinematicIfCurrent(runID)
                return
            }

            guard standardAuthRunID == runID, user != nil else { return }

            if piece < 4 {
                standardAuthCinematicStage = .placing(piece + 1)
            } else {
                standardAuthCinematicStage = .assembled
            }
        }

        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }
        standardAuthCinematicStage = .accessGranted

        do {
            try await Task.sleep(for: .milliseconds(900))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        await revealHomeAfterStandardAuth(runID: runID)
    }

    private func revealHomeAfterStandardAuth(runID: UUID) async {
        guard standardAuthRunID == runID, user != nil else { return }

        authHomeRevealAnimationID = nil
        authHomeRevealPhase = .covered
        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }
        standardAuthCinematicStage = nil
        await waitForPostAuthActiveRoomRestoreIfNeeded()
        await prepareLatestPendingShellRouteForReveal()

        do {
            try await Task.sleep(for: .milliseconds(260))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }
        await prepareLatestPendingShellRouteForReveal()
        _ = await animateAuthHomeRevealToIdle()
        guard standardAuthRunID == runID, user != nil else { return }
        standardAuthRunID = nil
#if DEBUG
        isUIPreviewMode = false
#endif
    }

    private func clearStandardAuthCinematicIfCurrent(_ runID: UUID) {
        guard standardAuthRunID == runID else { return }
        standardAuthRunID = nil
        standardAuthCinematicStage = nil
        if authHomeRevealRestartTask == nil {
            authHomeRevealAnimationID = nil
            authHomeRevealPhase = .idle
        }
    }

#if DEBUG
    func runStandardAuthPreview(with previewUser: SpyUser) async {
        await beginStandardAuthCinematic(
            with: previewUser,
            startDelay: .milliseconds(650)
        )
    }
#endif

    func logout() {
#if DEBUG
        // Logout must always leave forced UI-preview routing. Otherwise a
        // device launched into the Apple-auth preview keeps rendering the
        // already-dismissed debug presenter instead of WelcomeView.
        isUIPreviewMode = false
#endif
        standardAuthTimelineTask?.cancel()
        standardAuthTimelineTask = nil
        standardAuthRunID = nil
        onboardingSyncTask?.cancel()
        onboardingSyncTask = nil
        onboardingSyncUserID = nil
        postAuthActiveRoomRestoreTask?.cancel()
        postAuthActiveRoomRestoreTask = nil
        postAuthActiveRoomRestoreUserID = nil
        authHomeRevealRestartTask?.cancel()
        authHomeRevealRestartTask = nil
        authHomeRevealRestartID = nil
        authHomeRevealAnimationID = nil
        HapticManager.shared.fire(.notification(.success))
        PushNotificationCoordinator.shared.prepareForLogout()
        client.clearToken()
        KeychainStore.clearToken()
        user = nil
        authPhase = .email
        authError = nil
        authNotice = nil
        appleAuthStage = nil
        standardAuthCinematicStage = nil
        authHomeRevealPhase = .idle
        onboardingLaunchMessage = nil
        isFinishingOnboarding = false
        selectedTab = .home
        shellRoute = .main
        activeRoom = nil
        roomSyncOperation = nil
        roomSyncRevision &+= 1
        activeRoomActivationRefreshTask?.cancel()
        activeRoomActivationRefreshTask = nil
        presentedSheet = nil
        pendingJoinCode = nil
        pendingMatchRoomID = nil
        pendingNotificationRoute = nil
        authPresentationRequestID = 0
        deepLinkStatus = nil
        isJoiningDeepLink = false
        isOpeningPendingMatch = false
    }

    private func revealHomeAfterAppleAuth() async {
        // Phase 1 is committed on its own render pass. This guarantees the
        // black root curtain exists before RootView swaps Welcome for Home.
        authHomeRevealAnimationID = nil
        authHomeRevealPhase = .covered
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else {
            appleAuthStage = nil
            authHomeRevealPhase = .idle
            return
        }

        // Mount the authenticated destination under an already opaque, stable
        // curtain and let the auth sheet disappear black-to-black.
        appleAuthStage = nil
        await waitForPostAuthActiveRoomRestoreIfNeeded()
        await prepareLatestPendingShellRouteForReveal()
        try? await Task.sleep(for: .milliseconds(260))
        guard !Task.isCancelled else {
            authHomeRevealPhase = .idle
            return
        }

        // Start the one visible reveal only after Home and its entrance state
        // have both had time to mount behind the curtain.
        await prepareLatestPendingShellRouteForReveal()
        _ = await animateAuthHomeRevealToIdle()
    }

    func openLocalSetup() {
        pendingNotificationRoute = nil
        isShellChromeSuppressed = false
        localSetupRequestID += 1
        selectedTab = .local
    }

    func canOpenRoomFriends(roomID: String) -> Bool {
        guard let activeRoom else { return false }
        return RoomFriendsNavigationPolicy.canOpen(
            sourceRoomID: roomID,
            activeRoomID: activeRoom.id,
            activeRoomStatus: activeRoom.normalizedStatus
        )
    }

    @discardableResult
    func openRoomFriends(roomID: String) -> Bool {
        guard let activeRoom,
              let request = RoomFriendsNavigationPolicy.makeRequest(
                  sourceRoomID: roomID,
                  activeRoomID: activeRoom.id,
                  activeRoomStatus: activeRoom.normalizedStatus
              ) else { return false }

        pendingNotificationRoute = nil
        isShellChromeSuppressed = false
        shellRoute = .main
        selectedTab = .game
        presentedSheet = nil
        roomFriendsNavigationRequest = request
        return true
    }

    @discardableResult
    func consumeRoomFriendsNavigationRequest(for room: GameRoom) -> Bool {
        guard let request = roomFriendsNavigationRequest else { return false }
        roomFriendsNavigationRequest = nil
        return RoomFriendsNavigationPolicy.matches(
            request,
            activeRoomID: room.id,
            activeRoomStatus: room.normalizedStatus
        )
    }

    func openHomeRoot() {
        pendingNotificationRoute = nil
        homeRootRequestID &+= 1
        isHomeLandingPresentationRequested = true
        presentedSheet = nil
        notificationFocusItemID = nil
        shellRoute = .main
        selectedTab = .home
    }

    func setLanguage(_ newLanguage: AppLanguage, syncRemote: Bool = true) async throws {
        language = newLanguage
        newLanguage.persist()

        guard syncRemote, user != nil else {
            return
        }

        user = try await client.updateLanguage(newLanguage)
    }

    func setOnboardingLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
        newLanguage.persist()
    }

    func finishOnboarding(
        source: OnboardingAcquisitionSource
    ) async {
        guard !isFinishingOnboarding,
              let authenticatedUser = user,
              requiresOnboarding else { return }

        onboardingSyncTask?.cancel()
        onboardingSyncTask = nil
        onboardingSyncUserID = nil
        isFinishingOnboarding = true
        defer { isFinishingOnboarding = false }

        let submission = OnboardingSubmission(
            language: language,
            acquisitionSource: source
        )
        var updatedUser: SpyUser?
        var shouldRetrySync = false

#if DEBUG
        if !isUIPreviewMode {
            do {
                updatedUser = try await client.completeOnboarding(submission)
            } catch is CancellationError {
                return
            } catch {
                guard authenticatedUser.onboardingCompleted != false,
                      Self.canDeferOnboardingSync(after: error) else {
                    showToast(onboardingSaveFailureMessage, kind: .error)
                    return
                }
                shouldRetrySync = true
            }
        }
#else
        do {
            updatedUser = try await client.completeOnboarding(submission)
        } catch is CancellationError {
            return
        } catch {
            guard authenticatedUser.onboardingCompleted != false,
                  Self.canDeferOnboardingSync(after: error) else {
                showToast(onboardingSaveFailureMessage, kind: .error)
                return
            }
            shouldRetrySync = true
        }
#endif

        guard user?.id == authenticatedUser.id else { return }

        onboardingLaunchMessage = nil
        authHomeRevealAnimationID = nil
        authHomeRevealPhase = .covered
        HapticManager.shared.fire(.reveal)

        // Give the opaque curtain its own render pass before changing the
        // account gate. This keeps Onboarding and Home from ever sharing a
        // visible frame.
        try? await Task.sleep(for: .milliseconds(120))
        guard user?.id == authenticatedUser.id else {
            onboardingLaunchMessage = nil
            authHomeRevealPhase = .idle
            return
        }

        if let updatedUser {
            OnboardingProgressStore.markSynced(submission, for: authenticatedUser.id)
        } else if shouldRetrySync {
            OnboardingProgressStore.savePending(submission, for: authenticatedUser.id)
        } else {
            // DEBUG previews have no authenticated Base44 transport, but still
            // need to exercise the complete root transition deterministically.
            OnboardingProgressStore.markSynced(submission, for: authenticatedUser.id)
        }
        selectedTab = .home
        shellRoute = .main
        presentedSheet = nil
        user = updatedUser ?? authenticatedUser
        await waitForPostAuthActiveRoomRestoreIfNeeded()
        await prepareLatestPendingShellRouteForReveal()

#if DEBUG
        if isUIPreviewMode {
            isUIPreviewMode = false
        }
#endif

        // Play the launch phrase only after Home and any deferred destination
        // are ready beneath the opaque curtain. Its 1.35 s entrance, 1.00 s
        // hold, and 1.65 s exit form one uninterrupted four-second arc.
        onboardingLaunchMessage = onboardingLaunchTitle
        try? await Task.sleep(for: .milliseconds(4_080))
        onboardingLaunchMessage = nil
        try? await Task.sleep(for: .milliseconds(80))
        await prepareLatestPendingShellRouteForReveal()
        _ = await animateAuthHomeRevealToIdle()

        if shouldRetrySync {
            queuePendingOnboardingSyncIfNeeded()
            showToast(onboardingPendingSyncMessage, kind: .warning)
        }
        await consumePendingRoutesIfPossible()
    }

    private static func canDeferOnboardingSync(after error: Error) -> Bool {
        guard let error = error as? Base44Error else { return true }
        if error.retryable { return true }
        guard let statusCode = error.statusCode else { return true }
        return statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    private var onboardingLaunchTitle: String {
        switch language {
        case .en: "LET'S BEGIN"
        case .es: "EMPECEMOS"
        case .ru: "ПРИСТУПИМ"
        case .uk: "РОЗПОЧНІМО"
        }
    }

    private var onboardingSaveFailureMessage: String {
        switch language {
        case .en: "ONBOARDING COULD NOT BE SAVED. TRY AGAIN."
        case .es: "NO SE PUDO GUARDAR. INTÉNTALO DE NUEVO."
        case .ru: "НЕ УДАЛОСЬ СОХРАНИТЬ. ПОПРОБУЙТЕ ЕЩЁ РАЗ."
        case .uk: "НЕ ВДАЛОСЯ ЗБЕРЕГТИ. СПРОБУЙТЕ ЩЕ РАЗ."
        }
    }

    private var onboardingPendingSyncMessage: String {
        switch language {
        case .en: "SAVED ON THIS DEVICE. ACCOUNT SYNC WILL RETRY."
        case .es: "GUARDADO EN ESTE DISPOSITIVO. REINTENTAREMOS LA SINCRONIZACIÓN."
        case .ru: "СОХРАНЕНО НА УСТРОЙСТВЕ. СИНХРОНИЗАЦИЮ ПОВТОРИМ."
        case .uk: "ЗБЕРЕЖЕНО НА ПРИСТРОЇ. СИНХРОНІЗАЦІЮ БУДЕ ПОВТОРЕНО."
        }
    }

    private func queuePendingOnboardingSyncIfNeeded() {
        guard onboardingSyncTask == nil,
              let user,
              user.onboardingCompleted != false,
              client.hasSessionToken,
              let submission = OnboardingProgressStore.pendingSubmission(for: user.id),
              submission.version >= OnboardingSubmission.currentVersion else {
            return
        }

        let userID = user.id
        onboardingSyncUserID = userID
        onboardingSyncTask = Task { @MainActor [weak self] in
            await self?.runPendingOnboardingSync(
                submission,
                userID: userID
            )
        }
    }

    private func runPendingOnboardingSync(
        _ submission: OnboardingSubmission,
        userID: String
    ) async {
        defer {
            if onboardingSyncUserID == userID {
                onboardingSyncTask = nil
                onboardingSyncUserID = nil
            }
        }

        do {
            let synchronizedUser = try await client.completeOnboarding(submission)
            guard !Task.isCancelled, user?.id == userID else { return }
            OnboardingProgressStore.markSynced(submission, for: userID)
            guard (OnboardingProgressStore.pendingSubmission(for: userID)?.version ?? 0)
                <= submission.version else { return }
            user = synchronizedUser
        } catch {
            // Keep the account-scoped payload for the next authenticated
            // activation. Onboarding answers are never copied between users.
        }
    }

    func setRadarInvitePolicy(_ policy: RadarInvitePolicy) {
        let selectablePolicy = policy.selectableValue
        radarNearby.setInvitePolicy(selectablePolicy)
        guard let userID = user?.id, client.hasSessionToken else {
            radarInvitePolicySyncState = .localOnly
            return
        }
        queueRadarInvitePolicySync(selectablePolicy, userID: userID)
    }

    var isRadarActivated: Bool {
        _ = radarActivationRevision
        guard let user, !requiresOnboarding else { return false }
        return OnboardingProgressStore.isNearbyTransportEnabled(for: user.id)
    }

    func activateRadarAndStartScanning(requestCameraAccess: Bool = false) {
        guard let user, !requiresOnboarding else { return }
        OnboardingProgressStore.setNearbyTransportEnabled(true, for: user.id)
        radarActivationRevision &+= 1
        reconcileRadarInvitePolicy(for: user, accountChanged: false)
        radarNearby.startScanning(requestCameraAccess: requestCameraAccess)
#if DEBUG
        installPreviewRadarFailureIfRequested()
#endif
    }

    func resumeRadarScanningIfActivated(requestCameraAccess: Bool = false) {
        guard let user, isRadarActivated else { return }
        reconcileRadarInvitePolicy(for: user, accountChanged: false)
        radarNearby.startScanning(requestCameraAccess: requestCameraAccess)
#if DEBUG
        installPreviewRadarFailureIfRequested()
#endif
    }

    func retryRadarScanning(requestCameraAccess: Bool = false) {
        guard let user, isRadarActivated else { return }
        reconcileRadarInvitePolicy(for: user, accountChanged: false)
        radarNearby.retryScanning(requestCameraAccess: requestCameraAccess)
    }

    func retryRadarInvitePolicySync() {
        guard radarInvitePolicySyncState == .pendingRetry,
              let userID = user?.id,
              client.hasSessionToken else {
            return
        }
        queueRadarInvitePolicySync(radarNearby.invitePolicy, userID: userID)
    }

    static func hasUncommittedRadarInvitePolicy(
        userID: String?,
        syncOwnerUserID: String?,
        syncState: RadarInvitePolicySyncState,
        hasQueuedWrite: Bool
    ) -> Bool {
        guard let userID, userID == syncOwnerUserID else { return false }
        return syncState == .syncing || syncState == .pendingRetry || hasQueuedWrite
    }

    private func reconcileRadarInvitePolicy(
        for user: SpyUser?,
        accountChanged: Bool
    ) {
        if accountChanged {
            radarInvitePolicySyncTask?.cancel()
            radarInvitePolicySyncTask = nil
            radarInvitePolicySyncRunID = nil
            pendingRadarInvitePolicy = nil
            radarInvitePolicySyncOwnerUserID = user?.id
            radarInvitePolicySyncState = .localOnly
        }

        let hasPendingWrite = Self.hasUncommittedRadarInvitePolicy(
            userID: user?.id,
            syncOwnerUserID: radarInvitePolicySyncOwnerUserID,
            syncState: radarInvitePolicySyncState,
            hasQueuedWrite: pendingRadarInvitePolicy != nil
        )
        radarNearby.configure(
            user: user,
            applyRemoteInvitePolicy: !hasPendingWrite,
            allowsTransport: user.map {
                !OnboardingProgressStore.shouldPresentOnboarding(for: $0)
                    && OnboardingProgressStore.isNearbyTransportEnabled(for: $0.id)
            } ?? false
        )

        guard let user, client.hasSessionToken else {
            radarInvitePolicySyncState = .localOnly
            return
        }
        let remotePolicy = RadarInvitePolicy(rawValue: user.radarInvitePolicy ?? "")
        if remotePolicy == .blocked {
            if !hasPendingWrite {
                queueRadarInvitePolicySync(.ask, userID: user.id)
            }
            return
        }
        if remotePolicy != nil {
            if !hasPendingWrite {
                radarInvitePolicySyncState = .synced
            }
            return
        }
        if !hasPendingWrite {
            queueRadarInvitePolicySync(radarNearby.invitePolicy, userID: user.id)
        }
    }

    private func queueRadarInvitePolicySync(
        _ policy: RadarInvitePolicy,
        userID: String
    ) {
        guard user?.id == userID, client.hasSessionToken else {
            radarInvitePolicySyncState = .localOnly
            return
        }

        radarInvitePolicySyncOwnerUserID = userID
        pendingRadarInvitePolicy = policy
        radarInvitePolicySyncState = .syncing
        guard radarInvitePolicySyncTask == nil else { return }

        let runID = UUID()
        radarInvitePolicySyncRunID = runID
        radarInvitePolicySyncTask = Task { @MainActor [weak self] in
            await self?.runRadarInvitePolicySync(userID: userID, runID: runID)
        }
    }

    private func runRadarInvitePolicySync(userID: String, runID: UUID) async {
        defer {
            if radarInvitePolicySyncRunID == runID {
                radarInvitePolicySyncTask = nil
                radarInvitePolicySyncRunID = nil
            }
        }

        while !Task.isCancelled,
              user?.id == userID,
              radarInvitePolicySyncOwnerUserID == userID,
              let requestedPolicy = pendingRadarInvitePolicy {
            pendingRadarInvitePolicy = nil
            do {
                let confirmedPolicy = try await client.updateRadarInvitePolicy(requestedPolicy)
                guard !Task.isCancelled,
                      user?.id == userID,
                      radarInvitePolicySyncOwnerUserID == userID else {
                    return
                }

                if pendingRadarInvitePolicy == nil {
                    if radarNearby.invitePolicy == confirmedPolicy {
                        radarInvitePolicySyncState = .synced
                    } else {
                        pendingRadarInvitePolicy = radarNearby.invitePolicy
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard user?.id == userID,
                      radarInvitePolicySyncOwnerUserID == userID else {
                    return
                }
                if pendingRadarInvitePolicy == nil {
                    radarInvitePolicySyncState = .pendingRetry
                    return
                }
            }
        }
    }

    func resumeAfterActivation() {
        queuePendingOnboardingSyncIfNeeded()
        deferredActiveGameRetryGeneration = nil
        guard user != nil,
              !isRestoring,
              !isAuthTransitionActive,
              !shouldUsePreviewData,
              activationResumeTask == nil else {
            return
        }

        activationResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activationResumeTask = nil }
            await self.consumePendingRoutesIfPossible()
            self.synchronizeMatchLiveActivity(previousRoom: nil, room: self.activeRoom)
        }
    }

    private func reconcileGameRoomRealtimeSubscription() {
        gameRoomRealtimeGeneration = UUID()
        gameRoomRealtimeRefreshTask?.cancel()
        gameRoomRealtimeRefreshTask = nil
        pendingGameRoomRealtimeRevision = 0
        gameRoomRealtimeCatchUpRequested = false

        guard let user,
              let token = client.currentAccessToken,
              let roomID = activeRoom?.id else {
            gameRoomRealtime.stop()
            return
        }

        gameRoomRealtime.start(
            appID: Base44Client.appID,
            token: token,
            userID: user.id,
            roomID: roomID
        )
    }

    private func handleGameRoomRealtimeSignal(
        _ signal: GameRoomRealtimeSignal,
        serviceGeneration: UUID
    ) {
        let receivedAt = Date()
        switch GameRoomRealtimeSignalPolicy.disposition(
            signal: signal,
            activeRoomID: activeRoom?.id,
            activeRoomStatus: activeRoom?.normalizedStatus,
            currentRoomRevision: activeRoom?.roomRevision,
            currentLobbyRevision: activeRoom?.lobbyRevision ?? 0,
            subscriptionGenerationIsCurrent: gameRoomRealtime.isCurrent(
                generation: serviceGeneration
            )
        ) {
        case .ignore:
            return
        case .applyLobbyMode(let projection):
            guard let currentRoom = activeRoom,
                  let roomRevision = signal.roomRevision,
                  currentRoom.id == signal.roomID,
                  currentRoom.normalizedStatus == "waiting" else { return }
            let room = GameRoomRealtimeLobbyModeApplier.applying(
                signal: signal,
                projection: projection,
                to: currentRoom
            )
            activeRoom = room

            if let scope = lobbySettingsSyncScope,
               scope.roomID == room.id,
               room.hostEmail == user?.email {
                _ = lobbySettingsSyncState.rebaseGameMode(
                    roomID: room.id,
                    mode: projection.gameMode
                )
                lobbyModeProtection = lobbySettingsSyncState.hasOptimisticChanges
                    ? LobbyModeProtection(
                        roomID: room.id,
                        mode: projection.gameMode
                    )
                    : nil
                if lobbySettingsSyncState.hasPendingIntent {
                    startLobbySettingsWorker(debounce: .zero)
                }
            }

            let latency = GameRoomRealtimeProjectionLatency.measure(
                projection: projection,
                receivedAt: receivedAt
            )
            let commitMS = latency.commitToReceiveMilliseconds.map(String.init) ?? "unknown"
            let emitMS = latency.emitToReceiveMilliseconds.map(String.init) ?? "unknown"
            print(
                "[LobbyModeRealtime] projection_id=\(projection.id) " +
                    "commit_to_receive_ms=\(commitMS) emit_to_receive_ms=\(emitMS) " +
                    "direct_apply=true room_revision=\(roomRevision)"
            )
        case .close:
            closeActiveRoomAfterRefresh(
                roomID: signal.roomID,
                authoritativeRoomRevision: signal.roomRevision,
                authoritativeLobbyRevision: signal.lobbyRevision
            )
        case .refresh(let forceCatchUp):
            pendingGameRoomRealtimeRevision = max(
                pendingGameRoomRealtimeRevision,
                signal.roomRevision ?? signal.lobbyRevision
            )
            // Legacy signals need a forced read because their lobby revision
            // does not advance during gameplay.
            if forceCatchUp {
                gameRoomRealtimeCatchUpRequested = true
            }
            scheduleGameRoomRealtimeRefresh()
        }
    }

    private func handleGameRoomRealtimeCatchUp() {
        guard activeRoom != nil else { return }
        gameRoomRealtimeCatchUpRequested = true
        scheduleGameRoomRealtimeRefresh()
    }

    private func scheduleGameRoomRealtimeRefresh() {
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        guard user != nil, activeRoom != nil,
              gameRoomRealtimeRefreshTask == nil else { return }

        let generation = gameRoomRealtimeGeneration
        gameRoomRealtimeRefreshTask = Task { @MainActor [weak self] in
            await self?.runGameRoomRealtimeRefresh(generation: generation)
        }
    }

    private func runGameRoomRealtimeRefresh(generation: UUID) async {
        var shouldRescheduleAfterRun = false
        defer {
            if generation == gameRoomRealtimeGeneration {
                gameRoomRealtimeRefreshTask = nil
                if roomSyncOperation == nil,
                   shouldRescheduleAfterRun || gameRoomRealtimeCatchUpRequested {
                    scheduleGameRoomRealtimeRefresh()
                }
            }
        }

        do {
            try await Task.sleep(for: .milliseconds(110))
        } catch {
            return
        }

        var staleReadAttempts = 0
        var transientFailureAttempts = 0
        while !Task.isCancelled, generation == gameRoomRealtimeGeneration {
            // Do not spin while a serialized room mutation owns the refresh
            // lane. `endRoomSync` restarts one bounded catch-up batch.
            guard roomSyncOperation == nil else { return }
            guard let roomID = activeRoom?.id else { return }

            let requiredRevision = pendingGameRoomRealtimeRevision
            let isCatchUp = gameRoomRealtimeCatchUpRequested
            gameRoomRealtimeCatchUpRequested = false
            if !isCatchUp,
               requiredRevision <= (activeRoom?.roomRevision ?? activeRoom?.lobbyRevision ?? 0) {
                pendingGameRoomRealtimeRevision = 0
                return
            }
            pendingGameRoomRealtimeRevision = 0
            let refreshRevision = roomSyncRevision

            let refreshedRoom: GameRoom?
            do {
                refreshedRoom = try await client.refreshRoom(id: roomID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == gameRoomRealtimeGeneration,
                      activeRoom?.id == roomID,
                      roomSyncOperation == nil else { return }
                if RoomPollPolicy.failureDisposition(for: error) == .close {
                    closeActiveRoomAfterRefresh(roomID: roomID)
                    return
                }
                if LobbySyncRetryPolicy.isRetryable(error),
                   let delay = GameRoomRealtimeRefreshRetryPolicy
                    .delayMilliseconds(afterFailedAttempt: transientFailureAttempts) {
                    transientFailureAttempts += 1
                    pendingGameRoomRealtimeRevision = max(
                        pendingGameRoomRealtimeRevision,
                        requiredRevision
                    )
                    gameRoomRealtimeCatchUpRequested =
                        gameRoomRealtimeCatchUpRequested || isCatchUp
                    do {
                        try await Task.sleep(for: .milliseconds(delay))
                    } catch {
                        return
                    }
                    continue
                }
                // Park the wake-up revision instead of recursively spinning on
                // a failing endpoint. Polling, reconnect catch-up, activation,
                // or a later signal will make another bounded attempt.
                pendingGameRoomRealtimeRevision = max(
                    pendingGameRoomRealtimeRevision,
                    requiredRevision
                )
                shouldRescheduleAfterRun =
                    pendingGameRoomRealtimeRevision > requiredRevision ||
                    gameRoomRealtimeCatchUpRequested
                return
            }

            guard !Task.isCancelled,
                  generation == gameRoomRealtimeGeneration,
                  activeRoom?.id == roomID,
                  roomSyncOperation == nil else { return }

            guard roomSyncRevision == refreshRevision else {
                pendingGameRoomRealtimeRevision = max(
                    pendingGameRoomRealtimeRevision,
                    requiredRevision
                )
                gameRoomRealtimeCatchUpRequested =
                    gameRoomRealtimeCatchUpRequested || isCatchUp
                continue
            }

            guard let refreshedRoom else {
                closeActiveRoomAfterRefresh(roomID: roomID)
                return
            }

            transientFailureAttempts = 0

            let fetchedRevision = refreshedRoom.roomRevision ?? refreshedRoom.lobbyRevision ?? 0
            if RoomPollPolicy.acceptsSnapshot(
                currentRoomRevision: activeRoom?.roomRevision,
                currentLobbyRevision: activeRoom?.lobbyRevision,
                fetchedRoomRevision: refreshedRoom.roomRevision,
                fetchedLobbyRevision: refreshedRoom.lobbyRevision
            ) {
                activeRoom = refreshedRoom
            }

            let newestRequiredRevision = max(
                requiredRevision,
                pendingGameRoomRealtimeRevision
            )
            guard fetchedRevision < newestRequiredRevision else {
                pendingGameRoomRealtimeRevision = 0
                return
            }

            pendingGameRoomRealtimeRevision = newestRequiredRevision
            staleReadAttempts += 1
            // A malicious or corrupted future revision must not cause an HTTP
            // storm. Keep it parked and let the regular poll remain the
            // correctness fallback after three stale reads.
            guard staleReadAttempts < 3 else { return }
            do {
                try await Task.sleep(for: .milliseconds(140 * staleReadAttempts))
            } catch {
                return
            }
        }
    }

    func openCommunity() {
        pendingNotificationRoute = nil
        presentedSheet = nil
        notificationFocusItemID = nil
        shellRoute = .community
    }

    func closeCommunity() {
        shellRoute = .main
    }

    func openNotifications(
        scope: NotificationInboxScope = .global,
        itemID: String? = nil
    ) {
        pendingNotificationRoute = nil
        presentedSheet = nil
        notificationInbox.selectScope(scope)
        notificationFocusItemID = itemID?.nilIfBlank.map { value in
            value.contains(":") ? value : "\(scope.rawValue):\(value)"
        }
        notificationFocusRequestID &+= 1
        shellRoute = .notifications
    }

    func openMainTab(_ tab: AppTab) {
        pendingNotificationRoute = nil
        presentedSheet = nil
        notificationFocusItemID = nil
        shellRoute = .main
        if tab == .home {
            isHomeLandingPresentationRequested = false
        }
        selectedTab = tab
    }

    func dismissHomeLandingPresentation() {
        isHomeLandingPresentationRequested = false
    }

    private func refreshNotificationInboxAfterPush() {
        guard user != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.notificationInbox.refreshSummary()
            if self.shellRoute == .notifications {
                await self.notificationInbox.refresh(
                    scope: self.notificationInbox.selectedScope
                )
            }
        }
    }

    func setRadarApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        radarNearby.setApplicationActive(isActive)
        if isActive {
            gameRoomRealtime.resume()
        }
    }

    func markWordPacksChanged() {
        wordPacksRevision &+= 1
    }

    @discardableResult
    func acceptRadarInvitation() async -> Bool {
        guard let invitation = radarNearby.incomingInvitation else { return false }

        if let activeRoom,
           activeRoom.code.caseInsensitiveCompare(invitation.roomCode) == .orderedSame {
            await radarNearby.acceptIncomingInvitation()
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
            return true
        }

        let joined = await joinRoom(code: invitation.roomCode)
        if joined {
            await radarNearby.acceptIncomingInvitation()
        }
        return joined
    }

    func declineRadarInvitation() {
        radarNearby.declineIncomingInvitation()
        HapticManager.shared.fire(.buttonPress)
    }

    private func handleAutomaticRadarInvitation(_ invitation: RadarIncomingInvitation) {
        guard !requiresOnboarding else { return }

        if let activeRoom,
           activeRoom.code.caseInsensitiveCompare(invitation.roomCode) != .orderedSame {
            // Never replace an active session without explicit confirmation,
            // even when the user opted into automatic nearby joins.
            radarNearby.presentForConfirmation(invitation)
            return
        }

        guard activeRoom == nil else { return }
        Task {
            let joined = await joinRoom(code: invitation.roomCode)
            if joined {
                await radarNearby.acceptIncomingInvitation()
            } else {
                radarNearby.presentForConfirmation(invitation)
            }
        }
    }

    @discardableResult
    func joinRoom(code rawCode: String) async -> Bool {
        guard let user else {
            pendingJoinCode = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            deepLinkStatus = language.auth.signInToJoin(pendingJoinCode)
            authPhase = .email
            return false
        }

        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            return false
        }

        do {
            let room = try await joinRoomSnapshotForExplicitActivation(
                code: code,
                user: user
            )
            try confirmExplicitRoomActivation(room)
            activeRoom = room
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
            pendingJoinCode = nil
            deepLinkStatus = language.home.roomReady(code)
            HapticManager.shared.fire(.milestone)
            return true
        } catch {
            if let base44Error = error as? Base44Error,
               base44Error.isClientUpdateRequired {
                deepLinkStatus = switch language {
                case .en: "UPDATE SPYCLASH TO JOIN THIS MULTI-SPY ROOM"
                case .es: "ACTUALIZA SPYCLASH PARA ENTRAR EN ESTA SALA MULTIESPIA"
                case .ru: "ОБНОВИ SPYCLASH, ЧТОБЫ ВОЙТИ В КОМНАТУ С НЕСКОЛЬКИМИ ШПИОНАМИ"
                case .uk: "ОНОВИ SPYCLASH, ЩОБ УВІЙТИ ДО КІМНАТИ З КІЛЬКОМА ШПИГУНАМИ"
                }
            } else {
                deepLinkStatus = error.localizedDescription.uppercased()
            }
            HapticManager.shared.fire(.notification(.error))
            return false
        }
    }

    func handleIncomingURL(_ url: URL) {
        if let route = SpyClashCustomRoute.parse(url) {
            switch route {
            case .notifications(let scope, let itemID):
                if user == nil || isAuthTransitionActive {
                    deferNotificationRoute(
                        .notifications(
                            scope: scope,
                            itemID: itemID
                        )
                    )
                } else {
                    openNotifications(scope: scope, itemID: itemID)
                }
            case .community:
                if user == nil || isAuthTransitionActive {
                    deferNotificationRoute(.communityRequests)
                } else {
                    openCommunity()
                }
            case .match(let roomID):
                queueMatchRoute(roomID: roomID)
            case .join(let code):
                pendingJoinCode = code
                deepLinkStatus = language.welcome.inviteArmed(code)
                if user == nil {
                    authPhase = .email
                } else {
                    Task { await consumePendingJoinIfPossible() }
                }
            case .resetPassword(let token):
                authPhase = .resetPassword(token: token)
                authError = nil
                authNotice = language.auth.chooseNewPassphraseNotice
                presentedSheet = nil
            case .authenticationCallback, .unsupported:
                break
            }
            return
        }

        if let token = ResetPasswordLinkParser.tokenIfPresent(from: url.absoluteString) {
            authPhase = .resetPassword(token: token)
            authError = nil
            authNotice = language.auth.chooseNewPassphraseNotice
            presentedSheet = nil
            return
        }

        guard let code = SpyLinkParser.roomCodeIfPresent(from: url.absoluteString) else {
            return
        }

        pendingJoinCode = code
        deepLinkStatus = language.welcome.inviteArmed(code)

        guard user != nil else {
            authPhase = .email
            return
        }

        Task {
            await consumePendingJoinIfPossible()
        }
    }

    private func queueMatchRoute(roomID: String) {
        guard let normalizedRoomID = roomID.nilIfBlank else { return }
        pendingMatchRoomID = normalizedRoomID
        guard user != nil, !isRestoring else {
            if user == nil { requestAuthenticationPresentation() }
            return
        }
        Task { await consumePendingMatchRouteIfPossible() }
    }

    private func openMatchFromLiveActivity(roomID: String) async {
        guard let user else { return }

        if activeRoom?.id == roomID {
            clearPendingMatchRoute(ifMatching: roomID)
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
            return
        }

        do {
            guard let room = try await client.refreshRoom(id: roomID) else {
                clearPendingMatchRoute(ifMatching: roomID)
                return
            }
            try Task.checkCancellation()
            guard pendingMatchRoomID == roomID else { return }
            guard room.playersList.contains(where: {
                $0.email.compare(user.email, options: .caseInsensitive) == .orderedSame
            }) else {
                clearPendingMatchRoute(ifMatching: roomID)
                return
            }
            clearPendingMatchRoute(ifMatching: roomID)
            activeRoom = room
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
        } catch is CancellationError {
            return
        } catch {
            guard pendingMatchRoomID == roomID else { return }
            deepLinkStatus = error.localizedDescription.uppercased()
        }
    }

    private func clearPendingMatchRoute(ifMatching roomID: String) {
        guard pendingMatchRoomID == roomID else { return }
        pendingMatchRoomID = nil
    }

    private func handleNotificationRoute(_ route: SpyNotificationRoute) {
        switch route {
        case .room(let code):
            pendingJoinCode = code
            deepLinkStatus = language.welcome.inviteArmed(code)
            if user == nil {
                authPhase = .email
            } else {
                Task { await consumePendingJoinIfPossible() }
            }
        case .url(let url):
            // URL routing owns its own auth/onboarding deferral so password
            // reset callbacks are never trapped behind an authenticated gate.
            handleIncomingURL(url)
        case .communityRequests, .activeGame, .notifications:
            guard user != nil, !isAuthTransitionActive else {
                deferNotificationRoute(route)
                return
            }

            switch route {
            case .communityRequests:
                openCommunity()
            case .activeGame:
                if activeRoom != nil {
                    pendingNotificationRoute = nil
                    selectedTab = .game
                    shellRoute = .main
                    presentedSheet = nil
                } else {
                    deferNotificationRoute(route)
                }
            case .notifications(let scope, let itemID):
                openNotifications(scope: scope ?? .global, itemID: itemID)
            case .room, .url:
                break
            }
        }
    }

    private func deferNotificationRoute(_ route: SpyNotificationRoute) {
        activeRoomActivationRefreshTask?.cancel()
        activeRoomActivationRefreshTask = nil
        pendingNotificationRoute = route
        guard user != nil else {
            requestAuthenticationPresentation()
            return
        }

        if authHomeRevealPhase == .revealing {
            restartAuthHomeRevealForPendingRoute()
        } else if authHomeRevealPhase == .idle,
                  !requiresOnboarding,
                  case .activeGame = route {
            restartAuthHomeRevealForPendingRoute()
        }
    }

    private func preparePendingShellRouteForReveal() async {
        guard user != nil,
              !requiresOnboarding,
              authHomeRevealPhase == .covered,
              pendingNotificationRoute != nil else { return }

        var activeRoomOutcome: ActiveRoomRestoreOutcome?
        var attemptedActiveGameGeneration: UInt64?
        if case .activeGame? = pendingNotificationRoute,
           activeRoom == nil {
            attemptedActiveGameGeneration = pendingNotificationRouteGeneration
            activeRoomOutcome = await restoreActiveRoomIfPossible(selectGame: false)
        }

        guard user != nil,
              !requiresOnboarding,
              authHomeRevealPhase == .covered,
              let route = pendingNotificationRoute else { return }

        switch route {
        case .communityRequests:
            pendingNotificationRoute = nil
            openCommunity()
        case .notifications(let scope, let itemID):
            pendingNotificationRoute = nil
            openNotifications(scope: scope ?? .global, itemID: itemID)
        case .activeGame:
            guard activeRoom != nil else {
                guard attemptedActiveGameGeneration == pendingNotificationRouteGeneration else {
                    return
                }
                if activeRoomOutcome == .noActiveRoom {
                    pendingNotificationRoute = nil
                } else if activeRoomOutcome == .retryLater {
                    deferredActiveGameRetryGeneration = pendingNotificationRouteGeneration
                }
                return
            }
            pendingNotificationRoute = nil
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
        case .room, .url:
            return
        }
    }

    private func prepareLatestPendingShellRouteForReveal() async {
        var attempts = 0
        while user != nil,
              !requiresOnboarding,
              authHomeRevealPhase == .covered,
              pendingNotificationRoute != nil,
              deferredActiveGameRetryGeneration
                != pendingNotificationRouteGeneration,
              attempts < 3 {
            let attemptedGeneration = pendingNotificationRouteGeneration
            attempts += 1
            await preparePendingShellRouteForReveal()

            if pendingNotificationRoute == nil
                || deferredActiveGameRetryGeneration
                    == pendingNotificationRouteGeneration
                || attemptedGeneration == pendingNotificationRouteGeneration {
                return
            }
        }

        if attempts == 3,
           case .activeGame? = pendingNotificationRoute,
           activeRoom == nil {
            // A burst of replacement game events must not create an unbounded
            // network loop under the curtain. Preserve the latest intent for a
            // future activation instead of revealing Home and retrying visibly.
            deferredActiveGameRetryGeneration = pendingNotificationRouteGeneration
        }
    }

    private func animateAuthHomeRevealToIdle() async -> Bool {
        let animationID = UUID()
        authHomeRevealAnimationID = animationID
        authHomeRevealPhase = .revealing

        do {
            try await Task.sleep(for: .milliseconds(860))
        } catch {
            if authHomeRevealAnimationID == animationID {
                authHomeRevealAnimationID = nil
                authHomeRevealPhase = .idle
            }
            return false
        }

        guard authHomeRevealAnimationID == animationID else { return false }
        authHomeRevealAnimationID = nil
        authHomeRevealPhase = .idle
        return true
    }

    private func restartAuthHomeRevealForPendingRoute() {
        guard user != nil,
              !requiresOnboarding,
              authHomeRevealPhase == .idle || authHomeRevealPhase == .revealing else {
            return
        }

        authHomeRevealRestartTask?.cancel()
        authHomeRevealAnimationID = nil
        authHomeRevealPhase = .covered

        let restartID = UUID()
        authHomeRevealRestartID = restartID
        authHomeRevealRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard self.authHomeRevealRestartID == restartID,
                  self.user != nil else { return }

            await self.prepareLatestPendingShellRouteForReveal()

            do {
                try await Task.sleep(for: .milliseconds(260))
            } catch {
                return
            }
            guard self.authHomeRevealRestartID == restartID,
                  self.user != nil else { return }

            // A second route may arrive while the new destination is mounting.
            // Resolve the latest route once more before the single visible fade.
            await self.prepareLatestPendingShellRouteForReveal()
            let didReveal = await self.animateAuthHomeRevealToIdle()
            guard self.authHomeRevealRestartID == restartID else { return }

            self.authHomeRevealRestartTask = nil
            self.authHomeRevealRestartID = nil
            if didReveal {
                await self.consumePendingRoutesIfPossible()
            }
        }
    }

    @discardableResult
    func consumePendingJoinIfPossible() async -> Bool {
        guard user != nil,
              !isAuthTransitionActive,
              let code = pendingJoinCode else {
            return false
        }

        isJoiningDeepLink = true
        defer { isJoiningDeepLink = false }
        return await joinRoom(code: code)
    }

    func consumePendingRoutesIfPossible() async {
        guard user != nil,
              !isAuthTransitionActive,
              !isConsumingPendingRoutes else { return }
        isConsumingPendingRoutes = true
        defer { isConsumingPendingRoutes = false }

        authPresentationRequestID = 0
        if case .activeGame? = pendingNotificationRoute,
           activeRoom == nil {
            if deferredActiveGameRetryGeneration
                != pendingNotificationRouteGeneration {
                // Own the async lookup from an unstructured, generation-guarded
                // task. RootView's transition-keyed task is cancelled as soon as
                // the curtain is raised and therefore must not own this work.
                restartAuthHomeRevealForPendingRoute()
                return
            }
        } else if let route = pendingNotificationRoute {
            pendingNotificationRoute = nil
            handleNotificationRoute(route)
        }
        _ = await consumePendingJoinIfPossible()
        await consumePendingMatchRouteIfPossible()
    }

    private func requestAuthenticationPresentation() {
        authPhase = .email
        authPresentationRequestID &+= 1
    }

    private func consumePendingMatchRouteIfPossible() async {
        guard user != nil,
              !isRestoring,
              !isAuthTransitionActive,
              !isOpeningPendingMatch,
              pendingMatchRoomID != nil else {
            return
        }
        isOpeningPendingMatch = true
        defer { isOpeningPendingMatch = false }

        while !Task.isCancelled, let roomID = pendingMatchRoomID {
            await openMatchFromLiveActivity(roomID: roomID)
            if pendingMatchRoomID == roomID { return }
        }
    }

    private func performAuth(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        authError = nil
        authNotice = nil
        defer { isBusy = false }

        do {
            try await operation()
        } catch {
            authError = error.localizedDescription
            HapticManager.shared.fire(.notification(.error))
        }
    }

    private func startPostAuthActiveRoomRestoreIfNeeded() {
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        guard let userID = user?.id,
              client.hasSessionToken else { return }

        postAuthActiveRoomRestoreTask?.cancel()
        postAuthActiveRoomRestoreUserID = userID
        postAuthActiveRoomRestoreTask = Task { @MainActor [weak self] in
            guard let self,
                  self.user?.id == userID else { return }
            _ = await self.restoreActiveRoomIfPossible()
        }
    }

    private func waitForPostAuthActiveRoomRestoreIfNeeded() async {
        guard let task = postAuthActiveRoomRestoreTask,
              let userID = postAuthActiveRoomRestoreUserID,
              user?.id == userID else { return }

        await task.value
        guard postAuthActiveRoomRestoreUserID == userID else { return }
        postAuthActiveRoomRestoreTask = nil
        postAuthActiveRoomRestoreUserID = nil
    }

    @discardableResult
    private func restoreActiveRoomIfPossible(
        selectGame: Bool = true
    ) async -> ActiveRoomRestoreOutcome {
        guard let user else { return .retryLater }
        let expectedUserID = user.id
        let storedRoomID = UserDefaults.standard
            .string(forKey: Self.activeRoomIDStorageKey)?
            .nilIfBlank

        var room: GameRoom?
        if let storedRoomID {
            do {
                room = try await client.refreshRoom(id: storedRoomID)
            } catch is CancellationError {
                return .retryLater
            } catch {
                // The bounded active-room lookup below remains the recovery
                // path when a stale preferred room can no longer be fetched.
                room = nil
            }
            guard !Task.isCancelled,
                  self.user?.id == expectedUserID else { return .retryLater }
        }
        let activeStatuses: Set<String> = [
            "waiting",
            "ready_voting",
            "roulette",
            "playing"
        ]
        let preferredRoomIsUsable = room.map {
            activeStatuses.contains($0.normalizedStatus)
                && !isDismissedRoom($0.id)
                && $0.containsPlayer(email: user.email)
        } ?? false
        if !preferredRoomIsUsable {
            // The backend keeps this lookup bounded to the preferred id, host
            // query, and the authenticated participant index. Never enumerate
            // rooms from the client when moving an account between Web and iOS.
            do {
                room = try await client.activeRoom(preferredRoomID: storedRoomID)
            } catch {
                return .retryLater
            }
            guard !Task.isCancelled,
                  self.user?.id == expectedUserID else { return .retryLater }
        }

        guard var room,
              !isDismissedRoom(room.id),
              activeStatuses.contains(room.normalizedStatus),
              room.containsPlayer(email: user.email) else {
            if storedRoomID != nil {
                clearStoredActiveRoom()
            }
            return .noActiveRoom
        }

        if room.normalizedStatus == "waiting" {
            do {
                room = try await client.resumeWaitingRoom(room, user: user)
            } catch {
                // Waiting-room mutations must not be enabled from a stale
                // player record that predates this client's capability token.
                return .retryLater
            }
            guard !Task.isCancelled,
                  self.user?.id == expectedUserID else { return .retryLater }
        }

        activeRoom = room
        if selectGame {
            selectedTab = .game
        }
        return .restored
    }

    private func synchronizeLiveActivitiesForAccountChange(previousUserID: String?) {
#if DEBUG
        guard !isUIPreviewMode else { return }
#endif
        if previousUserID != nil, let expectedUserID = user?.id {
            // An Activity may still contain the previous account's private role/word.
            // Tear it down before observing or projecting state for the replacement account.
            liveActivitySyncTask?.cancel()
            cancelLiveActivityPushTokenObservers()
            cancelLiveActivityStateObservers()
            cancelLiveActivityPushToStartTokenObserver()
            cancelLiveActivityLifecycleObserver()
            liveActivitySyncTask = Task { @MainActor [weak self] in
                await SpyClashMatchLiveActivityController.shared.endAll()
                guard let self, self.user?.id == expectedUserID else { return }
                self.observeLiveActivityLifecycleIfNeeded()
                self.observeLiveActivityPushToStartTokenIfNeeded()
                guard !self.isRestoring else { return }
                self.synchronizeMatchLiveActivity(previousRoom: nil, room: self.activeRoom)
            }
            return
        }

        guard user != nil else {
            liveActivitySyncTask?.cancel()
            // Cancel registration retries before the logout cleanup request can
            // race a late token write back into the previous account.
            cancelLiveActivityPushTokenObservers()
            cancelLiveActivityStateObservers()
            cancelLiveActivityPushToStartTokenObserver()
            cancelLiveActivityLifecycleObserver()
            liveActivitySyncTask = Task { @MainActor in
                await SpyClashMatchLiveActivityController.shared.endAll()
            }
            return
        }

        observeLiveActivityLifecycleIfNeeded()
        observeLiveActivityPushToStartTokenIfNeeded()
        guard !isRestoring else { return }
        synchronizeMatchLiveActivity(previousRoom: nil, room: activeRoom)
    }

    private func synchronizeMatchLiveActivity(
        previousRoom: GameRoom?,
        room: GameRoom?
    ) {
#if DEBUG
        guard !isUIPreviewMode else { return }
#endif
        guard !isRestoring else { return }
        let viewer = user
        let displayLanguage = language
        liveActivitySyncTask?.cancel()
        liveActivitySyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let controller = SpyClashMatchLiveActivityController.shared

            if let previousRoom,
               room?.id != previousRoom.id {
                await controller.endAll()
                cancelLiveActivityPushTokenObservers()
            }

            let previousMatchID = previousRoom?.matchID?.nilIfBlank
            let currentMatchID = room?.matchID?.nilIfBlank
            if let previousRoom,
               previousRoom.id == room?.id,
               previousMatchID != currentMatchID {
                if let previousMatchID,
                   let activityID = controller.activityID(matchID: previousMatchID) {
                    PushNotificationCoordinator.shared.cancelPendingLiveActivityRegistration(
                        tokenKind: .activity,
                        activityID: activityID,
                        matchID: previousMatchID
                    )
                    await PushNotificationCoordinator.shared.unregisterLiveActivityToken(
                        tokenKind: .activity,
                        activityID: activityID,
                        matchID: previousMatchID
                    )
                    liveActivityPushTokenTasks.removeValue(forKey: activityID)?.cancel()
                }
                await controller.endActivities(
                    roomID: previousRoom.id,
                    excludingMatchID: currentMatchID
                )
            }

            guard !Task.isCancelled,
                  let room,
                  let viewer,
                  let projection = room.liveActivityProjection(
                    for: viewer,
                    displayLanguage: displayLanguage
                  ) else {
                if room == nil {
                    await controller.endAll()
                    cancelLiveActivityPushTokenObservers()
                }
                return
            }

            if projection.state.phase == .completed {
                if let activityID = controller.activityID(matchID: projection.attributes.matchID) {
                    PushNotificationCoordinator.shared.cancelPendingLiveActivityRegistration(
                        tokenKind: .activity,
                        activityID: activityID,
                        matchID: projection.attributes.matchID
                    )
                    await PushNotificationCoordinator.shared.unregisterLiveActivityToken(
                        tokenKind: .activity,
                        activityID: activityID,
                        matchID: projection.attributes.matchID
                    )
                    liveActivityPushTokenTasks.removeValue(forKey: activityID)?.cancel()
                }
                try? await controller.end(
                    matchID: projection.attributes.matchID,
                    finalState: projection.state
                )
                return
            }

            do {
                await controller.endActivities(
                    roomID: projection.attributes.roomID,
                    excludingMatchID: projection.attributes.matchID
                )
                if #available(iOS 17.2, *) {
                    // Push-to-start is the sole creation authority. A local
                    // fallback can race a delayed APNs start and create two
                    // Activities for the same personalized match.
                    if let activityID = try await controller.updateIfPresent(
                        attributes: projection.attributes,
                        state: projection.state
                    ) {
                        await reconcileAndObserveLiveActivity(activityID: activityID)
                    }
                } else {
                    let activityID = try await controller.startOrUpdate(
                        attributes: projection.attributes,
                        initialState: projection.state,
                        receivesPushUpdates: true
                    )
                    await reconcileAndObserveLiveActivity(activityID: activityID)
                }
            } catch {
#if DEBUG
                print("Live Activity synchronization failed: \(error.localizedDescription)")
#endif
            }
        }
    }

    private func cancelLiveActivityPushTokenObservers() {
        for task in liveActivityPushTokenTasks.values {
            task.cancel()
        }
        liveActivityPushTokenTasks.removeAll()
    }

    private func cancelLiveActivityStateObservers() {
        for task in liveActivityStateTasks.values {
            task.cancel()
        }
        liveActivityStateTasks.removeAll()
    }

    private func observeLiveActivityLifecycleIfNeeded() {
        guard liveActivityLifecycleTask == nil else { return }
        liveActivityLifecycleTask = SpyClashMatchLiveActivityController.shared
            .observeActivityUpdates { [weak self] activityID in
                guard let self else { return }
                await self.reconcileAndObserveLiveActivity(activityID: activityID)
            }
    }

    private func reconcileAndObserveLiveActivity(activityID: String) async {
        let controller = SpyClashMatchLiveActivityController.shared
        let duplicates = await controller.reconcileDuplicateActivities()
        for duplicate in duplicates {
            await retireLiveActivity(
                duplicate,
                cancelStateObserver: true
            )
        }

        guard controller.activityDescriptor(activityID: activityID) != nil else {
            return
        }
        observeLiveActivityStateIfNeeded(activityID: activityID)
        observeLiveActivityPushTokensIfNeeded(activityID: activityID)
    }

    private func observeLiveActivityStateIfNeeded(activityID: String) {
        guard liveActivityStateTasks[activityID] == nil else { return }
        do {
            liveActivityStateTasks[activityID] = try SpyClashMatchLiveActivityController.shared
                .observeActivityState(activityID: activityID) { [weak self] update in
                    guard update.state.isTerminal, let self else { return }
                    await self.retireLiveActivity(
                        update.activity,
                        cancelStateObserver: false
                    )
                }
        } catch {
#if DEBUG
            print("Live Activity state observation failed: \(error.localizedDescription)")
#endif
        }
    }

    private func retireLiveActivity(
        _ activity: SpyClashMatchLiveActivityController.ActivityDescriptor,
        cancelStateObserver: Bool
    ) async {
        liveActivityPushTokenTasks.removeValue(forKey: activity.activityID)?.cancel()
        if cancelStateObserver {
            liveActivityStateTasks.removeValue(forKey: activity.activityID)?.cancel()
        } else {
            // This callback runs inside the state observer. Removing without
            // cancelling lets the exact unregister request finish first.
            _ = liveActivityStateTasks.removeValue(forKey: activity.activityID)
        }
        PushNotificationCoordinator.shared.cancelPendingLiveActivityRegistration(
            tokenKind: .activity,
            activityID: activity.activityID,
            matchID: activity.matchID
        )
        await PushNotificationCoordinator.shared.unregisterLiveActivityToken(
            tokenKind: .activity,
            activityID: activity.activityID,
            matchID: activity.matchID
        )
    }

    private func observeLiveActivityPushTokensIfNeeded(activityID: String) {
        guard liveActivityPushTokenTasks[activityID] == nil else { return }
        do {
            liveActivityPushTokenTasks[activityID] = try SpyClashMatchLiveActivityController.shared
                .observePushTokens(activityID: activityID) { registration in
                    await PushNotificationCoordinator.shared.registerLiveActivityToken(
                        token: registration.token,
                        tokenKind: .activity,
                        activityID: registration.activityID,
                        roomID: registration.roomID,
                        matchID: registration.matchID
                    )
                }
        } catch {
#if DEBUG
            print("Live Activity token observation failed: \(error.localizedDescription)")
#endif
        }
    }

    private func observeLiveActivityPushToStartTokenIfNeeded() {
        guard liveActivityPushToStartTokenTask == nil else { return }
        if #available(iOS 17.2, *) {
            liveActivityPushToStartTokenTask = SpyClashMatchLiveActivityController.shared
                .observePushToStartTokens { token in
                    await PushNotificationCoordinator.shared.registerLiveActivityToken(
                        token: token,
                        tokenKind: .pushToStart
                    )
                }
        }
    }

    private func cancelLiveActivityPushToStartTokenObserver() {
        liveActivityPushToStartTokenTask?.cancel()
        liveActivityPushToStartTokenTask = nil
    }

    private func cancelLiveActivityLifecycleObserver() {
        liveActivityLifecycleTask?.cancel()
        liveActivityLifecycleTask = nil
    }


    private func persistActiveRoomReference(_ room: GameRoom?) {
#if DEBUG
        guard !isUIPreviewMode else { return }
#endif

        if let room {
            UserDefaults.standard.set(room.id, forKey: Self.activeRoomIDStorageKey)
        } else {
            clearStoredActiveRoom()
        }
    }

    private func clearStoredActiveRoom() {
        UserDefaults.standard.removeObject(forKey: Self.activeRoomIDStorageKey)
    }

#if DEBUG
    private func installPreviewRadarFailureIfRequested() {
        guard isUIPreviewMode,
              ProcessInfo.processInfo.arguments.contains(
                  "--spyclash-preview-radar-unavailable"
              ) else { return }
        radarNearby.installPreviewScanFailure()
    }

    private func activateUIPreviewModeIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--spyclash-ui-preview") else {
            return false
        }

        isUIPreviewMode = true
        let directPreviewValue = previewArgumentValue(
            prefix: "--spyclash-preview-direct=",
            in: arguments
        )
        let shouldPreviewOnboarding = arguments.contains("--spyclash-preview-onboarding")
            || directPreviewValue.map {
                ["onboarding", "on-board", "setup"].contains($0)
            } == true
        if shouldPreviewOnboarding {
            OnboardingProgressStore.clear(for: "debug-ui-preview-user")
        }
        user = SpyUser(
            id: "debug-ui-preview-user",
            email: "operative.preview@spyclash.local",
            fullName: "Preview Operative",
            displayName: "Red Raven",
            avatar: "🕵️",
            language: nil,
            onboardingCompleted: shouldPreviewOnboarding ? nil : true,
            onboardingVersion: shouldPreviewOnboarding
                ? nil
                : OnboardingSubmission.currentVersion,
            onboardingCompletedAt: shouldPreviewOnboarding
                ? nil
                : ISO8601DateFormatter().string(from: Date()),
            acquisitionSource: shouldPreviewOnboarding ? nil : "other",
            role: arguments.contains("--spyclash-preview-admin") ? "admin" : "user",
            isVerified: true,
            rating: 1240,
            gamesPlayed: 42,
            gamesWon: 25,
            remoteSpyID: "350-911",
            spyCardTheme: "field",
            spyCardAccent: "signal_red",
            spyCardBadge: "operative",
            radarInvitePolicy: nil
        )
        let requestedTab = previewTab(from: arguments) ?? .home
        let shouldPreviewActiveRoom = requestedTab == .game || arguments.contains("--spyclash-preview-active-room")
        selectedTab = requestedTab
        language = previewLanguage(from: arguments) ?? AppLanguage.stored
        let previewPlayerCount = previewArgumentValue(
            prefix: "--spyclash-preview-player-count=",
            in: arguments
        ).flatMap(Int.init)
        activeRoom = shouldPreviewActiveRoom
            ? GameRoom.previewRoom(
                status: previewArgumentValue(prefix: "--spyclash-preview-room=", in: arguments) ?? "waiting",
                playerCount: previewPlayerCount ?? 3
            )
            : nil
        if var previewRoom = activeRoom,
           let previewDurationMinutes = previewArgumentValue(
               prefix: "--spyclash-preview-duration-minutes=",
               in: arguments
           ).flatMap(Int.init) {
            previewRoom.gameDurationSeconds = min(max(previewDurationMinutes, 5), 15) * 60
            activeRoom = previewRoom
        }
        if var previewRoom = activeRoom,
           arguments.contains("--spyclash-preview-vote-cancellation") {
            previewRoom.detectiveVoteCancellationEventID = "preview-vote-cancellation"
            previewRoom.detectiveVoteCancellationRoundID = "preview-vote-round"
            previewRoom.detectiveVoteCancellationPresentAt = ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(1)
            )
            previewRoom.detectiveVoteCancellationReason = DetectiveVoteCancellationEvent.supportedReason
            activeRoom = previewRoom
        }
        roomSyncOperation = previewRoomSyncOperation(from: arguments)
        pendingJoinCode = nil
        deepLinkStatus = nil
        isJoiningDeepLink = false
        isBusy = false
        isRestoring = false
        shellRoute = .main

        switch previewArgumentValue(prefix: "--spyclash-preview-sheet=", in: arguments) {
        case "privacy", "privacyPolicy", "privacy-policy":
            presentedSheet = .legal(.privacy)
        case "terms", "termsOfService", "terms-of-service":
            presentedSheet = .legal(.terms)
        case "roomQR", "room-qr", "qr":
            presentedSheet = .roomQR(activeRoom ?? GameRoom.previewRoom(status: "waiting"))
        case "scanner", "qrScanner", "qr-scanner":
            presentedSheet = .qrScanner
        case "community":
            presentedSheet = nil
            shellRoute = .community
        case "notifications", "inbox":
            presentedSheet = nil
            notificationInbox.installPreview(accountID: user?.id ?? "debug-ui-preview-user")
            shellRoute = .notifications
        default:
            presentedSheet = nil
        }

        if arguments.contains("--spyclash-preview-radar-invite") {
            radarNearby.presentForConfirmation(
                RadarIncomingInvitation(
                    roomCode: "R7VN87",
                    hostCallSign: "Night Fox",
                    hostAvatar: "🥷",
                    hostSpyID: "350-911",
                    hostSpyCardTheme: .dossier,
                    hostSpyCardAccent: .clearanceAmber,
                    hostSpyCardBadge: .ghost,
                    hostRating: 1_240,
                    hostGamesPlayed: 42,
                    hostWinRate: 60
                )
            )
        }

        if arguments.contains("--spyclash-preview-radar-peers") {
            radarNearby.installPreviewRangingPeers()
        }

        if arguments.contains("--spyclash-preview-toasts") {
            let previewToastCopy = switch language {
            case .en:
                ("PROFILE SAVED", "CHECK CONNECTION", "SYNC FAILED")
            case .es:
                ("PERFIL GUARDADO", "REVISA LA CONEXIÓN", "ERROR DE SINCRONIZACIÓN")
            case .ru:
                ("ПРОФИЛЬ СОХРАНЁН", "ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ", "НЕ УДАЛОСЬ СИНХРОНИЗИРОВАТЬ")
            case .uk:
                ("ПРОФІЛЬ ЗБЕРЕЖЕНО", "ПЕРЕВІРТЕ З’ЄДНАННЯ", "НЕ ВДАЛОСЯ СИНХРОНІЗУВАТИ")
            }
            showToast(
                previewToastCopy.0,
                kind: .success,
                duration: .seconds(10)
            )
            showToast(
                previewToastCopy.1,
                kind: .warning,
                duration: .seconds(10)
            )
            showToast(
                previewToastCopy.2,
                kind: .error,
                duration: .seconds(10)
            )
        }

        if arguments.contains("--spyclash-preview-room-presence-events") {
            scheduleToastPreviewIfRequested(roomID: activeRoom?.id)
        }

        if arguments.contains("--spyclash-live-activity-preview") {
            startLiveActivityPreview(
                mode: previewArgumentValue(
                    prefix: "--spyclash-live-activity-mode=",
                    in: arguments
                )
            )
        }

        return true
    }

    private func startLiveActivityPreview(mode rawMode: String?) {
        Task { @MainActor in
            let controller = SpyClashMatchLiveActivityController.shared
            await controller.endAll()

            let viewerID = "preview-red-raven"
            let mode: SpyClashMatchActivityAttributes.MatchMode = rawMode == "associations"
                ? .associations
                : .questions
            let publicTopic = switch language {
            case .en: "SECRET AGENT"
            case .es: "AGENTE SECRETO"
            case .ru: "ТАЙНЫЙ АГЕНТ"
            case .uk: "ТАЄМНИЙ АГЕНТ"
            }
            let participants = [
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-field-agent",
                    displayName: "Field Agent",
                    avatarSymbol: "🕵️"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-night-fox",
                    displayName: "Night Fox",
                    avatarSymbol: "🥷"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: viewerID,
                    displayName: "Red Raven",
                    avatarSymbol: "🕵️‍♂️"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-specter",
                    displayName: "Specter",
                    avatarSymbol: "🤖"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-silent-key",
                    displayName: "Silent Key",
                    avatarSymbol: "🕵️"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-shadow",
                    displayName: "Shadow",
                    avatarSymbol: "🥷"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-cipher",
                    displayName: "Cipher",
                    avatarSymbol: "🎭"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-crimson-owl",
                    displayName: "Crimson Owl",
                    avatarSymbol: "🦉"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-sable",
                    displayName: "Sable",
                    avatarSymbol: "🦊"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-orbit",
                    displayName: "Orbit",
                    avatarSymbol: "🛰️"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-velvet",
                    displayName: "Velvet",
                    avatarSymbol: "🐈‍⬛"
                ),
                SpyClashMatchActivityAttributes.Participant(
                    id: "preview-last-speaker",
                    displayName: "Last Speaker",
                    avatarSymbol: "🦅"
                )
            ]
            let attributes = SpyClashMatchActivityAttributes(
                roomID: "preview-room",
                matchID: "preview-match-build-20-\(mode.rawValue)",
                viewerPlayerID: viewerID,
                startedAt: .now
            )
            let state = SpyClashMatchActivityAttributes.ContentState(
                phase: .playing,
                mode: mode,
                participants: participants,
                currentSpeakerID: "preview-last-speaker",
                currentAskerID: mode == .questions ? "preview-last-speaker" : nil,
                currentResponderID: mode == .questions ? viewerID : nil,
                round: 2,
                publicTopic: publicTopic,
                displayLanguageCode: language.rawValue,
                timerEndsAt: .now.addingTimeInterval(8 * 60),
                privateIntel: .init(
                    ownerPlayerID: viewerID,
                    role: .detective,
                    secretWord: "MUST NEVER LEAVE THE APP"
                ),
                revision: 20
            )

            do {
                _ = try await controller.startPreview(
                    attributes: attributes,
                    initialState: state
                )
            } catch {
                print("Live Activity preview failed: \(error.localizedDescription)")
            }
        }
    }

    private func previewTab(from arguments: [String]) -> AppTab? {
        guard let rawValue = previewArgumentValue(prefix: "--spyclash-preview-tab=", in: arguments) else {
            return nil
        }
        return AppTab(rawValue: rawValue)
    }

    private func previewRoomSyncOperation(from arguments: [String]) -> RoomSyncOperation? {
        switch previewArgumentValue(prefix: "--spyclash-preview-room-sync=", in: arguments) {
        case "create", "creating": .creatingRoom
        case "join", "joining": .joiningRoom
        case "close", "closing": .closingRoom
        case "leave", "leaving": .leavingRoom
        case "questions": .updatingMode(.questions)
        case "associations": .updatingMode(.associations)
        case "duration": .updatingDuration(minutes: 10)
        default: nil
        }
    }

    private func previewLanguage(from arguments: [String]) -> AppLanguage? {
        guard let rawValue = previewArgumentValue(prefix: "--spyclash-preview-lang=", in: arguments) else {
            return nil
        }
        return AppLanguage.normalized(rawValue)
    }

    private func previewArgumentValue(prefix: String, in arguments: [String]) -> String? {
        arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap(\.nilIfBlank)
    }
#endif

    private func reconcileLanguagePreference(with remoteLanguage: String?) {
        guard !AppLanguage.hasStoredPreference else {
            language = AppLanguage.stored
            return
        }

        language = AppLanguage.normalized(remoteLanguage)
        language.persist()
    }
}

extension AppState: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

enum AuthPhase: Equatable {
    case email
    case password(email: String)
    case registerEmail
    case registerPassword(email: String)
    case otp(email: String)
    case forgotPassword(email: String)
    case resetEmailSent(email: String)
    case resetPassword(token: String)

    var isRecoveryPresentation: Bool {
        switch self {
        case .forgotPassword, .resetEmailSent, .resetPassword:
            true
        default:
            false
        }
    }
}

enum RoomQRTarget: String, Hashable {
    case web
    case ios

    mutating func toggle() {
        self = self == .web ? .ios : .web
    }
}

struct RoomFriendsNavigationRequest: Equatable, Identifiable {
    let id: UUID
    let roomID: String
}

enum RoomFriendsNavigationPolicy {
    static func canOpen(
        sourceRoomID: String,
        activeRoomID: String,
        activeRoomStatus: String
    ) -> Bool {
        let sourceRoomID = cleaned(sourceRoomID)
        let activeRoomID = cleaned(activeRoomID)
        return !sourceRoomID.isEmpty
            && sourceRoomID == activeRoomID
            && normalized(activeRoomStatus) == "waiting"
    }

    static func makeRequest(
        sourceRoomID: String,
        activeRoomID: String,
        activeRoomStatus: String
    ) -> RoomFriendsNavigationRequest? {
        guard canOpen(
            sourceRoomID: sourceRoomID,
            activeRoomID: activeRoomID,
            activeRoomStatus: activeRoomStatus
        ) else { return nil }
        return RoomFriendsNavigationRequest(
            id: UUID(),
            roomID: cleaned(sourceRoomID)
        )
    }

    static func matches(
        _ request: RoomFriendsNavigationRequest,
        activeRoomID: String,
        activeRoomStatus: String
    ) -> Bool {
        canOpen(
            sourceRoomID: request.roomID,
            activeRoomID: activeRoomID,
            activeRoomStatus: activeRoomStatus
        )
    }

    static func shouldRetain(
        _ request: RoomFriendsNavigationRequest,
        activeRoomID: String?,
        activeRoomStatus: String?
    ) -> Bool {
        guard let activeRoomID, let activeRoomStatus else { return false }
        return matches(
            request,
            activeRoomID: activeRoomID,
            activeRoomStatus: activeRoomStatus
        )
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        cleaned(value).lowercased()
    }
}

enum AppShellRoute: String, Hashable {
    case main
    case community
    case notifications
}

enum AppSheet: Identifiable, Hashable {
    case qrScanner
    case roomQR(GameRoom)
    case legal(LegalSheetKind)

    var id: String {
        switch self {
        case .qrScanner:
            "qrScanner"
        case .roomQR(let room):
            "roomQR-\(room.id)"
        case .legal(let kind):
            "legal-\(kind.id)"
        }
    }
}

private extension URL {
    var queryItems: [String: String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { $0[$1.name] = $1.value } ?? [:]
    }
}

private enum ResetPasswordLinkParser {
    static func tokenIfPresent(from payload: String) -> String? {
        if let url = URL(string: payload),
           let token = token(from: url) {
            return token
        }
        return nil
    }

    private static func token(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let token = components.queryItems?.first(where: { ["token", "reset_token", "resetToken"].contains($0.name) })?.value?.nilIfBlank,
           isResetURL(url) {
            return token
        }

        guard let fragment = url.fragment else {
            return nil
        }

        let query = fragment.hasPrefix("?") ? String(fragment.dropFirst()) : fragment
        guard let token = URLComponents(string: "https://spyclash.local?\(query)")?
            .queryItems?
            .first(where: { ["token", "reset_token", "resetToken"].contains($0.name) })?
            .value?
            .nilIfBlank,
            isResetURL(url) || fragment.lowercased().contains("reset") else {
            return nil
        }

        return token
    }

    private static func isResetURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host.contains("reset") || path.contains("reset-password") || path.contains("reset")
    }
}
enum SpyClashRelease {
    static var headerVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let marketingVersion = info["CFBundleShortVersionString"] as? String,
              let buildVersion = info["CFBundleVersion"] as? String,
              let majorVersion = marketingVersion.split(separator: ".").first else {
            return ""
        }

        let formattedBuild = Int(buildVersion)
            .map { String(format: "%02d", $0) }
            ?? buildVersion
        return "\(majorVersion).\(formattedBuild)v"
    }
}
