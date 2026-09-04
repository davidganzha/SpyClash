import AVFoundation
import Network
import NearbyInteraction
import UserNotifications
import XCTest
@testable import SpyClash

final class OnboardingPermissionStatusMappingTests: XCTestCase {
    func testPermissionFlowRequiresEveryStepAndLocalNetworkGrant() {
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

        XCTAssertFalse(flow.resolveWithoutRequest(.denied, for: .nearby))
        XCTAssertEqual(flow.phase, .ready)

        let deniedLocalNetworkRequestID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .nearby,
                requestID: deniedLocalNetworkRequestID
            )
        )
        XCTAssertFalse(
            flow.resolveRequest(
                for: .nearby,
                requestID: deniedLocalNetworkRequestID,
                status: .denied
            )
        )
        XCTAssertEqual(flow.phase, .ready)
        XCTAssertFalse(flow.advance(after: .nearby))

        let unavailableLocalNetworkRequestID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .nearby,
                requestID: unavailableLocalNetworkRequestID
            )
        )
        XCTAssertFalse(
            flow.resolveRequest(
                for: .nearby,
                requestID: unavailableLocalNetworkRequestID,
                status: .unavailable
            )
        )
        XCTAssertEqual(flow.phase, .ready)

        let grantedLocalNetworkRequestID = UUID()
        XCTAssertTrue(
            flow.beginRequest(
                for: .nearby,
                requestID: grantedLocalNetworkRequestID
            )
        )
        XCTAssertTrue(
            flow.resolveRequest(
                for: .nearby,
                requestID: grantedLocalNetworkRequestID,
                status: .granted
            )
        )
        XCTAssertTrue(flow.advance(after: .nearby))
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.currentPermission)
        XCTAssertEqual(flow.phase, .complete)
    }

    func testPermissionFlowAcceptsSimulatorUnsupportedStatus() {
        var flow = OnboardingPermissionFlow()

        XCTAssertTrue(flow.markReady(for: .notifications))
        XCTAssertTrue(flow.resolveWithoutRequest(.denied, for: .notifications))
        XCTAssertTrue(flow.advance(after: .notifications))

        XCTAssertTrue(flow.resolveWithoutRequest(.granted, for: .camera))
        XCTAssertTrue(flow.advance(after: .camera))

        XCTAssertTrue(
            flow.resolveWithoutRequest(.unsupported, for: .nearby)
        )
        XCTAssertTrue(flow.advance(after: .nearby))
        XCTAssertTrue(flow.isComplete)
    }

    func testVersionTwoUpgradeStartsAtOnlyRequiredLocalNetworkStep() {
        var flow = OnboardingPermissionFlow(startingAt: .nearby)

        XCTAssertEqual(flow.currentPermission, .nearby)
        XCTAssertEqual(flow.phase, .loading)
        XCTAssertFalse(flow.markReady(for: .notifications))
        XCTAssertFalse(flow.markReady(for: .camera))
        XCTAssertTrue(flow.markReady(for: .nearby))
        XCTAssertTrue(flow.resolveWithoutRequest(.granted, for: .nearby))
        XCTAssertTrue(flow.advance(after: .nearby))
        XCTAssertTrue(flow.isComplete)
        XCTAssertNil(flow.currentPermission)
    }

    func testOnlyRequiredLocalNetworkRejectsRecoverableFailures() {
        for permission in [
            OnboardingPermissionKind.notifications,
            .camera
        ] {
            XCTAssertTrue(
                OnboardingPermissionFlow.statusCompletesStep(
                    .denied,
                    for: permission
                )
            )
            XCTAssertTrue(
                OnboardingPermissionFlow.statusCompletesStep(
                    .unavailable,
                    for: permission
                )
            )
        }

        XCTAssertFalse(
            OnboardingPermissionFlow.statusCompletesStep(
                .denied,
                for: .nearby
            )
        )
        XCTAssertFalse(
            OnboardingPermissionFlow.statusCompletesStep(
                .unavailable,
                for: .nearby
            )
        )
        XCTAssertTrue(
            OnboardingPermissionFlow.statusCompletesStep(
                .granted,
                for: .nearby
            )
        )
        XCTAssertTrue(
            OnboardingPermissionFlow.statusCompletesStep(
                .unsupported,
                for: .nearby
            )
        )
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

    func testLocalNetworkPolicyDeniedUsesTN3179DNSServiceCode() {
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.localNetworkPolicyDeniedCode,
            -65_570
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.localNetworkDNSServiceError(-65_570),
            .denied
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.localNetworkDNSServiceError(-65_537),
            .unavailable
        )
    }

    func testLocalNetworkBrowserReadyIsGrantedAndSetupHasNoResult() {
        let policyDenied = NWError.dns(-65_570)

        XCTAssertEqual(
            OnboardingPermissionStatusMapping.localNetworkBrowserState(.ready),
            .granted
        )
        XCTAssertNil(
            OnboardingPermissionStatusMapping.localNetworkBrowserState(.setup)
        )
        XCTAssertNil(
            OnboardingPermissionStatusMapping.localNetworkBrowserState(.cancelled)
        )
        XCTAssertNil(
            OnboardingPermissionStatusMapping.localNetworkBrowserState(
                .waiting(policyDenied)
            )
        )
        XCTAssertTrue(
            OnboardingPermissionStatusMapping.isLocalNetworkPolicyDeniedWaiting(
                .waiting(policyDenied)
            )
        )
        XCTAssertFalse(
            OnboardingPermissionStatusMapping.isLocalNetworkPolicyDeniedWaiting(
                .waiting(.dns(-65_537))
            )
        )
        XCTAssertEqual(
            OnboardingPermissionStatusMapping.localNetworkBrowserState(
                .failed(policyDenied)
            ),
            .denied
        )
    }

    @MainActor
    func testLocalNetworkCoordinatorUsesPlatformAppropriateInitialState() async {
        XCTAssertEqual(
            OnboardingPermissionCoordinator.radarBonjourServiceType,
            "_spyclash-radar._tcp"
        )
        let coordinator = OnboardingPermissionCoordinator()

#if targetEnvironment(simulator)
        XCTAssertFalse(
            OnboardingPermissionCoordinator.canEvaluateLocalNetworkPrivacy
        )
        XCTAssertEqual(coordinator.status(for: .nearby), .unsupported)

        let didStartRequest = await coordinator.request(.nearby)

        XCTAssertTrue(didStartRequest)
        XCTAssertEqual(coordinator.status(for: .nearby), .unsupported)
#else
        XCTAssertTrue(
            OnboardingPermissionCoordinator.canEvaluateLocalNetworkPrivacy
        )
        XCTAssertEqual(coordinator.status(for: .nearby), .notDetermined)
#endif
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
    }

    func testAutomaticRangefinderProbeStartsOnlyFromConnectableStates() {
        XCTAssertTrue(
            RadarAutomaticRangefinderPolicy.shouldBeginProbe(from: .waitingForPeer)
        )
        XCTAssertTrue(
            RadarAutomaticRangefinderPolicy.shouldBeginProbe(from: .ready)
        )

        for state in [
            RadarRangefinderAccessState.requesting,
            .granted,
            .denied,
            .unavailable,
            .unsupported
        ] {
            XCTAssertFalse(
                RadarAutomaticRangefinderPolicy.shouldBeginProbe(from: state)
            )
        }
    }

    func testRadarTransportRetryUsesBoundedBackoff() {
        XCTAssertEqual(
            RadarTransportRetryPolicy.delayMilliseconds(afterFailureCount: 1),
            1_000
        )
        XCTAssertEqual(
            RadarTransportRetryPolicy.delayMilliseconds(afterFailureCount: 2),
            3_000
        )
        XCTAssertEqual(
            RadarTransportRetryPolicy.delayMilliseconds(afterFailureCount: 4),
            20_000
        )
        XCTAssertNil(
            RadarTransportRetryPolicy.delayMilliseconds(afterFailureCount: 0)
        )
        XCTAssertNil(
            RadarTransportRetryPolicy.delayMilliseconds(afterFailureCount: 5)
        )
    }

    func testRangingTokenExchangeRetryIsBounded() {
        XCTAssertEqual(
            RadarRangingTokenRetryPolicy.delayMilliseconds(afterFailureCount: 1),
            750
        )
        XCTAssertEqual(
            RadarRangingTokenRetryPolicy.delayMilliseconds(afterFailureCount: 2),
            2_000
        )
        XCTAssertNil(
            RadarRangingTokenRetryPolicy.delayMilliseconds(afterFailureCount: 3)
        )
    }

    func testLegacyBuild132RangingInvitationRetryIsBounded() {
        XCTAssertTrue(
            RadarLegacyRangingRetryPolicy.allowsAttempt(afterFailureCount: 0)
        )
        XCTAssertEqual(
            RadarLegacyRangingRetryPolicy.delayMilliseconds(afterFailureCount: 1),
            2_000
        )
        XCTAssertEqual(
            RadarLegacyRangingRetryPolicy.delayMilliseconds(afterFailureCount: 2),
            5_000
        )
        XCTAssertNil(
            RadarLegacyRangingRetryPolicy.delayMilliseconds(afterFailureCount: 3)
        )
        XCTAssertFalse(
            RadarLegacyRangingRetryPolicy.allowsAttempt(afterFailureCount: 3)
        )
    }

    func testRadarProtocolKeepsBidirectionalBuild132RangingCompatibility() {
        XCTAssertEqual(RadarPeerProtocolPolicy.advertisedVersion, "4")
        XCTAssertEqual(RadarPeerProtocolPolicy.acceptedVersions, Set(["4", "5"]))
        XCTAssertEqual(
            RadarPeerProtocolPolicy.connectionStrategy(
                peerVersion: "4",
                supportsPrecision: true,
                supportsRangefinderProbe: true,
                supportsConnectedRanging: false
            ),
            .legacyRanging
        )
        XCTAssertEqual(
            RadarPeerProtocolPolicy.connectionStrategy(
                peerVersion: "4",
                supportsPrecision: true,
                supportsRangefinderProbe: true,
                supportsConnectedRanging: true
            ),
            .presence
        )
        XCTAssertEqual(
            RadarPeerProtocolPolicy.connectionStrategy(
                peerVersion: "5",
                supportsPrecision: true,
                supportsRangefinderProbe: true,
                supportsConnectedRanging: true
            ),
            .presence
        )
        XCTAssertEqual(
            RadarPeerProtocolPolicy.connectionStrategy(
                peerVersion: "4",
                supportsPrecision: false,
                supportsRangefinderProbe: false,
                supportsConnectedRanging: false
            ),
            .presence
        )
    }

    func testSimultaneousRangefinderProbesChooseOneStableInitiator() {
        XCTAssertEqual(
            RadarRangefinderProbeCollisionPolicy.decision(
                localPeerID: "spy-a",
                localProbeID: "probe-z",
                incomingPeerID: "spy-b",
                incomingProbeID: "probe-a"
            ),
            .continueLocalProbe
        )
        XCTAssertEqual(
            RadarRangefinderProbeCollisionPolicy.decision(
                localPeerID: "spy-b",
                localProbeID: "probe-a",
                incomingPeerID: "spy-a",
                incomingProbeID: "probe-z"
            ),
            .yieldAndRespond
        )
    }

    func testNewRangingGenerationSupersedesOldBeforeCollisionTieBreak() {
        XCTAssertTrue(
            RadarRangingExchangeCollisionPolicy.shouldAcceptIncoming(
                currentInitiatorPeerID: "spy-a",
                currentExchangeID: "old",
                currentSupersedesExchangeID: nil,
                incomingInitiatorPeerID: "spy-z",
                incomingExchangeID: "new",
                incomingSupersedesExchangeID: "old"
            )
        )
        XCTAssertFalse(
            RadarRangingExchangeCollisionPolicy.shouldAcceptIncoming(
                currentInitiatorPeerID: "spy-a",
                currentExchangeID: "new",
                currentSupersedesExchangeID: "old",
                incomingInitiatorPeerID: "spy-z",
                incomingExchangeID: "old",
                incomingSupersedesExchangeID: nil
            )
        )
    }

    func testConcurrentRangingRestartsUseStableTieBreak() {
        XCTAssertFalse(
            RadarRangingExchangeCollisionPolicy.shouldAcceptIncoming(
                currentInitiatorPeerID: "spy-a",
                currentExchangeID: "restart-a",
                currentSupersedesExchangeID: "old",
                incomingInitiatorPeerID: "spy-b",
                incomingExchangeID: "restart-b",
                incomingSupersedesExchangeID: "old"
            )
        )
        XCTAssertTrue(
            RadarRangingExchangeCollisionPolicy.shouldAcceptIncoming(
                currentInitiatorPeerID: "spy-b",
                currentExchangeID: "restart-b",
                currentSupersedesExchangeID: "old",
                incomingInitiatorPeerID: "spy-a",
                incomingExchangeID: "restart-a",
                incomingSupersedesExchangeID: "old"
            )
        )
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

    func testTransientRangingFailureDoesNotEraseProvenRangefinderGrant() {
        let transientFailure = NSError(
            domain: NIErrorDomain,
            code: NIError.Code.invalidConfiguration.rawValue
        )

        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterRangingInvalidation(
                transientFailure,
                currentState: .granted,
                hasOtherActiveContext: false,
                canVerifyOnCurrentDevice: true
            ),
            .granted
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterRangingInvalidation(
                transientFailure,
                currentState: .requesting,
                hasOtherActiveContext: true,
                canVerifyOnCurrentDevice: true
            ),
            .requesting
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterRangingInvalidation(
                transientFailure,
                currentState: .requesting,
                hasOtherActiveContext: false,
                canVerifyOnCurrentDevice: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterTransientPeerFailure(
                currentState: .granted,
                hasOtherActiveContext: false
            ),
            .granted
        )
        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterTransientPeerFailure(
                currentState: .requesting,
                hasOtherActiveContext: true
            ),
            .requesting
        )
    }

    func testExactRangingDenialOverridesExistingGrant() {
        let denial = NSError(
            domain: NIErrorDomain,
            code: NIError.Code.userDidNotAllow.rawValue
        )

        XCTAssertEqual(
            RadarRangefinderAccessPolicy.stateAfterRangingInvalidation(
                denial,
                currentState: .granted,
                hasOtherActiveContext: true,
                canVerifyOnCurrentDevice: true
            ),
            .denied
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
    func testRadarOutgoingInvitationRemainsAvailableWithoutPreciseDistance() async throws {
        let radar = RadarNearbyService()
        radar.installPreviewRangingPeers()
        let peer = try XCTUnwrap(radar.peers.first)
        let room = GameRoom.previewRoom(status: "waiting")

        radar.installPreviewRangefinderAccessState(.denied)
        let deniedResult = await radar.toggleInvitation(peer, to: room)
        XCTAssertEqual(deniedResult, .sent)
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
