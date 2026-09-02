import AVFoundation
import Foundation
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
    /// Nearby Interaction can only be verified once Radar has a real peer token.
    case deferredToRadar

    var completesOnboardingStep: Bool {
        switch self {
        case .granted, .denied, .unavailable, .deferredToRadar:
            true
        case .notDetermined, .requesting:
            false
        }
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

    // Notifications and Camera are optional system requests. Nearby Interaction
    // is explained here, then verified by Radar once a real peer token exists.
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
        guard status.completesOnboardingStep else {
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
              status.completesOnboardingStep else { return false }
        phase = .resolved(status)
        return true
    }

    @discardableResult
    mutating func advance(after permission: OnboardingPermissionKind) -> Bool {
        guard currentPermission == permission,
              case .resolved(let status) = phase,
              status.completesOnboardingStep else { return false }

        index += 1
        phase = Self.order.indices.contains(index) ? .ready : .complete
        return true
    }
}

enum OnboardingPermissionStatusMapping {
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
}

@MainActor
@Observable
final class OnboardingPermissionCoordinator {
    private(set) var notificationsStatus: OnboardingPermissionStatus = .notDetermined
    private(set) var cameraStatus: OnboardingPermissionStatus = .notDetermined
    private(set) var nearbyStatus: OnboardingPermissionStatus = .deferredToRadar

    @ObservationIgnored
    private let pushNotifications: PushNotificationCoordinator
    @ObservationIgnored
    private var activeRequest: OnboardingPermissionKind?

    init(pushNotifications: PushNotificationCoordinator = .shared) {
        self.pushNotifications = pushNotifications
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
    /// Nearby Interaction deliberately remains deferred until Radar has a real
    /// nearby peer token and can run an actual `NISession` configuration.
    func refresh() async {
        let notificationAuthorization = await pushNotifications
            .notificationAuthorizationStatus()
        notificationsStatus = OnboardingPermissionStatusMapping.notifications(
            notificationAuthorization
        )
        cameraStatus = OnboardingPermissionStatusMapping.camera(
            AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    @discardableResult
    func request(_ permission: OnboardingPermissionKind) async -> Bool {
        // There is no standalone Nearby Interaction authorization request.
        // Radar performs the real request and verification with an external
        // peer token; onboarding must never substitute a Local Network probe.
        guard permission != .nearby else { return false }
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
            return false
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
}
