import AVFoundation
import Network
import UserNotifications
import XCTest
@testable import SpyClash

final class OnboardingPermissionStatusMappingTests: XCTestCase {
    func testPermissionFlowRequiresGrantForEveryPermissionInStrictOrder() {
        var flow = OnboardingPermissionFlow()

        XCTAssertEqual(flow.currentPermission, .notifications)
        XCTAssertEqual(flow.phase, .loading)
        XCTAssertFalse(flow.advance(after: .notifications))
        XCTAssertFalse(flow.markReady(for: .camera))
        XCTAssertTrue(flow.markReady(for: .notifications))

        XCTAssertFalse(flow.resolveWithoutRequest(.denied, for: .notifications))
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .notifications))

        let deniedRequestID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .notifications,
                requestID: deniedRequestID
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .notifications,
                requestID: deniedRequestID,
                status: .denied
            )
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .notifications))
        XCTAssertFalse(flow.advance(after: .camera))

        let grantedRequestID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .notifications,
                requestID: grantedRequestID
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .notifications,
                requestID: grantedRequestID,
                status: .granted
            )
        )
        XCTAssertTrue(flow.advance(after: .notifications))
        XCTAssertEqual(flow.currentPermission, .camera)
        XCTAssertEqual(flow.phase, .ready)

        XCTAssertTrue(flow.resolveWithoutRequest(.granted, for: .camera))
        XCTAssertTrue(flow.advance(after: .camera))
        XCTAssertEqual(flow.currentPermission, .nearby)

        let unavailableRequestID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .nearby,
                requestID: unavailableRequestID
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .nearby,
                requestID: unavailableRequestID,
                status: .unavailable
            )
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .nearby))

        XCTAssertTrue(flow.resolveWithoutRequest(.granted, for: .nearby))
        XCTAssertTrue(flow.advance(after: .nearby))
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.currentPermission)
        XCTAssertEqual(flow.phase, .complete)
    }

    func testPermissionFlowRejectsStaleRequestResults() {
        var flow = OnboardingPermissionFlow()
        let currentRequestID = UUID()
        let staleRequestID = UUID()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(
            flow.beginRequest(
                for: .notifications,
                requestID: currentRequestID
            )
        )
        XCTAssertFalse(
            flow.resolveRequest(
                for: .notifications,
                requestID: staleRequestID,
                status: .granted
            )
        )
        XCTAssertEqual(flow.phase, .requesting(currentRequestID))
        XCTAssertFalse(
            flow.resolveRequest(
                for: .camera,
                requestID: currentRequestID,
                status: .granted
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .notifications,
                requestID: currentRequestID,
                status: .granted
            )
        )
        XCTAssertEqual(flow.phase, .resolved(.granted))
    }

    func testPermissionFlowOnlyRechecksSettingsAfterAppActuallyLeaves() {
        var flow = OnboardingPermissionFlow()
        let tripID = UUID()
        let recheckID = UUID()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(
            flow.beginSettingsTrip(
                for: .notifications,
                tripID: tripID
            )
        )
        XCTAssertFalse(
            flow.beginSettingsRecheck(
                for: .notifications,
                tripID: tripID,
                requestID: recheckID
            )
        )
        XCTAssertTrue(flow.markSettingsDidLeaveApp())
        XCTAssertFalse(flow.markSettingsDidLeaveApp())
        XCTAssertFalse(
            flow.beginSettingsRecheck(
                for: .notifications,
                tripID: UUID(),
                requestID: recheckID
            )
        )
        XCTAssertTrue(
            flow.beginSettingsRecheck(
                for: .notifications,
                tripID: tripID,
                requestID: recheckID
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .notifications,
                requestID: recheckID,
                status: .denied
            )
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .notifications))

        let grantedTripID = UUID()
        let grantedRecheckID = UUID()
        XCTAssertTrue(
            flow.beginSettingsTrip(
                for: .notifications,
                tripID: grantedTripID
            )
        )
        XCTAssertTrue(flow.markSettingsDidLeaveApp())
        XCTAssertTrue(
            flow.beginSettingsRecheck(
                for: .notifications,
                tripID: grantedTripID,
                requestID: grantedRecheckID
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .notifications,
                requestID: grantedRecheckID,
                status: .granted
            )
        )
        XCTAssertTrue(flow.advance(after: .notifications))
        XCTAssertEqual(flow.currentPermission, .camera)
    }

    func testPermissionFlowCanRecoverWhenSettingsFailsToOpen() {
        var flow = OnboardingPermissionFlow()
        let tripID = UUID()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(
            flow.beginSettingsTrip(
                for: .notifications,
                tripID: tripID
            )
        )
        XCTAssertFalse(
            flow.cancelSettingsTrip(
                for: .notifications,
                tripID: UUID()
            )
        )
        XCTAssertTrue(
            flow.cancelSettingsTrip(
                for: .notifications,
                tripID: tripID
            )
        )
        XCTAssertEqual(flow.phase, .ready)
    }

    func testNotificationAuthorizationStatusesMapToOnboardingStatuses() {
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.notifications(.notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.notifications(.denied),
            .denied
        )
        for status in [
            UNAuthorizationStatus.authorized,
            .provisional,
            .ephemeral
        ] {
            XCTAssertEqual(
                OnboardingPermissionStatusMapping.notifications(status),
                .granted
            )
        }
    }

    func testCameraAuthorizationStatusesMapToOnboardingStatuses() {
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.camera(.notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.camera(.authorized),
            .granted
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.camera(.denied),
            .denied
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.camera(.restricted),
            .unavailable
        )
    }

    func testNearbyPolicyDeniedUsesTN3179DNSServiceCode() {
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.localNetworkPolicyDeniedCode,
            -65_570
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.nearbyDNSServiceError(-65_570),
            .denied
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.nearbyDNSServiceError(-65_537),
            .unavailable
        )
    }

    func testNearbyBrowserReadyIsGrantedAndSetupHasNoResult() {
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.nearbyBrowserState(.ready),
            .granted
        )
        XCTAssertNil(
            OnboardingPermissionStatusMapping.nearbyBrowserState(.setup)
        )
    }

    func testPermissionKindsExposeStableUIIdentifiers() {
        XCTAssertEqual(
            OnboardingPermissionKind.allCases.map(\.rawValue),
            ["notifications", "camera", "nearby"]
        )
        XCTAssertEqual(
            OnboardingPermissionKind.allCases.map(\.id),
            ["notifications", "camera", "nearby"]
        )
    }

    @MainActor
    func testRadarTransportStaysDormantWhileOnboardingBlocksAccess() throws {
        let user = try JSONDecoder().decode(
            SpyUser.self,
            from: Data(#"{"id":"onboarding-user","email":"radar@example.com"}"#.utf8)
        )
        let radar = RadarNearbyService()

        radar.configure(user: user, allowsTransport: false)
        radar.setApplicationActive(true)
        radar.startScanning(requestCameraAccess: true)

        XCTAssertEqual(radar.scanState, .idle)
        XCTAssertTrue(radar.peers.isEmpty)
    }
}
