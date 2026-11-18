import Foundation
import Observation
import OSLog
import UIKit
@preconcurrency import UnityAds

enum UnityRewardedGenerationAdError: LocalizedError {
    case unavailable
    case alreadyPresenting
    case presentationUnavailable
    case incompatibleInitialization
    case initializationFailed(String)
    case loadFailed(String)
    case presentationFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: "Rewarded Unity ads are not configured in this build."
        case .alreadyPresenting: "Another advertising or privacy screen is already open."
        case .presentationUnavailable: "Return to the generation screen and try again."
        case .incompatibleInitialization: "Unity Ads was initialized with a different configuration. Relaunch the app."
        case .initializationFailed(let message): "Unity Ads initialization failed: \(message)"
        case .loadFailed(let message): "Unity Ads could not load the ad: \(message)"
        case .presentationFailed(let message): "Unity Ads could not show the ad: \(message)"
        case .timedOut: "Unity Ads did not respond in time. Please try again."
        }
    }
}

/// An explicit rewarded viewing bound to a server-issued attempt. SDK callbacks
/// only tell the store to poll; the signed server callback alone grants credit.
@MainActor
@Observable
final class UnityRewardedGenerationAdPresenter: NSObject {
    enum Status: Equatable {
        case idle, initializing, loading, ready, presenting, completed, skipped, cancelled
        case failed(String)
    }

    private(set) var isBusy = false
    private(set) var status: Status = .idle

    @ObservationIgnored private let configuration: UnityRewardedGenerationAdConfiguration
    @ObservationIgnored private var initializedForRewards = false
    @ObservationIgnored private var initializationIsPending = false
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var loadingID: UUID?
    @ObservationIgnored private var cachedAd: UADSRewardedAd?
    @ObservationIgnored private var cachedAt: Date?
    @ObservationIgnored private var lastPreparationFailure: Date?
    @ObservationIgnored private var preparationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var nextTrace: PresentationTrace?
    private static let logger = Logger(subsystem: "com.spyclash.ios", category: "RewardedAds")

    init(configuration: UnityRewardedGenerationAdConfiguration = .current) {
        self.configuration = configuration
        super.init()
        // Construction performs no SDK initialization or network request.
    }

    var isConfigured: Bool { configuration.isConfigured }
    var isPresentingAd: Bool { operation?.phase == .presenting }

    func beginPresentationTrace() {
        let cache = cachedAd != nil && cachedAt.map { Date().timeIntervalSince($0) < 120 } == true
            ? "ready" : (preparationID != nil ? "loading" : "cold")
        nextTrace = PresentationTrace(tappedAt: ProcessInfo.processInfo.systemUptime, cache: cache)
    }

    /// Preloading carries no player identifier and creates no reward attempt.
    /// The SDK request is shared with a later explicit viewing.
    func preload() {
        guard isConfigured, UIApplication.shared.applicationState == .active, !isBusy else { return }
        if let lastPreparationFailure, Date().timeIntervalSince(lastPreparationFailure) < 15 { return }
        prepareAd()
    }

    /// A true result means reward confirmation should be polled, not granted.
    func present(attempt: GenerationRewardAttempt, onEarned: @escaping @MainActor () -> Void) async throws -> Bool {
        try await present(attempt: attempt, onPhaseChanged: { _ in }, beforePresentation: {}, onEarned: onEarned)
    }

    func present(
        attempt: GenerationRewardAttempt,
        onPhaseChanged: @escaping @MainActor (GenerationRewardPresentationPhase) -> Void,
        beforePresentation: @escaping @MainActor () async throws -> Void,
        onEarned: @escaping @MainActor () -> Void
    ) async throws -> Bool {
        guard configuration.permits(attempt), let serverID = attempt.serverID else {
            throw UnityRewardedGenerationAdError.unavailable
        }
        return try await present(serverID: serverID, onPhaseChanged: onPhaseChanged,
                                 beforePresentation: beforePresentation, onStarted: {}, onEarned: onEarned)
    }

    /// A guest viewing has no server capability and cannot credit any account.
    func presentGuest(onStarted: @escaping @MainActor () -> Void) async throws -> Bool {
        guard isConfigured else { throw UnityRewardedGenerationAdError.unavailable }
        return try await present(serverID: nil, onPhaseChanged: { _ in },
                                 beforePresentation: {}, onStarted: onStarted, onEarned: {})
    }

    private func present(
        serverID: String?,
        onPhaseChanged: @escaping @MainActor (GenerationRewardPresentationPhase) -> Void,
        beforePresentation: @escaping @MainActor () async throws -> Void,
        onStarted: @escaping @MainActor () -> Void,
        onEarned: @escaping @MainActor () -> Void
    ) async throws -> Bool {
        guard !isBusy else { throw UnityRewardedGenerationAdError.alreadyPresenting }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active,
              let presenter = Self.visiblePresenter() else {
            throw UnityRewardedGenerationAdError.presentationUnavailable
        }

        let id = UUID()
        let trace = nextTrace ?? PresentationTrace(tappedAt: ProcessInfo.processInfo.systemUptime, cache: "untracked")
        nextTrace = nil
        let cancellation = UnityGenerationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation = Operation(id: id, presenter: presenter, serverID: serverID,
                                      onPhaseChanged: onPhaseChanged, beforePresentation: beforePresentation,
                                      onStarted: onStarted, onEarned: onEarned, trace: trace,
                                      cancellation: cancellation, continuation: continuation)
                isBusy = true
                onPhaseChanged(.preparing)
                observePendingPresentation(id)
                prepareAd()
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            Task { @MainActor in
                guard self?.operation?.id == id else { return }
                self?.cancelPendingPresentation()
            }
        }
    }

    /// A visible SDK ad retains control of its dismissal and delegate.
    func cancelPendingPresentation() {
        guard let operation, operation.phase != .presenting else { return }
        finish(operation.id, result: .failure(CancellationError()))
    }

    private func prepareAd() {
        if let cachedAd, let cachedAt, Date().timeIntervalSince(cachedAt) < 120 {
            if let operation { schedulePresentation(cachedAd, operationID: operation.id) }
            return
        }
        cachedAd = nil
        cachedAt = nil
        guard preparationID == nil else { return }
        let id = UUID()
        preparationID = id
        preparationTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.preparationID == id else { return }
            self?.preparationFailed(UnityRewardedGenerationAdError.timedOut)
        }
        if initializedForRewards { loadRewardedAd(id); return }
        setStatus(.initializing)
        // Unity offers no cancellation API for initialization. A later caller
        // joins its result, including after an earlier caller's bounded wait.
        guard !initializationIsPending else { return }
        guard !UnityAds.isInitialized() else {
            preparationFailed(UnityRewardedGenerationAdError.incompatibleInitialization)
            return
        }
        UnityAds.setUserConsent(false)
        UnityAds.setUserOptOut(true)
        UnityAds.setNonBehavioral(true)
        initializationIsPending = true
        let sdkConfiguration = UADSInitializationConfigurationBuilder(gameId: configuration.gameID)
            .with(testMode: configuration.usesTestAds)
            .build()
        UnityAds.initialize(sdkConfiguration) { [weak self] error in
            let failure = error.map { "\($0.code): \($0.message)" }
            Task { @MainActor in
                guard let self else { return }
                self.initializationIsPending = false
                self.initializedForRewards = failure == nil
                guard let current = self.preparationID else { return }
                if let failure {
                    self.preparationFailed(UnityRewardedGenerationAdError.initializationFailed(failure))
                } else {
                    self.loadRewardedAd(current)
                }
            }
        }
    }

    private func loadRewardedAd(_ id: UUID) {
        guard preparationID == id, loadingID == nil else { return }
        loadingID = id
        setStatus(.loading)
        let config = UADSLoadConfigurationBuilder(placementId: configuration.adUnitID).build()
        UADSRewardedAd.load(config) { [weak self] ad, error in
            let failure = error.map { "\($0.code): \($0.message)" }
            let transfer = UnityGenerationLoadedAdTransfer(ad)
            Task { @MainActor in
                guard let self, self.preparationID == id, self.loadingID == id else { return }
                self.loadingID = nil
                if let failure {
                    self.preparationFailed(UnityRewardedGenerationAdError.loadFailed(failure))
                } else if let ad = transfer.ad {
                    self.preparationID = nil
                    self.preparationTimeoutTask?.cancel()
                    self.preparationTimeoutTask = nil
                    self.lastPreparationFailure = nil
                    self.cachedAd = ad
                    self.cachedAt = Date()
                    let adID = ObjectIdentifier(ad)
                    ad.onAdExpired = { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.cachedAd.map(ObjectIdentifier.init) == adID else { return }
                            self.cachedAd = nil
                            self.cachedAt = nil
                        }
                    }
                    self.setStatus(.ready)
                    if let current = self.operation { self.schedulePresentation(ad, operationID: current.id) }
                } else {
                    self.preparationFailed(UnityRewardedGenerationAdError.loadFailed("No ad was returned."))
                }
            }
        }
    }

    private func preparationFailed(_ error: Error) {
        preparationID = nil
        loadingID = nil
        preparationTimeoutTask?.cancel()
        preparationTimeoutTask = nil
        lastPreparationFailure = Date()
        setStatus(.failed(error.localizedDescription))
        if let current = operation, current.phase != .presenting {
            finish(current.id, result: .failure(error))
        }
    }

    private func schedulePresentation(_ ad: UADSRewardedAd, operationID id: UUID) {
        guard let current = operation, current.id == id, current.phase == .preparing else { return }
        cachedAd = nil
        cachedAt = nil
        ad.onAdExpired = nil
        current.ad = ad
        current.phase = .readyToPresent
        presentationTask = Task { @MainActor [weak self] in
            do {
                try await current.beforePresentation()
                try self?.validatePendingOperation(id)
                guard let self, let operation = self.operation, operation.id == id,
                      let presenter = operation.presenter else { return }
                self.navigationTask?.cancel()
                self.navigationTask = nil
                operation.phase = .presenting
                operation.onPhaseChanged(.presenting)
                self.setStatus(.presenting)
                let builder = UADSShowConfigurationBuilder().with(viewController: presenter)
                let show = operation.serverID.map { builder.with(customRewardString: $0).build() } ?? builder.build()
                ad.show(show, delegate: self)
            } catch { self?.finish(id, result: .failure(error)) }
        }
    }

    private func validatePendingOperation(_ id: UUID) throws {
        guard let operation, operation.id == id else { throw CancellationError() }
        guard !operation.cancellation.isCancelled else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active,
              let presenter = operation.presenter,
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed,
              Self.visiblePresenter() === presenter else {
            throw UnityRewardedGenerationAdError.presentationUnavailable
        }
    }

    private func observePendingPresentation(_ id: UUID) {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.operation?.id == id else { return }
                self?.cancelPendingPresentation()
            }
        }
        navigationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self, let current = self.operation, current.id == id,
                      current.phase != .presenting else { return }
                do { try self.validatePendingOperation(id) }
                catch { self.finish(id, result: .failure(error)); return }
            }
        }
    }

    private func finish(_ id: UUID, result: Result<Bool, Error>) {
        guard let current = operation, current.id == id else { return }
        operation = nil
        presentationTask?.cancel()
        presentationTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        isBusy = false
        switch result {
        case .success(let completed): setStatus(completed ? .completed : .skipped)
        case .failure(is CancellationError): setStatus(.cancelled)
        case .failure(let error): setStatus(.failed(error.localizedDescription))
        }
        current.continuation.resume(with: result)
    }

    private func setStatus(_ value: Status) {
        status = value
    }

    private func presentingOperation(for adID: ObjectIdentifier) -> Operation? {
        guard let operation, operation.phase == .presenting,
              let ad = operation.ad, ObjectIdentifier(ad) == adID else { return nil }
        return operation
    }

    private static func visiblePresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return nil }
        func top(_ controller: UIViewController) -> UIViewController {
            if let presented = controller.presentedViewController, !presented.isBeingDismissed { return top(presented) }
            if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController { return top(visible) }
            if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { return top(selected) }
            return controller
        }
        let visible = top(root)
        guard visible.viewIfLoaded?.window != nil, !visible.isBeingDismissed else { return nil }
        return visible
    }

    private struct PresentationTrace {
        let tappedAt: TimeInterval
        let cache: String
    }

    @MainActor
    private final class Operation {
        enum Phase { case preparing, readyToPresent, presenting }
        let id: UUID
        let serverID: String?
        let onPhaseChanged: @MainActor (GenerationRewardPresentationPhase) -> Void
        let beforePresentation: @MainActor () async throws -> Void
        let onStarted: @MainActor () -> Void
        let onEarned: @MainActor () -> Void
        let trace: PresentationTrace
        var didLogShowStart = false
        var didReceiveReward = false
        weak var presenter: UIViewController?
        let cancellation: UnityGenerationCancellation
        let continuation: CheckedContinuation<Bool, Error>
        var phase: Phase = .preparing
        var ad: UADSRewardedAd?

        init(id: UUID, presenter: UIViewController, serverID: String?,
             onPhaseChanged: @escaping @MainActor (GenerationRewardPresentationPhase) -> Void,
             beforePresentation: @escaping @MainActor () async throws -> Void,
             onStarted: @escaping @MainActor () -> Void,
             onEarned: @escaping @MainActor () -> Void, trace: PresentationTrace,
             cancellation: UnityGenerationCancellation, continuation: CheckedContinuation<Bool, Error>) {
            self.id = id
            self.serverID = serverID
            self.onPhaseChanged = onPhaseChanged
            self.beforePresentation = beforePresentation
            self.onStarted = onStarted
            self.onEarned = onEarned
            self.trace = trace
            self.presenter = presenter
            self.cancellation = cancellation
            self.continuation = continuation
        }
    }
}

extension UnityRewardedGenerationAdPresenter: UADSRewardedShowDelegate {
    nonisolated func showDidStart(_ unityAd: UADSRewardedAd) {
        let adID = ObjectIdentifier(unityAd)
        Task { @MainActor [weak self] in
            guard let self, let current = self.presentingOperation(for: adID) else { return }
            if !current.didLogShowStart {
                current.didLogShowStart = true
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - current.trace.tappedAt) * 1_000)
                Self.logger.notice("unity_show_started elapsed_ms=\(elapsed, privacy: .public) cache=\(current.trace.cache, privacy: .public)")
            }
            current.onStarted()
            self.setStatus(.presenting)
        }
    }

    nonisolated func showDidClick(_ unityAd: UADSRewardedAd) {}

    nonisolated func showDidComplete(_ unityAd: UADSRewardedAd, with finishState: UADSShowFinishState) {
        let adID = ObjectIdentifier(unityAd)
        let completed = finishState == .completed
        Task { @MainActor [weak self] in
            guard let self, let current = self.presentingOperation(for: adID) else { return }
            if completed && !current.didReceiveReward {
                current.didReceiveReward = true
                current.onEarned()
            }
            self.finish(current.id, result: .success(current.didReceiveReward))
        }
    }

    nonisolated func showDidFail(_ unityAd: UADSRewardedAd, error: UnityAdsError) {
        let adID = ObjectIdentifier(unityAd)
        let message = "\(error.code): \(error.message)"
        Task { @MainActor [weak self] in
            guard let self, let current = self.presentingOperation(for: adID) else { return }
            self.finish(current.id, result: .failure(UnityRewardedGenerationAdError.presentationFailed(message)))
        }
    }

    nonisolated func showDidReceiveReward(_ unityAd: UADSRewardedAd) {
        let adID = ObjectIdentifier(unityAd)
        Task { @MainActor [weak self] in
            guard let self, let current = self.presentingOperation(for: adID), !current.didReceiveReward else { return }
            current.didReceiveReward = true
            current.onEarned()
            // Keep the SDK ad and delegate alive until its terminal callback.
        }
    }
}

/// Transfers the callback's opaque SDK object to MainActor exactly once. Our code
/// never accesses the object off MainActor after constructing this wrapper.
private final class UnityGenerationLoadedAdTransfer: @unchecked Sendable {
    let ad: UADSRewardedAd?
    init(_ ad: UADSRewardedAd?) { self.ad = ad }
}

/// Only this flag crosses actors synchronously; every access is lock-protected.
private final class UnityGenerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
