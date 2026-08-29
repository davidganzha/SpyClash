import AVFoundation
import Network
import UserNotifications
import XCTest
@testable import SpyClash

final class OnboardingPermissionStatusMappingTests: XCTestCase {
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
