import AVFoundation
import NearbyInteraction
import UserNotifications
import XCTest
@testable import SpyClash

final class OnboardingPermissionStatusMappingTests: XCTestCase {
    func testPermissionFlowRequiresEveryStepButNotEveryGrant() {
        var flow = OnboardingPermissionFlow()

        XCTAssertEqual(
            OnboardingPermissionFlow.order,
            [.notifications, .camera, .nearby]
        )
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
        XCTAssertEqual(flow.currentPermission, .camera)

        XCTAssertTrue(flow.resolveWithoutRequest(.unavailable, for: .camera))
        XCTAssertTrue(flow.advance(after: .camera))
        XCTAssertEqual(flow.currentPermission, .nearby)

        XCTAssertTrue(
            flow.resolveWithoutRequest(.deferredToRadar, for: .nearby)
        )
        XCTAssertTrue(flow.advance(after: .nearby))
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.currentPermission)
        XCTAssertEqual(flow.phase, .complete)
    }

    func testPermissionFlowAcceptsExistingTerminalStatuses() {
        var flow = OnboardingPermissionFlow()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(flow.resolveWithoutRequest(.denied, for: .notifications))
        XCTAssertTrue(flow.advance(after: .notifications))

        XCTAssertTrue(flow.resolveWithoutRequest(.granted, for: .camera))
        XCTAssertTrue(flow.advance(after: .camera))

        XCTAssertTrue(
            flow.resolveWithoutRequest(.deferredToRadar, for: .nearby)
        )
        XCTAssertTrue(flow.advance(after: .nearby))
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

    @MainActor
    func testNearbyAuthorizationIsDeferredToRadarWithoutOnboardingRequest() async {
        let coordinator = OnboardingPermissionCoordinator()

        XCTAssertEqual(coordinator.status(for: .nearby), .deferredToRadar)
        XCTAssertTrue(
            coordinator.status(for: .nearby).completesOnboardingStep
        )

        let didStartSystemRequest = await coordinator.request(.nearby)

        XCTAssertFalse(didStartSystemRequest)
        XCTAssertEqual(coordinator.status(for: .nearby), .deferredToRadar)
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

    func testRadarRangefinderPolicyUsesUnsupportedFallbackOnlyWithoutProbeCapability() {
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.initialState(canVerifyOnCurrentDevice: false),
            .unsupported
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.initialState(canVerifyOnCurrentDevice: true),
            .waitingForPeer
        )

        for state in [
            RadarRangefinderAccessState.waitingForPeer,
            .ready,
            .requesting,
            .denied,
            .unavailable
        ] {
            XCTAssertFalse(RadarRangefinderAccessPolicy.allowsRadarUse(state))
        }
        XCTAssertTrue(RadarRangefinderAccessPolicy.allowsRadarUse(.granted))
        XCTAssertTrue(RadarRangefinderAccessPolicy.allowsRadarUse(.unsupported))
    }

    func testRadarRangefinderPolicyRecognizesOnlyExactNearbyInteractionDenial() {
        let denial = NSError(
            domain: NIErrorDomain,
            code: NIError.Code.userDidNotAllow.rawValue
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterInvalidation(
                denial,
                canVerifyOnCurrentDevice: true
            ),
            .denied
        )

        let wrongDomain = NSError(
            domain: "SpyClashTests",
            code: NIError.Code.userDidNotAllow.rawValue
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterInvalidation(
                wrongDomain,
                canVerifyOnCurrentDevice: true
            ),
            .unavailable
        )

        let otherNearbyError = NSError(
            domain: NIErrorDomain,
            code: NIError.Code.invalidConfiguration.rawValue
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterInvalidation(
                otherNearbyError,
                canVerifyOnCurrentDevice: true
            ),
            .unavailable
        )
    }

    func testRadarRangefinderPolicyMapsUnsupportedRuntimeWithoutBlockingRadar() {
        let unsupported = NSError(
            domain: NIErrorDomain,
            code: NIError.Code.unsupportedPlatform.rawValue
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterInvalidation(
                unsupported,
                canVerifyOnCurrentDevice: true
            ),
            .unsupported
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterInvalidation(
                unsupported,
                canVerifyOnCurrentDevice: false
            ),
            .unsupported
        )
    }

    func testRadarRangefinderResumeWaitsForForegroundAndSuspensionEnded() {
        XCTAssertFalse(
            RadarRangefinderResumePolicy.canRun(
                wasSuspended: true,
                suspensionDidEnd: false,
                isApplicationActive: true
            )
        )
        XCTAssertFalse(
            RadarRangefinderResumePolicy.canRun(
                wasSuspended: true,
                suspensionDidEnd: true,
                isApplicationActive: false
            )
        )
        XCTAssertTrue(
            RadarRangefinderResumePolicy.canRun(
                wasSuspended: true,
                suspensionDidEnd: true,
                isApplicationActive: true
            )
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

#if DEBUG
    @MainActor
    func testRadarOutgoingInvitationIsBlockedUntilRangefinderAccessIsGranted() async throws {
        let radar = RadarNearbyService()
        radar.installPreviewRangingPeers()
        let peer = try XCTUnwrap(radar.peers.first)
        let room = GameRoom.previewRoom(status: "waiting")

        radar.installPreviewRangefinderAccessState(.denied)
        let deniedResult = await radar.toggleInvitation(peer, to: room)
        XCTAssertEqual(deniedResult, .unavailable)
        XCTAssertNil(radar.invitationState(for: peer.id))

        radar.installPreviewRangefinderAccessState(.granted)
        let grantedResult = await radar.toggleInvitation(peer, to: room)
        XCTAssertEqual(grantedResult, .sent)
        XCTAssertEqual(radar.invitationState(for: peer.id), .waiting)

        radar.stopScanning()
    }

    @MainActor
    func testRadarRetryRecoversPreviewScanAfterUnavailableTransport() throws {
        let user = try JSONDecoder().decode(
            SpyUser.self,
            from: Data(#"{"id":"radar-retry-user","email":"radar-retry@example.com"}"#.utf8)
        )
        let radar = RadarNearbyService()

        radar.configure(user: user, allowsTransport: true)
        radar.setApplicationActive(true)
        radar.installPreviewRangingPeers()
        radar.startScanning()
        radar.installPreviewScanFailure(message: "Local network unavailable")
        let rebuildCountBeforeRetry = radar.transportRebuildCountForTesting

        XCTAssertEqual(radar.scanState, .unavailable("Local network unavailable"))
        XCTAssertTrue(radar.peers.isEmpty)

        radar.stopScanning()
        radar.startScanning()

        XCTAssertEqual(radar.scanState, .unavailable("Local network unavailable"))
        XCTAssertGreaterThan(radar.transportRebuildCountForTesting, rebuildCountBeforeRetry)

        let rebuildCountBeforeExplicitRetry = radar.transportRebuildCountForTesting

        radar.retryScanning()

        XCTAssertEqual(radar.scanState, .scanning)
        XCTAssertFalse(radar.peers.isEmpty)
        XCTAssertGreaterThan(
            radar.transportRebuildCountForTesting,
            rebuildCountBeforeExplicitRetry
        )

        radar.stopScanning()
        radar.configure(user: nil, allowsTransport: false)
    }
#endif
}
