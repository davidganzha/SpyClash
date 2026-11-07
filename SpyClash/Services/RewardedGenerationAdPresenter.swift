import Foundation
import Observation
import UIKit
@preconcurrency import GoogleMobileAds
@preconcurrency import UserMessagingPlatform

enum RewardedGenerationAdError: LocalizedError {
    case unavailable
    case alreadyPresenting
    case consentUnavailable
    case invalidRewardContext
    case presentationUnavailable
    case privacyOptionsUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "Rewarded ads are not available in this build."
        case .alreadyPresenting: "An advertising or privacy screen is already open."
        case .consentUnavailable: "Advertising is not available with the current privacy settings."
        case .invalidRewardContext: "The reward could not be prepared. Please try again."
        case .presentationUnavailable: "Return to the generation screen to watch the ad."
        case .privacyOptionsUnavailable: "There are no advertising privacy options to display."
        }
    }
}

/// Presents one explicitly requested ad. A true return value is only the SDK's
/// earned signal; the caller must wait for its server to confirm the reward.
@MainActor
@Observable
final class RewardedGenerationAdPresenter: NSObject {
    static let shared = RewardedGenerationAdPresenter()

    private(set) var isBusy = false
    private(set) var privacyOptionsRequired = false
    var isConfigured: Bool { configuration.isConfigured }
    var canOfferAds: Bool { isConfigured && !isBusy }
    var isTestConfiguration: Bool { configuration.isTestConfiguration }
    var configuredAdUnitID: String { configuration.adUnitID }

    @ObservationIgnored private let configuration: RewardedGenerationAdConfiguration
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var presentation: RewardedGenerationAdAttempt?
    @ObservationIgnored private var contentTransition: RewardedGenerationAdTransition?
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?

    init(configuration: RewardedGenerationAdConfiguration = .current) {
        self.configuration = configuration
        super.init()
        // Merely constructing this object does not touch either SDK.
    }

    func present(
        adUnitID: String,
        userID: String,
        customData: String,
        onEarned: @escaping @MainActor () -> Void = {}
    ) async throws -> Bool {
        guard configuration.permits(adUnitID: adUnitID) else { throw RewardedGenerationAdError.unavailable }
        // SSV identifiers are opaque IDs, never an email address or player name.
        guard !userID.isEmpty, userID.utf8.count <= 256,
              !userID.contains("@"), userID.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !customData.isEmpty, customData.utf8.count <= 2_048 else {
            throw RewardedGenerationAdError.invalidRewardContext
        }
        guard !isBusy else { throw RewardedGenerationAdError.alreadyPresenting }
        try Task.checkCancellation()
        guard let presenter = Self.visiblePresenter() else { throw RewardedGenerationAdError.presentationUnavailable }

        let id = UUID()
        operationID = id
        isBusy = true
        observeBackgrounding()
        defer { endOperation(id) }

        return try await withTaskCancellationHandler {
            try await updateConsent(from: presenter, operation: id)
            try validatePendingOperation(id, presenter: presenter)
            guard ConsentInformation.shared.canRequestAds else { throw RewardedGenerationAdError.consentUnavailable }

            configurePrivacyBeforeInitialization()
            if !initialized {
                await MobileAds.shared.start()
                initialized = true
            }
            try validatePendingOperation(id, presenter: presenter)
            guard ConsentInformation.shared.canRequestAds else { throw RewardedGenerationAdError.consentUnavailable }

            let request = Request()
            let extras = Extras()
            var requestParameters = ["npa": "1"]
#if DEBUG
            // Compare an official test creative without changing live ad delivery.
            if configuration.isTestConfiguration,
               ProcessInfo.processInfo.arguments.contains("--spyclash-preview-ad-trueview") {
                requestParameters["ft_ctype"] = "trueview"
            }
#endif
            extras.additionalParameters = requestParameters
            request.register(extras)
            let ad = try await RewardedAd.load(with: adUnitID, request: request)
            try validatePendingOperation(id, presenter: presenter)

            let options = ServerSideVerificationOptions()
            options.userIdentifier = userID
            options.customRewardText = customData
            ad.serverSideVerificationOptions = options
            try ad.canPresent(from: presenter)

            // Capture only app-owned content, before the SDK creates its modal.
            // Include the sheet's presenting content so its margins fade too.
            let transition = RewardedGenerationAdTransition(contentViews: Self.appContentViews(below: presenter))
            contentTransition = transition
            await transition.fadeToBlack(reduceMotion: Self.reduceMotion)
            do {
                // Loading and the fade both yield; neither may autoplay after
                // the user leaves this screen or backgrounds the app.
                try validatePendingOperation(id, presenter: presenter)
                try ad.canPresent(from: presenter)
                let attempt = RewardedGenerationAdAttempt(ad: ad, onEarned: onEarned)
                presentation = attempt
                // Once visible, the SDK owns dismissal and its entire ad UI.
                let earned = try await attempt.present(from: presenter)
                await transition.revealContent(reduceMotion: Self.reduceMotion, animated: Self.canReveal(presenter))
                return earned
            } catch {
                await transition.revealContent(reduceMotion: Self.reduceMotion, animated: Self.canReveal(presenter))
                throw error
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.operationID == id else { return }
                self?.cancelPendingPresentation()
            }
        }
    }

    /// Call together with task cancellation when the generation sheet disappears.
    /// Does not forcibly close a video the user has already chosen to watch.
    func cancelPendingPresentation() {
        guard presentation == nil else { return }
        operationID = nil
        contentTransition?.remove()
    }

    func presentPrivacyOptions() async throws {
        guard isConfigured else { throw RewardedGenerationAdError.unavailable }
        guard !isBusy else { throw RewardedGenerationAdError.alreadyPresenting }
        guard let presenter = Self.visiblePresenter() else { throw RewardedGenerationAdError.presentationUnavailable }
        try Task.checkCancellation()
        let id = UUID()
        operationID = id
        isBusy = true
        observeBackgrounding()
        defer { endOperation(id) }
        try await withTaskCancellationHandler {
            // Refresh consent in this launch before using any UMP privacy API.
            try await requestConsentUpdate()
            refreshPrivacyOptionsRequirement()
            try validatePendingOperation(id, presenter: presenter)
            guard privacyOptionsRequired else { throw RewardedGenerationAdError.privacyOptionsUnavailable }
            try await ConsentForm.presentPrivacyOptionsForm(from: presenter)
            refreshPrivacyOptionsRequirement()
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.operationID == id else { return }
                self?.cancelPendingPresentation()
            }
        }
    }

    private func updateConsent(from presenter: UIViewController, operation id: UUID) async throws {
        do {
            try await requestConsentUpdate()
            refreshPrivacyOptionsRequirement()
            try validatePendingOperation(id, presenter: presenter)
            if ConsentInformation.shared.consentStatus == .required {
                let form = try await ConsentForm.load()
                // Keep consent loading separate from presentation so navigating
                // away cannot cause a delayed privacy modal either.
                try validatePendingOperation(id, presenter: presenter)
                try await form.present(from: presenter)
            }
        } catch {
            refreshPrivacyOptionsRequirement()
            // UMP may retain a still-valid choice after a transient update error.
            // Cancellation/navigation are never converted into consent success.
            try validatePendingOperation(id, presenter: presenter)
            guard ConsentInformation.shared.canRequestAds else { throw error }
        }
        refreshPrivacyOptionsRequirement()
    }

    private func requestConsentUpdate() async throws {
        let parameters = RequestParameters()
        // Until the app has a verified age flow, apply the most protective age
        // treatment to every request; do not infer that a player is an adult.
        parameters.isTaggedForUnderAgeOfConsent = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func configurePrivacyBeforeInitialization() {
        let requestConfiguration = MobileAds.shared.requestConfiguration
        requestConfiguration.ageRestrictedTreatment = .child
        requestConfiguration.maxAdContentRating = .general
        requestConfiguration.publisherPrivacyPersonalizationState = .disabled
        requestConfiguration.setPublisherFirstPartyIDEnabled(false)
        requestConfiguration.coarseLocationCollectionEnabled = false
        // No ATT prompt, contextual keywords, location, or personal profile data.
    }

    private func refreshPrivacyOptionsRequirement() {
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    private func validatePendingOperation(_ id: UUID, presenter: UIViewController) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active,
              presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed,
              Self.visiblePresenter() === presenter else {
            throw RewardedGenerationAdError.presentationUnavailable
        }
    }

    private func observeBackgrounding() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelPendingPresentation()
                // Never retain an opaque app overlay across backgrounding,
                // including while an SDK-owned video is already visible.
                self?.contentTransition?.remove()
            }
        }
    }

    private func endOperation(_ id: UUID) {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        contentTransition?.remove()
        contentTransition = nil
        presentation = nil
        if operationID == id { operationID = nil }
        isBusy = false
    }

    private static var reduceMotion: Bool {
        InterfacePreferences.shared.settings.effectiveReduceMotion(system: UIAccessibility.isReduceMotionEnabled)
    }

    private static func canReveal(_ presenter: UIViewController) -> Bool {
        UIApplication.shared.applicationState == .active &&
        presenter.viewIfLoaded?.window != nil && !presenter.isBeingDismissed
    }

    private static func appContentViews(below presenter: UIViewController) -> [UIView] {
        var views: [UIView] = []
        var current: UIViewController? = presenter
        while let controller = current {
            var container = controller
            while let parent = container.parent { container = parent }
            if let view = container.viewIfLoaded { views.append(view) }
            current = container.presentingViewController
        }
        return views
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
}

/// These overlays stay inside existing app views, below any SDK presentation.
/// Removing one also finishes an interrupted animation waiter exactly once.
@MainActor
final class RewardedGenerationAdTransition {
    private var overlays: [UIView]
    private var animator: UIViewPropertyAnimator?
    private var continuation: CheckedContinuation<Void, Never>?

    init(contentViews: [UIView]) {
        overlays = contentViews.map { content in
            let overlay = UIView(frame: content.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = .black
            overlay.alpha = 0
            overlay.accessibilityElementsHidden = true
            // Briefly block the app's controls during the transition only.
            // The SDK modal is above these views and keeps all its controls.
            overlay.isUserInteractionEnabled = true
            content.addSubview(overlay)
            return overlay
        }
    }

    func fadeToBlack(reduceMotion: Bool) async {
        await animate(to: 1, duration: reduceMotion ? 0 : 0.22)
    }

    func revealContent(reduceMotion: Bool, animated: Bool) async {
        await animate(to: 0, duration: animated && !reduceMotion ? 0.28 : 0)
        remove()
    }

    func remove() {
        let waiting = continuation
        continuation = nil
        animator?.stopAnimation(true)
        animator = nil
        overlays.forEach { $0.removeFromSuperview() }
        overlays.removeAll()
        waiting?.resume()
    }

    private func animate(to alpha: CGFloat, duration: TimeInterval) async {
        guard !overlays.isEmpty else { return }
        guard duration > 0 else {
            overlays.forEach { $0.alpha = alpha }
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut) { [overlays] in
                overlays.forEach { $0.alpha = alpha }
            }
            self.animator = animator
            animator.addCompletion { [weak self] _ in
                guard let self else { return }
                self.animator = nil
                let waiting = self.continuation
                self.continuation = nil
                waiting?.resume()
            }
            animator.startAnimation()
        }
    }
}

/// Each ad owns its delegate and one continuation. A late callback from a previous
/// ad can never finish a later operation or grant a second reward.
@MainActor
private final class RewardedGenerationAdAttempt: NSObject, FullScreenContentDelegate {
    private let ad: RewardedAd
    private let onEarned: @MainActor () -> Void
    private var continuation: CheckedContinuation<Bool, Error>?
    private var earned = false

    init(ad: RewardedAd, onEarned: @escaping @MainActor () -> Void) {
        self.ad = ad
        self.onEarned = onEarned
        super.init()
        ad.fullScreenContentDelegate = self
    }

    func present(from presenter: UIViewController) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            ad.present(from: presenter) { [weak self] in
                guard let self, !self.earned else { return }
                self.earned = true
                // Journal this signal before dismissal so process termination
                // cannot erase the caller's pending-confirmation state.
                self.onEarned()
            }
        }
    }

    func adDidDismissFullScreenContent(_ ad: any FullScreenPresentingAd) {
        finish(.success(earned))
    }

    func ad(_ ad: any FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Bool, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
