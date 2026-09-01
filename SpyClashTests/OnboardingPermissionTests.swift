import AVFoundation
import Network
import UserNotifications
import XCTest
@testable import SpyClash

final class OnboardingPermissionStatusMappingTests: XCTestCase {
    func testPermissionFlowRequiresEveryStepButNotEveryGrant() {
        var flow = OnboardingPermissionFlow()

        XCTAssertEqual(OnboardingPermissionFlow.order, [.notifications])
        XCTAssertEqual(flow.currentPermission, .notifications)
        XCTAssertEqual(flow.phase, .loading)
        XCTAssertFalse(flow.advance(after: .notifications))
        XCTAssertFalse(flow.markReady(for: .camera))
        XCTAssertTrue(flow.markReady(for: .notifications))
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
        XCTAssertEqual(flow.phase, .resolved(.denied))
        XCTAssertFalse(flow.advance(after: .camera))
        XCTAssertTrue(flow.advance(after: .notifications))
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.currentPermission)
        XCTAssertEqual(flow.phase, .complete)
    }

    func testPermissionFlowAcceptsExistingTerminalStatuses() {
        var flow = OnboardingPermissionFlow()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(flow.resolveWithoutRequest(.denied, for: .notifications))
        XCTAssertTrue(flow.advance(after: .notifications))
        XCTAssertTrue(flow.isComplete)
    }

    func testPermissionFlowRejectsNonterminalResolution() {
        var flow = OnboardingPermissionFlow()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertFalse(
            flow.resolveWithoutRequest(.notDetermined, for: .notifications)
        )
        XCTAssertFalse(
            flow.resolveWithoutRequest(.requesting, for: .notifications)
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .notifications))

        let requestingResultID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .notifications,
                requestID: requestingResultID
            )
        )
        XCTAssertFalse(
            flow.resolveRequest(
                for: .notifications,
                requestID: requestingResultID,
                status: .requesting
            )
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .notifications))

        let undeterminedResultID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .notifications,
                requestID: undeterminedResultID
            )
        )
        XCTAssertFalse(
            flow.resolveRequest(
                for: .notifications,
                requestID: undeterminedResultID,
                status: .notDetermined
            )
        )
        XCTAssertEqual(flow.phase, .ready)
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

    func testPermissionFlowCanCancelOnlyTheActiveRequest() {
        var flow = OnboardingPermissionFlow()
        let requestID = UUID()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(
            flow.beginRequest(
                for: .notifications,
                requestID: requestID
            )
        )
        XCTAssertFalse(
            flow.cancelRequest(
                for: .notifications,
                requestID: UUID()
            )
        )
        XCTAssertFalse(
            flow.cancelRequest(
                for: .camera,
                requestID: requestID
            )
        )
        XCTAssertTrue(
            flow.cancelRequest(
                for: .notifications,
                requestID: requestID
            )
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .notifications))
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
