import Foundation

enum OnboardingAcquisitionSource: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chatGPT = "chatgpt"
    case appStoreSearch = "app_store_search"
    case webSearch = "web_search"
    case socialMedia = "social_media"
    case friendsOrFamily = "friends_or_family"
    case other

    var id: String { rawValue }
}

struct OnboardingSubmission: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let language: AppLanguage
    let acquisitionSource: OnboardingAcquisitionSource
    let version: Int
    let completedAt: Date

    init(
        language: AppLanguage,
        acquisitionSource: OnboardingAcquisitionSource,
        version: Int = Self.currentVersion,
        completedAt: Date = Date()
    ) {
        self.language = language
        self.acquisitionSource = acquisitionSource
        self.version = version
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case language
        case acquisitionSource = "acquisition_source"
        case version = "onboarding_version"
        case completedAt = "onboarding_completed_at"
    }
}

enum OnboardingRoutingPolicy {
    /// Resolves account routing without mutating local progress. An explicit
    /// server `false` is authoritative over all local state. A pending
    /// submission may bridge a missing or older positive server payload until
    /// Base44 confirms it. A missing server field may use this device's
    /// account-scoped completion so older User payloads remain compatible.
    static func shouldPresentOnboarding(
        remoteCompleted: Bool?,
        remoteVersion: Int?,
        localCompletedVersion: Int?,
        localPendingVersion: Int? = nil,
        requiredVersion: Int = OnboardingSubmission.currentVersion
    ) -> Bool {
        let requiredVersion = max(1, requiredVersion)

        if remoteCompleted == false {
            return true
        }

        if (localPendingVersion ?? 0) >= requiredVersion {
            return false
        }

        if remoteCompleted == true {
            // Explicit completion written before versioning was introduced is
            // the first onboarding contract, never an implicit latest version.
            return (remoteVersion ?? 1) < requiredVersion
        }

        return (localCompletedVersion ?? 0) < requiredVersion
    }
}

enum OnboardingProgressStoreError: Error, Equatable {
    case invalidUserID
}

struct OnboardingProgressStore {
    private static let namespace = "spyclash.onboarding"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func completedVersion(
        for userID: String,
        defaults: UserDefaults = .standard
    ) -> Int? {
        Self(defaults: defaults).completedVersion(for: userID)
    }

    static func pendingSubmission(
        for userID: String,
        defaults: UserDefaults = .standard
    ) -> OnboardingSubmission? {
        Self(defaults: defaults).pendingSubmission(for: userID)
    }

    static func savePending(
        _ submission: OnboardingSubmission,
        for userID: String,
        defaults: UserDefaults = .standard
    ) {
        try? Self(defaults: defaults).savePending(submission, for: userID)
    }

    static func markSynced(
        _ submission: OnboardingSubmission,
        for userID: String,
        defaults: UserDefaults = .standard
    ) {
        Self(defaults: defaults).markSynced(submission, for: userID)
    }

    static func reconcileRemoteState(
        for user: SpyUser,
        defaults: UserDefaults = .standard
    ) {
        Self(defaults: defaults).reconcileRemoteState(for: user)
    }

    static func shouldPresentOnboarding(
        for user: SpyUser,
        requiredVersion: Int = OnboardingSubmission.currentVersion,
        defaults: UserDefaults = .standard
    ) -> Bool {
        Self(defaults: defaults).shouldPresentOnboarding(
            for: user,
            requiredVersion: requiredVersion
        )
    }

    static func setNearbyTransportEnabled(
        _ isEnabled: Bool,
        for userID: String,
        defaults: UserDefaults = .standard
    ) {
        Self(defaults: defaults).setNearbyTransportEnabled(isEnabled, for: userID)
    }

    static func isNearbyTransportEnabled(
        for userID: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        Self(defaults: defaults).isNearbyTransportEnabled(for: userID)
    }

    static func clear(
        for userID: String,
        defaults: UserDefaults = .standard
    ) {
        let store = Self(defaults: defaults)
        for field in [
            "completed-version",
            "pending-submission",
            "nearby-transport-enabled"
        ] {
            guard let key = store.accountKey(field, userID: userID) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    func completedVersion(for userID: String) -> Int? {
        guard let key = accountKey("completed-version", userID: userID),
              defaults.object(forKey: key) != nil else {
            return nil
        }
        let version = defaults.integer(forKey: key)
        return version > 0 ? version : nil
    }

    func pendingSubmission(for userID: String) -> OnboardingSubmission? {
        guard let key = accountKey("pending-submission", userID: userID),
              let data = defaults.data(forKey: key) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OnboardingSubmission.self, from: data)
    }

    func savePending(
        _ submission: OnboardingSubmission,
        for userID: String
    ) throws {
        guard let completedKey = accountKey("completed-version", userID: userID),
              let pendingKey = accountKey("pending-submission", userID: userID) else {
            throw OnboardingProgressStoreError.invalidUserID
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedSubmission = try encoder.encode(submission)
        let resolvedVersion = max(
            completedVersion(for: userID) ?? 0,
            submission.version
        )
        if resolvedVersion > 0 {
            defaults.set(resolvedVersion, forKey: completedKey)
        }
        defaults.set(encodedSubmission, forKey: pendingKey)
    }

    /// Call only after Base44 confirms the completion update. Pending state is
    /// intentionally retained for every transport or server failure.
    func markSynced(
        _ submission: OnboardingSubmission,
        for userID: String
    ) {
        guard let completedKey = accountKey("completed-version", userID: userID),
              let pendingKey = accountKey("pending-submission", userID: userID) else {
            return
        }

        let resolvedVersion = max(
            completedVersion(for: userID) ?? 0,
            submission.version
        )
        if resolvedVersion > 0 {
            defaults.set(resolvedVersion, forKey: completedKey)
        }
        if (pendingSubmission(for: userID)?.version ?? 0) <= submission.version {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    /// Reconciles durable local fallback state with an authoritative User row.
    /// Explicit remote false clears local progress. Explicit true only clears
    /// pending answers through the version the server actually confirmed.
    func reconcileRemoteState(
        completed remoteCompleted: Bool?,
        version remoteVersion: Int?,
        for userID: String
    ) {
        guard let completedKey = accountKey("completed-version", userID: userID),
              let pendingKey = accountKey("pending-submission", userID: userID) else {
            return
        }

        if remoteCompleted == false {
            defaults.removeObject(forKey: completedKey)
            defaults.removeObject(forKey: pendingKey)
            return
        }

        guard remoteCompleted == true else { return }
        let confirmedVersion = max(1, remoteVersion ?? 1)
        defaults.set(confirmedVersion, forKey: completedKey)
        if (pendingSubmission(for: userID)?.version ?? 0) <= confirmedVersion {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    func reconcileRemoteState(for user: SpyUser) {
        reconcileRemoteState(
            completed: user.onboardingCompleted,
            version: user.onboardingVersion,
            for: user.id
        )
    }

    func shouldPresentOnboarding(
        for user: SpyUser,
        requiredVersion: Int = OnboardingSubmission.currentVersion
    ) -> Bool {
        OnboardingRoutingPolicy.shouldPresentOnboarding(
            remoteCompleted: user.onboardingCompleted,
            remoteVersion: user.onboardingVersion,
            localCompletedVersion: completedVersion(for: user.id),
            localPendingVersion: pendingSubmission(for: user.id)?.version,
            requiredVersion: requiredVersion
        )
    }

    func setNearbyTransportEnabled(_ isEnabled: Bool, for userID: String) {
        guard let key = accountKey("nearby-transport-enabled", userID: userID) else {
            return
        }
        defaults.set(isEnabled, forKey: key)
    }

    func isNearbyTransportEnabled(for userID: String) -> Bool {
        guard let key = accountKey("nearby-transport-enabled", userID: userID) else {
            return false
        }
        return defaults.bool(forKey: key)
    }

    private func accountKey(_ field: String, userID: String) -> String? {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else { return nil }
        let accountScope = Data(userID.utf8).base64EncodedString()
        return "\(Self.namespace).\(accountScope).\(field)"
    }
}
