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
            extras.additionalParameters = ["npa": "1"]
            request.register(extras)
            let ad = try await RewardedAd.load(with: adUnitID, request: request)
            try validatePendingOperation(id, presenter: presenter)

            let options = ServerSideVerificationOptions()
            options.userIdentifier = userID
            options.customRewardText = customData
            ad.serverSideVerificationOptions = options
            try ad.canPresent(from: presenter)

            let attempt = RewardedGenerationAdAttempt(ad: ad, onEarned: onEarned)
            presentation = attempt
            // Once visible, the SDK owns dismissal. Cancellation prevents future
            // autoplay but cannot replace an earned result with a second ad.
            return try await attempt.present(from: presenter)
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
            Task { @MainActor in self?.cancelPendingPresentation() }
        }
    }

    private func endOperation(_ id: UUID) {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        presentation = nil
        if operationID == id { operationID = nil }
        isBusy = false
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
