#if DEBUG
import Foundation
import Observation
import UIKit
@preconcurrency import UnityAds

enum UnityAdsTestError: LocalizedError {
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
        case .unavailable: "Unity Ads testing is not enabled in this build."
        case .alreadyPresenting: "Another advertising or privacy screen is already open."
        case .presentationUnavailable: "Return to the ad test screen and try again."
        case .incompatibleInitialization: "Unity Ads was initialized outside this test session. Relaunch the app."
        case .initializationFailed(let message): "Unity Ads initialization failed: \(message)"
        case .loadFailed(let message): "Unity Ads could not load the test ad: \(message)"
        case .presentationFailed(let message): "Unity Ads could not show the test ad: \(message)"
        case .timedOut: "Unity Ads did not respond in time. Please try again."
        }
    }
}

/// A viewing-only, explicitly requested SDK preview. It never contacts the reward
/// backend or grants a generation credit, even when Unity reports a reward.
@MainActor
@Observable
final class UnityAdsTestPresenter: NSObject {
    enum Status: Equatable {
        case idle, initializing, loading, presenting, completed, skipped, cancelled
        case failed(String)
    }

    static let shared = UnityAdsTestPresenter()

    private(set) var isBusy = false
    private(set) var status: Status = .idle

    @ObservationIgnored private let configuration: UnityAdsTestConfiguration
    @ObservationIgnored private var initializedForTest = false
    @ObservationIgnored private var initializationIsPending = false
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?

    init(configuration: UnityAdsTestConfiguration = .current) {
        self.configuration = configuration
        super.init()
        // Construction performs no SDK initialization or network request.
    }

    /// Returns whether the preview finished, never an authorization for a reward.
    func present() async throws -> Bool {
        guard configuration.isEnabled,
              !configuration.gameID.isEmpty, !configuration.adUnitID.isEmpty else {
            throw UnityAdsTestError.unavailable
        }
        guard !isBusy, !RewardedGenerationAdPresenter.shared.isBusy else {
            throw UnityAdsTestError.alreadyPresenting
        }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active,
              let presenter = Self.visiblePresenter() else {
            throw UnityAdsTestError.presentationUnavailable
        }

        let id = UUID()
        let cancellation = UnityAdsPreviewCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation = Operation(id: id, presenter: presenter, cancellation: cancellation, continuation: continuation)
                isBusy = true
                observePendingPresentation(id)
                initializeForPreview(id)
            }
        } onCancel: { [weak self] in
            // Mark synchronously so an already queued SDK callback cannot show
            // before the actor processes this cancellation handler's task.
            cancellation.cancel()
            Task { @MainActor in
                guard self?.operation?.id == id else { return }
                self?.cancelPendingPresentation()
            }
        }
    }

    /// The screen calls this on navigation away. A visible SDK ad retains control
    /// of its dismissal; cancellation never closes it or releases its delegate.
    func cancelPendingPresentation() {
        guard let operation, operation.phase != .presenting else { return }
        finish(operation.id, result: .failure(CancellationError()))
    }

    private func initializeForPreview(_ id: UUID) {
        do { try validatePendingOperation(id) }
        catch { finish(id, result: .failure(error)); return }
        if initializedForTest {
            loadPreview(id)
            return
        }

        setStatus(.initializing)
        startTimeout(id, phase: .initializing)
        // A timed-out/cancelled caller does not restart an SDK initialization
        // still in flight. A new explicit request can wait for the same result.
        guard !initializationIsPending else { return }
        guard !UnityAds.isInitialized() else {
            finish(id, result: .failure(UnityAdsTestError.incompatibleInitialization))
            return
        }

        UnityAds.setUserConsent(false)
        UnityAds.setUserOptOut(true)
        UnityAds.setNonBehavioral(true)
        initializationIsPending = true
        let sdkConfiguration = UADSInitializationConfigurationBuilder(gameId: configuration.gameID)
            .with(testMode: true)
            .build()
        UnityAds.initialize(sdkConfiguration) { [weak self] error in
            // Copy only Sendable values from the SDK callback before hopping.
            let failure = error.map { "\($0.code): \($0.message)" }
            Task { @MainActor in
                guard let self else { return }
                self.initializationIsPending = false
                self.initializedForTest = failure == nil
                guard let current = self.operation, current.phase == .initializing else { return }
                if let failure {
                    self.finish(current.id, result: .failure(UnityAdsTestError.initializationFailed(failure)))
                } else {
                    self.loadPreview(current.id)
                }
            }
        }
    }

    private func loadPreview(_ id: UUID) {
        do { try validatePendingOperation(id) }
        catch { finish(id, result: .failure(error)); return }
        operation?.phase = .loading
        setStatus(.loading)
        startTimeout(id, phase: .loading)
        let loadConfiguration = UADSLoadConfigurationBuilder(placementId: configuration.adUnitID).build()
        UADSRewardedAd.load(loadConfiguration) { [weak self] ad, error in
            let failure = error.map { "\($0.code): \($0.message)" }
            let transfer = LoadedAdTransfer(ad)
            Task { @MainActor in
                guard let self, self.operation?.id == id, self.operation?.phase == .loading else { return }
                if let failure {
                    self.finish(id, result: .failure(UnityAdsTestError.loadFailed(failure)))
                } else if let ad = transfer.ad {
                    self.showPreview(ad, operationID: id)
                } else {
                    self.finish(id, result: .failure(UnityAdsTestError.loadFailed("No ad was returned.")))
                }
            }
        }
    }

    private func showPreview(_ ad: UADSRewardedAd, operationID id: UUID) {
        do { try validatePendingOperation(id) }
        catch { finish(id, result: .failure(error)); return }
        guard let operation, let presenter = operation.presenter else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        operation.ad = ad
        operation.phase = .presenting
        setStatus(.presenting)
        // Mark the request as presenting before entering SDK code. From here to
        // its terminal callback, only the SDK can dismiss its own screen.
        ad.show(UADSShowConfigurationBuilder().with(viewController: presenter).build(), delegate: self)
    }

    private func validatePendingOperation(_ id: UUID) throws {
        guard let operation, operation.id == id else { throw CancellationError() }
        guard !operation.cancellation.isCancelled else { throw CancellationError() }
        guard !RewardedGenerationAdPresenter.shared.isBusy else {
            throw UnityAdsTestError.alreadyPresenting
        }
        guard UIApplication.shared.applicationState == .active,
              let presenter = operation.presenter,
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed,
              Self.visiblePresenter() === presenter else {
            throw UnityAdsTestError.presentationUnavailable
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

    private func startTimeout(_ id: UUID, phase: Operation.Phase) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            guard let self, self.operation?.id == id, self.operation?.phase == phase else { return }
            self.finish(id, result: .failure(UnityAdsTestError.timedOut))
        }
    }

    private func finish(_ id: UUID, result: Result<Bool, Error>) {
        guard let current = operation, current.id == id else { return }
        operation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
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
        print("[UnityAdsTest] \(value)")
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

    @MainActor
    private final class Operation {
        enum Phase { case initializing, loading, presenting }
        let id: UUID
        weak var presenter: UIViewController?
        let cancellation: UnityAdsPreviewCancellation
        let continuation: CheckedContinuation<Bool, Error>
        var phase: Phase = .initializing
        var ad: UADSRewardedAd?

        init(id: UUID, presenter: UIViewController, cancellation: UnityAdsPreviewCancellation, continuation: CheckedContinuation<Bool, Error>) {
            self.id = id
            self.presenter = presenter
            self.cancellation = cancellation
            self.continuation = continuation
        }
    }
}

extension UnityAdsTestPresenter: UADSRewardedShowDelegate {
    nonisolated func showDidStart(_ unityAd: UADSRewardedAd) {
        let adID = ObjectIdentifier(unityAd)
        Task { @MainActor [weak self] in
            guard let self, self.presentingOperation(for: adID) != nil else { return }
            self.setStatus(.presenting)
        }
    }

    nonisolated func showDidClick(_ unityAd: UADSRewardedAd) {}

    nonisolated func showDidComplete(_ unityAd: UADSRewardedAd, with finishState: UADSShowFinishState) {
        let adID = ObjectIdentifier(unityAd)
        let completed = finishState == .completed
        Task { @MainActor [weak self] in
            guard let self, let current = self.presentingOperation(for: adID) else { return }
            self.finish(current.id, result: .success(completed))
        }
    }

    nonisolated func showDidFail(_ unityAd: UADSRewardedAd, error: UnityAdsError) {
        let adID = ObjectIdentifier(unityAd)
        let message = "\(error.code): \(error.message)"
        Task { @MainActor [weak self] in
            guard let self, let current = self.presentingOperation(for: adID) else { return }
            self.finish(current.id, result: .failure(UnityAdsTestError.presentationFailed(message)))
        }
    }

    nonisolated func showDidReceiveReward(_ unityAd: UADSRewardedAd) {
        // Deliberately ignored: this local preview never grants a real reward and
        // continues retaining the ad until its terminal show callback.
    }
}

/// Transfers the callback's opaque SDK object to MainActor exactly once. Our code
/// never accesses the object off MainActor after constructing this wrapper.
private final class LoadedAdTransfer: @unchecked Sendable {
    let ad: UADSRewardedAd?
    init(_ ad: UADSRewardedAd?) { self.ad = ad }
}

/// Only this flag crosses actors synchronously; every access is lock-protected.
private final class UnityAdsPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
#endif
