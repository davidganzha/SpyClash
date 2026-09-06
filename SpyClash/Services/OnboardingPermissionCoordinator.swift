import AVFoundation
import Foundation
import Network
import Observation
import UserNotifications

enum OnboardingPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case notifications
    case camera
    case nearby

    var id: String { rawValue }
}

enum OnboardingPermissionStatus: Equatable, Sendable {
    case notDetermined
    case requesting
    case granted
    case denied
    case unavailable
    /// Simulator cannot evaluate Local Network privacy or Nearby Interaction.
    case unsupported

    var allowsRadarInvitationSettings: Bool {
        self == .granted || self == .unsupported
    }

    var requiresLocalNetworkSettings: Bool { self == .denied }

    /// A cached grant can be revoked outside the app. Recheck on foreground,
    /// while allowing an existing system prompt/probe to finish uninterrupted.
    var canRefreshLocalNetworkOnActivation: Bool {
        self != .requesting && self != .unsupported
    }
}

struct OnboardingPermissionFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case ready
        case requesting(UUID)
        case resolved(OnboardingPermissionStatus)
        case complete
    }

    // Notifications and Camera are optional. The nearby step verifies the Local
    // Network access Radar needs for Bonjour discovery. Nearby Interaction is
    // requested later, automatically, once Radar has a real peer token.
    static let order: [OnboardingPermissionKind] = [
        .notifications,
        .camera,
        .nearby
    ]

    private(set) var index = 0
    private(set) var phase: Phase = .loading

    init(startingAt permission: OnboardingPermissionKind? = nil) {
        if let permission,
           let requestedIndex = Self.order.firstIndex(of: permission) {
            index = requestedIndex
        }
    }

    var currentPermission: OnboardingPermissionKind? {
        guard phase != .complete, Self.order.indices.contains(index) else {
            return nil
        }
        return Self.order[index]
    }

    var isComplete: Bool {
        phase == .complete
    }

    @discardableResult
    mutating func markReady(for permission: OnboardingPermissionKind) -> Bool {
        guard currentPermission == permission, phase == .loading else { return false }
        phase = .ready
        return true
    }

    @discardableResult
    mutating func beginRequest(
        for permission: OnboardingPermissionKind,
        requestID: UUID
    ) -> Bool {
        guard currentPermission == permission, phase == .ready else { return false }
        phase = .requesting(requestID)
        return true
    }

    @discardableResult
    mutating func resolveRequest(
        for permission: OnboardingPermissionKind,
        requestID: UUID,
        status: OnboardingPermissionStatus
    ) -> Bool {
        guard currentPermission == permission,
              phase == .requesting(requestID) else { return false }
        guard Self.statusCompletesStep(status, for: permission) else {
            phase = .ready
            return false
        }
        phase = .resolved(status)
        return true
    }

    @discardableResult
    mutating func cancelRequest(
        for permission: OnboardingPermissionKind,
        requestID: UUID
    ) -> Bool {
        guard currentPermission == permission,
              phase == .requesting(requestID) else { return false }
        phase = .ready
        return true
    }

    @discardableResult
    mutating func resolveWithoutRequest(
        _ status: OnboardingPermissionStatus,
        for permission: OnboardingPermissionKind
    ) -> Bool {
        guard currentPermission == permission,
              phase == .ready,
              Self.statusCompletesStep(status, for: permission) else { return false }
        phase = .resolved(status)
        return true
    }

    @discardableResult
    mutating func advance(after permission: OnboardingPermissionKind) -> Bool {
        guard currentPermission == permission,
              case .resolved(let status) = phase,
              Self.statusCompletesStep(status, for: permission) else { return false }

        index += 1
        phase = Self.order.indices.contains(index) ? .ready : .complete
        return true
    }

    static func statusCompletesStep(
        _ status: OnboardingPermissionStatus,
        for permission: OnboardingPermissionKind
    ) -> Bool {
        switch status {
        case .notDetermined, .requesting:
            false
        case .denied, .unavailable:
            // Radar cannot discover another iPhone until Local Network access
            // succeeds. Optional permissions may still be declined or absent.
            permission != .nearby
        case .granted, .unsupported:
            true
        }
    }
}

enum OnboardingPermissionStatusMapping {
    /// TN3179's `kDNSServiceErr_PolicyDenied` value returned by Bonjour.
    static let localNetworkPolicyDeniedCode = -65_570

    static func notifications(
        _ authorizationStatus: UNAuthorizationStatus
    ) -> OnboardingPermissionStatus {
        switch authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized, .provisional, .ephemeral:
            .granted
        @unknown default:
            .unavailable
        }
    }

    static func camera(
        _ authorizationStatus: AVAuthorizationStatus
    ) -> OnboardingPermissionStatus {
        switch authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .granted
        case .denied:
            .denied
        case .restricted:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    static func localNetworkDNSServiceError(
        _ code: Int
    ) -> OnboardingPermissionStatus {
        code == localNetworkPolicyDeniedCode ? .denied : .unavailable
    }

    static func localNetworkBrowserState(
        _ state: NWBrowser.State
    ) -> OnboardingPermissionStatus? {
        switch state {
        case .setup:
            nil
        case .ready:
            .granted
        case .waiting:
            // The first operation can enter policyDenied while iOS is still
            // presenting the Local Network alert. Keep the waiting-capable
            // browser alive so an Allow response can advance it to `.ready`.
            nil
        case .failed(let error):
            localNetwork(error)
        case .cancelled:
            nil
        @unknown default:
            .unavailable
        }
    }

    static func isLocalNetworkPolicyDeniedWaiting(
        _ state: NWBrowser.State
    ) -> Bool {
        guard case .waiting(let error) = state else { return false }
        return localNetwork(error) == .denied
    }

    private static func localNetwork(
        _ error: NWError
    ) -> OnboardingPermissionStatus {
        guard case .dns(let code) = error else {
            return .unavailable
        }
        return localNetworkDNSServiceError(Int(code))
    }
}

@MainActor
protocol LocalNetworkPermissionBrowser: AnyObject {
    func start(onStateChange: @escaping @MainActor @Sendable (NWBrowser.State) -> Void)
    func cancel()
}

@MainActor
private final class SystemLocalNetworkPermissionBrowser: LocalNetworkPermissionBrowser {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "com.spyclash.onboarding.local-network-permission")

    init() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(
            for: .bonjour(type: OnboardingPermissionCoordinator.radarBonjourServiceType, domain: nil),
            using: parameters
        )
    }

    func start(onStateChange: @escaping @MainActor @Sendable (NWBrowser.State) -> Void) {
        browser.stateUpdateHandler = { state in
            Task { @MainActor in onStateChange(state) }
        }
        browser.start(queue: queue)
    }

    func cancel() {
        browser.stateUpdateHandler = nil
        browser.cancel()
    }
}

@MainActor
@Observable
final class OnboardingPermissionCoordinator {
    static let radarBonjourServiceType = "_spyclash-radar._tcp"

    static var canEvaluateLocalNetworkPrivacy: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    private static var simulatedLocalNetworkStatus: OnboardingPermissionStatus? {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--spyclash-preview-local-network-denied") {
            return .denied
        }
#endif
        return nil
    }

    private(set) var notificationsStatus: OnboardingPermissionStatus = .notDetermined
    private(set) var cameraStatus: OnboardingPermissionStatus = .notDetermined
    private(set) var localNetworkStatus: OnboardingPermissionStatus

    @ObservationIgnored
    private let pushNotifications: PushNotificationCoordinator
    @ObservationIgnored
    private let canProbeLocalNetwork: Bool
    @ObservationIgnored
    private let localNetworkPreviewStatus: OnboardingPermissionStatus?
    @ObservationIgnored
    private let makeLocalNetworkBrowser: @MainActor () -> any LocalNetworkPermissionBrowser
    @ObservationIgnored
    private let sleepForLocalNetwork: @MainActor (Duration) async throws -> Void
    @ObservationIgnored
    private var localNetworkBrowser: (any LocalNetworkPermissionBrowser)?
    @ObservationIgnored
    private var localNetworkBrowserGenerationID: UUID?
    @ObservationIgnored
    private var localNetworkRequestID: UUID?
    @ObservationIgnored
    private var localNetworkTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    private var localNetworkDenialResolutionTask: Task<Void, Never>?
    @ObservationIgnored
    private var localNetworkContinuation: CheckedContinuation<
        OnboardingPermissionStatus,
        Never
    >?
    @ObservationIgnored
    private var pendingPolicyDeniedRequestID: UUID?
    @ObservationIgnored
    private var pendingPolicyDeniedBrowserGenerationID: UUID?
    @ObservationIgnored
    private var isPostPromptLocalNetworkVerification = false
    @ObservationIgnored
    private var isApplicationActive = false
    @ObservationIgnored
    private var activeRequest: OnboardingPermissionKind?

    init(
        pushNotifications: PushNotificationCoordinator = .shared,
        localNetworkBrowserFactory: (@MainActor () -> any LocalNetworkPermissionBrowser)? = nil,
        localNetworkSleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pushNotifications = pushNotifications
        // An injected browser models the permission protocol without invoking
        // Bonjour or implying Simulator can verify physical privacy settings.
        let canProbe = localNetworkBrowserFactory != nil || Self.canEvaluateLocalNetworkPrivacy
        let previewStatus = localNetworkBrowserFactory == nil ? Self.simulatedLocalNetworkStatus : nil
        canProbeLocalNetwork = canProbe
        localNetworkPreviewStatus = previewStatus
        makeLocalNetworkBrowser = localNetworkBrowserFactory ?? { SystemLocalNetworkPermissionBrowser() }
        sleepForLocalNetwork = localNetworkSleep
        localNetworkStatus = previewStatus ?? (canProbe ? .notDetermined : .unsupported)
    }

    func status(
        for permission: OnboardingPermissionKind
    ) -> OnboardingPermissionStatus {
        switch permission {
        case .notifications:
            notificationsStatus
        case .camera:
            cameraStatus
        case .nearby:
            localNetworkStatus
        }
    }

    /// Local Network's Bonjour probe can report `policyDenied` while iOS is
    /// still presenting its first-run alert. Keep the browser alive through
    /// that inactive interval, then verify with a new browser generation once
    /// the app is stably active. This separates the alert's provisional state
    /// from a real denial and also handles an access setting denied earlier.
    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        guard localNetworkRequestID != nil else { return }
        if !isActive {
            localNetworkDenialResolutionTask?.cancel()
            localNetworkDenialResolutionTask = nil
            return
        }
        schedulePolicyDeniedResolutionIfNeeded()
    }

    /// Refreshes permissions that expose a non-prompting status API.
    /// Local Network has no general status API. On a physical device its state
    /// is learned by running the explicit foreground Bonjour probe.
    func refresh() async {
        let notificationAuthorization = await pushNotifications
            .notificationAuthorizationStatus()
        notificationsStatus = OnboardingPermissionStatusMapping.notifications(
            notificationAuthorization
        )
        cameraStatus = OnboardingPermissionStatusMapping.camera(
            AVCaptureDevice.authorizationStatus(for: .video)
        )

        if !canProbeLocalNetwork {
            localNetworkStatus = localNetworkPreviewStatus ?? .unsupported
        }
    }

    @discardableResult
    func request(_ permission: OnboardingPermissionKind) async -> Bool {
        guard activeRequest == nil,
              status(for: permission) != .requesting else { return false }
        activeRequest = permission
        defer {
            if activeRequest == permission {
                activeRequest = nil
            }
        }

        switch permission {
        case .notifications:
            await requestNotifications()
        case .camera:
            await requestCamera()
        case .nearby:
            await requestLocalNetwork()
        }
        return true
    }

    private func requestNotifications() async {
        notificationsStatus = .requesting
        do {
            let authorizationStatus = try await pushNotifications
                .requestNotificationAuthorization()
            notificationsStatus = OnboardingPermissionStatusMapping.notifications(
                authorizationStatus
            )
        } catch is CancellationError {
            notificationsStatus = OnboardingPermissionStatusMapping.notifications(
                await pushNotifications.notificationAuthorizationStatus()
            )
        } catch {
            notificationsStatus = .unavailable
        }
    }

    private func requestCamera() async {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        guard current == .notDetermined else {
            cameraStatus = OnboardingPermissionStatusMapping.camera(current)
            return
        }

        cameraStatus = .requesting
        _ = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = OnboardingPermissionStatusMapping.camera(
            AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    private func requestLocalNetwork() async {
        if let simulatedStatus = localNetworkPreviewStatus {
            localNetworkStatus = simulatedStatus
            return
        }
        guard canProbeLocalNetwork else {
            // Simulator doesn't enforce Local Network privacy. A successful
            // browse there is transport evidence, not permission evidence.
            localNetworkStatus = .unsupported
            return
        }

        let startsInVerificationMode = localNetworkStatus == .denied
        let requestID = UUID()
        localNetworkStatus = .requesting
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<OnboardingPermissionStatus, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                beginLocalNetworkRequest(
                    requestID: requestID,
                    continuation: continuation,
                    startsInVerificationMode: startsInVerificationMode
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLocalNetworkRequest(
                    with: .unavailable,
                    requestID: requestID
                )
            }
        }
        localNetworkStatus = result
    }

    private func beginLocalNetworkRequest(
        requestID: UUID,
        continuation: CheckedContinuation<OnboardingPermissionStatus, Never>,
        startsInVerificationMode: Bool
    ) {
        stopLocalNetworkBrowser()

        localNetworkRequestID = requestID
        localNetworkContinuation = continuation
        pendingPolicyDeniedRequestID = nil
        pendingPolicyDeniedBrowserGenerationID = nil
        localNetworkDenialResolutionTask?.cancel()
        localNetworkDenialResolutionTask = nil
        startLocalNetworkBrowser(
            requestID: requestID,
            isVerification: startsInVerificationMode
        )
    }

    private func startLocalNetworkBrowser(
        requestID: UUID,
        isVerification: Bool
    ) {
        guard localNetworkRequestID == requestID else { return }
        stopLocalNetworkBrowser()

        let generationID = UUID()
        let browser = makeLocalNetworkBrowser()
        localNetworkBrowserGenerationID = generationID
        localNetworkBrowser = browser
        isPostPromptLocalNetworkVerification = isVerification

        browser.start { [weak self] state in
            guard let self,
                  self.localNetworkRequestID == requestID,
                  self.localNetworkBrowserGenerationID == generationID else { return }
            if OnboardingPermissionStatusMapping
                .isLocalNetworkPolicyDeniedWaiting(state) {
                self.pendingPolicyDeniedRequestID = requestID
                self.pendingPolicyDeniedBrowserGenerationID = generationID
                self.localNetworkTimeoutTask?.cancel()
                self.localNetworkTimeoutTask = nil
                self.schedulePolicyDeniedResolutionIfNeeded()
                return
            }
            guard let mappedStatus = OnboardingPermissionStatusMapping
                .localNetworkBrowserState(state) else {
                return
            }
            self.finishLocalNetworkRequest(with: mappedStatus, requestID: requestID)
        }

        localNetworkTimeoutTask?.cancel()
        localNetworkTimeoutTask = Task { @MainActor [weak self, sleepForLocalNetwork] in
            do {
                try await sleepForLocalNetwork(isVerification ? .seconds(5) : .seconds(30))
            } catch {
                return
            }
            guard self?.localNetworkRequestID == requestID,
                  self?.localNetworkBrowserGenerationID == generationID else {
                return
            }
            self?.finishLocalNetworkRequest(
                with: .unavailable,
                requestID: requestID
            )
        }
    }

    private func schedulePolicyDeniedResolutionIfNeeded() {
        guard isApplicationActive,
              let requestID = localNetworkRequestID,
              pendingPolicyDeniedRequestID == requestID,
              let generationID = localNetworkBrowserGenerationID,
              pendingPolicyDeniedBrowserGenerationID == generationID else { return }
        let isVerification = isPostPromptLocalNetworkVerification
        localNetworkDenialResolutionTask?.cancel()
        localNetworkDenialResolutionTask = Task { @MainActor [weak self, sleepForLocalNetwork] in
            do {
                // A first-run system alert moves the app inactive and cancels
                // this task. Stable activity means either the alert returned
                // or access had already been denied before this request.
                try await sleepForLocalNetwork(.milliseconds(isVerification ? 350 : 600))
            } catch {
                return
            }
            guard let self,
                  self.isApplicationActive,
                  self.localNetworkRequestID == requestID,
                  self.pendingPolicyDeniedRequestID == requestID,
                  self.localNetworkBrowserGenerationID == generationID,
                  self.pendingPolicyDeniedBrowserGenerationID == generationID else {
                return
            }
            if isVerification {
                self.finishLocalNetworkRequest(
                    with: .denied,
                    requestID: requestID
                )
                return
            }
            self.pendingPolicyDeniedRequestID = nil
            self.pendingPolicyDeniedBrowserGenerationID = nil
            self.localNetworkDenialResolutionTask = nil
            self.startLocalNetworkBrowser(
                requestID: requestID,
                isVerification: true
            )
        }
    }

    private func finishLocalNetworkRequest(
        with status: OnboardingPermissionStatus,
        requestID: UUID
    ) {
        guard localNetworkRequestID == requestID else { return }

        let continuation = localNetworkContinuation
        localNetworkContinuation = nil
        localNetworkRequestID = nil
        localNetworkTimeoutTask?.cancel()
        localNetworkTimeoutTask = nil
        localNetworkDenialResolutionTask?.cancel()
        localNetworkDenialResolutionTask = nil
        pendingPolicyDeniedRequestID = nil
        pendingPolicyDeniedBrowserGenerationID = nil
        isPostPromptLocalNetworkVerification = false
        stopLocalNetworkBrowser()
        localNetworkStatus = status
        continuation?.resume(returning: status)
    }

    private func stopLocalNetworkBrowser() {
        let browser = localNetworkBrowser
        localNetworkBrowser = nil
        localNetworkBrowserGenerationID = nil
        browser?.cancel()
    }
}
