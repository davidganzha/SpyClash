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
    let storeKit: StoreKitManager
    let membershipRealtime: MembershipRealtimeService
    let radarNearby: RadarNearbyService
    var user: SpyUser? {
        didSet {
            radarNearby.configure(user: user)
            radarNearby.setActiveRoom(activeRoom)
            guard oldValue?.id != user?.id else { return }
            // A verified entitlement belongs to exactly one SpyClash account.
            // Clear it synchronously before the replacement account renders.
            membership = nil
            membershipOwnerUserID = nil
            membershipSyncState = .unknown
            membershipExpiryTask?.cancel()
            membershipExpiryTask = nil
            storeKit.accountDidChange()
            membershipRealtime.stop()
            if let user, let token = client.currentAccessToken {
                membershipRealtime.start(
                    appID: Base44Client.appID,
                    token: token,
                    userID: user.id
                )
            }
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
    var appleAuthStage: AppleAuthStage?
    var standardAuthCinematicStage: StandardAuthCinematicStage?
    var authHomeRevealPhase: AuthHomeRevealPhase = .idle
    private(set) var membership: Membership?
    private(set) var membershipSyncState: MembershipSyncState = .unknown
    private(set) var limitlessUnlockPresentationID: UUID?
    var selectedTab: AppTab = .home
    var shellRoute: AppShellRoute = .main
    var localSetupRequestID = 0
    var activeRoom: GameRoom? {
        didSet {
            persistActiveRoomReference(activeRoom)
            radarNearby.setActiveRoom(activeRoom)
            handleRoomPresenceChange(from: oldValue, to: activeRoom)
        }
    }
    var isShellChromeSuppressed = false
    private(set) var roomSyncOperation: RoomSyncOperation?
    var presentedSheet: AppSheet?
    var roomQRTarget: RoomQRTarget = .web
    var language: AppLanguage = .stored
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
    @ObservationIgnored private var commerceActivationSyncTask: Task<Void, Never>?
    @ObservationIgnored private var membershipRealtimeRefreshTask: Task<Void, Never>?
    private static let activeRoomIDStorageKey = "spyclash.activeRoomID"

    override init() {
        let client = Base44Client()
        let radarNearby = RadarNearbyService()
        self.client = client
        self.storeKit = StoreKitManager(client: client)
        self.membershipRealtime = MembershipRealtimeService()
        self.radarNearby = radarNearby
        super.init()

        storeKit.onEntitlementChanged = { [weak self] in
            await self?.refreshSubscription()
        }
        membershipRealtime.onMembershipSignal = { [weak self] in
            self?.handleMembershipRealtimeSignal()
        }
        radarNearby.onAutomaticInvitation = { [weak self] invitation in
            self?.handleAutomaticRadarInvitation(invitation)
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

        while !Task.isCancelled, activeRoom?.id == roomID {
            if roomSyncOperation == nil {
                do {
                    let refreshedRoom = try await client.refreshRoom(id: roomID)
                    guard !Task.isCancelled,
                          activeRoom?.id == roomID,
                          roomSyncOperation == nil else { return }

                    if let refreshedRoom {
                        activeRoom = refreshedRoom
                    } else {
                        activeRoom = nil
                        if selectedTab == .game {
                            selectedTab = .home
                        }
                        showToast(
                            roomClosedToastMessage,
                            kind: .warning,
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                        return
                    }
                } catch {
                    // Background room refreshes are best-effort. User-initiated
                    // actions publish their own actionable errors as toasts.
                }
            }

            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
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
        if isAlphaProgram { return .limitless }
        guard let membership else { return nil }
        return membership.isLimitless ? .limitless : .free
    }

    var membershipBenefits: MembershipBenefits? {
        if isAlphaProgram { return .limitless }
        guard let membership else { return nil }
        return membership.isLimitless ? membership.benefits : .free
    }

    var hasLimitlessAccess: Bool {
        isAlphaProgram || membership?.isLimitless == true
    }

    /// Temporary launch phase. Keep billing and entitlement infrastructure in
    /// the binary, while exposing the complete product without paid gates.
    var isAlphaProgram: Bool { SpyClashRelease.isAlpha }

    // Kept as a read-only bridge for existing premium presentation code while
    // the richer membership model becomes the shared source of truth.
    var subscriptionActive: Bool {
        hasLimitlessAccess
    }

    func restoreSession() async {
        isRestoring = true

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
            await synchronizeCommerceAccess()
            await restoreActiveRoomIfPossible()
        } catch {
            client.clearToken()
            KeychainStore.clearToken()
            user = nil
            membership = nil
            membershipOwnerUserID = nil
            membershipSyncState = .unknown
            clearStoredActiveRoom()
        }

        isRestoring = false
        await consumePendingJoinIfPossible()
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
            let token = try await client.appleNativeAccessToken(for: credential) { [weak self] phase in
                switch phase {
                case .verifyingIdentity:
                    self?.appleAuthStage = .verifyingIdentity
                case .establishingSession:
                    self?.appleAuthStage = .establishingSession
                }
            }
            appleAuthStage = .synchronizingProfile
            try await acceptProviderToken(token, cinematic: .apple)

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
        cinematic: ProviderAuthCinematic
    ) async throws {
        client.setToken(token)
        do {
            let authenticatedUser = try await client.autoRegisterUser()
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
                // Subscription work must not hold the Apple access screen.
                Task { [weak self] in
                    await self?.synchronizeCommerceAccess()
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
            await self?.synchronizeCommerceAccess()
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
        client.clearToken()
        KeychainStore.clearToken()
        user = nil
        membership = nil
        membershipOwnerUserID = nil
        membershipSyncState = .unknown
        limitlessUnlockPresentationID = nil
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
        presentedSheet = nil
        pendingJoinCode = nil
        deepLinkStatus = nil
        isJoiningDeepLink = false
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
            let shouldPresentUnlock = !isAlphaProgram &&
                membership != nil &&
                membership?.isLimitless == false &&
                refreshedMembership.isLimitless
            membership = refreshedMembership
            membershipOwnerUserID = requestedUserID
            membershipSyncState = .synced
            scheduleMembershipExpiryRefresh(
                for: refreshedMembership,
                ownerUserID: requestedUserID
            )
            if shouldPresentUnlock {
                presentLimitlessUnlock()
            }
        } catch is CancellationError {
            guard user?.id == requestedUserID else { return }
            membershipSyncState = membership == nil ? .unknown : .synced
        } catch {
            guard user?.id == requestedUserID else { return }
            // Preserve the last verified category during an outage. A failed
            // refresh must not silently turn a LIMITLESS member into FREE.
            membershipSyncState = .unavailable(message: error.localizedDescription)
        }
    }

    func synchronizeCommerceAccess() async {
        if client.hasSessionToken {
            do {
                _ = try await storeKit.synchronizeStoreKitState()
            } catch is CancellationError {
                return
            } catch {
                // Stripe or a previously verified Apple source can still be
                // resolved by checkSubscription while StoreKit/Base44 sync is
                // temporarily unavailable.
            }
        }
        await refreshSubscription()
    }

    func synchronizeCommerceAccessOnActivation() {
        guard user != nil,
              !isRestoring,
              !shouldUsePreviewData,
              commerceActivationSyncTask == nil else {
            return
        }

        membershipRealtime.resume()

        commerceActivationSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commerceActivationSyncTask = nil }
            await self.synchronizeCommerceAccess()
        }
    }

    func dismissLimitlessUnlock(_ presentationID: UUID) {
        guard limitlessUnlockPresentationID == presentationID else { return }
        limitlessUnlockPresentationID = nil
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

    private func presentLimitlessUnlock() {
        limitlessUnlockPresentationID = UUID()
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

    @discardableResult
    func consumePendingJoinIfPossible() async -> Bool {
        guard user != nil, let code = pendingJoinCode else {
            return false
        }

        isJoiningDeepLink = true
        defer { isJoiningDeepLink = false }
        return await joinRoom(code: code)
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
        guard let user,
              let roomID = UserDefaults.standard.string(forKey: Self.activeRoomIDStorageKey)?.nilIfBlank else {
            return
        }

        guard let room = try? await client.refreshRoom(id: roomID),
              ["waiting", "ready_voting", "roulette", "playing"].contains(room.normalizedStatus),
              room.playersList.contains(where: { $0.email == user.email }) else {
            clearStoredActiveRoom()
            return
        }

        activeRoom = room
        selectedTab = .game
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
        membership = arguments.contains("--spyclash-preview-limitless")
            ? .limitlessPreview
            : .free
        membershipOwnerUserID = user?.id
        membershipSyncState = .synced
        let requestedTab = previewTab(from: arguments) ?? .home
        let shouldPreviewActiveRoom = requestedTab == .game || arguments.contains("--spyclash-preview-active-room")
        selectedTab = requestedTab
        language = previewLanguage(from: arguments) ?? AppLanguage.stored
        activeRoom = shouldPreviewActiveRoom
            ? GameRoom.previewRoom(status: previewArgumentValue(prefix: "--spyclash-preview-room=", in: arguments) ?? "waiting")
            : nil
        roomSyncOperation = previewRoomSyncOperation(from: arguments)
        pendingJoinCode = nil
        deepLinkStatus = nil
        isJoiningDeepLink = false
        isBusy = false
        isRestoring = false
        shellRoute = .main

        switch previewArgumentValue(prefix: "--spyclash-preview-sheet=", in: arguments) {
        case "pricing":
            presentedSheet = .pricing
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
                    roomCode: "R7VN",
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

        return true
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
    case pricing
    case legal(LegalSheetKind)

    var id: String {
        switch self {
        case .qrScanner:
            "qrScanner"
        case .roomQR(let room):
            "roomQR-\(room.id)"
        case .pricing:
            "pricing"
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
    static let isAlpha = true
    static let alphaVersionLabel = "ALPHA 01.01V"
}
