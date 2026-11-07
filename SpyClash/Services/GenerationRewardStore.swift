import Foundation
import Observation

@MainActor
protocol GenerationRewardsClientProtocol: AnyObject {
    func generationRewardStatus() async throws -> GenerationRewardStatus
    func prepareGenerationReward(requestID: UUID) async throws -> GenerationRewardAttempt
    func generationRewardClaim(attemptID: UUID) async throws -> GenerationRewardClaim
}

extension Base44Client: GenerationRewardsClientProtocol {}

@MainActor
protocol GenerationRewardAdPresenting: AnyObject {
    var canOfferAds: Bool { get }
    var isOwnedSimulatorTestConfiguration: Bool { get }
    func present(adUnitID: String, userID: String, customData: String, onEarned: @escaping @MainActor () -> Void) async throws -> Bool
    func cancelPendingPresentation()
}

extension GenerationRewardAdPresenting {
    var isOwnedSimulatorTestConfiguration: Bool { false }
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
    @ObservationIgnored private let client: any GenerationRewardsClientProtocol
    @ObservationIgnored private let ads: any GenerationRewardAdPresenting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var watchID: UUID?
    @ObservationIgnored private var recoveryID: UUID?

    init(client: any GenerationRewardsClientProtocol, ads: any GenerationRewardAdPresenting = RewardedGenerationAdPresenter.shared, defaults: UserDefaults = .standard, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client; self.ads = ads; self.defaults = defaults; self.sleep = sleep
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
        refreshID = UUID(); watchID = nil; recoveryID = nil
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
            return true
        } catch {
            // Old servers may not expose the new service before rollout. Never
            // manufacture a FREE account or block their existing generation API.
            return false
        }
    }

    func reportLimitReached() { notice = .limitReached }
    func generationDidComplete() { notice = nil }

    func watch(testAd: Bool = false) async {
        guard (testAd ? canWatchTestAd : canWatch), let accountID = scope.userID else { return }
        let account = scope, id = UUID()
        watchID = id; isWatching = true; notice = nil
        defer { if watchID == id { isWatching = false; watchID = nil } }
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
            guard scope == account, watchID == id else { return }
            // Persist before presentation: an app interruption must not lose a
            // completed ad whose server callback arrives after the next launch.
            setPending(attempt.attemptID)
            let earned = try await ads.present(adUnitID: attempt.adUnitID, userID: attempt.userID, customData: attempt.customData) { [weak self] in
                guard let self, self.scope == account, self.watchID == id, self.pendingAttemptID == attempt.attemptID else { return }
                self.markAwaitingReward()
            }
            guard scope == account, watchID == id else { return }
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
            guard scope == account, watchID == id else { return }
            if isAwaitingReward {
                // Cancellation/network failures are ambiguous. Keep the durable
                // attempt until the server confirms its final disposition.
                notice = .confirming
                if !Task.isCancelled { await recoverPending() }
            } else {
                setPending(nil)
                if !(error is CancellationError) { notice = .unavailable }
                if !Task.isCancelled { _ = await refresh() }
            }
        }
    }

    func recoverPending() async {
        guard !isPreview, recoveryID == nil, let attempt = pendingAttemptID else { return }
        let account = scope, id = UUID()
        recoveryID = id
        defer { if recoveryID == id { recoveryID = nil } }
        do {
            let result = try await client.generationRewardClaim(attemptID: attempt)
            guard !Task.isCancelled, account == scope, pendingAttemptID == attempt else { return }
            snapshot = result.status
            if result.state == "earned" {
                setPending(nil); notice = .earned
            } else if ["expired", "cancelled", "rejected"].contains(result.state) {
                setPending(nil); notice = .unavailable
            } else if isAwaitingReward { notice = .confirming }
        } catch {
            // The persisted attempt is retried on activation, not by asking the
            // player to repeat an ad or manually recover their reward.
        }
    }

    func cancelPresentation() { ads.cancelPendingPresentation() }

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
