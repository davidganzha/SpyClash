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

enum MembershipSyncState: Equatable {
    case unknown
    case refreshing
    case synced
    case unavailable(message: String)
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
        case (.creatingRoom, _): "CREATING ROOM"
        case (.joiningRoom, .ru): "ПОДКЛЮЧЕНИЕ К КОМНАТЕ"
        case (.joiningRoom, .es): "CONECTANDO A LA SALA"
        case (.joiningRoom, _): "JOINING ROOM"
        case (.closingRoom, .ru): "ЗАКРЫТИЕ КОМНАТЫ"
        case (.closingRoom, .es): "CERRANDO SALA"
        case (.closingRoom, _): "CLOSING ROOM"
        case (.leavingRoom, .ru): "ВЫХОД ИЗ КОМНАТЫ"
        case (.leavingRoom, .es): "SALIENDO DE LA SALA"
        case (.leavingRoom, _): "LEAVING ROOM"
        case (.updatingMode, .ru): "СИНХРОНИЗАЦИЯ РЕЖИМА"
        case (.updatingMode, .es): "SINCRONIZANDO MODO"
        case (.updatingMode, _): "SYNCING GAME MODE"
        case (.updatingDuration, .ru): "СИНХРОНИЗАЦИЯ ВРЕМЕНИ"
        case (.updatingDuration, .es): "SINCRONIZANDO TIEMPO"
        case (.updatingDuration, _): "SYNCING DURATION"
        }
    }

    func detail(for language: AppLanguage) -> String {
        switch self {
        case .creatingRoom:
            return switch language {
            case .ru: "Подготавливаем защищённую игровую сессию. Пожалуйста, подождите."
            case .es: "Preparando una sesion segura. Espera un momento."
            default: "Preparing a secure game session. Please wait."
            }
        case .joiningRoom:
            return switch language {
            case .ru: "Подключаемся и синхронизируем состояние комнаты. Пожалуйста, подождите."
            case .es: "Conectando y sincronizando el estado de la sala. Espera un momento."
            default: "Connecting and synchronizing room state. Please wait."
            }
        case .closingRoom:
            return switch language {
            case .ru: "Закрываем сессию для всех игроков. Пожалуйста, подождите."
            case .es: "Cerrando la sesion para todos los jugadores. Espera un momento."
            default: "Closing the session for every player. Please wait."
            }
        case .leavingRoom:
            return switch language {
            case .ru: "Синхронизируем выход из комнаты. Пожалуйста, подождите."
            case .es: "Sincronizando tu salida de la sala. Espera un momento."
            default: "Synchronizing your exit from the room. Please wait."
            }
        case .updatingMode(let mode):
            let modeTitle: String
            switch (mode, language) {
            case (.questions, .ru): modeTitle = "«Вопросы»"
            case (.associations, .ru): modeTitle = "«Ассоциации»"
            case (.questions, .es): modeTitle = "Preguntas"
            case (.associations, .es): modeTitle = "Asociaciones"
            case (.questions, _): modeTitle = "Questions"
            case (.associations, _): modeTitle = "Associations"
            }
            switch language {
            case .ru: return "Переключаем комнату на режим \(modeTitle). Пожалуйста, подождите."
            case .es: return "Cambiando la sala al modo \(modeTitle). Espera un momento."
            default: return "Switching the room to \(modeTitle) mode. Please wait."
            }
        case .updatingDuration(let minutes):
            return switch language {
            case .ru: "Устанавливаем длительность игры: \(minutes) мин. Пожалуйста, подождите."
            case .es: "Ajustando la duracion a \(minutes) min. Espera un momento."
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

@MainActor
@Observable
final class AppState: NSObject {
    let client: Base44Client
    /// Nil while CASADA is active so StoreKit is neither initialized nor
    /// observed in the full-access protocol.
    let storeKit: StoreKitManager?
    let membershipRealtime: MembershipRealtimeService
    let radarNearby: RadarNearbyService
    var user: SpyUser? {
        didSet {
            let previousUserID = oldValue?.id
            radarNearby.configure(user: user)
            radarNearby.setActiveRoom(activeRoom)
            guard previousUserID != user?.id else { return }
            // Account-scoped access belongs to exactly one SpyClash account.
            // Clear it synchronously before the replacement account renders.
            membership = nil
            membershipOwnerUserID = nil
            membershipSyncState = .unknown
            membershipExpiryTask?.cancel()
            membershipExpiryTask = nil
            storeKit?.accountDidChange()
            membershipRealtime.stop()
            if let user, let token = client.currentAccessToken {
                membershipRealtime.start(
                    appID: Base44Client.appID,
                    token: token,
                    userID: user.id
                )
            }
            PushNotificationCoordinator.shared.accountDidChange(
                isSignedIn: user != nil && client.hasSessionToken
            )
            synchronizeLiveActivitiesForAccountChange(previousUserID: previousUserID)
        }
    }
    var isRestoring = true
    var isBusy = false
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
    private(set) var membership: Membership?
    private(set) var membershipSyncState: MembershipSyncState = .unknown
    private(set) var fullAccessUnlockPresentationID: UUID?
    var selectedTab: AppTab = .home
    var shellRoute: AppShellRoute = .main
    var localSetupRequestID = 0
    var activeRoom: GameRoom? {
        didSet {
            if oldValue?.id != activeRoom?.id {
                roomConnectionState = .synced
            }
            persistActiveRoomReference(activeRoom)
            radarNearby.setActiveRoom(activeRoom)
            handleRoomPresenceChange(from: oldValue, to: activeRoom)
            synchronizeMatchLiveActivity(previousRoom: oldValue, room: activeRoom)
        }
    }
    var isShellChromeSuppressed = false
    private(set) var roomSyncOperation: RoomSyncOperation?
    private(set) var roomConnectionState: RoomConnectionState = .synced
    var presentedSheet: AppSheet?
    var roomQRTarget: RoomQRTarget = .web
    var language: AppLanguage = .stored {
        didSet {
            PushNotificationCoordinator.shared.updatePreferredLocale(language.rawValue)
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
    private var membershipOwnerUserID: String?
    @ObservationIgnored private var standardAuthTimelineTask: Task<Void, Never>?
    @ObservationIgnored private var standardAuthRunID: UUID?
    @ObservationIgnored private var membershipExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var accessActivationSyncTask: Task<Void, Never>?
    @ObservationIgnored private var activeRoomActivationRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var membershipRealtimeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivitySyncTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityPushTokenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var liveActivityStateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var liveActivityPushToStartTokenTask: Task<Void, Never>?
    @ObservationIgnored private var liveActivityLifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMatchRoomID: String?
    @ObservationIgnored private var isOpeningPendingMatch = false
    private static let activeRoomIDStorageKey = "spyclash.activeRoomID"

    override init() {
        let client = Base44Client()
        let radarNearby = RadarNearbyService()
        self.client = client
        self.storeKit = SpyClashRelease.isCasadaProtocolActive
            ? nil
            : StoreKitManager(client: client)
        self.membershipRealtime = MembershipRealtimeService()
        self.radarNearby = radarNearby
        super.init()

        storeKit?.onEntitlementChanged = { [weak self] in
            await self?.refreshSubscription()
        }
        membershipRealtime.onMembershipSignal = { [weak self] in
            self?.handleMembershipRealtimeSignal()
        }
        radarNearby.onAutomaticInvitation = { [weak self] invitation in
            self?.handleAutomaticRadarInvitation(invitation)
        }
        PushNotificationCoordinator.shared.configure(client: client) { [weak self] route in
            self?.handleNotificationRoute(route)
        }
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
        return true
    }

    func endRoomSync(_ operation: RoomSyncOperation) {
        guard roomSyncOperation == operation else { return }
        roomSyncOperation = nil
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
                do {
                    let refreshedRoom = try await client.refreshRoom(id: roomID)
                    guard !Task.isCancelled,
                          activeRoom?.id == roomID,
                          roomSyncOperation == nil else { return }

                    if let refreshedRoom {
                        activeRoom = refreshedRoom
                        if failureTracker.recordSuccess() {
                            markRoomSyncRecoveredIfNeeded()
                        }
                    } else {
                        closeActiveRoomAfterRefresh(roomID: roomID)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
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
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    func refreshActiveRoomOnActivation() {
#if DEBUG
        guard !shouldUsePreviewData else { return }
#endif
        guard user != nil, roomSyncOperation == nil else { return }

        let preferredRoomID = activeRoom?.id ?? UserDefaults.standard
            .string(forKey: Self.activeRoomIDStorageKey)?
            .nilIfBlank

        activeRoomActivationRefreshTask?.cancel()
        activeRoomActivationRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var refreshedRoom: GameRoom?
            if let preferredRoomID {
                refreshedRoom = try? await self.client.refreshRoom(id: preferredRoomID)
            }
            if refreshedRoom == nil || refreshedRoom?.normalizedStatus == "finished" {
                do {
                    refreshedRoom = try await self.client.activeRoom(preferredRoomID: preferredRoomID)
                } catch {
                    // A network failure is not evidence that the room closed.
                    // The existing monitor will continue its bounded retries.
                    return
                }
            }

            guard !Task.isCancelled, self.roomSyncOperation == nil else { return }

            if let refreshedRoom,
               ["waiting", "ready_voting", "roulette", "playing"].contains(refreshedRoom.normalizedStatus),
               refreshedRoom.containsPlayer(email: self.user?.email) {
                self.activeRoom = refreshedRoom
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

    private func closeActiveRoomAfterRefresh(roomID: String) {
        guard activeRoom?.id == roomID else { return }
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
        let errorMarkers = ["ERROR", "FAILED", "NOT FOUND", "COULD NOT", "НЕ УДАЛ", "НЕ НАЙД", "NO SE PUDO"]
        if errorMarkers.contains(where: upper.contains) {
            return .error
        }
        if upper.contains("READY") || upper.contains("ГОТОВ") || upper.contains("LISTA") {
            return .success
        }
        return .warning
    }

    private var roomClosedToastMessage: String {
        switch language {
        case .ru: "ХОСТ ЗАКРЫЛ КОМНАТУ"
        case .es: "EL HOST CERRÓ LA SALA"
        default: "ROOM CLOSED BY HOST"
        }
    }

    private var roomSyncInterruptedToastMessage: String {
        switch language {
        case .ru: "СВЯЗЬ С КОМНАТОЙ ПРЕРВАНА — ПЕРЕПОДКЛЮЧАЕМСЯ"
        case .es: "CONEXIÓN INTERRUMPIDA — RECONECTANDO"
        default: "ROOM SYNC INTERRUPTED — RECONNECTING"
        }
    }

    private var roomSyncRecoveredToastMessage: String {
        switch language {
        case .ru: "СИНХРОНИЗАЦИЯ КОМНАТЫ ВОССТАНОВЛЕНА"
        case .es: "SINCRONIZACIÓN DE SALA RESTAURADA"
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

    var isAuthTransitionActive: Bool {
        hasActiveAuthCinematic || authHomeRevealPhase != .idle
    }

    var membershipTier: MembershipTier? {
        if isCasadaProtocolActive { return .limitless }
        guard let membership else { return nil }
        return membership.grantsFullAccess ? .limitless : .free
    }

    var membershipBenefits: MembershipBenefits? {
        if isCasadaProtocolActive { return .fullAccess }
        guard let membership else { return nil }
        return membership.grantsFullAccess ? membership.benefits : .free
    }

    var hasFullAccess: Bool {
        isCasadaProtocolActive || membership?.grantsFullAccess == true
    }

    /// CASADA exposes the complete product without paid gates. Legacy billing
    /// infrastructure remains available only for entitlement compatibility.
    var isCasadaProtocolActive: Bool { SpyClashRelease.isCasadaProtocolActive }

    // Kept as a read-only bridge for existing premium presentation code while
    // the richer membership model becomes the shared source of truth.
    var subscriptionActive: Bool {
        hasFullAccess
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
            await synchronizeAccess()
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
            membership = nil
            membershipOwnerUserID = nil
            membershipSyncState = .unknown
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
                // Access synchronization must not hold the Apple sign-in screen.
                Task { [weak self] in
                    await self?.synchronizeAccess()
                }
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

        Task { [weak self] in
            await self?.synchronizeAccess()
        }

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

        authHomeRevealPhase = .covered
        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }
        standardAuthCinematicStage = nil

        do {
            try await Task.sleep(for: .milliseconds(260))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }
        authHomeRevealPhase = .revealing

        do {
            try await Task.sleep(for: .milliseconds(860))
        } catch {
            clearStandardAuthCinematicIfCurrent(runID)
            return
        }

        guard standardAuthRunID == runID, user != nil else { return }
        authHomeRevealPhase = .idle
        standardAuthRunID = nil
#if DEBUG
        isUIPreviewMode = false
#endif
    }

    private func clearStandardAuthCinematicIfCurrent(_ runID: UUID) {
        guard standardAuthRunID == runID else { return }
        standardAuthRunID = nil
        standardAuthCinematicStage = nil
        authHomeRevealPhase = .idle
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
        HapticManager.shared.fire(.notification(.success))
        PushNotificationCoordinator.shared.prepareForLogout()
        client.clearToken()
        KeychainStore.clearToken()
        user = nil
        membership = nil
        membershipOwnerUserID = nil
        membershipSyncState = .unknown
        fullAccessUnlockPresentationID = nil
        authPhase = .email
        authError = nil
        authNotice = nil
        appleAuthStage = nil
        standardAuthCinematicStage = nil
        authHomeRevealPhase = .idle
        selectedTab = .home
        shellRoute = .main
        activeRoom = nil
        roomSyncOperation = nil
        activeRoomActivationRefreshTask?.cancel()
        activeRoomActivationRefreshTask = nil
        presentedSheet = nil
        pendingJoinCode = nil
        pendingMatchRoomID = nil
        deepLinkStatus = nil
        isJoiningDeepLink = false
        isOpeningPendingMatch = false
    }

    private func revealHomeAfterAppleAuth() async {
        // Phase 1 is committed on its own render pass. This guarantees the
        // black root curtain exists before RootView swaps Welcome for Home.
        authHomeRevealPhase = .covered
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else {
            appleAuthStage = nil
            authHomeRevealPhase = .idle
            return
        }

        // Mount Home under an already opaque, stable curtain and let the auth
        // sheet disappear black-to-black.
        appleAuthStage = nil
        try? await Task.sleep(for: .milliseconds(260))
        guard !Task.isCancelled else {
            authHomeRevealPhase = .idle
            return
        }

        // Start the one visible reveal only after Home and its entrance state
        // have both had time to mount behind the curtain.
        authHomeRevealPhase = .revealing
        try? await Task.sleep(for: .milliseconds(860))
        authHomeRevealPhase = .idle
    }

    func openLocalSetup() {
        isShellChromeSuppressed = false
        localSetupRequestID += 1
        selectedTab = .local
    }

    func setLanguage(_ newLanguage: AppLanguage, syncRemote: Bool = true) async throws {
        language = newLanguage
        newLanguage.persist()

        guard syncRemote, user != nil else {
            return
        }

        user = try await client.updateLanguage(newLanguage)
    }

    func refreshSubscription() async {
        guard let requestedUserID = user?.id else {
            membership = nil
            membershipOwnerUserID = nil
            membershipSyncState = .unknown
            return
        }

        if let membershipOwnerUserID, membershipOwnerUserID != requestedUserID {
            // Entitlements must never bleed across an account switch.
            membership = nil
            self.membershipOwnerUserID = nil
        }

        membershipSyncState = .refreshing

        do {
            let refreshedMembership = try await client.membership()

            // Ignore a response that belongs to the account that just logged
            // out (or was replaced by another login) while this was in flight.
            guard user?.id == requestedUserID else { return }
            let shouldPresentUnlock = !isCasadaProtocolActive &&
                membership != nil &&
                membership?.grantsFullAccess == false &&
                refreshedMembership.grantsFullAccess
            membership = refreshedMembership
            membershipOwnerUserID = requestedUserID
            membershipSyncState = .synced
            scheduleMembershipExpiryRefresh(
                for: refreshedMembership,
                ownerUserID: requestedUserID
            )
            if shouldPresentUnlock {
                presentFullAccessUnlock()
            }
        } catch is CancellationError {
            guard user?.id == requestedUserID else { return }
            membershipSyncState = membership == nil ? .unknown : .synced
        } catch {
            guard user?.id == requestedUserID else { return }
            // Preserve the last verified access state during an outage.
            membershipSyncState = .unavailable(message: error.localizedDescription)
        }
    }

    func synchronizeAccess() async {
        if !isCasadaProtocolActive,
           client.hasSessionToken,
           let storeKit {
            do {
                _ = try await storeKit.synchronizeStoreKitState()
            } catch is CancellationError {
                return
            } catch {
                // Legacy provider access can still be resolved by Base44 while
                // StoreKit synchronization is temporarily unavailable.
            }
        }
        await refreshSubscription()
    }

    func synchronizeAccessOnActivation() {
        guard user != nil,
              !isRestoring,
              !shouldUsePreviewData,
              accessActivationSyncTask == nil else {
            return
        }

        membershipRealtime.resume()

        accessActivationSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accessActivationSyncTask = nil }
            await self.synchronizeAccess()
            await self.consumePendingRoutesIfPossible()
            self.synchronizeMatchLiveActivity(previousRoom: nil, room: self.activeRoom)
        }
    }

    func dismissFullAccessUnlock(_ presentationID: UUID) {
        guard fullAccessUnlockPresentationID == presentationID else { return }
        fullAccessUnlockPresentationID = nil
    }

    private func handleMembershipRealtimeSignal() {
        guard user != nil else { return }
        membershipRealtimeRefreshTask?.cancel()
        membershipRealtimeRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            await self?.refreshSubscription()
        }
    }

    private func presentFullAccessUnlock() {
        fullAccessUnlockPresentationID = UUID()
    }

    private func scheduleMembershipExpiryRefresh(
        for membership: Membership,
        ownerUserID: String
    ) {
        membershipExpiryTask?.cancel()
        membershipExpiryTask = nil

        guard membership.tier == .limitless,
              !membership.providers.contains("preview"),
              let expiresAt = membership.expiresAt else {
            return
        }

        let delay = expiresAt.timeIntervalSinceNow
        guard delay > 0 else { return }
        membershipExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.user?.id == ownerUserID else { return }
            await self.refreshSubscription()
        }
    }

    func recordAIUsage(used: Int?, remaining: Int?) {
        guard let membership,
              membershipOwnerUserID == user?.id else {
            return
        }
        self.membership = membership.updatingAIUsage(used: used, remaining: remaining)
    }

    func openCommunity() {
        presentedSheet = nil
        shellRoute = .community
    }

    func closeCommunity() {
        shellRoute = .main
    }

    func setRadarApplicationActive(_ isActive: Bool) {
        radarNearby.setApplicationActive(isActive)
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
            activeRoom = try await client.join(code: code, user: user)
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
            pendingJoinCode = nil
            deepLinkStatus = language.home.roomReady(code)
            HapticManager.shared.fire(.milestone)
            return true
        } catch {
            deepLinkStatus = error.localizedDescription.uppercased()
            HapticManager.shared.fire(.notification(.error))
            return false
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.scheme?.lowercased() == "spyclash",
           url.host?.lowercased() == "community" {
            openCommunity()
            return
        }

        if url.scheme?.lowercased() == "spyclash",
           url.host?.lowercased() == "match",
           let roomID = url.pathComponents.first(where: { $0 != "/" && !$0.isEmpty }) {
            queueMatchRoute(roomID: roomID)
            return
        }

        if url.scheme?.lowercased() == "spyclash",
           url.host?.lowercased() == "game",
           let roomID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "room_id" })?
            .value?.nilIfBlank {
            queueMatchRoute(roomID: roomID)
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
            authPhase = .email
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
        case .communityRequests:
            openCommunity()
        case .room(let code):
            pendingJoinCode = code
            deepLinkStatus = language.welcome.inviteArmed(code)
            if user == nil {
                authPhase = .email
            } else {
                Task { await consumePendingJoinIfPossible() }
            }
        case .activeGame:
            if activeRoom != nil {
                selectedTab = .game
                shellRoute = .main
                presentedSheet = nil
            }
        case .url(let url):
            handleIncomingURL(url)
        }
    }

    @discardableResult
    func consumePendingJoinIfPossible() async -> Bool {
        guard user != nil, let code = pendingJoinCode else {
            return false
        }

        isJoiningDeepLink = true
        defer { isJoiningDeepLink = false }
        return await joinRoom(code: code)
    }

    func consumePendingRoutesIfPossible() async {
        _ = await consumePendingJoinIfPossible()
        await consumePendingMatchRouteIfPossible()
    }

    private func consumePendingMatchRouteIfPossible() async {
        guard user != nil,
              !isRestoring,
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

    private func restoreActiveRoomIfPossible() async {
        guard let user else { return }
        let storedRoomID = UserDefaults.standard
            .string(forKey: Self.activeRoomIDStorageKey)?
            .nilIfBlank

        var room: GameRoom?
        if let storedRoomID {
            room = try? await client.refreshRoom(id: storedRoomID)
        }
        if room == nil || room?.normalizedStatus == "finished" {
            // The backend keeps this lookup bounded to the preferred id, host
            // query, and the authenticated participant index. Never enumerate
            // rooms from the client when moving an account between Web and iOS.
            room = try? await client.activeRoom(preferredRoomID: storedRoomID)
        }

        guard let room,
              ["waiting", "ready_voting", "roulette", "playing"].contains(room.normalizedStatus),
              room.containsPlayer(email: user.email) else {
            if storedRoomID != nil {
                clearStoredActiveRoom()
            }
            return
        }

        activeRoom = room
        selectedTab = .game
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
                  let projection = room.liveActivityProjection(for: viewer) else {
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
    private func activateUIPreviewModeIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--spyclash-ui-preview") else {
            return false
        }

        isUIPreviewMode = true
        user = SpyUser(
            id: "debug-ui-preview-user",
            email: "operative.preview@spyclash.local",
            fullName: "Preview Operative",
            displayName: "Red Raven",
            avatar: "🕵️",
            language: nil,
            role: "user",
            isVerified: true,
            rating: 1240,
            gamesPlayed: 42,
            gamesWon: 25,
            remoteSpyID: "350-911",
            spyCardTheme: "field",
            spyCardAccent: "signal_red",
            spyCardBadge: "operative"
        )
        let previewsFullAccess = arguments.contains("--spyclash-preview-casada")
            || arguments.contains("--spyclash-preview-limitless")
        membership = previewsFullAccess
            ? .fullAccessPreview
            : .free
        membershipOwnerUserID = user?.id
        membershipSyncState = .synced
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
        default:
            presentedSheet = nil
        }

        if arguments.contains("--spyclash-preview-radar-invite") {
            radarNearby.presentForConfirmation(
                RadarIncomingInvitation(
                    roomCode: "R7VN28",
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
            showToast(
                language == .ru ? "ПРОФИЛЬ СОХРАНЁН" : "PROFILE SAVED",
                kind: .success,
                duration: .seconds(10)
            )
            showToast(
                language == .ru ? "ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ" : "CHECK CONNECTION",
                kind: .warning,
                duration: .seconds(10)
            )
            showToast(
                language == .ru ? "НЕ УДАЛОСЬ СИНХРОНИЗИРОВАТЬ" : "SYNC FAILED",
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

enum AppShellRoute: String, Hashable {
    case main
    case community
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
    static let isCasadaProtocolActive = true

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
