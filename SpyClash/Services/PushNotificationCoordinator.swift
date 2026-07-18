import Foundation
import UIKit
import UserNotifications

enum SpyNotificationRoute: Sendable {
    case communityRequests
    case room(code: String)
    case activeGame
    case url(URL)
}

/// Deterministic and unit-testable retry schedule for idempotent ActivityKit
/// token registration and removal requests.
struct LiveActivityRegistrationRetryPolicy: Equatable, Sendable {
    let maxAttempts: Int
    let initialDelayMilliseconds: Int
    let maximumDelayMilliseconds: Int

    static let standard = LiveActivityRegistrationRetryPolicy(
        maxAttempts: 5,
        initialDelayMilliseconds: 400,
        maximumDelayMilliseconds: 3_200
    )

    func delayMilliseconds(afterFailedAttempt attempt: Int) -> Int {
        let exponent = min(max(0, attempt - 1), 20)
        let multiplier = 1 << exponent
        return min(
            maximumDelayMilliseconds,
            initialDelayMilliseconds * multiplier
        )
    }

    func isRetryableHTTPStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return true }
        return statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode)
    }
}

private struct LiveActivityRegistrationKey: Hashable, Sendable {
    let tokenKind: LiveActivityPushTokenKind
    let activityID: String?
    let matchID: String?
}

private struct PendingLiveActivityRegistration: Sendable {
    let key: LiveActivityRegistrationKey
    let token: String
    let roomID: String?
    let accountGeneration: UInt64
}

private struct PendingLiveActivityUnregistration: Sendable {
    let key: LiveActivityRegistrationKey
    let accountGeneration: UInt64
}

@MainActor
final class PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    static let friendRequestCategory = "SPYCLASH_FRIEND_REQUEST"
    static let roomInviteCategory = "SPYCLASH_ROOM_INVITE"
    static let gameUpdateCategory = "SPYCLASH_GAME_UPDATE"

    private static let installationIDKey = "spyclash.push.installation-id"
    private static let apnsTokenKey = "spyclash.push.apns-token"

    private var client: Base44Client?
    private var routeHandler: ((SpyNotificationRoute) -> Void)?
    private var pendingRoute: SpyNotificationRoute?
    private var signedIn = false
    private var preferredLocale = AppLanguage.stored.rawValue
    private var lastRegistrationSignature: String?
    private var registrationTask: Task<Void, Never>?
    private var accountGeneration: UInt64 = 0
    private var isApplicationActive = false
    private var pendingLiveActivityRegistrations: [
        LiveActivityRegistrationKey: PendingLiveActivityRegistration
    ] = [:]
    private var pendingLiveActivityRetryTasks: [
        LiveActivityRegistrationKey: Task<Void, Never>
    ] = [:]
    private var pendingLiveActivityUnregistrations: [
        LiveActivityRegistrationKey: PendingLiveActivityUnregistration
    ] = [:]
    private var pendingLiveActivityUnregistrationRetryTasks: [
        LiveActivityRegistrationKey: Task<Void, Never>
    ] = [:]

    private init() {}

    var installationID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.installationIDKey),
           UUID(uuidString: existing) != nil {
            return existing
        }

        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: Self.installationIDKey)
        return value
    }

    func configure(
        client: Base44Client,
        routeHandler: @escaping (SpyNotificationRoute) -> Void
    ) {
        self.client = client
        self.routeHandler = routeHandler
        if let pendingRoute {
            self.pendingRoute = nil
            routeHandler(pendingRoute)
        }
    }

    func accountDidChange(isSignedIn: Bool) {
        accountGeneration &+= 1
        clearPendingLiveActivityRequests()
        signedIn = isSignedIn
        lastRegistrationSignature = nil

        guard isSignedIn else {
            registrationTask?.cancel()
            registrationTask = nil
            return
        }

        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            await self?.requestAuthorizationAndRegister()
        }
    }

    func updatePreferredLocale(_ locale: String) {
        let normalized = locale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != preferredLocale else { return }
        preferredLocale = normalized
        lastRegistrationSignature = nil
        guard signedIn else { return }
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            await self?.refreshRegistration()
        }
    }

    func applicationDidBecomeActive() {
        isApplicationActive = true
        guard signedIn else { return }
        resumePendingLiveActivityRegistrations()
        resumePendingLiveActivityUnregistrations()
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            await self?.refreshRegistration()
        }
    }

    func applicationDidEnterBackground() {
        isApplicationActive = false
        registrationTask?.cancel()
        registrationTask = nil
        cancelPendingLiveActivityRetryTasks()
    }

    func didReceiveAPNsToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.apnsTokenKey) != token else {
            return
        }

        defaults.set(token, forKey: Self.apnsTokenKey)
        lastRegistrationSignature = nil

        guard signedIn else { return }
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            await self?.registerStoredDevice()
        }
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
#if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
#endif
    }

    func prepareForLogout() {
        accountGeneration &+= 1
        clearPendingLiveActivityRequests()
        registrationTask?.cancel()
        registrationTask = nil
        guard let client,
              let accessToken = client.currentAccessToken else {
            signedIn = false
            return
        }

        let installationID = installationID
        signedIn = false
        lastRegistrationSignature = nil
        Task {
            try? await client.unregisterPushDevice(
                installationID: installationID,
                accessToken: accessToken
            )
        }
    }

    func route(userInfo: [AnyHashable: Any]) {
        let route = Self.notificationRoute(from: userInfo)
        guard let route else { return }
        guard let routeHandler else {
            pendingRoute = route
            return
        }
        routeHandler(route)
    }

    @discardableResult
    func registerLiveActivityToken(
        token: String,
        tokenKind: LiveActivityPushTokenKind,
        activityID: String? = nil,
        roomID: String? = nil,
        matchID: String? = nil
    ) async -> Bool {
        guard signedIn, client != nil else { return false }
        let key = LiveActivityRegistrationKey(
            tokenKind: tokenKind,
            activityID: activityID,
            matchID: matchID
        )
        let request = PendingLiveActivityRegistration(
            key: key,
            token: token,
            roomID: roomID,
            accountGeneration: accountGeneration
        )

        // A newly yielded token supersedes any delayed attempt for the same
        // Activity. Keep the retry keyed by Activity identity rather than by
        // token so rotation can never resurrect the previous token.
        pendingLiveActivityUnregistrationRetryTasks
            .removeValue(forKey: key)?
            .cancel()
        pendingLiveActivityUnregistrations.removeValue(forKey: key)
        pendingLiveActivityRetryTasks.removeValue(forKey: key)?.cancel()
        if pendingLiveActivityRegistrations[key]?.token != token {
            pendingLiveActivityRegistrations.removeValue(forKey: key)
        }
        return await performLiveActivityRegistration(request)
    }

    /// Cancels a retained registration before ending or unregistering the
    /// exact Activity. Without this, an app-activation retry could recreate a
    /// server record after ActivityKit has already dismissed it.
    func cancelPendingLiveActivityRegistration(
        tokenKind: LiveActivityPushTokenKind,
        activityID: String? = nil,
        matchID: String? = nil
    ) {
        let key = LiveActivityRegistrationKey(
            tokenKind: tokenKind,
            activityID: activityID,
            matchID: matchID
        )
        pendingLiveActivityRetryTasks.removeValue(forKey: key)?.cancel()
        pendingLiveActivityRegistrations.removeValue(forKey: key)
    }

    @discardableResult
    func unregisterLiveActivityToken(
        tokenKind: LiveActivityPushTokenKind,
        activityID: String? = nil,
        matchID: String? = nil
    ) async -> Bool {
        cancelPendingLiveActivityRegistration(
            tokenKind: tokenKind,
            activityID: activityID,
            matchID: matchID
        )
        guard signedIn, client != nil else { return false }
        let key = LiveActivityRegistrationKey(
            tokenKind: tokenKind,
            activityID: activityID,
            matchID: matchID
        )
        let request = PendingLiveActivityUnregistration(
            key: key,
            accountGeneration: accountGeneration
        )
        pendingLiveActivityUnregistrationRetryTasks
            .removeValue(forKey: key)?
            .cancel()
        return await performLiveActivityUnregistration(request)
    }

    static func notificationType(from userInfo: [AnyHashable: Any]) -> String {
        let candidates = ["event_type", "notification_type", "type"]
        for key in candidates {
            if let value = userInfo[key] as? String, !value.isEmpty {
                return value.lowercased()
            }
        }
        return ""
    }

    private func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge])
            settings = await center.notificationSettings()
        }

        UIApplication.shared.registerForRemoteNotifications()
        await registerDeviceIfPossible(settings: settings)
    }

    private func isCurrentAccountGeneration(_ generation: UInt64) -> Bool {
        signedIn && accountGeneration == generation && !Task.isCancelled
    }

    private func performLiveActivityRegistration(
        _ request: PendingLiveActivityRegistration
    ) async -> Bool {
        guard signedIn,
              let client,
              isCurrentAccountGeneration(request.accountGeneration) else {
            return false
        }

        let policy = LiveActivityRegistrationRetryPolicy.standard
        for attempt in 1...policy.maxAttempts {
            guard isCurrentAccountGeneration(request.accountGeneration) else {
                return false
            }

            do {
                _ = try await client.registerLiveActivityToken(
                    installationID: installationID,
                    tokenKind: request.key.tokenKind,
                    token: request.token,
                    environment: .current,
                    activityID: request.key.activityID,
                    roomID: request.roomID,
                    matchID: request.key.matchID
                )
                guard isCurrentAccountGeneration(request.accountGeneration) else {
                    return false
                }
                if pendingLiveActivityRegistrations[request.key]?.token == request.token {
                    pendingLiveActivityRegistrations.removeValue(forKey: request.key)
                }
                return true
            } catch {
                let retryable = shouldRetryLiveActivityRequest(error, policy: policy)
                guard retryable,
                      attempt < policy.maxAttempts,
                      await waitForLiveActivityRetry(
                          policy: policy,
                          failedAttempt: attempt,
                          accountGeneration: request.accountGeneration
                      ) else {
                    if retryable,
                       isCurrentAccountGeneration(request.accountGeneration) {
                        // ActivityKit does not guarantee another emission for
                        // an unchanged token. Retain it and retry while the app
                        // remains active; activation resumes a suspended retry.
                        pendingLiveActivityRegistrations[request.key] = request
                        schedulePendingLiveActivityRegistrationRetry(request)
                    } else if pendingLiveActivityRegistrations[request.key]?.token == request.token {
                        pendingLiveActivityRegistrations.removeValue(forKey: request.key)
                    }
#if DEBUG
                    print("Live Activity token registration failed: \(error.localizedDescription)")
#endif
                    return false
                }
            }
        }
        return false
    }

    private func performLiveActivityUnregistration(
        _ request: PendingLiveActivityUnregistration
    ) async -> Bool {
        guard signedIn,
              let client,
              isCurrentAccountGeneration(request.accountGeneration) else {
            return false
        }

        let policy = LiveActivityRegistrationRetryPolicy.standard
        for attempt in 1...policy.maxAttempts {
            guard isCurrentAccountGeneration(request.accountGeneration) else {
                return false
            }

            do {
                try await client.unregisterLiveActivityToken(
                    installationID: installationID,
                    tokenKind: request.key.tokenKind,
                    activityID: request.key.activityID,
                    matchID: request.key.matchID
                )
                guard isCurrentAccountGeneration(request.accountGeneration) else {
                    return false
                }
                pendingLiveActivityUnregistrations.removeValue(forKey: request.key)
                return true
            } catch {
                let retryable = shouldRetryLiveActivityRequest(error, policy: policy)
                guard retryable,
                      attempt < policy.maxAttempts,
                      await waitForLiveActivityRetry(
                          policy: policy,
                          failedAttempt: attempt,
                          accountGeneration: request.accountGeneration
                      ) else {
                    if retryable,
                       isCurrentAccountGeneration(request.accountGeneration) {
                        // A terminal Activity emits no future token event. Keep
                        // retrying the exact deletion so a short outage cannot
                        // consume the server's active-token quota forever.
                        pendingLiveActivityUnregistrations[request.key] = request
                        schedulePendingLiveActivityUnregistrationRetry(request)
                    } else {
                        pendingLiveActivityUnregistrations.removeValue(forKey: request.key)
                    }
#if DEBUG
                    print("Live Activity token removal failed: \(error.localizedDescription)")
#endif
                    return false
                }
            }
        }
        return false
    }

    private func resumePendingLiveActivityRegistrations() {
        guard signedIn else { return }

        for (key, request) in pendingLiveActivityRegistrations where
            request.accountGeneration == accountGeneration &&
            pendingLiveActivityRetryTasks[key] == nil {
            schedulePendingLiveActivityRegistrationRetry(
                request,
                delaySeconds: 0
            )
        }
    }

    private func resumePendingLiveActivityUnregistrations() {
        guard signedIn else { return }

        for (key, request) in pendingLiveActivityUnregistrations where
            request.accountGeneration == accountGeneration &&
            pendingLiveActivityUnregistrationRetryTasks[key] == nil {
            schedulePendingLiveActivityUnregistrationRetry(
                request,
                delaySeconds: 0
            )
        }
    }

    private func schedulePendingLiveActivityRegistrationRetry(
        _ request: PendingLiveActivityRegistration,
        delaySeconds: Int = 30
    ) {
        guard signedIn,
              isApplicationActive,
              request.accountGeneration == accountGeneration else {
            return
        }
        let key = request.key
        pendingLiveActivityRetryTasks.removeValue(forKey: key)?.cancel()
        pendingLiveActivityRetryTasks[key] = Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    return
                }
            }
            guard let self,
                  self.isCurrentAccountGeneration(request.accountGeneration),
                  self.pendingLiveActivityRegistrations[key]?.token == request.token else {
                return
            }
            self.pendingLiveActivityRetryTasks.removeValue(forKey: key)
            _ = await self.performLiveActivityRegistration(request)
        }
    }

    private func schedulePendingLiveActivityUnregistrationRetry(
        _ request: PendingLiveActivityUnregistration,
        delaySeconds: Int = 30
    ) {
        guard signedIn,
              isApplicationActive,
              request.accountGeneration == accountGeneration else {
            return
        }
        let key = request.key
        pendingLiveActivityUnregistrationRetryTasks
            .removeValue(forKey: key)?
            .cancel()
        pendingLiveActivityUnregistrationRetryTasks[key] = Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                do {
                    try await Task.sleep(for: .seconds(delaySeconds))
                } catch {
                    return
                }
            }
            guard let self,
                  self.isCurrentAccountGeneration(request.accountGeneration),
                  self.pendingLiveActivityUnregistrations[key] != nil else {
                return
            }
            self.pendingLiveActivityUnregistrationRetryTasks.removeValue(forKey: key)
            _ = await self.performLiveActivityUnregistration(request)
        }
    }

    private func cancelPendingLiveActivityRetryTasks() {
        for task in pendingLiveActivityRetryTasks.values {
            task.cancel()
        }
        pendingLiveActivityRetryTasks.removeAll()
        for task in pendingLiveActivityUnregistrationRetryTasks.values {
            task.cancel()
        }
        pendingLiveActivityUnregistrationRetryTasks.removeAll()
    }

    private func clearPendingLiveActivityRequests() {
        cancelPendingLiveActivityRetryTasks()
        pendingLiveActivityRegistrations.removeAll()
        pendingLiveActivityUnregistrations.removeAll()
    }

    private func shouldRetryLiveActivityRequest(
        _ error: Error,
        policy: LiveActivityRegistrationRetryPolicy
    ) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return false
        }
        if let base44Error = error as? Base44Error {
            return policy.isRetryableHTTPStatus(base44Error.statusCode)
        }
        return true
    }

    private func waitForLiveActivityRetry(
        policy: LiveActivityRegistrationRetryPolicy,
        failedAttempt: Int,
        accountGeneration: UInt64
    ) async -> Bool {
        let milliseconds = policy.delayMilliseconds(
            afterFailedAttempt: failedAttempt
        )
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return isApplicationActive && isCurrentAccountGeneration(accountGeneration)
        } catch {
            return false
        }
    }

    private func refreshRegistration() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        UIApplication.shared.registerForRemoteNotifications()
        await registerDeviceIfPossible(settings: settings)
    }

    private func registerStoredDevice() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await registerDeviceIfPossible(settings: settings)
    }

    private func registerDeviceIfPossible(
        settings: UNNotificationSettings
    ) async {
        guard signedIn,
              let client,
              let token = UserDefaults.standard.string(forKey: Self.apnsTokenKey),
              !token.isEmpty else {
            return
        }

        let alertAuthorized = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        default:
            false
        }
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let buildVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? ""
        let version = if shortVersion.isEmpty {
            buildVersion
        } else if buildVersion.isEmpty {
            shortVersion
        } else {
            "\(shortVersion) (\(buildVersion))"
        }
        let signature = [token, String(alertAuthorized), version, preferredLocale]
            .joined(separator: "|")
        guard lastRegistrationSignature != signature else { return }

        do {
            _ = try await client.registerPushDevice(
                installationID: installationID,
                apnsToken: token,
                environment: .current,
                alertAuthorized: alertAuthorized,
                locale: preferredLocale,
                appVersion: version
            )
            lastRegistrationSignature = signature
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
#if DEBUG
            print("Push device registration failed: \(error.localizedDescription)")
#endif
        }
    }

    private static func notificationRoute(
        from userInfo: [AnyHashable: Any]
    ) -> SpyNotificationRoute? {
        if let rawURL = userInfo["deep_link"] as? String,
           let url = URL(string: rawURL) {
            return .url(url)
        }

        let type = notificationType(from: userInfo)
        if type == "friend_request" {
            return .communityRequests
        }

        if let rawCode = (userInfo["room_code"] ?? userInfo["code"]) as? String {
            let code = SpyLinkParser.roomCode(from: rawCode)
            if !code.isEmpty {
                return .room(code: code)
            }
        }

        if ["room_invite", "game_started", "game_update", "game_turn", "game_ended"]
            .contains(type) {
            return .activeGame
        }
        return nil
    }
}

@MainActor
final class SpyClashAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: PushNotificationCoordinator.friendRequestCategory,
                actions: [],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: PushNotificationCoordinator.roomInviteCategory,
                actions: [
                    UNNotificationAction(
                        identifier: "OPEN_ROOM",
                        title: "Open game",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: PushNotificationCoordinator.gameUpdateCategory,
                actions: [],
                intentIdentifiers: []
            )
        ])
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationCoordinator.shared.didReceiveAPNsToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationCoordinator.shared.didFailToRegisterForRemoteNotifications(error)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let type = PushNotificationCoordinator.notificationType(
            from: notification.request.content.userInfo
        )
        if ["game_started", "game_update", "game_turn", "game_ended"].contains(type) {
            return []
        }
        return [.banner, .list, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        PushNotificationCoordinator.shared.route(
            userInfo: response.notification.request.content.userInfo
        )
        try? await center.setBadgeCount(0)
    }
}
