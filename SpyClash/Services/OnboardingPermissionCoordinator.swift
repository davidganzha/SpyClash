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

struct OnboardingPermissionFlow: Equatable, Sendable {
    struct SettingsTrip: Equatable, Sendable {
        let id: UUID
        var didLeaveApp = false
    }

    enum Phase: Equatable, Sendable {
        case loading
        case ready
        case requesting(UUID)
        case awaitingSettings(SettingsTrip)
        case resolved(OnboardingPermissionStatus)
        case complete
    }

    static let order: [OnboardingPermissionKind] = [
        .notifications,
        .camera,
        .nearby
    ]

    private(set) var index = 0
    private(set) var phase: Phase = .loading

    var currentPermission: OnboardingPermissionKind? {
        guard phase != .complete, Self.order.indices.contains(index) else {
            return nil
        }
        return Self.order[index]
    }

    var isComplete: Bool {
        phase == .complete
    }

    var settingsTrip: SettingsTrip? {
        guard case .awaitingSettings(let trip) = phase else { return nil }
        return trip
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
        phase = status == .granted ? .resolved(.granted) : .ready
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
              status == .granted else { return false }
        phase = .resolved(.granted)
        return true
    }

    @discardableResult
    mutating func beginSettingsTrip(
        for permission: OnboardingPermissionKind,
        tripID: UUID
    ) -> Bool {
        guard currentPermission == permission, phase == .ready else { return false }
        phase = .awaitingSettings(SettingsTrip(id: tripID))
        return true
    }

    @discardableResult
    mutating func cancelSettingsTrip(
        for permission: OnboardingPermissionKind,
        tripID: UUID
    ) -> Bool {
        guard currentPermission == permission,
              case .awaitingSettings(let trip) = phase,
              trip.id == tripID else { return false }
        phase = .ready
        return true
    }

    @discardableResult
    mutating func markSettingsDidLeaveApp() -> Bool {
        guard case .awaitingSettings(var trip) = phase,
              !trip.didLeaveApp else { return false }
        trip.didLeaveApp = true
        phase = .awaitingSettings(trip)
        return true
    }

    @discardableResult
    mutating func beginSettingsRecheck(
        for permission: OnboardingPermissionKind,
        tripID: UUID,
        requestID: UUID
    ) -> Bool {
        guard currentPermission == permission,
              case .awaitingSettings(let trip) = phase,
              trip.id == tripID,
              trip.didLeaveApp else { return false }
        phase = .requesting(requestID)
        return true
    }

    @discardableResult
    mutating func advance(after permission: OnboardingPermissionKind) -> Bool {
        guard currentPermission == permission,
              phase == .resolved(.granted) else { return false }

        index += 1
        phase = Self.order.indices.contains(index) ? .ready : .complete
        return true
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
    @ObservationIgnored
    private var activeRequest: OnboardingPermissionKind?

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
        let notificationAuthorization = await pushNotifications
            .notificationAuthorizationStatus()
        notificationsStatus = OnboardingPermissionStatusMapping.notifications(
            notificationAuthorization
        )
        cameraStatus = OnboardingPermissionStatusMapping.camera(
            AVCaptureDevice.authorizationStatus(for: .video)
        )

        if !Self.canEvaluateNearbyPrivacy {
            nearbyStatus = .unavailable
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
            await requestNearby()
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
