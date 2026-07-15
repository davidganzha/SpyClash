@preconcurrency import ActivityKit
import Foundation

/// Application-side lifecycle API for the SpyClash match Live Activity.
///
/// The app starts the Activity while foregrounded, registers the returned push
/// token with its backend, and then updates it locally or with per-device
/// ActivityKit APNs payloads while the app isn't running.
@MainActor
final class SpyClashMatchLiveActivityController {
    typealias Attributes = SpyClashMatchActivityAttributes
    typealias ContentState = Attributes.ContentState

    struct PushTokenRegistration: Codable, Hashable, Sendable {
        let roomID: String
        let matchID: String
        let activityID: String
        let viewerPlayerID: String
        let token: String
    }

    struct ActivityDescriptor: Codable, Hashable, Sendable {
        let roomID: String
        let matchID: String
        let activityID: String
        let viewerPlayerID: String
    }

    enum LifecycleState: String, Codable, Hashable, Sendable {
        case active
        case stale
        case pending
        case ended
        case dismissed
        case unknown

        var isTerminal: Bool {
            self == .ended || self == .dismissed
        }
    }

    struct LifecycleUpdate: Codable, Hashable, Sendable {
        let activity: ActivityDescriptor
        let state: LifecycleState
    }

    enum ControllerError: LocalizedError, Equatable {
        case activitiesDisabled
        case invalidRoomID
        case invalidMatchID
        case invalidViewerPlayerID
        case invalidParticipants
        case payloadTooLarge
        case activityNotFound
        case remoteStartRequired

        var errorDescription: String? {
            switch self {
            case .activitiesDisabled:
                "Live Activities are disabled for SpyClash on this device."
            case .invalidRoomID:
                "The room identifier is missing."
            case .invalidMatchID:
                "The match identifier is missing."
            case .invalidViewerPlayerID:
                "The owning player identifier is missing."
            case .invalidParticipants:
                "The Live Activity requires unique, opaque participant identifiers."
            case .payloadTooLarge:
                "The Live Activity payload is too large for ActivityKit."
            case .activityNotFound:
                "No active SpyClash match Live Activity was found."
            case .remoteStartRequired:
                "On iOS 17.2 or later, the server owns Live Activity creation."
            }
        }
    }

    static let shared = SpyClashMatchLiveActivityController()

    private init() {}

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var activeMatchIDs: [String] {
        activeActivities.map(\.attributes.matchID)
    }

    /// Starts one personalized Activity per match and owning player, or updates
    /// the matching Activity when it already exists.
    @discardableResult
    func startOrUpdate(
        attributes: Attributes,
        initialState: ContentState,
        receivesPushUpdates: Bool = true,
        staleAfter: TimeInterval = 90
    ) async throws -> String {
        try validate(attributes: attributes, state: initialState)
        let sanitizedState = initialState.sanitized(for: attributes.viewerPlayerID)
        let content = makeContent(state: sanitizedState, staleAfter: staleAfter)

        if let existing = activity(
            matchID: attributes.matchID,
            viewerPlayerID: attributes.viewerPlayerID
        ) {
            await existing.update(content)
            return existing.id
        }

        // Starting locally while the same match can arrive through a delayed
        // push-to-start creates two Activities. iOS 17.2+ has one authority:
        // the server. iOS 17.0-17.1 retains the foreground local fallback.
        if #available(iOS 17.2, *) {
            throw ControllerError.remoteStartRequired
        }

        guard areActivitiesEnabled else {
            throw ControllerError.activitiesDisabled
        }

        let activity = try Activity<Attributes>.request(
            attributes: attributes,
            content: content,
            pushType: receivesPushUpdates ? .token : nil
        )
        return activity.id
    }

    /// Updates an Activity that already exists without creating a local
    /// competitor for a delayed push-to-start Activity.
    @discardableResult
    func updateIfPresent(
        attributes: Attributes,
        state: ContentState,
        staleAfter: TimeInterval = 90
    ) async throws -> String? {
        try validate(attributes: attributes, state: state)
        guard let existing = activity(
            matchID: attributes.matchID,
            viewerPlayerID: attributes.viewerPlayerID
        ) else {
            return nil
        }

        let sanitizedState = state.sanitized(for: attributes.viewerPlayerID)
        await existing.update(makeContent(state: sanitizedState, staleAfter: staleAfter))
        return existing.id
    }

    func update(
        matchID: String,
        state: ContentState,
        alert: AlertConfiguration? = nil,
        staleAfter: TimeInterval = 90
    ) async throws {
        guard let activity = activity(matchID: matchID) else {
            throw ControllerError.activityNotFound
        }

        try validate(attributes: activity.attributes, state: state)
        let sanitizedState = state.sanitized(for: activity.attributes.viewerPlayerID)
        await activity.update(
            makeContent(state: sanitizedState, staleAfter: staleAfter),
            alertConfiguration: alert
        )
    }

    func end(
        matchID: String,
        finalState: ContentState,
        dismissalPolicy: ActivityUIDismissalPolicy = .default
    ) async throws {
        // A push-to-start Activity can remain pending while a match completes
        // or the user logs out. Ending the complete trackable set prevents it
        // from activating later with stale role/word data.
        let matches = trackableActivities.filter { $0.attributes.matchID == matchID }
        guard !matches.isEmpty else {
            throw ControllerError.activityNotFound
        }

        for activity in matches {
            try validate(attributes: activity.attributes, state: finalState)
            var sanitizedState = finalState.sanitized(for: activity.attributes.viewerPlayerID)
            sanitizedState.phase = .completed
            let finalContent = ActivityContent(
                state: sanitizedState,
                staleDate: nil,
                relevanceScore: 0
            )
            await activity.end(finalContent, dismissalPolicy: dismissalPolicy)
        }
    }

    func endAll(dismissalPolicy: ActivityUIDismissalPolicy = .immediate) async {
        for activity in trackableActivities {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
        }
    }

    /// Ends activities from an earlier game in the same reusable room. This is
    /// the replay boundary that prevents a rotated word or role reaching a
    /// token issued for the previous match.
    func endActivities(
        roomID: String,
        excludingMatchID: String? = nil,
        dismissalPolicy: ActivityUIDismissalPolicy = .immediate
    ) async {
        for activity in trackableActivities where
            activity.attributes.roomID == roomID &&
            activity.attributes.matchID != excludingMatchID {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
        }
    }

    /// Returns a cancellable observation task. Send every yielded registration
    /// to the authenticated backend; the token can rotate during the Activity.
    @discardableResult
    func observePushTokens(
        activityID: String,
        onToken: @escaping @MainActor (PushTokenRegistration) async -> Bool
    ) throws -> Task<Void, Never> {
        guard let activity = Activity<Attributes>.activities.first(where: { $0.id == activityID }) else {
            throw ControllerError.activityNotFound
        }

        return Task { @MainActor in
            var lastToken: String?
            var deliveryTask: Task<Void, Never>?
            defer { deliveryTask?.cancel() }

            if let token = activity.pushToken {
                let registration = makeRegistration(token: token, for: activity)
                lastToken = registration.token
                deliveryTask = Task { @MainActor in
                    _ = await onToken(registration)
                }
            }

            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let registration = makeRegistration(token: token, for: activity)
                guard registration.token != lastToken else { continue }
                lastToken = registration.token
                deliveryTask?.cancel()
                deliveryTask = Task { @MainActor in
                    _ = await onToken(registration)
                }
            }
        }
    }

    /// Observes the full lifetime of one Activity. The caller uses terminal
    /// updates to cancel token streams and remove the exact server registration.
    func observeActivityState(
        activityID: String,
        onUpdate: @escaping @MainActor (LifecycleUpdate) async -> Void
    ) throws -> Task<Void, Never> {
        guard let activity = Activity<Attributes>.activities.first(where: { $0.id == activityID }) else {
            throw ControllerError.activityNotFound
        }

        let descriptor = descriptor(for: activity)
        return Task { @MainActor in
            let initial = LifecycleUpdate(
                activity: descriptor,
                state: lifecycleState(for: activity.activityState)
            )
            await onUpdate(initial)
            guard !initial.state.isTerminal else { return }

            for await activityState in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                let update = LifecycleUpdate(
                    activity: descriptor,
                    state: lifecycleState(for: activityState)
                )
                await onUpdate(update)
                if update.state.isTerminal { return }
            }
        }
    }

    /// A type-scoped push-to-start token lets APNs create the Live Activity
    /// when the game starts while the app is suspended or terminated.
    @available(iOS 17.2, *)
    func observePushToStartTokens(
        onToken: @escaping @MainActor (String) async -> Bool
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var lastToken: String?
            var deliveryTask: Task<Void, Never>?
            defer { deliveryTask?.cancel() }

            if let token = Activity<Attributes>.pushToStartToken {
                let encoded = Self.hexEncoded(token)
                lastToken = encoded
                deliveryTask = Task { @MainActor in
                    _ = await onToken(encoded)
                }
            }

            for await token in Activity<Attributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                let encoded = Self.hexEncoded(token)
                guard encoded != lastToken else { continue }
                lastToken = encoded
                deliveryTask?.cancel()
                deliveryTask = Task { @MainActor in
                    _ = await onToken(encoded)
                }
            }
        }
    }

    /// ActivityKit launches or wakes the app after a remote push-to-start. Its
    /// per-activity update token arrives through this type-wide stream rather
    /// than through the local `request` call used for foreground starts.
    func observeActivityUpdates(
        onActivity: @escaping @MainActor (String) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var observedIDs = Set<String>()
            for activity in Activity<Attributes>.activities {
                guard observedIDs.insert(activity.id).inserted else { continue }
                await onActivity(activity.id)
            }

            for await activity in Activity<Attributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                // Keep the de-duplication set bounded by the type's current
                // lifecycle instead of accumulating every historical ID.
                let currentIDs = Set(trackableActivities.map(\.id))
                observedIDs.formIntersection(currentIDs)
                guard observedIDs.insert(activity.id).inserted else { continue }
                await onActivity(activity.id)
            }
        }
    }

    /// Ends duplicate instances for the same personalized match. Keeping the
    /// earliest `(startedAt, activityID)` is deterministic across reconciliations.
    /// The returned descriptors must be unregistered by the app coordinator.
    func reconcileDuplicateActivities() async -> [ActivityDescriptor] {
        struct DuplicateKey: Hashable {
            let matchID: String
            let viewerPlayerID: String
        }

        let groups = Dictionary(grouping: trackableActivities) { activity in
            DuplicateKey(
                matchID: activity.attributes.matchID,
                viewerPlayerID: activity.attributes.viewerPlayerID
            )
        }
        var removed: [ActivityDescriptor] = []

        for group in groups.values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                let lhsRank = lifecyclePriority(lhs.activityState)
                let rhsRank = lifecyclePriority(rhs.activityState)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                if lhs.attributes.startedAt == rhs.attributes.startedAt {
                    return lhs.id < rhs.id
                }
                return lhs.attributes.startedAt < rhs.attributes.startedAt
            }
            for duplicate in ordered.dropFirst() {
                removed.append(descriptor(for: duplicate))
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
        }
        return removed
    }

    func activityDescriptor(activityID: String) -> ActivityDescriptor? {
        trackableActivities
            .first(where: { $0.id == activityID })
            .map(descriptor(for:))
    }

    func activityID(matchID: String) -> String? {
        trackableActivities.first {
            $0.attributes.matchID == matchID
        }?.id
    }

    private var activeActivities: [Activity<Attributes>] {
        trackableActivities.filter { activity in
            switch activity.activityState {
            case .active, .stale:
                true
            case .dismissed, .ended, .pending:
                false
            @unknown default:
                false
            }
        }
    }

    private var trackableActivities: [Activity<Attributes>] {
        Activity<Attributes>.activities.filter { activity in
            switch activity.activityState {
            case .active, .stale, .pending:
                true
            case .dismissed, .ended:
                false
            @unknown default:
                false
            }
        }
    }

    private func activity(
        matchID: String,
        viewerPlayerID: String? = nil
    ) -> Activity<Attributes>? {
        activeActivities.first { activity in
            activity.attributes.matchID == matchID
                && (viewerPlayerID == nil || activity.attributes.viewerPlayerID == viewerPlayerID)
        }
    }

    private func makeContent(
        state: ContentState,
        staleAfter: TimeInterval
    ) -> ActivityContent<ContentState> {
        let freshnessDeadline = Date.now.addingTimeInterval(max(15, staleAfter))
        let timerDeadline = state.timerEndsAt.map { $0.addingTimeInterval(60) }
        let staleDate: Date?

        if state.phase == .completed {
            staleDate = nil
        } else if state.isTimerRunning, let timerDeadline {
            // A deterministic countdown remains valid without per-turn pushes.
            // Don't dim a normal quiet match before its timer can expire.
            staleDate = max(freshnessDeadline, timerDeadline)
        } else {
            staleDate = freshnessDeadline
        }

        return ActivityContent(
            state: state,
            staleDate: staleDate,
            relevanceScore: relevanceScore(for: state.phase)
        )
    }

    private func relevanceScore(for phase: Attributes.MatchPhase) -> Double {
        switch phase {
        case .playing: 100
        case .voting: 90
        case .preparing: 60
        case .completed: 0
        }
    }

    private func validate(attributes: Attributes, state: ContentState) throws {
        guard !attributes.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControllerError.invalidRoomID
        }
        guard !attributes.matchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControllerError.invalidMatchID
        }
        guard !attributes.viewerPlayerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControllerError.invalidViewerPlayerID
        }

        let participantIDs = state.participants.map(\.id)
        let hasUnsafeIdentifier = participantIDs.contains { id in
            id.isEmpty || id.contains("@") || id.count > 128
        }
        guard !state.participants.isEmpty,
              state.participants.count <= 12,
              Set(participantIDs).count == participantIDs.count,
              !hasUnsafeIdentifier else {
            throw ControllerError.invalidParticipants
        }

        // ActivityKit caps the combined static and dynamic payload at 4 KB.
        // Keep headroom for system metadata that isn't represented here.
        let encoder = JSONEncoder()
        let attributesBytes = (try? encoder.encode(attributes).count) ?? Int.max
        let stateBytes = (try? encoder.encode(state).count) ?? Int.max
        guard attributesBytes <= 3_500,
              stateBytes <= 3_500,
              attributesBytes + stateBytes <= 3_500 else {
            throw ControllerError.payloadTooLarge
        }
    }

    private func makeRegistration(
        token: Data,
        for activity: Activity<Attributes>
    ) -> PushTokenRegistration {
        PushTokenRegistration(
            roomID: activity.attributes.roomID,
            matchID: activity.attributes.matchID,
            activityID: activity.id,
            viewerPlayerID: activity.attributes.viewerPlayerID,
            token: Self.hexEncoded(token)
        )
    }

    private func descriptor(
        for activity: Activity<Attributes>
    ) -> ActivityDescriptor {
        ActivityDescriptor(
            roomID: activity.attributes.roomID,
            matchID: activity.attributes.matchID,
            activityID: activity.id,
            viewerPlayerID: activity.attributes.viewerPlayerID
        )
    }

    private func lifecycleState(for state: ActivityState) -> LifecycleState {
        switch state {
        case .active: .active
        case .stale: .stale
        case .pending: .pending
        case .ended: .ended
        case .dismissed: .dismissed
        @unknown default: .unknown
        }
    }

    /// Visible Activities always win duplicate reconciliation over pending
    /// pushes, then the oldest deterministic instance wins within the tier.
    private func lifecyclePriority(_ state: ActivityState) -> Int {
        switch state {
        case .active, .stale: 0
        case .pending: 1
        case .ended, .dismissed: 2
        @unknown default: 3
        }
    }

    private static func hexEncoded(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
