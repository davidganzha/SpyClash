import Foundation
import Observation

@MainActor
protocol MembershipClientProtocol: AnyObject {
    func checkSubscription() async throws -> MembershipSnapshot
}

extension Base44Client: MembershipClientProtocol {}

@MainActor
@Observable
final class MembershipStore {
    private(set) var snapshot: MembershipSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var scope = MembershipScope(userID: nil, accessToken: nil)
    private(set) var isPreview = false
    private(set) var revision = 0
    private(set) var evaluationDate = Date()
    private(set) var unlockPresentationID: UUID?
    @ObservationIgnored private var unlockHapticsID: UUID?
    @ObservationIgnored private let client: any MembershipClientProtocol
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<MembershipSnapshot, Error>?
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    init(
        client: any MembershipClientProtocol,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.now = now
        self.sleep = sleep
        evaluationDate = now()
    }

    deinit { expiryTask?.cancel() }

    var hasAccess: Bool {
        // Reading observable evaluationDate invalidates dependent screens when a
        // verified expiry arrives, even if the subsequent network read fails.
        snapshot?.grantsAccess(at: max(evaluationDate, now())) == true
    }
    var benefits: MembershipBenefits? {
        guard let snapshot else { return nil }
        return hasAccess ? snapshot.benefits : .free
    }
    var canPurchase: Bool {
        scope.isAuthenticated && !isPreview && !isLoading && errorMessage == nil &&
        snapshot?.isResolved == true && snapshot?.active == false &&
        snapshot?.checkoutRequired == true && !hasAccess
    }

    func bind(_ scope: MembershipScope, preview: MembershipSnapshot? = nil) {
        guard self.scope != scope || isPreview != (preview != nil) else { return }
        generation &+= 1
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        self.scope = scope
        snapshot = preview
        unlockPresentationID = nil
        unlockHapticsID = nil
        isPreview = preview != nil
        isLoading = false
        errorMessage = nil
        revision &+= 1
        evaluationDate = now()
        scheduleExpiry()
    }

    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        guard scope.isAuthenticated, !isPreview else { return isPreview }
        evaluationDate = max(evaluationDate, now())
        // A transaction or realtime signal describes a change after a read may
        // have started. Its follow-up must not reuse that older response.
        if force {
            refreshTask?.cancel()
            refreshTask = nil
        }
        let expected = generation
        let task: Task<MembershipSnapshot, Error>
        if let refreshTask { task = refreshTask }
        else {
            isLoading = true
            refreshID = UUID()
            task = Task { try await client.checkSubscription() }
            refreshTask = task
        }
        let expectedRefresh = refreshID
        do {
            let next = try await task.value
            guard generation == expected else { return false }
            guard refreshID == expectedRefresh else {
                return await awaitSupersedingRefresh(expectedGeneration: expected)
            }
            guard next.isResolved else { throw MembershipError.unavailable }
            let shouldCelebrate = snapshot != nil && !hasAccess &&
                next.grantsAccess(at: now()) && !next.isUniversal
            snapshot = next
            if shouldCelebrate { unlockPresentationID = UUID() }
            if !next.grantsAccess(at: now()) { unlockPresentationID = nil }
            errorMessage = nil
            isLoading = false
            refreshTask = nil
            revision &+= 1
            scheduleExpiry()
            return true
        } catch {
            guard generation == expected else { return false }
            guard refreshID == expectedRefresh else {
                return await awaitSupersedingRefresh(expectedGeneration: expected)
            }
            isLoading = false
            refreshTask = nil
            // Keep only the last verified snapshot; its expiry is still enforced.
            // An outage never changes unknown access to FREE or enables checkout.
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            revision &+= 1
            return false
        }
    }

    private func awaitSupersedingRefresh(expectedGeneration: Int) async -> Bool {
        guard generation == expectedGeneration else { return false }
        // StoreKit delivery and realtime may both request a fresh read. The
        // displaced caller joins the newer read instead of reporting a false
        // purchase failure while that authoritative read is succeeding.
        if refreshTask != nil {
            let refreshed = await refresh()
            return generation == expectedGeneration && refreshed
        }
        return snapshot?.isResolved == true && errorMessage == nil
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let snapshot, !snapshot.isUniversal, snapshot.active,
              let expiry = snapshot.expiresAt, expiry > now() else { return }
        let expectedGeneration = generation
        let wait = sleep
        let delay = expiry.timeIntervalSince(now())
        expiryTask = Task { [weak self] in
            do { try await wait(.seconds(max(0, delay))) } catch { return }
            guard !Task.isCancelled, let self,
                  self.generation == expectedGeneration,
                  self.snapshot?.expiresAt == expiry else { return }
            // Invalidate observed access exactly at expiry even when the
            // foreground poll is sleeping or its network request fails.
            self.evaluationDate = max(self.now(), expiry)
            self.unlockPresentationID = nil
            self.revision &+= 1
            self.expiryTask = nil
        }
    }

    func updateAIUsage(used: Int?, remaining: Int?) {
        guard var next = snapshot else { return }
        // hasAccess reads snapshot. Resolve it before replacing the observable
        // value, so an optional-chained write cannot overlap that read.
        let updatedRemaining = hasAccess ? nil : remaining.map { max(0, $0) }
        next.aiGenerationsToday = used.map { max(0, $0) }
        next.aiRemaining = updatedRemaining
        snapshot = next
    }

    // Root and presented sheets can both host the overlay. Announce/haptics once
    // for the verified transition, regardless of which host appears first.
    func claimUnlockFeedback(_ id: UUID) -> Bool {
        guard unlockPresentationID == id, unlockHapticsID != id else { return false }
        unlockHapticsID = id
        return true
    }

    func dismissUnlock(_ id: UUID) {
        guard unlockPresentationID == id else { return }
        unlockPresentationID = nil
    }
}

enum MembershipError: LocalizedError {
    case unavailable, accountChanged, verificationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Access could not be verified. Please retry."
        case .accountChanged: "Your account changed. Please retry from the current account."
        case .verificationFailed: "The purchase has not been verified by the server yet. Please restore purchases to retry."
        }
    }
}
