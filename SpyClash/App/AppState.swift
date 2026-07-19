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

@MainActor
@Observable
final class AppState: NSObject {
    let client: Base44Client
    let storeKit: StoreKitManager
    let membershipRealtime: MembershipRealtimeService
    var user: SpyUser? {
        didSet {
            let previousUserID = oldValue?.id
            guard previousUserID != user?.id else { return }
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
            // A profile object alone is not an authenticated push session.
            // Starting APNs/ActivityKit registration before the access token
            // exists can manufacture a local 401 and clear an otherwise valid
            // auth transition (including provider handoff and debug previews).
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
    var authError: String?
    var authNotice: String?
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
            synchronizeMatchLiveActivity(previousRoom: oldValue, room: activeRoom)
        }
    }
    var isShellChromeSuppressed = false
    var presentedSheet: AppSheet?
    var roomQRTarget: RoomQRTarget = .web
    var language: AppLanguage = .stored {
        didSet {
            PushNotificationCoordinator.shared.updatePreferredLocale(language.rawValue)
        }
    }
    private(set) var isSynchronizingLanguage = false
    private(set) var isUpdatingProfile = false
    var pendingJoinCode: String?
    var deepLinkStatus: String?
    var isJoiningDeepLink = false
    private(set) var isJoiningRoom = false
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
        self.client = client
        self.storeKit = StoreKitManager(client: client)
        self.membershipRealtime = MembershipRealtimeService()
        super.init()

        storeKit.onEntitlementChanged = { [weak self] in
            await self?.refreshSubscription()
        }
        membershipRealtime.onMembershipSignal = { [weak self] in
            self?.handleMembershipRealtimeSignal()
        }
        client.setUnauthorizedHandler { [weak self] in
            self?.handleUnauthorizedSession()
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

    var hasActiveAuthCinematic: Bool {
        appleAuthStage != nil || standardAuthCinematicStage != nil
    }

    var isAuthTransitionActive: Bool {
        hasActiveAuthCinematic || authHomeRevealPhase != .idle
    }

    var membershipTier: MembershipTier? {
        guard let membership else { return nil }
        return membership.isLimitless ? .limitless : .free
    }

    var membershipBenefits: MembershipBenefits? {
        guard let membership else { return nil }
        return membership.isLimitless ? membership.benefits : .free
    }

    var hasLimitlessAccess: Bool {
        membership?.isLimitless == true
    }

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
        } catch let error as Base44Error where error.invalidatesSession {
            client.clearToken()
            KeychainStore.clearToken()
            user = nil
            membership = nil
            membershipOwnerUserID = nil
            membershipSyncState = .unknown
            clearStoredActiveRoom()
        } catch is CancellationError {
            isRestoring = false
            return
        } catch {
            // A transport, server, or decoding failure does not prove that the
            // credential is invalid. Preserve it so a temporary outage cannot
            // turn into a cascade of unauthenticated requests on next launch.
            authError = error.localizedDescription
        }

        isRestoring = false
        synchronizeMatchLiveActivity(previousRoom: nil, room: activeRoom)
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
        } catch is CancellationError {
            appleAuthStage = nil
            authHomeRevealPhase = .idle
            return
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
                    } catch is CancellationError {
                        continuation.resume()
                        return
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
            // A slower provider attempt can be cancelled after a newer login
            // has already installed its credential. Never let that stale
            // failure erase the replacement account.
            if client.currentAccessToken == token {
                client.clearToken()
                KeychainStore.clearToken()
            }
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
        clearSession(playFeedback: true, message: nil)
    }

    private func handleUnauthorizedSession() {
        guard user != nil || client.hasSessionToken || KeychainStore.readToken() != nil else {
            return
        }
        clearSession(playFeedback: false, message: sessionExpiredMessage)
    }

    private var sessionExpiredMessage: String {
        switch language {
        case .en:
            "Your session expired. Sign in again."
        case .ru:
            "Сессия истекла. Войдите снова."
        case .es:
            "Tu sesion ha caducado. Inicia sesion de nuevo."
        }
    }

    private func clearSession(playFeedback: Bool, message: String?) {
#if DEBUG
        // Logout must always leave forced UI-preview routing. Otherwise a
        // device launched into the Apple-auth preview keeps rendering the
        // already-dismissed debug presenter instead of WelcomeView.
        isUIPreviewMode = false
#endif
        standardAuthTimelineTask?.cancel()
        standardAuthTimelineTask = nil
        standardAuthRunID = nil
        webAuthSession?.cancel()
        webAuthSession = nil
        commerceActivationSyncTask?.cancel()
        commerceActivationSyncTask = nil
        membershipRealtimeRefreshTask?.cancel()
        membershipRealtimeRefreshTask = nil
        membershipExpiryTask?.cancel()
        membershipExpiryTask = nil
        if playFeedback {
            HapticManager.shared.fire(.notification(.success))
        }
        PushNotificationCoordinator.shared.prepareForLogout()
        client.clearToken()
        KeychainStore.clearToken()
        user = nil
        membership = nil
        membershipOwnerUserID = nil
        membershipSyncState = .unknown
        limitlessUnlockPresentationID = nil
        authPhase = .email
        authError = message
        authNotice = nil
        appleAuthStage = nil
        standardAuthCinematicStage = nil
        authHomeRevealPhase = .idle
        selectedTab = .home
        shellRoute = .main
        activeRoom = nil
        presentedSheet = nil
        pendingJoinCode = nil
        pendingMatchRoomID = nil
        deepLinkStatus = nil
        isJoiningDeepLink = false
        isJoiningRoom = false
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

    func updateProfile(
        displayName: String,
        avatar: String,
        language newLanguage: AppLanguage,
        spyCardTheme: SpyCardThemeID,
        spyCardAccent: SpyCardAccentID,
        spyCardBadge: SpyCardBadgeID
    ) async throws {
        guard !isUpdatingProfile, !isSynchronizingLanguage else {
            throw Base44Error(message: "Profile synchronization is already in progress.", statusCode: nil)
        }
        guard let requestedUserID = user?.id else {
            throw Base44Error(message: "Authentication required.", statusCode: 401)
        }

        isUpdatingProfile = true
        defer { isUpdatingProfile = false }

        let updatedUser = try await client.updateProfile(
            displayName: displayName,
            avatar: avatar,
            language: newLanguage,
            spyCardTheme: spyCardTheme,
            spyCardAccent: spyCardAccent,
            spyCardBadge: spyCardBadge
        )

        // The PUT may already have committed when its presenting view is
        // cancelled. Reconcile the verified response, but never let an old
        // account overwrite a replacement session.
        guard user?.id == requestedUserID else { throw CancellationError() }
        user = updatedUser
        language = newLanguage
        newLanguage.persist()
    }

    func setLanguage(_ newLanguage: AppLanguage, syncRemote: Bool = true) async throws {
        guard !isUpdatingProfile,
              !isSynchronizingLanguage || !syncRemote else {
            throw Base44Error(message: "Language synchronization is already in progress.", statusCode: nil)
        }
        let previousLanguage = language
        let requestedUserID = user?.id
        language = newLanguage
        newLanguage.persist()

        guard syncRemote, let requestedUserID else {
            return
        }

        isSynchronizingLanguage = true
        defer { isSynchronizingLanguage = false }

        do {
            let updatedUser = try await client.updateLanguage(newLanguage)
            try Task.checkCancellation()
            guard user?.id == requestedUserID else { throw CancellationError() }
            user = updatedUser
        } catch {
            if user?.id == requestedUserID, language == newLanguage {
                language = previousLanguage
                previousLanguage.persist()
            }
            throw error
        }
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
            let shouldPresentUnlock = membership != nil &&
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
        guard !isRestoring,
              !shouldUsePreviewData,
              commerceActivationSyncTask == nil,
              user != nil || client.hasSessionToken else {
            return
        }

        commerceActivationSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.commerceActivationSyncTask = nil }

            // A launch-time transport/5xx failure preserves the credential but
            // cannot populate `user`. Recover that exact session on the next
            // activation before any membership, room, route, push, or realtime
            // work is allowed to run. A real 401 still clears the same token in
            // Base44Client and never enters this path again.
            if self.user == nil {
                do {
                    let restoredUser = try await self.client.currentUser()
                    try Task.checkCancellation()
                    guard self.client.hasSessionToken else { return }
                    self.user = restoredUser
                    self.reconcileLanguagePreference(with: restoredUser.language)
                    self.authError = nil
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the valid credential for another activation retry.
                    // The app must not manufacture an unauthenticated cascade
                    // from a transient recovery failure.
                    self.authError = error.localizedDescription
                    return
                }
            }

            guard self.user != nil else { return }
            self.membershipRealtime.resume()
            await self.synchronizeCommerceAccess()
            if self.activeRoom == nil,
               !self.isJoiningRoom,
               !self.isJoiningDeepLink {
                await self.restoreActiveRoomIfPossible()
            }
            await self.consumePendingRoutesIfPossible()
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

    @discardableResult
    func joinRoom(code rawCode: String) async -> Bool {
        guard !isJoiningRoom else { return false }

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

        isJoiningRoom = true
        defer { isJoiningRoom = false }

        do {
            let room = try await client.join(code: code, user: user)
            // `join_room` is a server mutation and may already have committed
            // when a presenting QR sheet disappears. Reconcile the successful
            // response even if that UI task was cancelled; otherwise other
            // players see a ghost member while this device stays outside.
            guard self.user?.id == user.id else { return false }
            activeRoom = room
            selectedTab = .game
            shellRoute = .main
            presentedSheet = nil
            pendingJoinCode = nil
            deepLinkStatus = language.home.roomReady(code)
            HapticManager.shared.fire(.milestone)
            return true
        } catch is CancellationError {
            return false
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
            guard room.playersList.contains(where: { $0.email == user.email }) else {
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
            // Keep the route armed after a transient refresh failure. The app
            // activation path will retry it instead of silently losing the tap.
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
        guard user != nil,
              !isJoiningDeepLink,
              let code = pendingJoinCode else {
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
            // A transient failure intentionally keeps this exact route armed;
            // retry it on activation rather than spinning indefinitely here.
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
        } catch is CancellationError {
            return
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

        do {
            guard let room = try await client.refreshRoom(id: roomID) else {
                guard activeRoom == nil,
                      !isJoiningRoom,
                      !isJoiningDeepLink,
                      UserDefaults.standard.string(forKey: Self.activeRoomIDStorageKey) == roomID else {
                    return
                }
                clearStoredActiveRoom()
                return
            }
            try Task.checkCancellation()
            guard self.user?.id == user.id,
                  activeRoom == nil,
                  !isJoiningRoom,
                  !isJoiningDeepLink,
                  UserDefaults.standard.string(forKey: Self.activeRoomIDStorageKey) == roomID else {
                return
            }
            guard ["waiting", "ready_voting", "roulette", "playing"].contains(room.normalizedStatus),
                  room.playersList.contains(where: { $0.email == user.email }) else {
                clearStoredActiveRoom()
                return
            }

            activeRoom = room
            selectedTab = .game
        } catch is CancellationError {
            return
        } catch {
            // Preserve the stored room reference during a temporary outage.
            // `refreshRoom` returns nil only for a confirmed 404, handled
            // above; transport/5xx/decoding failures should be retried later.
            deepLinkStatus = error.localizedDescription.uppercased()
        }
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

        return true
    }

    private func previewTab(from arguments: [String]) -> AppTab? {
        guard let rawValue = previewArgumentValue(prefix: "--spyclash-preview-tab=", in: arguments) else {
            return nil
        }
        return AppTab(rawValue: rawValue)
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
