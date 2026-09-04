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
    @ObservationIgnored private let client: any MembershipClientProtocol
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<MembershipSnapshot, Error>?
    @ObservationIgnored private var refreshID = UUID()

    init(client: any MembershipClientProtocol) { self.client = client }

    var hasAccess: Bool {
        // Reading observable evaluationDate invalidates dependent screens when a
        // verified expiry arrives, even if the subsequent network read fails.
        snapshot?.grantsAccess(at: max(evaluationDate, Date())) == true
    }
    var benefits: MembershipBenefits? {
        guard let snapshot else { return nil }
        return hasAccess ? snapshot.benefits : .free
    }
    var canPurchase: Bool {
        scope.isAuthenticated && !isPreview && !isLoading && errorMessage == nil &&
        snapshot?.isResolved == true && snapshot?.checkoutRequired == true && !hasAccess
    }

    func bind(_ scope: MembershipScope, preview: MembershipSnapshot? = nil) {
        guard self.scope != scope || isPreview != (preview != nil) else { return }
        generation &+= 1
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        self.scope = scope
        snapshot = preview
        isPreview = preview != nil
        isLoading = false
        errorMessage = nil
        revision &+= 1
        evaluationDate = Date()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard scope.isAuthenticated, !isPreview else { return isPreview }
        evaluationDate = Date()
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
            guard generation == expected, refreshID == expectedRefresh else { return false }
            guard next.isResolved else { throw MembershipError.unavailable }
            snapshot = next
            errorMessage = nil
            isLoading = false
            refreshTask = nil
            revision &+= 1
            return true
        } catch {
            guard generation == expected, refreshID == expectedRefresh else { return false }
            isLoading = false
            refreshTask = nil
            // Keep only the last verified snapshot; its expiry is still enforced.
            // An outage never changes unknown access to FREE or enables checkout.
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            revision &+= 1
            return false
        }
    }

    func updateAIUsage(used: Int?, remaining: Int?) {
        guard snapshot != nil else { return }
        snapshot?.aiGenerationsToday = used.map { max(0, $0) }
        snapshot?.aiRemaining = hasAccess ? nil : remaining.map { max(0, $0) }
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
