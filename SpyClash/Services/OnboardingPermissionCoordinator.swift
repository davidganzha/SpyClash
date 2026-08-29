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

    static func nearbyDNSServiceError(
        _ code: Int
    ) -> OnboardingPermissionStatus {
        code == localNetworkPolicyDeniedCode ? .denied : .unavailable
    }

    static func nearbyBrowserState(
        _ state: NWBrowser.State
    ) -> OnboardingPermissionStatus? {
        switch state {
        case .setup:
            nil
        case .ready:
            .granted
        case .waiting(let error), .failed(let error):
            nearby(error)
        case .cancelled:
            nil
        @unknown default:
            .unavailable
        }
    }

    private static func nearby(_ error: NWError) -> OnboardingPermissionStatus {
        guard case .dns(let code) = error else {
            return .unavailable
        }
        return nearbyDNSServiceError(Int(code))
    }
}

@MainActor
@Observable
final class OnboardingPermissionCoordinator {
    static var canEvaluateNearbyPrivacy: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    private(set) var notificationsStatus: OnboardingPermissionStatus = .notDetermined
    private(set) var cameraStatus: OnboardingPermissionStatus = .notDetermined
    private(set) var nearbyStatus: OnboardingPermissionStatus

    @ObservationIgnored
    private let pushNotifications: PushNotificationCoordinator
    @ObservationIgnored
    private let nearbyQueue = DispatchQueue(
        label: "com.spyclash.onboarding.nearby-permission"
    )
    @ObservationIgnored
    private var nearbyBrowser: NWBrowser?
    @ObservationIgnored
    private var nearbyRequestID: UUID?
    @ObservationIgnored
    private var nearbyTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    private var nearbyContinuation: CheckedContinuation<
        OnboardingPermissionStatus,
        Never
    >?

    init(pushNotifications: PushNotificationCoordinator = .shared) {
        self.pushNotifications = pushNotifications
        nearbyStatus = Self.canEvaluateNearbyPrivacy ? .notDetermined : .unavailable
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
            nearbyStatus
        }
    }

    /// Refreshes permissions that expose a non-prompting status API.
    ///
    /// Local Network has no general status API. On a physical device its state
    /// is learned only after the user explicitly requests `.nearby`.
    func refresh() async {
        async let notificationAuthorization = pushNotifications
            .notificationAuthorizationStatus()
        let cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)

        notificationsStatus = OnboardingPermissionStatusMapping.notifications(
            await notificationAuthorization
        )
        cameraStatus = OnboardingPermissionStatusMapping.camera(cameraAuthorization)

        if !Self.canEvaluateNearbyPrivacy {
            nearbyStatus = .unavailable
        }
    }

    func request(_ permission: OnboardingPermissionKind) async {
        guard status(for: permission) != .requesting else { return }

        switch permission {
        case .notifications:
            await requestNotifications()
        case .camera:
            await requestCamera()
        case .nearby:
            await requestNearby()
        }
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

    private func requestNearby() async {
        guard Self.canEvaluateNearbyPrivacy else {
            // Simulator does not enforce Local Network privacy. A successful
            // browse there is transport evidence, not permission evidence.
            nearbyStatus = .unavailable
            return
        }

        nearbyStatus = .requesting
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                beginNearbyRequest(continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishNearbyRequest(with: .unavailable)
            }
        }
        nearbyStatus = result
    }

    private func beginNearbyRequest(
        continuation: CheckedContinuation<OnboardingPermissionStatus, Never>
    ) {
        stopNearbyBrowser()

        let requestID = UUID()
        let browser = NWBrowser(
            for: .bonjour(type: "_spyclash-radar._tcp", domain: nil),
            using: .tcp
        )
        nearbyRequestID = requestID
        nearbyContinuation = continuation
        nearbyBrowser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let mappedStatus = OnboardingPermissionStatusMapping
                .nearbyBrowserState(state) else {
                return
            }
            Task { @MainActor [weak self] in
                guard self?.nearbyRequestID == requestID else { return }
                self?.finishNearbyRequest(with: mappedStatus)
            }
        }
        browser.start(queue: nearbyQueue)

        nearbyTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard self?.nearbyRequestID == requestID else { return }
            self?.finishNearbyRequest(with: .unavailable)
        }
    }

    private func finishNearbyRequest(with status: OnboardingPermissionStatus) {
        guard nearbyRequestID != nil else { return }

        let continuation = nearbyContinuation
        nearbyContinuation = nil
        nearbyRequestID = nil
        nearbyTimeoutTask?.cancel()
        nearbyTimeoutTask = nil
        stopNearbyBrowser()
        nearbyStatus = status
        continuation?.resume(returning: status)
    }

    private func stopNearbyBrowser() {
        let browser = nearbyBrowser
        nearbyBrowser = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
    }
}
