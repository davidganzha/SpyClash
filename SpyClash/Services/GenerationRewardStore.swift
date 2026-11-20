import Foundation
import Observation

@MainActor
protocol GenerationRewardsClientProtocol: AnyObject {
    func generationRewardStatus() async throws -> GenerationRewardStatus
    func prepareGenerationReward(requestID: UUID) async throws -> GenerationRewardAttempt
    func generationRewardClaim(attemptID: UUID) async throws -> GenerationRewardClaim
}

extension Base44Client: GenerationRewardsClientProtocol {}

enum GenerationRewardPresentationPhase: Equatable {
    case idle, preparing, requestingConsent, readyToPresent, presenting, confirming
}

@MainActor
protocol GenerationRewardAdPresenting: AnyObject {
    var canOfferAds: Bool { get }
    var isOwnedSimulatorTestConfiguration: Bool { get }
    func present(attempt: GenerationRewardAttempt, onEarned: @escaping @MainActor () -> Void) async throws -> Bool
    func present(adUnitID: String, userID: String, customData: String, onEarned: @escaping @MainActor () -> Void) async throws -> Bool
    func present(attempt: GenerationRewardAttempt,
                 onPhaseChanged: @escaping @MainActor (GenerationRewardPresentationPhase) -> Void,
                 beforePresentation: @escaping @MainActor () async throws -> Void,
                 onEarned: @escaping @MainActor () -> Void) async throws -> Bool
    func preloadUnityAd() async
    func beginPresentationTrace()
    func cancelPendingPresentation()
}

extension GenerationRewardAdPresenting {
    var isOwnedSimulatorTestConfiguration: Bool { false }
    func preloadUnityAd() async {}
    func beginPresentationTrace() {}
    // Old presenters retain their original timing. SDK-aware implementations
    // call beforePresentation only once the creative and reward context exist.
    func present(attempt: GenerationRewardAttempt,
                 onPhaseChanged: @escaping @MainActor (GenerationRewardPresentationPhase) -> Void,
                 beforePresentation: @escaping @MainActor () async throws -> Void,
                 onEarned: @escaping @MainActor () -> Void) async throws -> Bool {
        onPhaseChanged(.presenting)
        return try await present(attempt: attempt, onEarned: onEarned)
    }
    func present(attempt: GenerationRewardAttempt, onEarned: @escaping @MainActor () -> Void) async throws -> Bool {
        guard attempt.provider == .admob else { throw RewardedGenerationAdError.unavailable }
        return try await present(adUnitID: attempt.adUnitID, userID: attempt.userID, customData: attempt.customData, onEarned: onEarned)
    }
}

extension RewardedGenerationAdPresenter: GenerationRewardAdPresenting {}

@MainActor @Observable
final class GenerationRewardStore {
    private(set) var snapshot: GenerationRewardStatus?
    private(set) var notice: GenerationRewardNotice?
    private(set) var isLoading = false
    private(set) var isWatching = false
    private(set) var pendingAttemptID: UUID?
    private(set) var isAwaitingReward = false
    private(set) var scope = MembershipScope(userID: nil, accessToken: nil)
    private(set) var isPreview = false
    private(set) var presentationPhase: GenerationRewardPresentationPhase = .idle
    private(set) var confirmedRewardAttemptID: UUID?
    @ObservationIgnored private var activePresentationEnd: (id: UUID, callback: @MainActor (Bool) -> Void)?
    @ObservationIgnored private var deferredConfirmedAttemptID: UUID?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private let presentationPause: (Duration) async throws -> Void
    @ObservationIgnored private let client: any GenerationRewardsClientProtocol
    @ObservationIgnored private let ads: any GenerationRewardAdPresenting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var watchID: UUID?
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var membershipEpoch = UUID()

    init(client: any GenerationRewardsClientProtocol, ads: any GenerationRewardAdPresenting = RewardedGenerationAdPresenter.shared, defaults: UserDefaults = .standard, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, presentationPause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client; self.ads = ads; self.defaults = defaults; self.sleep = sleep
        self.presentationPause = presentationPause
    }

    var canWatch: Bool {
        guard let snapshot else { return false }
        return snapshot.enabled && !snapshot.unlimited && snapshot.needsReward && snapshot.adAvailable && ads.canOfferAds && !isWatching && !isAwaitingReward
    }

    var showsTestAdControls: Bool {
        !isPreview && scope.isAuthenticated && ads.isOwnedSimulatorTestConfiguration
            && snapshot?.testAdAvailable == true
    }

    var canWatchTestAd: Bool {
        showsTestAdControls && snapshot?.testAdAvailable == true && ads.canOfferAds
            && !isWatching && !isAwaitingReward
    }

    func bind(_ scope: MembershipScope, preview: GenerationRewardStatus? = nil) {
        guard self.scope != scope || isPreview != (preview != nil) else { return }
        ads.cancelPendingPresentation()
        if let end = activePresentationEnd { endAdPresentation(end.id) }
        preloadTask?.cancel(); preloadTask = nil
        presentationPhase = .idle; confirmedRewardAttemptID = nil; deferredConfirmedAttemptID = nil
        refreshID = UUID(); watchID = nil; recoveryID = nil; membershipEpoch = UUID()
        self.scope = scope; snapshot = preview; isPreview = preview != nil
        notice = nil; isLoading = false; isWatching = false
        pendingAttemptID = preview == nil ? pendingKey.flatMap { defaults.string(forKey: $0) }.flatMap(UUID.init(uuidString:)) : nil
        isAwaitingReward = pendingAttemptID != nil && pendingKey.map { defaults.bool(forKey: $0 + ".earned") } == true
        if isAwaitingReward { notice = .confirming }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard scope.isAuthenticated || isPreview else { return false }
        if isPreview { return true }
        let account = scope, id = UUID()
        refreshID = id; isLoading = true
        defer { if refreshID == id { isLoading = false } }
        do {
            let status = try await client.generationRewardStatus()
            guard !Task.isCancelled, scope == account, refreshID == id else { return false }
            snapshot = status
            if pendingAttemptID != nil { await recoverPending() }
            preloadIfEligible()
            return true
        } catch {
            // Old servers may not expose the new service before rollout. Never
            // manufacture a FREE account or block their existing generation API.
            return false
        }
    }

    func reportLimitReached() { notice = .limitReached }
    func generationDidComplete() { notice = nil }

    /// A verified membership change invalidates stale ad/allowance UI at once.
    /// Access is populated by the next server response, never invented locally.
    /// Keep any completed viewing durable while its callback is still pending.
    func invalidateMembershipAccess() {
        guard !isPreview else { return }
        membershipEpoch = UUID(); refreshID = UUID(); recoveryID = nil
        snapshot = nil; isLoading = false
        notice = isAwaitingReward ? .confirming : nil
        cancelPresentation()
    }

    func watch(testAd: Bool = false, onAdPresentationChanged: (@MainActor (Bool) -> Void)? = nil) async {
        guard (testAd ? canWatchTestAd : canWatch), let accountID = scope.userID else { return }
        let account = scope, id = UUID(), epoch = membershipEpoch
        ads.beginPresentationTrace()
        watchID = id; isWatching = true; notice = nil; presentationPhase = .preparing
        confirmedRewardAttemptID = nil
        defer {
            endAdPresentation(id)
            if watchID == id {
                isWatching = false; watchID = nil
                presentationPhase = isAwaitingReward ? .confirming : .idle
                revealDeferredConfirmation()
                preloadIfEligible()
            }
        }
        do {
            let attempt: GenerationRewardAttempt
#if DEBUG
            if isPreview {
                attempt = GenerationRewardAttempt(attemptID: UUID(), customData: "isolated-preview", adUnitID: "ca-app-pub-3940256099942544/1712485313", userID: accountID)
            } else {
                attempt = try await client.prepareGenerationReward(requestID: id)
            }
#else
            attempt = try await client.prepareGenerationReward(requestID: id)
#endif
            try Task.checkCancellation()
            guard scope == account, watchID == id, membershipEpoch == epoch else { return }
            // Persist before presentation: an app interruption must not lose a
            // completed ad whose server callback arrives after the next launch.
            setPending(attempt.attemptID)
            let earned = try await ads.present(attempt: attempt, onPhaseChanged: { [weak self] phase in
                guard let self, self.scope == account, self.watchID == id, self.membershipEpoch == epoch else { return }
                self.presentationPhase = phase
                if phase == .presenting { self.beginAdPresentation(id, callback: onAdPresentationChanged) }
            }, beforePresentation: { [weak self] in
                guard let self, self.scope == account, self.watchID == id, self.membershipEpoch == epoch else { throw CancellationError() }
                try Task.checkCancellation()
                self.presentationPhase = .readyToPresent
                self.beginAdPresentation(id, callback: onAdPresentationChanged)
                try await self.presentationPause(.milliseconds(180))
                try Task.checkCancellation()
                guard self.scope == account, self.watchID == id, self.membershipEpoch == epoch else { throw CancellationError() }
            }) { [weak self] in
                guard let self, self.scope == account, self.watchID == id, self.pendingAttemptID == attempt.attemptID else { return }
                self.markAwaitingReward()
            }
            endAdPresentation(id)
            guard scope == account, watchID == id else { return }
            presentationPhase = .confirming
            revealDeferredConfirmation()
            if !earned {
                setPending(nil); notice = .incomplete
                return
            }
            // SSV can arrive while the ad's end card is still visible. Do not
            // recreate a pending state after that attempt was already credited.
            guard pendingAttemptID == attempt.attemptID else { return }
#if DEBUG
            if isPreview, let current = snapshot {
                // UI preview is fully local, never persisted or sent to a server.
                snapshot = GenerationRewardStatus(enabled: true, unlimited: false, freeRemaining: current.freeRemaining, bonusCredits: current.bonusCredits + 1, resetsAt: current.resetsAt, adAvailable: true)
                setPending(nil); notice = .earned
                confirmReward(attempt.attemptID)
                return
            }
#endif
            markAwaitingReward()
            notice = .confirming
            for _ in 0..<10 {
                await recoverPending()
                guard scope == account, pendingAttemptID != nil else { return }
                try await sleep(.seconds(3))
            }
        } catch {
            endAdPresentation(id)
            guard scope == account, watchID == id else { return }
            presentationPhase = isAwaitingReward ? .confirming : .idle
            revealDeferredConfirmation()
            if isAwaitingReward {
                // Cancellation/network failures are ambiguous. Keep the durable
                // attempt until the server confirms its final disposition.
                notice = .confirming
                if !Task.isCancelled { await recoverPending() }
            } else {
                setPending(nil)
                if let failure = error as? UnityRewardedGenerationAdError {
                    notice = .unavailableWithCode(failure.supportCode)
                } else if !(error is CancellationError) {
                    notice = .unavailable
                }
                if !Task.isCancelled { _ = await refresh() }
            }
        }
    }

    func recoverPending() async {
        guard !isPreview, recoveryID == nil, let attempt = pendingAttemptID else { return }
        let account = scope, id = UUID(), epoch = membershipEpoch
        recoveryID = id
        defer { if recoveryID == id { recoveryID = nil } }
        do {
            let result = try await client.generationRewardClaim(attemptID: attempt)
            guard !Task.isCancelled, account == scope, pendingAttemptID == attempt,
                  membershipEpoch == epoch, recoveryID == id else { return }
            snapshot = result.status
            if result.state == "earned" {
                setPending(nil); notice = .earned
                confirmReward(attempt)
            } else if ["expired", "cancelled", "rejected"].contains(result.state) {
                let completedViewing = isAwaitingReward
                setPending(nil)
                notice = completedViewing ? .unconfirmed : .unavailable
            } else if isAwaitingReward { notice = .confirming }
        } catch {
            // The persisted attempt is retried on activation, not by asking the
            // player to repeat an ad or manually recover their reward.
        }
    }

    func dismissRewardCelebration(_ attemptID: UUID) {
        guard confirmedRewardAttemptID == attemptID else { return }
        confirmedRewardAttemptID = nil
    }

    func cancelPresentation() {
        // A displayed SDK ad owns dismissal. A completed viewing must retain its
        // durable confirmation even when its original generation view disappears.
        guard [.preparing, .requestingConsent, .readyToPresent].contains(presentationPhase) else { return }
        ads.cancelPendingPresentation()
        if let id = watchID { endAdPresentation(id) }
        watchID = nil; isWatching = false; presentationPhase = .idle
        if !isAwaitingReward { setPending(nil) }
    }

    private func beginAdPresentation(_ id: UUID, callback: (@MainActor (Bool) -> Void)?) {
        guard activePresentationEnd == nil, let callback else { return }
        activePresentationEnd = (id, callback)
        callback(true)
    }

    private func endAdPresentation(_ id: UUID) {
        guard let end = activePresentationEnd, end.id == id else { return }
        activePresentationEnd = nil
        end.callback(false)
    }

    private func confirmReward(_ attemptID: UUID) {
        if presentationPhase == .presenting {
            deferredConfirmedAttemptID = attemptID
        } else {
            confirmedRewardAttemptID = attemptID
        }
    }

    private func revealDeferredConfirmation() {
        guard let attempt = deferredConfirmedAttemptID else { return }
        deferredConfirmedAttemptID = nil
        confirmedRewardAttemptID = attempt
    }

    private func preloadIfEligible() {
        guard !isPreview, scope.isAuthenticated, let status = snapshot,
              status.enabled, !status.unlimited, status.adAvailable, ads.canOfferAds,
              preloadTask == nil else { return }
        let account = scope, epoch = membershipEpoch
        preloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preloadTask = nil }
            guard !Task.isCancelled, self.scope == account, self.membershipEpoch == epoch else { return }
            await self.ads.preloadUnityAd()
        }
    }

#if DEBUG
    func consumePreviewGeneration() -> Bool {
        guard isPreview, let current = snapshot else { return true }
        guard current.canGenerate else { notice = .limitReached; return false }
        guard !current.unlimited else { return true }
        let free = current.freeRemaining ?? 0
        snapshot = GenerationRewardStatus(enabled: true, unlimited: false, freeRemaining: max(0, free - 1), bonusCredits: current.bonusCredits - (free > 0 ? 0 : 1), resetsAt: current.resetsAt, adAvailable: true)
        notice = nil
        return true
    }
#endif

    private var pendingKey: String? { scope.userID.map { "spyclash.generation-reward.pending.v1." + $0 } }
    private func markAwaitingReward() {
        isAwaitingReward = true
        if !isPreview, let key = pendingKey { defaults.set(true, forKey: key + ".earned") }
    }
    private func setPending(_ attempt: UUID?) {
        pendingAttemptID = attempt
        if attempt == nil { isAwaitingReward = false }
        guard !isPreview, let key = pendingKey else { return }
        defaults.removeObject(forKey: key + ".earned")
        if let attempt { defaults.set(attempt.uuidString, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
